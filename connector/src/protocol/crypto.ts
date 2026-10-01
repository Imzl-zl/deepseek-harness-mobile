/**
 * 握手、HKDF、AEAD、fc 计数器（契约 §4）。
 *
 * 为什么本层要单独有已知答案向量：协议 fixtures 有意不测加密（那边的 `seal` 是可逆占位），
 * 但两侧实现（connector 用 TS、手机端用 Dart）各自实现 X25519 / Ed25519 / HKDF / AEAD 时
 * 极易漂移 —— 而漂移的表现是"连不上"，不是"断言失败"。所以 `protocol/vectors/` 给出
 * 固定输入 → 期望输出，两侧都必须跑通同一批。
 *
 * 曲线与 AEAD 用 Node 内建 `node:crypto`，不引入第三方密码学依赖。
 *
 * 三条不可协商的规则：
 *
 * 1. **nonce = `fc` 的 96 位大端**，`fc` 从 0 开始每帧 +1、**不重用**（契约 §4.2）。
 *    不用随机 nonce：唯一性由计数器保证，不依赖随机数质量，也省掉每帧一次系统调用。
 * 2. **每次握手必须新生成临时密钥对**，不得跨连接复用。复用会让 `fc` 从 0 重数 ⇒ nonce 重用
 *    ⇒ 直接破掉 AEAD。握手失败后的重试同样要重新生成。
 * 3. **AAD 用 `frame.ts` 的 `aadOf`**，两端必须字节一致；不要在这里另拼一份。
 */
import {
  createCipheriv,
  createDecipheriv,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  hkdfSync,
  sign,
  type KeyObject,
} from 'node:crypto'

import { aadOf, type AadFields } from './frame.js'
import { ProtocolError } from './errors.js'

/** 密钥派生的 info 串（契约 §4.1）。 */
export const HANDSHAKE_INFO = 'dsh-mobile/v1'
export const KEY_INFO = 'dsh-mobile/v1/keys'
export const TRANSCRIPT_INFO = 'dsh-mobile/v1'
export const AEAD_ALGORITHM = 'chacha20-poly1305'
export const AEAD_TAG_BYTES = 16
export const MASTER_KEY_BYTES = 64

/** PKCS#8 前缀：X25519 = 1.3.101.110，Ed25519 = 1.3.101.112。 */
const PKCS8_PREFIX = {
  x25519: Buffer.from('302e020100300506032b656e04220420', 'hex'),
  ed25519: Buffer.from('302e020100300506032b657004220420', 'hex'),
} as const

export type Curve = keyof typeof PKCS8_PREFIX

const toHex = (bytes: Uint8Array): string => Buffer.from(bytes).toString('hex')
const fromHex = (hex: string): Buffer => Buffer.from(hex, 'hex')

/**
 * 只表达「能调一次 `setAAD(aad)`」的最小结构类型。
 *
 * 存在的理由：`@types/node` 把 ChaCha20-Poly1305 的 `setAAD` 声明成**必须**带
 * `{ plaintextLength }`，而那只对 CCM / OCB 有意义 —— Node 文档明说 `chacha20-poly1305`
 * 不需要它。解密侧更是填不出这个值：明文长度正是我们要解出来的东西。
 * 参考实现（`protocol/tools/vectors-core.mjs`）同样是单参调用，运行时行为一致。
 *
 * 所以这里断言到本类型，而**不是**为了过编译塞一个假的长度值。
 */
interface AeadCodec {
  setAAD(buffer: NodeJS.ArrayBufferView, options?: unknown): unknown
}

export interface KeyPair {
  readonly privateKey: KeyObject
  /** 32 字节原始公钥的十六进制。 */
  readonly publicKeyHex: string
}

/**
 * 从 32 字节种子构造密钥对。
 *
 * 设备身份是**一个 32 字节主种子**，经 HKDF 派生身份签名密钥与静态 DH 密钥
 * （契约 §4.1）—— 只存一个 secret，三端安全存储才统一得起来。
 */
