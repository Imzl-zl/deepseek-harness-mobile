/**
 * 跑 `protocol/vectors`（跨端密码学互操作）。
 *
 * 这是 `protocol/verify-vectors.mjs` 在 connector 侧的对应物，判据逐条对齐：
 * 重算握手派生 → 重算 AEAD 并做解密往返 → 跑篡改用例（改 AAD 或改 `fc` 必须解密失败）。
 *
 * **断言数必须与参考侧一致（33）**：数量对不上说明移植时漏了断言。
 *
 * 为什么本层单独要一批向量：协议 fixtures 有意不测加密（那边的 `seal` 是可逆占位），
 * 而两侧实现各自实现 X25519 / Ed25519 / HKDF / AEAD 时极易漂移 —— 漂移的表现是
 * 「连不上」，不是「断言失败」，所以必须有固定输入 → 期望输出的已知答案。
 */
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

import { deriveHandshake, keyPairFrom, open, seal, signTranscript } from '../src/protocol/crypto.js'
import type { AadFields } from '../src/protocol/frame.js'

const HERE = dirname(fileURLToPath(import.meta.url))
const VECTORS = join(HERE, '..', '..', 'protocol', 'vectors')

/** `verify-vectors.mjs` 的断言总数。两侧实现跑同一批向量，这个数必须相等。 */
const REFERENCE_CHECK_COUNT = 33

/* fixtures/vectors 是运行期读入的动态 JSON，形状由 gen-vectors 保证。 */
/* eslint-disable @typescript-eslint/no-explicit-any */
type Json = any

test('跨端密码学向量：握手派生 + AEAD 往返 + 篡改拒绝，断言数与参考侧一致', () => {
  const failures: string[] = []
  let checks = 0
  const check = (ok: boolean, label: string, detail?: string): void => {
    checks += 1
    if (!ok) failures.push(detail === undefined ? label : `${label} → ${detail}`)
  }

  // ---- 1. 握手派生 ----
  const hs: Json = JSON.parse(readFileSync(join(VECTORS, 'handshake.json'), 'utf8'))
  const recomputed = deriveHandshake(hs.input) as unknown as Record<string, string>
  for (const [key, want] of Object.entries(hs.expected as Record<string, string>)) {
    check(
      recomputed[key] === want,
      `handshake.${key}`,
      `向量 ${want}，重算 ${recomputed[key]}`,
    )
  }
  check(
    recomputed.master?.slice(0, 64) === recomputed.kA2B,
    'master 前 32 字节必须是 kA2B',
  )
  check(recomputed.master?.slice(64) === recomputed.kB2A, 'master 后 32 字节必须是 kB2A')
  check(
    recomputed.ss1 !== recomputed.ss2 && recomputed.ss2 !== recomputed.ss3,
    '三个共享密钥必须互不相同',
  )

  const sig = hs.signature as Json
  const recomputedSig = signTranscript(
    sig.signerEdSeed as string,
    Buffer.from(sig.transcript as string, 'utf8'),
  )
  check(recomputedSig === sig.sig, 'handshake 签名', `向量 ${sig.sig}，重算 ${recomputedSig}`)
  check(
    keyPairFrom('ed25519', sig.signerEdSeed as string).publicKeyHex.length === 64,
    '签名公钥必须是 32 字节',
  )

  // ---- 2. AEAD 往返 ----
  const aead: Json = JSON.parse(readFileSync(join(VECTORS, 'aead.json'), 'utf8'))
  for (const v of aead.vectors as Json[]) {
    const again = seal({
      keyHex: v.key,
      fc: v.fc,
      aadFields: v.aad as AadFields,
      plaintext: v.plaintext,
    })
    check(
      again.ciphertextHex === v.ciphertext,
      `${v.name}: 密文`,
      `向量 ${String(v.ciphertext).slice(0, 24)}…，重算 ${again.ciphertextHex.slice(0, 24)}…`,
    )
    check(again.tagHex === v.tag, `${v.name}: 认证标签`)
    const back = open({
      keyHex: v.key,
      fc: v.fc,
      aadFields: v.aad as AadFields,
      ciphertextHex: v.ciphertext,
      tagHex: v.tag,
    })
    check(back === v.plaintext, `${v.name}: 解密往返`, `得到 ${JSON.stringify(back).slice(0, 40)}`)
  }

  // ---- 3. 篡改用例必须失败 ----
  for (const t of aead.tamper as Json[]) {
    const v = (aead.vectors as Json[])[t.vectorIndex]
    const aadFields = { ...(v.aad as AadFields), ...(t.patch ?? {}) } as AadFields
    const fc: number = t.fc ?? v.fc
    let opened: string | null = null
    let threw = false
    try {
      opened = open({
        keyHex: v.key,
        fc,
        aadFields,
        ciphertextHex: v.ciphertext,
        tagHex: v.tag,
      })
    } catch {
      threw = true
    }
    check(threw, `${t.name} 必须解密失败`, `却成功解出 ${JSON.stringify(opened).slice(0, 40)}`)
  }

  if (failures.length > 0 || checks !== REFERENCE_CHECK_COUNT) {
    const head =
      `${failures.length}/${checks} 项不通过；` +
      `断言数期望 ${REFERENCE_CHECK_COUNT}，实际 ${checks}`
    assert.fail([head, ...failures.map((line) => `  - ${line}`)].join('\n'))
  }
})
