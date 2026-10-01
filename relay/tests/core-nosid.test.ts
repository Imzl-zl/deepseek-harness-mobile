/**
 * 设备侧"没有 `sid`"的帧（握手三帧、配对、保活）走**ticket 绑定**，回程靠帧头 `id`。
 *
 * 这条规则是三方链路的必需条件：设备的第一帧是 `hello`，而它**没有 `sid`** ——
 * 归属表按会话学，帮不上它；少了这条规则，配好的设备永远握不上手
 * （表现是"配对成功但连不上"，而中转侧看起来只是在丢弃一帧）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createRelayCore } from '../src/core.ts'

const line = (frame: Record<string, unknown>): string => JSON.stringify({ v: 1, ...frame })

test('设备侧的 hello（无 sid）按 ticket 绑定投给连接器，hello-ack 靠 id 回到那台设备', () => {
  const core = createRelayCore()
  core.attachConnector('conn-1')
  core.attachDevice('dev-1')
  core.registerPairing('conn-1', 'hash-a')
  assert.equal(core.claimTicket('dev-1', 'hash-a'), 'conn-1')

  const hello = line({ t: 'hello', id: 'h1', box: '{}' })
  assert.deepEqual(
    core.onLine({ kind: 'device', id: 'dev-1' }, hello),
    [{ to: 'conn-1', raw: hello }],
    '握手帧没有 sid —— 靠绑定路由，而不是被当成"没有归属"丢掉',
  )

  const ack = line({ t: 'hello-ack', id: 'h1', box: '{}' })
  assert.deepEqual(
    core.onLine({ kind: 'connector', id: 'conn-1' }, ack),
    [{ to: 'dev-1', raw: ack }],
    '电脑侧的回帧同样没有 sid —— 靠 `id` 找回发起方',
  )
})

test('没有绑定（未换票）时，握手帧被丢弃并计数（而不是投给随便谁）', () => {
  const core = createRelayCore()
  core.attachConnector('conn-1')
  core.attachDevice('dev-1')

  assert.deepEqual(core.onLine({ kind: 'device', id: 'dev-1' }, line({ t: 'hello', id: 'h1', box: '{}' })), [])
  assert.deepEqual(core.onLine({ kind: 'device', id: 'dev-1' }, line({ t: 'pair', id: 'p1', box: '{}' })), [])
  assert.equal(core.stats.dropped, 2, '两次丢弃都要计数（静默丢弃最难查）')
})

test('设备断开：`id` 关联一并清掉（重连是一次新的会话）', () => {
  const core = createRelayCore()
  core.attachConnector('conn-1')
  core.attachDevice('dev-1')
  core.registerPairing('conn-1', 'hash-a')
  core.claimTicket('dev-1', 'hash-a')
  core.onLine({ kind: 'device', id: 'dev-1' }, line({ t: 'hello', id: 'h1', box: '{}' }))

  core.detachDevice('dev-1')
  assert.deepEqual(
    core.onLine({ kind: 'connector', id: 'conn-1' }, line({ t: 'hello-ack', id: 'h1', box: '{}' })),
    [],
    '设备走了，那条 `id` 关联不该再指向任何东西',
  )
})
