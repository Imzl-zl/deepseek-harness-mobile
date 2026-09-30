/**
 * 生成跨端密码学向量（机生成，勿手改）。
 *
 * 跑法：node protocol/tools/gen-vectors.mjs
 *
 * 产物：protocol/vectors/handshake.json、protocol/vectors/aead.json
 * 校验：node protocol/verify-vectors.mjs（重算并比对，手改会红）
 *
 * 为什么用 node:crypto 生成：曲线、HKDF 与 AEAD 都必须是"独立于我们两侧实现"的第三方结果，
 * 否则向量只是把我们自己的假设抄了两遍。两侧实现（TS / Dart）都必须能复现这里的结果。
 */
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { deriveHandshake, seal, signTranscript, keyPairFrom } from './vectors-core.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const OUT = join(HERE, '..', 'vectors')
mkdirSync(OUT, { recursive: true })

// ---- 固定输入（全部写死在向量里，便于两端复现）----
/** 32 字节固定输入：从 start 起逐字节递增 —— 长度必然正确，且人可读、可复现。 */
const asc = (start) => Buffer.from(Array.from({ length: 32 }, (_, i) => (start + i) & 0xff)).toString('hex')

const input = {
  info: 'dsh-mobile/v1/keys',
  pairingId: 'pair-0001',
  seedA: asc(0x01),
  seedB: asc(0xa0),
  ephSeedA: asc(0x11),
  ephSeedB: asc(0xb1),
  nonceA: asc(0x21),
  nonceB: asc(0xc1),
}

// 输入自检：种子与 nonce 必须是 32 字节（十六进制 64 字符），否则后面的派生会静默用错长度
for (const [key, value] of Object.entries(input)) {
  if (key === 'info' || key === 'pairingId') continue
  if (!/^[0-9a-f]{64}$/.test(value)) throw new Error(`输入 ${key} 必须是 32 字节 hex（当前 ${value.length} 字符）`)
}

const expected = deriveHandshake(input)

const transcriptInput = {
  info: input.info,
  pairingId: input.pairingId,
  helloBox: '7b2265706850756241223a226465616462656566227d',
  helloAckBox: '7b2265706850756242223a226361666562616265227d',
}
const transcript = `dsh-mobile/v1|${transcriptInput.info}|${transcriptInput.pairingId}|${transcriptInput.helloBox}|${transcriptInput.helloAckBox}`
const signerEdSeed = asc(0xd0)
const signature = {
  ...transcriptInput,
  transcript,
  signerEdSeed,
  sig: signTranscript(signerEdSeed, Buffer.from(transcript, 'utf8')),
}

const handshake = {
  _generated: 'node protocol/tools/gen-vectors.mjs',
  spec: 'remote-channel.md §4.1(握手与密钥派生)',
  note: '两侧实现必须复现 expected 的全部字段;master 的前后 32 字节分别是 kA2B / kB2A',
  input,
  expected,
  signature,
}
writeFileSync(join(OUT, 'handshake.json'), `${JSON.stringify(handshake, null, 2)}\n`)

// ---- AEAD 向量：nonce 由 fc 派生、AAD 按规范拼串 ----
const key = expected.kA2B
const cases = [
  { name: 'ev 帧 fc=0', fc: 0, aad: { v: 1, t: 'ev', id: '', sid: 'sid_AAAAAAAAAAAAAAA', seq: 1, fc: 0 }, plaintext: '{"itemId":"m:1:1:assistant","text":"你好"}' },
  { name: 'ev 帧 fc=1(seq 递增)', fc: 1, aad: { v: 1, t: 'ev', id: '', sid: 'sid_AAAAAAAAAAAAAAA', seq: 2, fc: 1 }, plaintext: '{"itemId":"m:1:2:assistant","text":"世界"}' },
  { name: 'req 帧(无 sid/seq)', fc: 1000, aad: { v: 1, t: 'req', id: 'req_0123456789ab', sid: '', seq: '', fc: 1000 }, plaintext: '{"method":"session.prompt","params":{"requestId":"req_0123456789ab"}}' },
  { name: 'live 帧(易变流)', fc: 42, aad: { v: 1, t: 'live', id: '', sid: 'sid_AAAAAAAAAAAAAAA', seq: '', fc: 42 }, plaintext: '{"stream":1,"rev":7,"delta":"流式"}' },
  { name: '空载荷', fc: 7, aad: { v: 1, t: 'pong', id: '', sid: '', seq: '', fc: 7 }, plaintext: '' },
]
const vectors = cases.map((c) => {
  const sealed = seal({ keyHex: key, fc: c.fc, aadFields: c.aad, plaintext: c.plaintext })
  return { ...c, key, ciphertext: sealed.ciphertextHex, tag: sealed.tagHex }
})

const aead = {
  _generated: 'node protocol/tools/gen-vectors.mjs',
  spec: 'remote-channel.md §3(AAD 规范化)与 §4.2(nonce = fc 的 96 位大端)',
  note: '含 nonce 复用禁令的对照:同一 fc 不同明文必须产生不同密文,且 AAD 任一字段变化都必须解密失败',
  vectors,
  tamper: [
    { name: '改 AAD 的 seq', vectorIndex: 0, patch: { seq: 2 }, expect: 'auth-failure' },
    { name: '改 AAD 的帧类型', vectorIndex: 1, patch: { t: 'req' }, expect: 'auth-failure' },
    { name: '改 fc(等于 nonce 变了)', vectorIndex: 2, fc: 1001, expect: 'auth-failure' },
  ],
}
writeFileSync(join(OUT, 'aead.json'), `${JSON.stringify(aead, null, 2)}\n`)

console.log(`已生成向量：protocol/vectors/handshake.json（${Object.keys(expected).length} 个字段）、protocol/vectors/aead.json（${vectors.length} 条 + ${aead.tamper.length} 条篡改用例）`)
console.log(`签名公钥（供两端核对）：${keyPairFrom('ed25519', signature.signerEdSeed).pubHex}`)
