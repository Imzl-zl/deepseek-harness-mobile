/**
 * 配对派生规则的**跨端向量**（规格 `docs/subsystems/pairing-v2.md` §4–§5）。
 *
 * ## 为什么需要它
 *
 * 下面这几样都是"两端各自算、必须逐字一致"的东西，而它们**错了不会报错**：
 *
 * - `pairingId`：差一个字节的表现是"配上了但永远连不上"（`master` 不同 → 箱解不开），
 *   那时排查会从网络开始找，而真因在一个 HKDF 的 `info` 串或 ikm 的编码上；
 * - `handshakeContext`：它是 v2 新增的**被签**串（把邀请与候选身份钉进 transcript）。
 *   两端拼得不一样时，症状是**验签失败**，而错误信息会说"公钥被替换"（§4.1）——
 *   也就是"真因在一处拼串上，报出来的却是中间人攻击"；
 * - `deviceId`：手机要在**收到任何回执之前**把它放进 `hello`，算错即"配对成功但连不上"。
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

import {
  createPairing,
  pairingCodeHash,
  pairingHandshakeContext,
  pairingIdOf,
  sasOf,
} from '../../connector/src/pairing.ts'

const here = dirname(fileURLToPath(import.meta.url))
const repoRoot = join(here, '..', '..')
const outPath = join(repoRoot, 'app', 'test', 'fixtures', 'pairing-vectors.json')

/** 电脑侧标识与设备名：两者都进 `handshakeContext`，所以必须是固定值。 */
const PC_ID = 'conn-1'
const DEVICE_NAME = '我的手机'

/**
 * 确定性的"随机"源（每次调用返回同一形状的固定字节）。
 *
 * `createPairing.offer()` 里 `offerId` 与 `code` 必须互不相同，所以这里按调用次数
 * 递增填充 —— 于是整份向量**每次生成都逐字相同**（随机会让复现失败时得重新摇种子，
 * 而这份文件是要入库、要能被人复算的）。
 */
let randomCall = 0
const deterministicRandomBytes = (size) => {
  randomCall += 1
  return Buffer.alloc(size, randomCall)
}

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
    pcPubDh: '99887766554433221100ffeeddccbbaa99887766554433221100ffeeddccbbaa',
    devPubEd: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    devPubDh: 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210',
  },
  {
    name: '短码',
    code: 'x',
    pcPubEd: '00'.repeat(32),
    pcPubDh: '11'.repeat(32),
    devPubEd: 'ff'.repeat(32),
    devPubDh: '0f'.repeat(32),
  },
  {
    name: '含 base64url 特有字符（- 与 _）的码',
    code: 'ab-cd_ef-gh_ij',
    pcPubEd: 'deadbeef'.repeat(8),
    pcPubDh: 'feedface'.repeat(8),
    devPubEd: 'cafebabe'.repeat(8),
    devPubDh: '13579bdf'.repeat(8),
  },
  {
    // 中文设备名与码：验证 UTF-8 编码一致（用码的**字节**还是**十六进制字符串**的字节，
    // 是这条派生最容易写错的一处 —— 两者各自自洽，只在两端对上时才暴露）。
    // `handshakeContext` 里还有设备名的 SHA-256，同一个坑在那里也埋了一次。
    name: '非 ASCII',
    code: '配对码测试',
    pcPubEd: '11'.repeat(32),
    pcPubDh: '22'.repeat(32),
    devPubEd: '22'.repeat(32),
    devPubDh: '33'.repeat(32),
  },
]

const vectors = CASES.map((c) => {
  const codeHash = pairingCodeHash(c.code)
  // 这些值都走**真实的** `createPairing`（而不是在这里重写一遍派生）：
  // 重写一遍只能证明"我两次写的一样"。
  randomCall = 0
  const pairing = createPairing({
    relayUrl: 'wss://relay.invalid/ws',
    pcId: PC_ID,
    pcPubEd: c.pcPubEd,
    pcPubDh: c.pcPubDh,
    now: () => 1_700_000_000_000,
    randomBytes: deterministicRandomBytes,
  })
  const offer = pairing.offer()
  const candidate = {
    offerId: offer.offerId,
    devPubEd: c.devPubEd,
    devPubDh: c.devPubDh,
    name: DEVICE_NAME,
  }
  // v2 的 `accept` 收的是「请求（邀请 id + 秘密）」与「已认证的候选」两份东西：
  // 设备身份来自候选，不来自请求载荷（§5）。
  const accepted = pairing.accept({ v: 2, offerId: offer.offerId, code: offer.code }, candidate)
  if ('rejected' in accepted) {
    throw new Error(`[${c.name}] 配对被拒：${accepted.rejected}（向量本身配错了）`)
  }

  return {
    name: c.name,
    code: c.code,
    codeHash,
    pairingId: pairingIdOf(codeHash),
    pcId: PC_ID,
    pcPubEd: c.pcPubEd,
    pcPubDh: c.pcPubDh,
    offerId: offer.offerId,
    deviceName: DEVICE_NAME,
    devPubEd: c.devPubEd,
    devPubDh: c.devPubDh,
    sas: sasOf(c.pcPubEd, c.devPubEd),
    // 电脑侧算出的设备标识（手机侧必须推导出同一个）。
    deviceId: accepted.device.devId,
    // v2 新增：进 transcript 的配对上下文（拼错的表现是"验签失败、报成公钥被替换"）。
    handshakeContext: pairingHandshakeContext(
      { pcId: PC_ID, pcPubEd: c.pcPubEd, pcPubDh: c.pcPubDh },
      candidate,
    ),
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
