/**
 * 跨端密码学向量的核心计算（生成与校验共用）。
 *
 * 为什么需要它：协议层有意不测加密（fixtures 里的 seal 是可逆占位），
 * 但两侧实现（connector 用 TS、手机端用 Dart）各自实现 X25519 / Ed25519 / HKDF / AEAD 时
 * 极易漂移。这里给出**固定输入 → 期望输出**的已知答案，两侧都必须跑通。
 *
 * 曲线与 AEAD 用 Node 内建实现（node:crypto），不引入任何依赖。
 */
import { createPrivateKey, createPublicKey, diffieHellman, hkdfSync, sign, createCipheriv, createDecipheriv } from 'node:crypto'

/** PKCS#8 前缀：X25519 = 1.3.101.110，Ed25519 = 1.3.101.112。 */
const PKCS8 = {
  x25519: Buffer.from('302e020100300506032b656e04220420', 'hex'),
  ed25519: Buffer.from('302e020100300506032b657004220420', 'hex'),
}

const h = (bytes) => Buffer.from(bytes).toString('hex')
const unb = (hex) => Buffer.from(hex, 'hex')

export function keyPairFrom(alg, seedHex) {
  const seed = unb(seedHex)
  if (seed.length !== 32) throw new Error(`${alg} 种子必须是 32 字节`)
  const priv = createPrivateKey({ key: Buffer.concat([PKCS8[alg], seed]), format: 'der', type: 'pkcs8' })
  const pub = createPublicKey(priv)
  const rawPub = alg === 'x25519'
    ? pub.export({ format: 'der', type: 'spki' }).subarray(12)     // SPKI 头 12 字节
    : pub.export({ format: 'der', type: 'spki' }).subarray(12)
  return { priv, pubHex: h(rawPub) }
}

/** nonce = fc 的 96 位大端（契约 §4.2）。 */
export function nonceOf(fc) {
  if (!Number.isSafeInteger(fc) || fc < 0) throw new Error('fc 必须是非负安全整数')
  const buf = Buffer.alloc(12)
  buf.writeBigUInt64BE(BigInt(fc), 4)
  return buf
}

/** AAD 规范化（契约 §3）：v|t|id|sid|seq|fc，缺字段用空串。 */
export function aadOf({ v = 1, t, id = '', sid = '', seq = '', fc = '' }) {
  return Buffer.from([v, t, id, sid, seq, fc].join('|'), 'utf8')
}

export function seal({ keyHex, fc, aadFields, plaintext }) {
  const cipher = createCipheriv('chacha20-poly1305', unb(keyHex), nonceOf(fc), { authTagLength: 16 })
  cipher.setAAD(aadOf(aadFields))
  const ct = Buffer.concat([cipher.update(Buffer.from(plaintext, 'utf8')), cipher.final()])
  return { ciphertextHex: h(ct), tagHex: h(cipher.getAuthTag()) }
}

export function open({ keyHex, fc, aadFields, ciphertextHex, tagHex }) {
  const decipher = createDecipheriv('chacha20-poly1305', unb(keyHex), nonceOf(fc), { authTagLength: 16 })
  decipher.setAAD(aadOf(aadFields))
  decipher.setAuthTag(unb(tagHex))
  return Buffer.concat([decipher.update(unb(ciphertextHex)), decipher.final()]).toString('utf8')
}

/** 认证标签长度。 */
export const TAG_BYTES = 16

/**
 * 箱的容器格式（契约 §3）：`base64url(密文 ‖ tag)`，无填充。
 *
 * 它是**线上格式的一部分**，所以和曲线/AEAD 一样进向量：两端各自拼一遍再比对 ——
 * 各写各的容器（一个用十六进制、一个带分隔符）在单侧测试里都是绿的，
 * 只有真机互通时才断，而那时的症状是"解不开"。
 */
export function packBox({ ciphertextHex, tagHex }) {
  return Buffer.concat([unb(ciphertextHex), unb(tagHex)]).toString('base64url')
}

