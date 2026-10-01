/**
 * 配对的回归（契约 §12.1）。
 *
 * 这一层是**安全边界**：配对码是一次性 bearer 凭据，判定它的人（电脑侧）决定了谁能成为设备。
 * 所以断言写的都是"什么时候必须拒"：过期、对不上、已用过，以及**码本身不许留在内存里**。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  PAIRING_TTL_MS,
  createPairing,
  pairingIdOf,
  sasOf,
} from '../src/pairing.js'

const PC_ED = 'a'.repeat(64)
const PC_DH = 'b'.repeat(64)

function setup(patch: { now?: () => number } = {}) {
  // **每次调用都要给出不同的字节**：固定序列会让两次 `offer()` 出同一个码，
  // 于是"旧码立刻失效"这条根本构造不出来（第一版就栽在这里）。
  let round = 0
  return createPairing({
    relayUrl: 'wss://relay.example/ws',
    pcPubEd: PC_ED,
    pcPubDh: PC_DH,
    randomBytes: (size) => {
      round += 1
      return Uint8Array.from({ length: size }, (_, i) => (round * 31 + i) % 256)
    },
    ...(patch.now === undefined ? {} : { now: patch.now }),
  })
}

const request = (code: string) => ({
  code,
  devPubEd: 'c'.repeat(64),
  devPubDh: 'd'.repeat(64),
  name: '我的手机',
})

test('offer：二维码载荷带上电脑公钥与中转地址，而**内存里只留哈希**', () => {
  const pairing = setup()
  const offer = pairing.offer()

  const payload = JSON.parse(offer.payload) as Record<string, unknown>
  assert.equal(payload['relay'], 'wss://relay.example/ws')
  assert.equal(payload['pcPubEd'], PC_ED, '手机只信任二维码里带出的电脑公钥（§12.1 的硬规则）')
  assert.equal(payload['pcPubDh'], PC_DH)
  assert.equal(payload['code'], offer.code, '码本身在二维码里，但电脑侧不保留它')
  assert.equal(payload['v'], 1)

  assert.equal(offer.codeHash.length, 64, '哈希是 sha256 的十六进制')
  assert.notEqual(offer.codeHash, offer.code, '不许把码当哈希存')
  assert.equal(offer.expiresAt - Date.now() <= PAIRING_TTL_MS, true, '有效期 5 分钟')
})

test('accept：码对得上就落设备记录，并给出由配对码派生的 pairingId 与 SAS', () => {
  const pairing = setup()
  const offer = pairing.offer()

  const accepted = pairing.accept(request(offer.code))
  assert.ok('device' in accepted, `应当成功，实际 ${JSON.stringify(accepted)}`)
  assert.equal(accepted.device.name, '我的手机')
  assert.equal(accepted.device.edPubHex, 'c'.repeat(64))
  assert.equal(accepted.device.dhPubHex, 'd'.repeat(64))
  assert.equal(
    accepted.device.pairingId,
    pairingIdOf(offer.code),
    'pairingId 必须由配对码派生（两端各算一次，算不一样就握不上手）',
  )
  assert.equal(accepted.device.devId.length > 0, true)
  assert.match(accepted.sas, /^\d{6}$/, 'SAS 是 6 位数字（补零）')
  assert.equal(pairing.pending, false, '用过就没有待用码了')
})

test('accept：一次性 —— 同一个码第二次必须是 consumed', () => {
  const pairing = setup()
  const offer = pairing.offer()
  assert.ok('device' in pairing.accept(request(offer.code)))
  assert.deepEqual(pairing.accept(request(offer.code)), { rejected: 'consumed' })
})

test('accept：过期即作废（不留"可能还能用"的码）', () => {
  let clock = 1_000_000
  const pairing = setup({ now: () => clock })
  const offer = pairing.offer()

  clock += PAIRING_TTL_MS + 1
  assert.deepEqual(pairing.accept(request(offer.code)), { rejected: 'expired' })
  assert.equal(pairing.pending, false, '过期之后待用码必须清掉')
})

test('accept：码对不上就 mismatch，且**不消费**待用码（真正的手机还来得及配）', () => {
  const pairing = setup()
  const offer = pairing.offer()

  assert.deepEqual(pairing.accept(request('wrong-code')), { rejected: 'mismatch' })
  assert.equal(pairing.pending, true, '猜错不该把码作废 —— 否则谁都配不上了')
  assert.ok('device' in pairing.accept(request(offer.code)), '正确的码仍然可用')
})

test('offer：再出一次码会覆盖上一次（永远只有一个待用码）', () => {
  const pairing = setup()
  const first = pairing.offer()
  const second = pairing.offer()

  assert.deepEqual(pairing.accept(request(first.code)), { rejected: 'mismatch' }, '旧码立刻失效')
  assert.ok('device' in pairing.accept(request(second.code)))
})

test('pairingId / SAS：同一个输入永远同一个输出，且换一边公钥就变', () => {
  assert.equal(pairingIdOf('code-1'), pairingIdOf('code-1'))
  assert.notEqual(pairingIdOf('code-1'), pairingIdOf('code-2'))
  assert.equal(pairingIdOf('code-1').length, 43, '32 字节 base64url')

  assert.equal(sasOf(PC_ED, 'c'.repeat(64)), sasOf(PC_ED, 'c'.repeat(64)))
  assert.notEqual(
    sasOf(PC_ED, 'c'.repeat(64)),
    sasOf(PC_ED, 'e'.repeat(64)),
    '换了设备公钥，SAS 必须变 —— 否则带外核对没有意义（那正是它要防的替换攻击）',
  )
  assert.notEqual(sasOf(PC_ED, 'c'.repeat(64)), sasOf('f'.repeat(64), 'c'.repeat(64)))
})
