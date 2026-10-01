/**
 * 跨端密码学向量的校验（手改向量会红）。
 *
 * 跑法：node protocol/verify-vectors.mjs
 *
 * 它做四件事：
 * 1. 从固定输入重算握手派生（含 ss1/ss2/ss3、master、kA2B/kB2A）并与向量比对；
 * 2. 重算设备身份（主种子 → Ed25519 / X25519 两把长期密钥）；
 * 3. **从字段重拼 transcript** 并重签 —— 只重签存好的那串字节拦不住"顺序写反"；
 * 4. 重算每条 AEAD 向量（含解密往返与**线上容器**），再跑篡改用例：改 AAD 或改 fc 都必须解密失败。
 *
 * 两侧实现（connector 用 TS、手机端用 Dart）各自跑同一批向量；任何一侧对不上，
 * 说明该侧的曲线/HKDF/AEAD/AAD 规范化与契约不一致。
 */
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { deriveHandshake, deriveIdentity, packBox, seal, open, signTranscript, keyPairFrom, transcriptOf, unpackBox } from './tools/vectors-core.mjs'

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

// ---- 2. 设备身份（主种子 → 两把长期密钥）----
const identity = deriveIdentity(hs.identity.masterSeed)
for (const [key, want] of Object.entries(hs.identity.expected)) {
  check(identity[key] === want, `identity.${key}`, `向量 ${want}，重算 ${identity[key]}`)
}
check(
  identity.edSeed !== identity.dhSeed,
  '两把长期密钥必须来自不同的 info（否则签名密钥与 DH 密钥是同一把）',
)

// ---- 3. 握手签名：拼串规则本身也要重算 ----
// 只重签向量里存好的那串字节是不够的：两端各自拼一遍、比对同一段字节，才拦得住"顺序写反"。
const sig = hs.signature
const rebuilt = transcriptOf(sig.fields)
check(rebuilt.toString('utf8') === sig.transcript, 'transcript 拼串（从字段拼）', `向量 ${sig.transcript}，重算 ${rebuilt.toString('utf8')}`)
const recomputedSig = signTranscript(sig.signerEdSeed, rebuilt)
check(recomputedSig === sig.sig, 'handshake 签名', `向量 ${sig.sig}，重算 ${recomputedSig}`)
check(keyPairFrom('ed25519', sig.signerEdSeed).pubHex.length === 64, '签名公钥必须是 32 字节')

// ---- 4. AEAD 往返 + 线上容器 ----
const aead = JSON.parse(readFileSync(join(VECTORS, 'aead.json'), 'utf8'))
for (const v of aead.vectors) {
  const again = seal({ keyHex: v.key, fc: v.fc, aadFields: v.aad, plaintext: v.plaintext })
  check(again.ciphertextHex === v.ciphertext, `${v.name}: 密文`, `向量 ${v.ciphertext.slice(0, 24)}…，重算 ${again.ciphertextHex.slice(0, 24)}…`)
  check(again.tagHex === v.tag, `${v.name}: 认证标签`)
  // 容器也是线上格式的一部分：两端各拼一遍再比对，避免"各写各的、真机才断"。
  check(packBox(again) === v.box, `${v.name}: 箱容器`, `向量 ${v.box.slice(0, 24)}…，重算 ${packBox(again).slice(0, 24)}…`)
  const unpacked = unpackBox(v.box)
  check(
    unpacked.ciphertextHex === v.ciphertext && unpacked.tagHex === v.tag,
    `${v.name}: 容器往返`,
    `解出 ${unpacked.ciphertextHex.slice(0, 16)}… / ${unpacked.tagHex.slice(0, 16)}…`,
  )
  const back = open({ keyHex: v.key, fc: v.fc, aadFields: v.aad, ciphertextHex: v.ciphertext, tagHex: v.tag })
  check(back === v.plaintext, `${v.name}: 解密往返`, `得到 ${JSON.stringify(back).slice(0, 40)}`)
}

// ---- 5. 篡改用例必须失败 ----
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
console.log(`ALL CHECKS PASSED — ${checks} 项断言（跨端密码学向量：握手派生 + 设备身份 + 拼串与签名 + AEAD 往返 + 篡改拒绝）`)