export function keyPairFrom(curve: Curve, seedHex: string): KeyPair {
  const seed = fromHex(seedHex)
  if (seed.length !== 32) throw new Error(`${curve} 种子必须是 32 字节，收到 ${seed.length}`)
  const privateKey = createPrivateKey({
    key: Buffer.concat([PKCS8_PREFIX[curve], seed]),
    format: 'der',
    type: 'pkcs8',
  })
  // SPKI DER 的前 12 字节是算法标识，其后即 32 字节原始公钥。
  const spki = createPublicKey(privateKey).export({ format: 'der', type: 'spki' })
  return { privateKey, publicKeyHex: toHex(spki.subarray(12)) }
}

/** nonce = `fc` 的 96 位大端（契约 §4.2）。 */
export function nonceOf(fc: number): Buffer {
  if (!Number.isSafeInteger(fc) || fc < 0) throw new Error('fc 必须是非负安全整数')
  const buf = Buffer.alloc(12)
  buf.writeBigUInt64BE(BigInt(fc), 4)
  return buf
}

export interface SealedBox {
  ciphertextHex: string
  tagHex: string
}

export function seal(input: {
  keyHex: string
  fc: number
  aadFields: AadFields
  plaintext: string
}): SealedBox {
  const cipher = createCipheriv(AEAD_ALGORITHM, fromHex(input.keyHex), nonceOf(input.fc), {
    authTagLength: AEAD_TAG_BYTES,
  })
  // 见 `AeadCodec` 的说明：不为过编译塞假的 plaintextLength。
  ;(cipher as unknown as AeadCodec).setAAD(aadOf(input.aadFields))
  const ciphertext = Buffer.concat([
    cipher.update(Buffer.from(input.plaintext, 'utf8')),
    cipher.final(),
  ])
  return { ciphertextHex: toHex(ciphertext), tagHex: toHex(cipher.getAuthTag()) }
}

/**
 * 解封。**AAD 或 `fc` 不匹配时抛错** —— 这正是 nonce 与 AAD 规则的负向证据，
 * 调用方不得把异常吞成"内容为空"（那等于把篡改当成合法帧）。
 */
export function open(input: {
  keyHex: string
  fc: number
  aadFields: AadFields
  ciphertextHex: string
  tagHex: string
}): string {
  const decipher = createDecipheriv(AEAD_ALGORITHM, fromHex(input.keyHex), nonceOf(input.fc), {
    authTagLength: AEAD_TAG_BYTES,
  })
  // 见 `AeadCodec` 的说明：解密侧尤其不能塞 plaintextLength。
  ;(decipher as unknown as AeadCodec).setAAD(aadOf(input.aadFields))
  decipher.setAuthTag(fromHex(input.tagHex))
  return Buffer.concat([
    decipher.update(fromHex(input.ciphertextHex)),
    decipher.final(),
  ]).toString('utf8')
}

export interface HandshakeInput {
  /** 手机静态 DH 种子。 */
  seedA: string
  /** 电脑静态 DH 种子。 */
  seedB: string
  /** 手机临时 DH 种子（**每连接新生成**）。 */
  ephSeedA: string
  /** 电脑临时 DH 种子（**每连接新生成**）。 */
  ephSeedB: string
  nonceA: string
  nonceB: string
  info: string
  pairingId: string
}

export interface HandshakeDerivation {
  pubA: string
  pubB: string
  ephPubA: string
  ephPubB: string
  ss1: string
  ss2: string
  ss3: string
  master: string
  kA2B: string
  kB2A: string
}

/**
 * 握手密钥派生（契约 §4.1）。三份共享密钥缺一不可：
 * `ss1` = 手机临时 × 电脑静态、`ss2` = 手机静态 × 电脑临时、`ss3` = 双方临时。
 *
 * **`ss3` 是前向保密的来源**：长期种子泄露也解不开已结束连接的历史记录。
 * 去掉它就退化成普通的静态-静态协商，且 fixtures 与向量都不会报错。
 */
