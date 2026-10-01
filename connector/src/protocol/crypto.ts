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
  randomBytes,
  sign,
  type KeyObject,
} from 'node:crypto'

import { aadOf, type AadFields } from './frame.js'
import { ProtocolError } from './errors.js'

/**
 * 会话密钥派生的 `info` 前缀（契约 §4.1）。实际传给 HKDF 的是
 * `` `${KEY_INFO}|${pairingId}` `` —— 配对标识参与派生，所以两端必须用同一个。
 *
 * transcript 的标签（`dsh-mobile/v1`）**不在这里**：它的唯一出处是
 * `handshake-frames.ts` 的 `TRANSCRIPT_LABEL`，两处各写一遍就会漂移。
 */
export const KEY_INFO = 'dsh-mobile/v1/keys'
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

/** X25519 原始公钥（32 字节）的 SPKI 前缀。 */
const X25519_SPKI_PREFIX = Buffer.from('302a300506032b656e032100', 'hex')
/** Ed25519 原始公钥（32 字节）的 SPKI 前缀。 */
const ED25519_SPKI_PREFIX = Buffer.from('302a300506032b6570032100', 'hex')

/**
 * 从 32 字节原始公钥构造 `KeyObject`。
 *
 * 线上传的是**裸公钥**（`hello` / `hello-ack` 里的 `ephPubA` / `ephPubB`），
 * 而 `node:crypto` 只接受 DER/PEM —— 所以两端都必须做这层包装，且包装必须一致。
 * 少了这一层，`diffieHellman` 会直接抛，症状是"握手莫名其妙失败"。
 */
export function publicKeyFrom(curve: Curve, hex: string): KeyObject {
  const raw = fromHex(hex)
  if (raw.length !== 32) throw new Error(`${curve} 公钥必须是 32 字节，收到 ${raw.length}`)
  return createPublicKey({
    key: Buffer.concat([curve === 'x25519' ? X25519_SPKI_PREFIX : ED25519_SPKI_PREFIX, raw]),
    format: 'der',
    type: 'spki',
  })
}

/** 身份派生的两个 `info` 串（契约 §4.1）。改一个字就是另一套长期密钥。 */
export const IDENTITY_INFO = { sign: 'id-sign', dh: 'id-dh' } as const

export interface IdentityKeys {
  /** 派生出的 Ed25519 种子（`signTranscript` 收的是种子，不是 `KeyObject`）。 */
  signSeedHex: string
  /** 派生出的 X25519 种子。 */
  dhSeedHex: string
  /** Ed25519 身份签名密钥对：签/验 transcript。 */
  sign: KeyPair
  /** X25519 静态 DH 密钥对：参与 §4.1 的三份共享密钥。 */
  dh: KeyPair
}

/**
 * 设备身份（契约 §4.1）：**一个 32 字节主种子**经 HKDF 分成两把长期密钥。
 *
 * 为什么只存一个 secret：三端的安全存储（HUKS / Keychain / Keystore）只认"一把密钥"
 * 这件事最好统一；分成两把再各存一次，等于把同一份风险抄两遍。
 *
 * `salt` 为空 —— 与 RFC 5869 的"盐缺省即全零"等价。两个 `info` 是**域分隔**：
 * 少了它，签名密钥与 DH 密钥会是同一把（`deriveIdentity` 的测试专门拦这个）。
 *
 * 与 `protocol/tools/vectors-core.mjs` 的 `deriveIdentity` 必须逐字节一致 ——
 * 手机端（Dart）实现也要复现同一批向量。
 */
export function deriveIdentity(masterSeedHex: string): IdentityKeys {
  const seed = fromHex(masterSeedHex)
  if (seed.length !== 32) throw new Error(`主种子必须是 32 字节，收到 ${seed.length}`)
  const derive = (info: string): string =>
    toHex(Buffer.from(hkdfSync('sha256', seed, Buffer.alloc(0), Buffer.from(info, 'utf8'), 32)))
  const signSeedHex = derive(IDENTITY_INFO.sign)
  const dhSeedHex = derive(IDENTITY_INFO.dh)
  return {
    signSeedHex,
    dhSeedHex,
    sign: keyPairFrom('ed25519', signSeedHex),
    dh: keyPairFrom('x25519', dhSeedHex),
  }
}

/**
 * 新身份的主种子。**只在首次配对时生成一次**（契约 §12.1 第 1 步），生成即落安全存储。
 *
 * 放在协议层而不是适配层：它没有 DSH 依赖，而"随机数从哪来"是实现细节，
 * 不该和"种子存哪"（适配层的事）混在一起。
 */
