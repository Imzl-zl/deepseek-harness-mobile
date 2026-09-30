/**
 * 跨端密码学向量的校验（手改向量会红）。
 *
 * 跑法：node protocol/verify-vectors.mjs
 *
 * 它做三件事：
 * 1. 从固定输入重算握手派生（含 ss1/ss2/ss3、master、kA2B/kB2A）并与向量比对；
 * 2. 重算每条 AEAD 向量，并做一次"解密回明文"的往返；
 * 3. 跑篡改用例：改 AAD 或改 fc 都必须解密失败（这是 nonce 与 AAD 规则的负向证据）。
 *
 * 两侧实现（connector 用 TS、手机端用 Dart）各自跑同一批向量；任何一侧对不上，
 * 说明该侧的曲线/HKDF/AEAD/AAD 规范化与契约不一致。
 */
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { deriveHandshake, seal, open, signTranscript, keyPairFrom } from './tools/vectors-core.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const VECTORS = join(HERE, 'vectors')

const failures = []
let checks = 0
function check(ok, label, detail) {
  checks += 1
  if (!ok) failures.push(detail ? `${label} → ${detail}` : label)
}

// ---- 1. 握手派生 ----
const hs = JSON.parse(readFileSync(join(VECTORS, 'handshake.json'), 'utf8'))
const recomputed = deriveHandshake(hs.input)
for (const [key, want] of Object.entries(hs.expected)) {
  check(recomputed[key] === want, `handshake.${key}`, `向量 ${want}，重算 ${recomputed[key]}`)
}
check(recomputed.master.slice(0, 64) === recomputed.kA2B, 'master 前 32 字节必须是 kA2B')
check(recomputed.master.slice(64) === recomputed.kB2A, 'master 后 32 字节必须是 kB2A')
check(recomputed.ss1 !== recomputed.ss2 && recomputed.ss2 !== recomputed.ss3, '三个共享密钥必须互不相同')

const sig = hs.signature
const recomputedSig = signTranscript(sig.signerEdSeed, Buffer.from(sig.transcript, 'utf8'))
check(recomputedSig === sig.sig, 'handshake 签名', `向量 ${sig.sig}，重算 ${recomputedSig}`)
check(keyPairFrom('ed25519', sig.signerEdSeed).pubHex.length === 64, '签名公钥必须是 32 字节')

// ---- 2. AEAD 往返 ----
const aead = JSON.parse(readFileSync(join(VECTORS, 'aead.json'), 'utf8'))
for (const v of aead.vectors) {
  const again = seal({ keyHex: v.key, fc: v.fc, aadFields: v.aad, plaintext: v.plaintext })
  check(again.ciphertextHex === v.ciphertext, `${v.name}: 密文`, `向量 ${v.ciphertext.slice(0, 24)}…，重算 ${again.ciphertextHex.slice(0, 24)}…`)
  check(again.tagHex === v.tag, `${v.name}: 认证标签`)
  const back = open({ keyHex: v.key, fc: v.fc, aadFields: v.aad, ciphertextHex: v.ciphertext, tagHex: v.tag })
  check(back === v.plaintext, `${v.name}: 解密往返`, `得到 ${JSON.stringify(back).slice(0, 40)}`)
}

// ---- 3. 篡改用例必须失败 ----
for (const t of aead.tamper) {
  const v = aead.vectors[t.vectorIndex]
  const aadFields = { ...v.aad, ...(t.patch ?? {}) }
  const fc = t.fc ?? v.fc
  let opened = null
  let threw = false
  try {
    opened = open({ keyHex: v.key, fc, aadFields, ciphertextHex: v.ciphertext, tagHex: v.tag })
  } catch {
    threw = true
  }
  check(threw, `${t.name} 必须解密失败`, `却成功解出 ${JSON.stringify(opened).slice(0, 40)}`)
}

if (failures.length > 0) {
  console.error(`FAIL ${failures.length}/${checks} 项不通过（跨端密码学向量）\n`)
  for (const line of failures) console.error(`  - ${line}`)
  process.exit(1)
}
console.log(`ALL CHECKS PASSED — ${checks} 项断言（跨端密码学向量：握手派生 + AEAD 往返 + 篡改拒绝）`)
