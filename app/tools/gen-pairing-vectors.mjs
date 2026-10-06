/**
 * 配对派生规则的**跨端向量**（契约 §12.1）。
 *
 * ## 为什么需要它
 *
 * `pairingId` 与 SAS 是"两端各自算、必须逐字一致"的东西，而它们**错了不会报错** ——
 * 差一个字节的表现是"配上了但永远连不上"（`master` 不同 → 箱解不开），
 * 那时排查会从网络开始找，而真因在一个 HKDF 的 `info` 串或 ikm 的编码上。
 *
 * 所以：**用真实的 TS 实现（不是重写一遍）算出期望值，交给 Dart 侧断言**。
 * 这与 `protocol/verify-vectors.mjs` 是同一套做法 —— 那份管握手与 AEAD，
 * 这份管配对。
 *
 * 产出写到 `app/test/fixtures/pairing-vectors.json`，由
 * `app/test/pairing_vectors_test.dart` 读取断言。
 *
 * 跑法：`node app/tools/gen-pairing-vectors.mjs`
 */
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { pairingCodeHash, pairingIdOf, sasOf } from '../../connector/src/pairing.ts'
import { createPairing } from '../../connector/src/pairing.ts'

const here = dirname(fileURLToPath(import.meta.url))
const repoRoot = join(here, '..', '..')
const outPath = join(repoRoot, 'app', 'test', 'fixtures', 'pairing-vectors.json')

/**
 * 固定输入 —— **不用随机**。
 *
 * 随机向量能证明"这一跑一致"，但复现失败时要重新摇一遍种子；
 * 固定输入则让任何人在任何机器上复算同一个值。覆盖面由"多组不同形状"保证：
 * 含 base64url 字符的码、短码、16 字节公钥。
 */
const CASES = [
  {
    name: '典型：base64url 的 16 字节码',
    code: 'AAECAwQFBgcICQoLDA0ODw',
    pcPubEd: 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899',
    devPubEd: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    devPubDh: 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210',
  },
  {
    name: '短码',
    code: 'x',
    pcPubEd: '00'.repeat(32),
    devPubEd: 'ff'.repeat(32),
    devPubDh: '0f'.repeat(32),
  },
  {
    name: '含 base64url 特有字符（- 与 _）的码',
    code: 'ab-cd_ef-gh_ij',
    pcPubEd: 'deadbeef'.repeat(8),
    devPubEd: 'cafebabe'.repeat(8),
    devPubDh: '13579bdf'.repeat(8),
  },
  {
    // 中文设备名与码：验证 UTF-8 编码一致（用码的**字节**还是**十六进制字符串**的字节，
    // 是这条派生最容易写错的一处 —— 两者各自自洽，只在两端对上时才暴露）。
    name: '非 ASCII',
    code: '配对码测试',
    pcPubEd: '11'.repeat(32),
    devPubEd: '22'.repeat(32),
    devPubDh: '33'.repeat(32),
  },
]

const vectors = CASES.map((c) => {
  const codeHash = pairingCodeHash(c.code)
  // `devId` 由电脑侧在配对时算（`deviceIdOf`），而**手机侧本地推导同一个值** ——
  // 握手的 `hello` 里要带它，那时还没收到任何回执。两端不一致的后果是
  // "配对成功了但连不上"（电脑侧当作一台没见过的设备）。
  // 用真实的 `createPairing` 走一遍，拿到它对同一份 devPubDh 的答案。
  const pairing = createPairing({
    relayUrl: 'wss://relay.invalid/ws',
    pcPubEd: c.pcPubEd,
    pcPubDh: 'aa'.repeat(32),
    now: () => 1_700_000_000_000,
  })
  const offer = pairing.offer()
  const accepted = pairing.accept({
    codeHash: pairingCodeHash(offer.code),
    devPubEd: c.devPubEd,
    devPubDh: c.devPubDh,
    name: '我的手机',
  })
  if ('rejected' in accepted) {
    throw new Error(`[${c.name}] 配对被拒：${accepted.rejected}（向量本身配错了）`)
  }

  return {
    name: c.name,
    code: c.code,
    codeHash,
    pairingId: pairingIdOf(codeHash),
    pcPubEd: c.pcPubEd,
    devPubEd: c.devPubEd,
    devPubDh: c.devPubDh,
    sas: sasOf(c.pcPubEd, c.devPubEd),
    // 电脑侧算出的设备标识（手机侧必须推导出同一个）。
    deviceId: accepted.device.devId,
  }
})

mkdirSync(dirname(outPath), { recursive: true })
writeFileSync(
  outPath,
  `${JSON.stringify(
    {
      // 说明来源，让读到这份文件的人知道它**不是手写的**。
      generatedBy: 'app/tools/gen-pairing-vectors.mjs（调用 connector/src/pairing.ts）',
      contract: 'docs/subsystems/remote-channel.md §12.1',
      vectors,
    },
    null,
    2,
  )}\n`,
  'utf8',
)

console.log(`ALL CHECKS PASSED — 写了 ${vectors.length} 条配对向量到 app/test/fixtures/pairing-vectors.json`)
for (const v of vectors) {
  console.log(`  ${v.name}: pairingId=${v.pairingId.slice(0, 12)}… sas=${v.sas}`)
}