export function generateIdentitySeed(): string {
  return toHex(randomBytes(32))
}

export interface SessionKeyInput {
  /**
   * 本端在握手里的角色。**这个参数是必需的，不是冗余信息**：
   * `ss1` 的定义是「发起方临时 × 应答方静态」，而同一个 DH 表达式
   * `DH(自己的临时, 对端的静态)` 在两侧算出的分别是 `ss1` 与 `ss2`。
   * 不告诉函数角色，就无从决定拼接顺序 —— 而顺序错了不会报错，
   * 只会让两侧主密钥不同（症状：握手看起来走完，AEAD 永远解不开）。
   */
  role: 'initiator' | 'responder'
  /** 自己的静态私钥。 */
  ownStaticPrivate: KeyObject
  /** 自己的临时私钥（**每连接新生成**）。 */
  ownEphemeralPrivate: KeyObject
  /** 对端的静态公钥（电脑侧从设备表按 `devId` 查出来；手机侧从配对结果拿到）。 */
  peerStaticPublicHex: string
  /** 对端的临时公钥（来自对端的握手帧）。 */
  peerEphemeralPublicHex: string
  nonceA: string
  nonceB: string
  info: string
  pairingId: string
}

export interface SessionKeys {
  ss1: string
  ss2: string
  ss3: string
  master: string
  /** 手机 → 电脑方向的 AEAD 密钥。 */
  kA2B: string
  /** 电脑 → 手机方向。 */
  kB2A: string
}

/**
 * 会话密钥派生（契约 §4.1）—— **两侧各自调用这一个函数**。
 *
 * 这是握手能成立的关键：发起方与应答方手上的材料不同（各自的私钥 + 对方的公钥），
 * 但三份共享密钥算出来必须一样。三份的定义是**角色相关**的：
 *
 * ```text
 * ss1 = 发起方临时 × 应答方静态        // 手机 eph × 电脑 static
 * ss2 = 发起方静态 × 应答方临时        // 手机 static × 电脑 eph
 * ss3 = 双方临时                       // 与角色无关
 * ```
 *
 * 所以本函数必须知道 `role`：两侧各自算的是「自己的临时 × 对端的静态」，而它
 * 在发起方是 `ss1`、在应答方是 `ss2`。顺序反了不会报错，只会让两侧派生出不同的
 * 主密钥 —— 这正是 `tests/session-keys.test.ts` 的「双侧派生」用例要拦的东西。
 *
 * 方向约定（`kA2B` / `kB2A`）只与 `nonceA||nonceB` 的顺序有关，与角色无关，
 * 所以两侧必须用同一个顺序，否则会派生出互为反向的两把密钥。
 */
export function deriveSessionKeys(input: SessionKeyInput): SessionKeys {
  /** 自己的临时 × 对端的静态。 */
  const ephOwnStaticPeer = diffieHellman({
    privateKey: input.ownEphemeralPrivate,
    publicKey: publicKeyFrom('x25519', input.peerStaticPublicHex),
  })
  /** 自己的静态 × 对端的临时。 */
  const staticOwnEphPeer = diffieHellman({
    privateKey: input.ownStaticPrivate,
    publicKey: publicKeyFrom('x25519', input.peerEphemeralPublicHex),
  })
  /** 双方临时（与角色无关）。 */
  const ephEph = diffieHellman({
    privateKey: input.ownEphemeralPrivate,
    publicKey: publicKeyFrom('x25519', input.peerEphemeralPublicHex),
  })

  // 发起方：`ephOwnStaticPeer` 就是 ss1。应答方：它其实是 ss2（对调前两位）。
  const [ss1Raw, ss2Raw] = input.role === 'initiator'
    ? [ephOwnStaticPeer, staticOwnEphPeer]
    : [staticOwnEphPeer, ephOwnStaticPeer]

  const ikm = Buffer.concat([ss1Raw, ss2Raw, ephEph])
  const salt = Buffer.concat([fromHex(input.nonceA), fromHex(input.nonceB)])
  const master = Buffer.from(
    hkdfSync('sha256', ikm, salt, Buffer.from(`${input.info}|${input.pairingId}`, 'utf8'), MASTER_KEY_BYTES),
  )

  return {
    ss1: toHex(ss1Raw),
    ss2: toHex(ss2Raw),
    ss3: toHex(ephEph),
    master: toHex(master),
    kA2B: toHex(master.subarray(0, 32)),
    kB2A: toHex(master.subarray(32, 64)),
  }
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

/** 握手签名的被签内容见 `handshake-frames.ts` 的 `transcriptFromFields`（契约 §4.1）。 */

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
