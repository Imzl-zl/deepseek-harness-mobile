/**
 * 中转**公开邀请**登记的回归（契约 §12.1 的"出码登记"；`docs/subsystems/pairing-v2.md` §3）。
 *
 * v2 的关键分野：中转登记的是**公开** `offerId`（它可以被人看见、可以重复查询），
 * 配对秘密 `code` 只在电脑与手机之间，**从不**经过中转。于是三条纪律：
 *
 * 1. **查询不消费授权**：匿名查询一次就把邀请烧掉，等于"谁先扫谁作废"（真正的扫码设备反而没机会）；
 *    邀请的失效由**生命周期**给出 —— 重新出码、5 分钟 TTL、连接器断开。
 * 2. **一份当前出码**：同一连接器再登记一张邀请，旧的立即不再可用（§3）。
 * 3. **形状即边界**：只收 22 字符 base64url 的公开标识 —— 秘密进不来，也就无从泄露。
 *
 * 每条失效规则各配一条用例，因为它们各自留下的都是同一种坏结果
 * （**一个指向不存在连接的候选通道**），而症状都长成"扫码后连不上、中转侧一切正常"。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  PAIRING_REGISTRATION_TTL_MS,
  createPairingRegistry,
} from '../src/pairing-registry.ts'

const OFFER_A = 'A'.repeat(22)
const OFFER_B = 'B'.repeat(22)

test('登记 → 查询：拿到那台连接器；**查询不消费**（失效靠重新出码，不靠被查过）', () => {
  const registry = createPairingRegistry()
  registry.register(OFFER_A, 'conn-1')

  assert.equal(registry.lookup(OFFER_A), 'conn-1')
  assert.equal(
    registry.lookup(OFFER_A),
    'conn-1',
    '匿名查询不消费授权：不然一次试探就能把真正的扫码设备关在门外',
  )
  assert.deepEqual(registry.stats, { registrations: 1, connectors: 1 })

  const expiresAt = registry.register(OFFER_B, 'conn-1')
  assert.equal(expiresAt > 0, true, '登记返回过期时刻')
  assert.equal(registry.lookup(OFFER_A), undefined, '重新出码使旧邀请失效（同时只有一份当前出码）')
  assert.equal(registry.lookup(OFFER_B), 'conn-1')
  assert.deepEqual(registry.stats, { registrations: 1, connectors: 1 })
})

test('查询**未登记**的邀请：没有登记（不猜、不新建）', () => {
  const registry = createPairingRegistry()
  assert.equal(registry.lookup(OFFER_A), undefined)
  assert.deepEqual(registry.stats, { registrations: 0, connectors: 0 })
})

test('过期即作废：TTL 到了就查不到，且**就地删掉**（不靠清扫兜正确性）', () => {
  let clock = 1_000_000
  const registry = createPairingRegistry({ now: () => clock })
  registry.register(OFFER_A, 'conn-1')

  clock += PAIRING_REGISTRATION_TTL_MS + 1
  assert.equal(registry.lookup(OFFER_A), undefined, '过期的邀请不许换来票')
  assert.equal(registry.stats.registrations, 0, '查询时顺手清掉它')
})

test('连接器断开：它**没用上**的登记立即失效', () => {
  const registry = createPairingRegistry()
  registry.register(OFFER_A, 'conn-1')
  registry.register(OFFER_B, 'conn-2')

  assert.equal(registry.forgetConnector('conn-1'), 1)
  assert.equal(registry.lookup(OFFER_A), undefined, '否则设备会拿到指向已消失连接的票')
  assert.equal(registry.lookup(OFFER_B), 'conn-2', '别的连接器不受影响')
})

test('公开邀请不能被人抢走：同一个 offerId 由**别的**连接器登记 → 拒绝，且原归属一字不变', () => {
  const registry = createPairingRegistry()
  registry.register(OFFER_A, 'conn-1')

  assert.throws(() => registry.register(OFFER_A, 'conn-2'), /另一连接器/)
  assert.equal(registry.lookup(OFFER_A), 'conn-1', '被拒之后原来的归属一个字都没变')
  assert.deepEqual(registry.stats, { registrations: 1, connectors: 1 })
})

test('形状即边界：不是 22 字符 base64url 的标识一律拒收（秘密进不了中转）', () => {
  const registry = createPairingRegistry()
  const rejected = [
    '',
    'short',
    'A'.repeat(21),
    'A'.repeat(23),
    `${'A'.repeat(22)}!`,
    'a'.repeat(64), // 64 位十六进制 = 摘要的形状，不是公开标识的形状（v1 的 codeHash 正是它）
  ]
  for (const offerId of rejected) {
    assert.throws(() => registry.register(offerId, 'conn-1'), TypeError, `不该接受：${offerId.slice(0, 12)}`)
  }
  assert.deepEqual(registry.stats, { registrations: 0, connectors: 0 }, '被拒的登记一行都不许落')
})

test('prune：只清过期的，活的留着', () => {
  let clock = 1_000_000
  const registry = createPairingRegistry({ now: () => clock })
  registry.register(OFFER_A, 'conn-1')
  clock += PAIRING_REGISTRATION_TTL_MS - 1
  registry.register(OFFER_B, 'conn-2') // 新的：过期时刻更晚
  clock += 2

  assert.equal(registry.prune(), 1, '只清掉 A')
  assert.equal(registry.stats.registrations, 1)
  assert.equal(registry.lookup(OFFER_B), 'conn-2')
})
