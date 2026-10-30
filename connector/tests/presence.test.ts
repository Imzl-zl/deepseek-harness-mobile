/**
 * `presence.ts` 的设备瞬时状态。
 *
 * 三个读者：管理面的设备列表、`connection-scope.ts` 的订阅集上报、
 * "手机答过一次话"的时间戳。下面几条用例各钉住一个不变量，特别是
 * 「连接层认证过不等于授权过」与「断开要整条作废」。
 *
 * **这里没有"离线通知"**：断线不是任何交互的终态（DSH 的 gateway 断线只撤投递、
 * 不结算，`packages/api/gateway/src/index.ts:717-721`）—— 曾经为"看护"加的
 * `onOffline` 已随那条自创规则一起删除。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createDevicePresence, type DevicePresence } from '../src/presence.js'

/** 配对行：`pairedAtOf` 返回 `undefined` = 没配过对或已吊销。 */
function makePresence(paired: Record<string, number | undefined> = {}): DevicePresence {
  return createDevicePresence({ pairedAtOf: (devId) => paired[devId] })
}

const PAIRED = { 'dev-a': 100, 'dev-b': 50 }

test('四个上报时机各自改变判定输入', () => {
  const presence = makePresence(PAIRED)

  // 鉴权完成：在线，但**前台态仍为 false**（还没收到 sync.hello）。
  // 少了这条，一个刚连上的设备会被 foreground 档误判成"用户正看着手机"。
  presence.online('dev-a')
  assert.deepEqual(presence.devices(), [
    { id: 'dev-a', pairedAt: 100, online: true, foreground: false, subscribed: [] },
  ])

  // sync.hello：声明前台 + 订阅集。
  presence.app('dev-a', 'foreground')
  presence.subscriptions('dev-a', ['sid_1'])
  assert.deepEqual(presence.devices(), [
    { id: 'dev-a', pairedAt: 100, online: true, foreground: true, subscribed: ['sid_1'] },
  ])

  // 答了一次话：`lastInteractedAt` 只覆盖被答的那个会话，别的会话不受影响。
  presence.interacted('dev-a', 'sid_1', 777)
  assert.deepEqual(presence.devices()[0]?.lastInteractedAt, { sid_1: 777 })
  presence.interacted('dev-a', 'sid_2', 888)
  assert.deepEqual(presence.devices()[0]?.lastInteractedAt, { sid_1: 777, sid_2: 888 })

  // 订阅集是**整体覆盖**，不是追加：手机退订一个会话后它不该还留在判定输入里。
  presence.subscriptions('dev-a', ['sid_2'])
  assert.deepEqual(presence.devices()[0]?.subscribed, ['sid_2'])
})

test('连接层认证过不等于授权过：未配对与已吊销的设备都不出现在列表里', () => {
  const presence = makePresence({ 'dev-a': 100, 'dev-b': undefined })
  presence.online('dev-a')
  presence.online('dev-b')
  assert.deepEqual(
    presence.devices().map((device) => device.id),
    ['dev-a'],
    'dev-b 没有配对行（或已吊销）—— 它连上了，但不进列表',
  )
  assert.equal(presence.size, 2, '记录仍在（诊断要看得到），只是不进列表')
})

test('断开整条作废：订阅集不留下次连接的影子', () => {
  const presence = makePresence(PAIRED)
  presence.online('dev-a')
  presence.app('dev-a', 'foreground')
  presence.subscriptions('dev-a', ['sid_1'])
  presence.interacted('dev-a', 'sid_1', 1)

  presence.offline('dev-a')
  assert.equal(presence.liveOf('dev-a'), undefined)
  assert.deepEqual(presence.devices(), [])

  // 重连后是一条**新**记录：前台、订阅、最近交互全部从零开始。
  // 少了这一条，"设备已断但 decideTakeover 仍认为它订阅着这个会话"就会发生 ——
  // 而 foreground 档的 claim 判据正是"前台且已订阅"。
  presence.online('dev-a')
  assert.deepEqual(presence.devices(), [
    { id: 'dev-a', pairedAt: 100, online: true, foreground: false, subscribed: [] },
  ])
})

test('占用位：只有当在线且有效的那一台占着，断开即空', () => {
  const presence = makePresence({ 'dev-a': 100, 'dev-b': 50, 'dev-gone': undefined })
  // 没人连：没有占用者。
  assert.equal(presence.serving(), undefined)

  presence.online('dev-a')
  assert.equal(presence.serving()?.id, 'dev-a', '在线即占位')

  // **已吊销 / 没有配对行的设备连上来也不占位**（占坑 DoS 的判据：停用一台旧手机
  // 不能让它把占用位永久挂着）。
  presence.online('dev-gone')
  assert.equal(presence.serving()?.id, 'dev-a', '已吊销的那台不占位')

  // 占位者离开：下一次心跳前后都不该再有人占着（主动 close 的判据）。
  presence.offline('dev-a')
  assert.equal(presence.serving(), undefined, '断开即释放占用位')
})

test('换网重连：旧连接迟到的 offline 不许抹掉新连接的占用位', () => {
  // 中转对同一 (connectorId, deviceId) 会先关旧通道再放新通道（`replaced`），
  // 但两条连接走两条 TCP —— 旧连接的 close 完全可能晚于新连接的握手完成。
  // 没有令牌时，旧连接的 `offline` 会把**新连接**刚占上的记录删掉：
  // 面板显示离线、下一台设备被放进来（两台同时在服务）。
  const presence = makePresence(PAIRED)
  const oldConnection = {}
  const newConnection = {}

  presence.online('dev-a', oldConnection)
  presence.online('dev-a', newConnection) // 新连接接管记录
  assert.equal(presence.serving()?.id, 'dev-a')

  presence.offline('dev-a', oldConnection) // 旧连接迟到的断开
  assert.equal(presence.serving()?.id, 'dev-a', '记录现在属于新连接，不许删')
  assert.equal(presence.liveOf('dev-a')?.online, true)

  presence.offline('dev-a', newConnection) // 新连接自己断开
  assert.equal(presence.serving(), undefined, '令牌对上了才真的释放')
})

test('未在线的设备问 liveOf 是 undefined（读取面据此显示"离线"，不猜一条幽灵记录）', () => {
  const presence = makePresence(PAIRED)
  assert.equal(presence.liveOf('dev-a'), undefined)
  presence.online('dev-a')
  assert.equal(presence.liveOf('dev-a')?.online, true)
})
