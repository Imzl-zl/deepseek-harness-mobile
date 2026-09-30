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

/** 握手签名的被签内容（transcript 的规范串）。 */
export function transcriptOf({ info, pairingId, helloBox, helloAckBox }) {
  return Buffer.from(`dsh-mobile/v1|${info}|${pairingId}|${helloBox}|${helloAckBox}`, 'utf8')
}

export function signTranscript(seedHex, transcript) {
  return h(sign(null, transcript, keyPairFrom('ed25519', seedHex).priv))
}
