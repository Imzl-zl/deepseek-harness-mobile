/**
 * 设备侧**没有 `sid`** 的帧（握手三帧、配对提交、保活）走**通道绑定**路由，回程同样靠通道绑定 ——
 * 不再靠帧头 `id` 猜（不变量见 `docs/subsystems/pairing-v2.md` §2）。
 *
 * 这条规则是三方链路的必需条件：设备的第一帧是 `hello`，而它**没有 `sid`** ——
 * 按会话学的那张归属表帮不上它；少了这条规则，配好的设备永远握不上手
 * （表现是"配对成功但连不上"，而中转侧看起来只是在丢弃一帧）。
 *
 * v2 把它做得更硬：`id` 只是端点的关联标记，中转**不认识**它 ——
 * 同一个 `id` 出现在两条通道上时各回各的（靠 `id → 设备` 的表则会在冲突时串台）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createRelayCore } from '../src/core.ts'
import type { DeviceBinding } from '../../protocol/relay-control.mjs'

const line = (frame: Record<string, unknown>): string => JSON.stringify({ v: 1, ...frame })
const binding = (deviceId: string, connectorId = 'pc-1'): DeviceBinding =>
  ({ connectorId, deviceId, purpose: 'paired' })

test('无 sid 的握手帧沿通道投给连接器；回帧沿同一条通道回来（同一个 id 也各回各的）', () => {
  const core = createRelayCore()
  core.attachConnector('pc-1')
  core.attachConnector('pc-2')
  core.openDevice('channel-a', binding('phone-a', 'pc-1'))
  core.openDevice('channel-c', binding('phone-c', 'pc-2'))
  core.attachData('pc-1', 'phone-a', 'channel-a')
  core.attachData('pc-2', 'phone-c', 'channel-c')

  const hello = line({ t: 'hello', id: 'h1', box: '{}' })
  assert.deepEqual(
    core.onLine({ kind: 'device', channelId: 'channel-a' }, hello).deliveries,
    [{ channelId: 'channel-a', to: 'data', raw: hello }],
    '握手帧没有 sid —— 靠通道绑定路由，而不是被当成"没有归属"丢掉',
  )

  const ack = line({ t: 'hello-ack', id: 'h1', box: '{}' })
  assert.deepEqual(
    core.onLine({ kind: 'data', channelId: 'channel-a' }, ack).deliveries,
    [{ channelId: 'channel-a', to: 'device', raw: ack }],
    '电脑侧的回帧同样没有 sid —— 靠通道绑定找回发起方',
  )

  // 逐字相同的 `id` 出现在另一条通道上：各回各的（"按 id 找设备"会在这里串台）。
  assert.deepEqual(
    core.onLine({ kind: 'data', channelId: 'channel-c' }, ack).deliveries,
    [{ channelId: 'channel-c', to: 'device', raw: ack }],
  )
  assert.deepEqual(
    core.onLine({ kind: 'device', channelId: 'channel-c' }, hello).deliveries,
    [{ channelId: 'channel-c', to: 'data', raw: hello }],
  )
})

test('没有通道（未换票）时，无 sid 的帧被丢弃并计数（而不是投给随便谁）', () => {
  const core = createRelayCore()
  core.attachConnector('pc-1')

  assert.deepEqual(
    core.onLine({ kind: 'device', channelId: 'channel-x' }, line({ t: 'hello', id: 'h1', box: '{}' })).deliveries,
    [],
  )
  assert.deepEqual(
    core.onLine({ kind: 'device', channelId: 'channel-x' }, line({ t: 'pair-commit', id: 'p1', box: '{}' })).deliveries,
    [],
  )
  assert.equal(core.stats.dropped, 2, '两次丢弃都要计数（静默丢弃最难查）')

  // 对比：通道存在、只是电脑侧的数据连接还没到 —— 那**不是**丢弃，那条帧进有界缓冲。
  core.openDevice('channel-a', binding('phone-a'))
  assert.deepEqual(
    core.onLine({ kind: 'device', channelId: 'channel-a' }, line({ t: 'hello', id: 'h2', box: '{}' })).deliveries,
    [],
  )
  assert.equal(core.stats.dropped, 2, '缓冲不算丢弃')
})

test('通道关闭：旧通道上的握手回帧不再指向任何东西（重连是一条新代次）', () => {
  const core = createRelayCore()
  core.attachConnector('pc-1')
  core.openDevice('channel-a', binding('phone-a'))
  core.attachData('pc-1', 'phone-a', 'channel-a')
  core.onLine({ kind: 'device', channelId: 'channel-a' }, line({ t: 'hello', id: 'h1', box: '{}' }))

  core.closeChannel('channel-a')
  assert.deepEqual(
    core.onLine({ kind: 'data', channelId: 'channel-a' }, line({ t: 'hello-ack', id: 'h1', box: '{}' })).deliveries,
    [],
    '设备走了，那条通道的关联不该再指向任何东西',
  )
  assert.equal(core.stats.dropped, 1)

  // 重连是新代次：新通道上同一个 `id` 照常走通（旧代次的账不会压在它头上）。
  core.openDevice('channel-new', binding('phone-a'))
  core.attachData('pc-1', 'phone-a', 'channel-new')
  const ack = line({ t: 'hello-ack', id: 'h1', box: '{}' })
  assert.deepEqual(core.onLine({ kind: 'data', channelId: 'channel-new' }, ack).deliveries, [
    { channelId: 'channel-new', to: 'device', raw: ack },
  ])
})
