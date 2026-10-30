/**
 * 按人的流量额度（契约 §2.4；`relay/src/metering.ts`）。
 *
 * 这一组不开 socket：额度是纯判定 —— 周期怎么滚、谁和谁共用一个桶、
 * 恰好用满算不算超、`off` 会不会挡住人。开 socket 的那一半在 `server-quota.test.ts`。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  createMetering, nextBoundaryOf, periodKeyOf, type QuotaConfig,
} from '../src/metering.ts'

const OCT_30 = Date.UTC(2026, 9, 30, 12, 0, 0)

const config = (patch: Partial<QuotaConfig> = {}): QuotaConfig => ({
  period: 'month',
  enforce: 'cut',
  defaultBytes: 100,
  ...patch,
})

test('周期键用 UTC：日/月滚动，none 永不清零', () => {
  assert.equal(periodKeyOf(OCT_30, 'month'), '2026-10')
  assert.equal(periodKeyOf(OCT_30, 'day'), '2026-10-30')
  assert.equal(periodKeyOf(OCT_30, 'none'), 'all')
  assert.equal(nextBoundaryOf(OCT_30, 'day'), Date.UTC(2026, 9, 31))
  assert.equal(nextBoundaryOf(OCT_30, 'month'), Date.UTC(2026, 10, 1))
  assert.equal(nextBoundaryOf(OCT_30, 'none'), undefined, '永不清零 = 不会自行恢复')
})

test('默认不限制：没写 defaultBytes 时 limit 是 null，charge 永不超、check 永不挡', () => {
  const metering = createMetering({
    quota: {}, ownerOf: () => undefined, now: () => OCT_30,
  })
  assert.equal(metering.limitOf('connector:c'), null)
  assert.equal(metering.charge('c', 10 ** 9).over, false, '一个 GB 也不超 —— 没设上限')
  assert.equal(metering.check('c').exceeded, false)
  assert.deepEqual(metering.snapshot(), [{ subject: 'connector:c', used: 10 ** 9, limit: null, period: '2026-10' }])
})

test('额度按人：两台电脑共用一个桶；没配 owner 退回连接器键', () => {
  const metering = createMetering({
    quota: config({ defaultBytes: 100, owners: { alice: 50 } }),
    ownerOf: (id) => ({ home: 'alice', work: 'alice' } as Record<string, string>)[id],
    now: () => OCT_30,
  })
  assert.equal(metering.subjectOf('home'), 'user:alice')
  assert.equal(metering.subjectOf('work'), 'user:alice', '多开一台电脑不多领额度')
  assert.equal(metering.subjectOf('solo'), 'connector:solo')
  assert.equal(metering.limitOf('user:alice'), 50, '按人覆盖默认值')
  assert.equal(metering.limitOf('connector:solo'), 100)

  metering.charge('home', 30)
  metering.charge('work', 25)
  assert.equal(metering.usedOf('user:alice'), 55, '两台电脑记在同一行')
  assert.equal(metering.check('home').exceeded, true)
  assert.equal(metering.check('solo').exceeded, false)
})

test('用满就算满（>=），未用满不挡；off 只记账不挡', () => {
  const metering = createMetering({ quota: config({ defaultBytes: 10 }), ownerOf: () => undefined, now: () => OCT_30 })
  assert.equal(metering.charge('c', 9).over, false)
  assert.equal(metering.check('c').exceeded, false, '还差 1 字节')
  assert.equal(metering.charge('c', 1).over, true, '恰好用满 = 这一帧之后没有额度了')
  assert.equal(metering.check('c').exceeded, true)

  const lax = createMetering({ quota: config({ enforce: 'off', defaultBytes: 1 }), ownerOf: () => undefined, now: () => OCT_30 })
  lax.charge('c', 1_000)
  assert.equal(lax.check('c').exceeded, false, 'off = 只记账（面板还能看到用量）')
  assert.equal(lax.usedOf('connector:c'), 1_000)
})

test('近 60 分钟序列：按分钟滚动，跨分钟补零，跨过整个窗口就清空', () => {
  let now = OCT_30
  const metering = createMetering({ quota: {}, ownerOf: () => undefined, now: () => now })
  metering.charge('c', 5)
  now += 60_000
  metering.charge('c', 7)

  const first = metering.traffic()
  assert.equal(first.perMinute.length, 60)
  assert.equal(first.perMinute[58], 5, '上一分钟的落在倒数第二格')
  assert.equal(first.perMinute[59], 7, '当前分钟在最后一格')
  assert.equal(first.total, 12)

  now += 120 * 60_000
  const later = metering.traffic()
  assert.equal(later.total, 0, '两小时后，窗口里已经没有那两分钟')
  assert.equal(later.perMinute.every((value) => value === 0), true)
})

test('周期滚动：跨月自动归零（惰性结算，不靠定时器）', () => {
  let now = OCT_30
  const metering = createMetering({ quota: config({ defaultBytes: 10 }), ownerOf: () => undefined, now: () => now })
  metering.charge('c', 10)
  assert.equal(metering.check('c').exceeded, true)
  assert.equal(metering.check('c').retryAfterMs, Date.UTC(2026, 10, 1) - now)

  now = Date.UTC(2026, 10, 1, 0, 0, 1)
  assert.equal(metering.check('c').exceeded, false, '新周期从零起算')
  assert.equal(metering.usedOf('connector:c'), 0)
})

test('手动重置与快照', () => {
  const metering = createMetering({
    quota: config({ defaultBytes: 10 }), ownerOf: (id) => (id === 'home' ? 'alice' : undefined), now: () => OCT_30,
  })
  metering.charge('home', 4)
  metering.charge('solo', 2)
  assert.deepEqual(
    metering.snapshot().map((row) => [row.subject, row.used, row.limit]).sort(),
    [['connector:solo', 2, 10], ['user:alice', 4, 10]],
  )
  assert.equal(metering.reset('user:alice'), true)
  assert.equal(metering.usedOf('user:alice'), 0)
  assert.equal(metering.reset('nobody'), false)
})

test('落盘形状：同周期读回接着算，跨周期的行丢掉', () => {
  const first = createMetering({ quota: config({ defaultBytes: 10 }), ownerOf: () => undefined, now: () => OCT_30 })
  first.charge('c', 7)
  const state = first.serialize()
  assert.deepEqual(state, { v: 1, meters: { 'connector:c': { period: '2026-10', bytes: 7 } } })

  const sameMonth = createMetering({
    quota: config({ defaultBytes: 10 }), ownerOf: () => undefined, state, now: () => OCT_30,
  })
  assert.equal(sameMonth.usedOf('connector:c'), 7)

  const nextMonth = createMetering({
    quota: config({ defaultBytes: 10 }), ownerOf: () => undefined, state,
    now: () => Date.UTC(2026, 10, 2),
  })
  assert.equal(nextMonth.usedOf('connector:c'), 0, '上个月的用量不该算进这个月')
})