export function deriveHandshake(input: HandshakeInput): HandshakeDerivation {
  const staticA = keyPairFrom('x25519', input.seedA)
  const staticB = keyPairFrom('x25519', input.seedB)
  const ephA = keyPairFrom('x25519', input.ephSeedA)
  const ephB = keyPairFrom('x25519', input.ephSeedB)

  const ss1 = diffieHellman({
    privateKey: ephA.privateKey,
    publicKey: createPublicKey(staticB.privateKey),
  })
  const ss2 = diffieHellman({
    privateKey: staticA.privateKey,
    publicKey: createPublicKey(ephB.privateKey),
  })
  const ss3 = diffieHellman({
    privateKey: ephA.privateKey,
    publicKey: createPublicKey(ephB.privateKey),
  })

  const ikm = Buffer.concat([ss1, ss2, ss3])
  const salt = Buffer.concat([fromHex(input.nonceA), fromHex(input.nonceB)])
  const info = Buffer.from(`${input.info}|${input.pairingId}`, 'utf8')
  const master = Buffer.from(hkdfSync('sha256', ikm, salt, info, MASTER_KEY_BYTES))

  return {
    pubA: staticA.publicKeyHex,
    pubB: staticB.publicKeyHex,
    ephPubA: ephA.publicKeyHex,
    ephPubB: ephB.publicKeyHex,
    ss1: toHex(ss1),
    ss2: toHex(ss2),
    ss3: toHex(ss3),
    master: toHex(master),
    kA2B: toHex(master.subarray(0, 32)),
    kB2A: toHex(master.subarray(32, 64)),
  }
}

/** 握手签名的被签内容（transcript 的规范串，契约 §4.1）。 */
export function transcriptOf(input: {
  info: string
  pairingId: string
  helloBox: string
  helloAckBox: string
}): Buffer {
  return Buffer.from(
    `${TRANSCRIPT_INFO}|${input.info}|${input.pairingId}|${input.helloBox}|${input.helloAckBox}`,
    'utf8',
  )
}

/** 用 Ed25519 身份密钥对 transcript 签名。验签失败即 `protocol/not-paired` 并断开。 */
export function signTranscript(edSeedHex: string, transcript: Buffer): string {
  return toHex(sign(null, transcript, keyPairFrom('ed25519', edSeedHex).privateKey))
}

/** 发送方向的帧计数器（契约 §4.2）。 */
export interface SendCounter {
  /** 取下一个 `fc` 并推进。**它是 nonce 的来源，绝不能回退或重用。** */
  next(): number
  /** 已经发出去多少帧。 */
  readonly value: number
}

/**
 * `fc` 从 0 开始、每发一帧 +1（含 `ping` / `credit`）。
 *
 * 刻意用计数器而不是随机 nonce：唯一性由单调性保证，不依赖随机数质量，
 * 也省掉每帧一次系统调用。
 */
export function createSendCounter(): SendCounter {
  let next = 0
  return {
    next: () => next++,
    get value() {
      return next
    },
  }
}

/** 接收方向的重放防护（契约 §4.2）。 */
export interface ReplayGuard {
  /** 接受一个 `fc`；重放或重复投递时抛 `ProtocolError('protocol/replay')`。 */
  accept(fc: number): void
  readonly maxFc: number
}

/**
 * 接收方维护 `maxFc`：
 * - `fc < maxFc` → 重放，拒绝；
 * - `fc == maxFc` → 只可能来自重复投递，**同样拒绝**；
 * - `fc > maxFc` → 接受并推进。
 *
 * 本层不允许乱序（单 TCP 流本来就保序），任何乱序都按攻击或故障处理。
 * 握手每连接换密钥，所以旧连接的帧必然解不开 —— 这一层是纵深防御，不是唯一防线。
 */
export function createReplayGuard(): ReplayGuard {
  let maxFc = -1
  return {
    accept(fc) {
      if (!Number.isSafeInteger(fc) || fc < 0) {
        throw new ProtocolError('protocol/bad-frame', `fc 必须是非负安全整数，收到 ${fc}`)
      }
      if (fc <= maxFc) {
        throw new ProtocolError('protocol/replay', `fc=${fc} 不大于已见最大 ${maxFc}`)
      }
      maxFc = fc
    },
    get maxFc() {
      return maxFc
    },
  }
}
