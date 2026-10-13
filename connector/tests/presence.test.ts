/**
 * `presence.ts` 的设备瞬时状态（契约 §6.2 仲裁判定的**唯一**输入）。
 *
 * 这一层在接线之前恒为空，于是完整因果链是
 * 「`liveDevices()` 返回 [] → `decideTakeover` 永不 claim → answerer 永远 `next()`
 * → fail-closed 桩根本跑不到」。下面几条用例各自钉住这一层的一个不变量，
 * 特别是「连接层认证过不等于授权过」与「断开要整条作废」。
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

test('连接层认证过不等于授权过：未配对与已吊销的设备都不进仲裁', () => {
  const presence = makePresence({ 'dev-a': 100, 'dev-b': undefined })
  presence.online('dev-a')
  presence.online('dev-b')
  assert.deepEqual(
    presence.devices().map((device) => device.id),
    ['dev-a'],
    'dev-b 没有配对行（或已吊销）—— 它连上了，但不参与仲裁',
  )
  assert.equal(presence.size, 2, '记录仍在（诊断要看得到），只是不进仲裁输入')
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

test('onOffline：断开即通知，注销后不再通知，桶空了就撤掉', () => {
  const presence = makePresence(PAIRED)
  presence.online('dev-a')
  let fired = 0
  const cancel = presence.onOffline('dev-a', () => {
    fired += 1
  })

  // 在线期间的普通上报不触发下线通知。
  presence.app('dev-a', 'foreground')
  assert.equal(fired, 0)

  presence.offline('dev-a')
  assert.equal(fired, 1, '断开必须立刻通知：看护要靠它收束，不能等满一个看护周期')

  // 已经下线再调一次不再触发（记录已经没了）。
  presence.offline('dev-a')
  assert.equal(fired, 1)

  cancel()
  presence.online('dev-a')
  presence.offline('dev-a')
  assert.equal(fired, 1, '注销之后不再通知：否则在途 claim 会累积监听器')
})

test('未在线的设备问 liveOf 是 undefined（端口据此立刻 fail-closed）', () => {
  const presence = makePresence(PAIRED)
  assert.equal(presence.liveOf('dev-a'), undefined)
  presence.online('dev-a')
  assert.equal(presence.liveOf('dev-a')?.online, true)
})
