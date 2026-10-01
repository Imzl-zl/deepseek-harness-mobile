/**
 * 中转大脑的回归（契约 §2 / §12.1 / I10）。
 *
 * 三种帧走三条不同的路，而它们**都不是靠内容判断**的：
 * 带 `sid` 的按归属表、`pair` 按 ticket 绑定、`pair-ack` 按帧头 `id`。
 * 三条路各自有一条会红的用例，外加"断开要清干净"（否则留下指向消失连接的投递）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createRelayCore } from '../src/core.js'

const line = (frame: Record<string, unknown>): string => JSON.stringify({ v: 1, ...frame })
const ev = (sid: string, seq: number, box = 'x'): string =>
  line({ t: 'ev', sid, seq, fc: seq, box })

test('带 sid：电脑侧的帧投给"在听这个会话"的设备（没听众就不投）', () => {
  const core = createRelayCore()
  core.attachConnector('conn-1')
  core.attachDevice('dev-1')

  assert.deepEqual(core.onLine({ kind: 'connector', id: 'conn-1' }, ev('sid_1', 1)), [], '还没设备在听')

  // 设备先说话 = 它在听（并在归属表里登记）
  const out = core.onLine({ kind: 'device', id: 'dev-1' }, ev('sid_1', 0))
  assert.deepEqual(out, [{ to: 'conn-1', raw: ev('sid_1', 0) }], '设备侧的帧投给归属连接器')

  const back = core.onLine({ kind: 'connector', id: 'conn-1' }, ev('sid_1', 1))
  assert.deepEqual(back, [{ to: 'dev-1', raw: ev('sid_1', 1) }])
})

test('pair（没有 sid）：按 ticket 绑定投给连接器；pair-ack 按帧头 id 回到那台设备', () => {
  const core = createRelayCore()
  core.attachConnector('conn-1')
  core.attachDevice('dev-1')
  core.registerPairing('conn-1', 'hash-a')
  assert.equal(core.claimTicket('dev-1', 'hash-a'), 'conn-1', 'ticket 认领把设备绑给连接器')

  const pair = line({ t: 'pair', id: 'p1', box: '{}' })
  assert.deepEqual(core.onLine({ kind: 'device', id: 'dev-1' }, pair), [{ to: 'conn-1', raw: pair }])

  const ack = line({ t: 'pair-ack', id: 'p1', box: '{}' })
  assert.deepEqual(
    core.onLine({ kind: 'connector', id: 'conn-1' }, ack),
    [{ to: 'dev-1', raw: ack }],
    '没有 sid：回执靠 `id` 找回发起的那台设备（I10 把 id 列为可见字段的原因）',
  )
})

test('丢弃要计数、要有理由：没有归属 / 未知 sid / 坏行 / 没换 ticket 的 pair', () => {
  const core = createRelayCore()
  core.attachConnector('conn-1')
  core.attachDevice('dev-1')

  assert.deepEqual(core.onLine({ kind: 'device', id: 'dev-1' }, 'not json'), [], '坏行')
  assert.deepEqual(core.onLine({ kind: 'device', id: 'dev-1' }, ev('sid_x', 1)), [], '未知 sid')
  assert.deepEqual(
    core.onLine({ kind: 'device', id: 'dev-1' }, line({ t: 'pair', id: 'p1', box: '{}' })),
    [],
    '还没换 ticket 的 pair：不知道该给谁',
  )
  assert.deepEqual(core.onLine({ kind: 'connector', id: 'gone' }, ev('sid_1', 1)), [], '来源不在线')
  assert.equal(core.stats.dropped, 4, '每一次丢弃都要计数（静默丢弃最难查）')
})

test('连接器断开：未认领的登记与设备绑定一并失效（不留指向消失连接的投递）', () => {
  const core = createRelayCore()
  core.attachConnector('conn-1')
  core.attachDevice('dev-1')
  core.registerPairing('conn-1', 'hash-a')
  core.registerPairing('conn-1', 'hash-b')
  assert.equal(core.claimTicket('dev-1', 'hash-a'), 'conn-1')

  core.detachConnector('conn-1')
  assert.equal(core.claimTicket('dev-1', 'hash-b'), undefined, '未认领的登记随连接器一起失效')
  assert.deepEqual(
    core.onLine({ kind: 'device', id: 'dev-1' }, line({ t: 'pair', id: 'p2', box: '{}' })),
    [],
    '设备失去了绑定：不能把帧投给一条已消失的连接',
  )
  assert.equal(core.stats.registrations, 0)
})

test('认领时连接器已不在线：绑定不成立（设备不该拿到指向空气的 ticket）', () => {
  const core = createRelayCore()
  core.attachConnector('conn-1')
  core.attachDevice('dev-1')
  core.registerPairing('conn-1', 'hash-a')
  core.detachConnector('conn-1') // 登记被清掉了
  assert.equal(core.claimTicket('dev-1', 'hash-a'), undefined)
})

test('设备断开：窗口、订阅关系与配对绑定都清掉（重连是一次新的订阅）', () => {
  const core = createRelayCore()
  core.attachConnector('conn-1')
  core.attachDevice('dev-1')
  core.onLine({ kind: 'device', id: 'dev-1' }, ev('sid_1', 0))
  core.onLine({ kind: 'connector', id: 'conn-1' }, ev('sid_1', 1))
  assert.equal(core.stats.windows, 1)

  core.detachDevice('dev-1')
  assert.equal(core.stats.windows, 0)
  assert.equal(core.stats.devices, 0)
})