/** 箱 → 密文与标签。长度不足即抛（调用方按 `protocol/bad-frame` 处理）。 */
export function unpackBox(box) {
  const raw = Buffer.from(box, 'base64url')
  if (raw.length < TAG_BYTES) throw new Error(`箱只有 ${raw.length} 字节，不足一个认证标签`)
  return {
    ciphertextHex: raw.subarray(0, raw.length - TAG_BYTES).toString('hex'),
    tagHex: raw.subarray(raw.length - TAG_BYTES).toString('hex'),
  }
}

/** 握手密钥派生（契约 §4.1）：X3DH 骨架，含 eph×eph ⇒ 前向保密。 */
export function deriveHandshake(input) {
  const A = keyPairFrom('x25519', input.seedA)
  const B = keyPairFrom('x25519', input.seedB)
  const ephA = keyPairFrom('x25519', input.ephSeedA)
  const ephB = keyPairFrom('x25519', input.ephSeedB)

  const ss1 = diffieHellman({ privateKey: ephA.priv, publicKey: B.priv ? createPublicKey(B.priv) : B.pub })
  const ss2 = diffieHellman({ privateKey: A.priv, publicKey: createPublicKey(ephB.priv) })
  const ss3 = diffieHellman({ privateKey: ephA.priv, publicKey: createPublicKey(ephB.priv) })
  const ikm = Buffer.concat([Buffer.from(ss1), Buffer.from(ss2), Buffer.from(ss3)])
  const salt = Buffer.concat([unb(input.nonceA), unb(input.nonceB)])
  const master = Buffer.from(hkdfSync('sha256', ikm, salt, Buffer.from(`${input.info}|${input.pairingId}`, 'utf8'), 64))

  return {
    pubA: A.pubHex,
    pubB: B.pubHex,
    ephPubA: ephA.pubHex,
    ephPubB: ephB.pubHex,
    ss1: h(ss1),
    ss2: h(ss2),
    ss3: h(ss3),
    master: h(master),
    kA2B: h(master.subarray(0, 32)),
    kB2A: h(master.subarray(32, 64)),
  }
}

/**
 * 设备身份的派生（契约 §4.1）：**一个 32 字节主种子**分成两把长期密钥。
 *
 * 只存一个 secret 的理由是三端安全存储能统一（HUKS / Keychain / Keystore 都只认一把）。
 * 盐为空 —— 与 RFC 5869 里"盐缺省即全零"等价；`info` 的两个串是**域分隔**，
 * 改一个字就是另一套密钥（所以它进了向量，不是实现细节）。
 */
export function deriveIdentity(masterSeedHex) {
  const seed = unb(masterSeedHex)
  if (seed.length !== 32) throw new Error(`主种子必须是 32 字节（当前 ${seed.length}）`)
  const derive = (info) => Buffer.from(hkdfSync('sha256', seed, Buffer.alloc(0), Buffer.from(info, 'utf8'), 32))
  const edSeed = derive('id-sign')
  const dhSeed = derive('id-dh')
  return {
    edSeed: h(edSeed),
    dhSeed: h(dhSeed),
    edPub: keyPairFrom('ed25519', h(edSeed)).pubHex,
    dhPub: keyPairFrom('x25519', h(dhSeed)).pubHex,
  }
}

/** transcript 的固定前缀。改动它等于改协议版本。 */
export const TRANSCRIPT_LABEL = 'dsh-mobile/v1'

/**
 * 握手签名的被签内容（契约 §4.1）：**从字段拼**，不拼两帧 `box`。
 *
 * 拼 `box` 是循环定义 —— `sigB` 就在 `hello-ack` 的 `box` 里，而 transcript 又要被 `sigB` 签。
 * 顺序是协议的一部分：换顺序不会报错，只会让两侧算出不同 transcript（症状是"公钥被替换"）。
 *
 * 定案过程与另一个被否的方案见 `.agents/notes/implemented/2026-10-01-handshake-third-frame.md`
 */
export function transcriptOf({ ephPubA, devId, nonceA, ephPubB, pcId, nonceB }) {
  return Buffer.from(
    [TRANSCRIPT_LABEL, 'hello', ephPubA, devId, nonceA, 'hello-ack', ephPubB, pcId, nonceB].join('|'),
    'utf8',
  )
}

export function signTranscript(seedHex, transcript) {
  return h(sign(null, transcript, keyPairFrom('ed25519', seedHex).priv))
}
