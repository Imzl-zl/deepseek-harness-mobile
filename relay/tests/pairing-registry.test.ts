/**
 * 中转配对登记的回归（契约 §12.1 的"出码登记"）。
 *
 * 三条失效规则各配一条用例，因为它们各自留下的都是同一种坏结果
 * （**一张指向不存在连接的 ticket**），而症状都长成"扫码后连不上、中转侧一切正常"。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  PAIRING_REGISTRATION_TTL_MS,
  createPairingRegistry,
} from '../src/pairing-registry.ts'

const HASH_A = 'a'.repeat(64)
const HASH_B = 'b'.repeat(64)

test('登记 → 认领：拿到那台连接器；**认领即消费**（第二次得到没有登记）', () => {
  const registry = createPairingRegistry()
  registry.register(HASH_A, 'conn-1')

  assert.equal(registry.claim(HASH_A), 'conn-1')
  assert.equal(registry.claim(HASH_A), undefined, '配对码是一次性的：认领过就没了')
  assert.deepEqual(registry.stats, { registrations: 0, connectors: 0 })
})

test('认领**未登记**的哈希：没有登记（不猜、不新建）', () => {
  const registry = createPairingRegistry()
  assert.equal(registry.claim(HASH_A), undefined)
  assert.equal(registry.stats.registrations, 0)
})

test('过期即作废：TTL 到了就认领不到，且**就地删掉**（不靠清扫兜正确性）', () => {
  let clock = 1_000_000
  const registry = createPairingRegistry({ now: () => clock })
  registry.register(HASH_A, 'conn-1')

  clock += PAIRING_REGISTRATION_TTL_MS + 1
  assert.equal(registry.claim(HASH_A), undefined, '过期的登记不许换来 ticket')
  assert.equal(registry.stats.registrations, 0, '认领时顺手清掉它')
})

test('连接器断开：它**未认领**的登记立即失效', () => {
  const registry = createPairingRegistry()
  registry.register(HASH_A, 'conn-1')
  registry.register(HASH_B, 'conn-2')

  assert.equal(registry.forgetConnector('conn-1'), 1)
  assert.equal(registry.claim(HASH_A), undefined, '否则设备会拿到指向已消失连接的 ticket')
  assert.equal(registry.claim(HASH_B), 'conn-2', '别的连接器不受影响')
})

test('同一个 codeHash 重新登记：**覆盖**（重新出码的场景）', () => {
  const registry = createPairingRegistry()
  registry.register(HASH_A, 'conn-1')
  registry.register(HASH_A, 'conn-2')
  assert.equal(registry.claim(HASH_A), 'conn-2', '以最后一次登记为准')
  assert.equal(registry.stats.registrations, 0)
})

test('prune：只清过期的，活的留着', () => {
  let clock = 1_000_000
  const registry = createPairingRegistry({ now: () => clock })
  registry.register(HASH_A, 'conn-1')
  clock += PAIRING_REGISTRATION_TTL_MS - 1
  registry.register(HASH_B, 'conn-2') // 新的：过期时刻更晚
  clock += 2

  assert.equal(registry.prune(), 1, '只清掉 A')
  assert.equal(registry.stats.registrations, 1)
  assert.equal(registry.claim(HASH_B), 'conn-2')
})
