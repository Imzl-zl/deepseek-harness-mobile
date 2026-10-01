/**
 * 连接行为的回归（契约 §2.2、§9、§10）。
 *
 * 这四个单元都是纯逻辑（时间与随机数注入），所以能在这里把「掉线、半开、攒批、非法迁移」
 * 这些平时要靠真机才碰得到的路径逐个走一遍 —— 而它们恰好是最难在真机上复现的部分
 * （真半开连接要拔网线、要等 NAT 超时）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  BACKOFF_BASE_MS,
  BACKOFF_MAX_MS,
  createBackoff,
} from '../src/transport/backoff.js'
import { createBatcher } from '../src/transport/batch.js'
import { HALF_OPEN_PERIODS, HEARTBEAT_MS, createKeepalive } from '../src/transport/keepalive.js'
import {
  CONNECTION_STATES,
  IllegalTransitionError,
  createConnectionMachine,
} from '../src/transport/state.js'

test('退避：指数递增、30 s 封顶、抖动在 ±20% 内、reset 回起点', () => {
  // random 固定成 0.5 ⇒ 抖动系数为 0，便于断言未抖动的骨架。
  const noJitter = createBackoff(() => 0.5)
  const sequence: number[] = []
  for (let i = 0; i < 10; i += 1) sequence.push(noJitter.next())
  assert.deepEqual(sequence.slice(0, 6), [1_000, 2_000, 4_000, 8_000, 16_000, 30_000])
  for (const ms of sequence) assert.ok(ms <= BACKOFF_MAX_MS, `${ms} 超过上界`)

  // 抖动不得顶破上界 —— 上界是「回到前台能快速恢复」的保证。
  const maxJitter = createBackoff(() => 1)
  for (let i = 0; i < 10; i += 1) assert.ok(maxJitter.next() <= BACKOFF_MAX_MS)

  const lowJitter = createBackoff(() => 0)
  assert.equal(lowJitter.next(), Math.round(BACKOFF_BASE_MS * 0.8))

  const backoff = createBackoff(() => 0.5)
  backoff.next()
  backoff.next()
  assert.equal(backoff.attempt, 2)
  backoff.reset()
  assert.equal(backoff.attempt, 0)
  assert.equal(backoff.next(), BACKOFF_BASE_MS, 'reset 后必须从 base 重来')
})

test('保活：空闲满一个周期发心跳，满两个周期判半开', () => {
  const keepalive = createKeepalive({ startedAt: 0 })

  assert.deepEqual(keepalive.tick(HEARTBEAT_MS - 1), { kind: 'idle' })
  assert.deepEqual(keepalive.tick(HEARTBEAT_MS), { kind: 'ping' })
  // 发过心跳后不该每 tick 都再发 —— 那会在对端还没回 pong 前就刷屏。
  assert.deepEqual(keepalive.tick(HEARTBEAT_MS + 1), { kind: 'idle' })

  // 心跳本身重置空闲计时，所以半开阈值从「上一次心跳」起算。
  const halfOpenAt = HEARTBEAT_MS + HEARTBEAT_MS * HALF_OPEN_PERIODS
  assert.deepEqual(keepalive.tick(halfOpenAt), { kind: 'half-open', silentMs: HEARTBEAT_MS * HALF_OPEN_PERIODS })
})

test('保活：任何一帧都重置空闲计时（收与发都算）', () => {
  const keepalive = createKeepalive({ startedAt: 0 })
  // 快到半开阈值时来了一帧，计时归零。
  keepalive.onFrame(HEARTBEAT_MS * HALF_OPEN_PERIODS - 1)
  assert.deepEqual(keepalive.tick(HEARTBEAT_MS * HALF_OPEN_PERIODS), { kind: 'idle' })
  assert.equal(keepalive.silentFor(HEARTBEAT_MS * HALF_OPEN_PERIODS), 1)
})

test('保活：后台不发心跳，但半开判定照旧', () => {
  const keepalive = createKeepalive({ startedAt: 0 })
  keepalive.setForeground(false)
  assert.deepEqual(keepalive.tick(HEARTBEAT_MS), { kind: 'idle' }, '后台不该发心跳')
  assert.equal(keepalive.tick(HEARTBEAT_MS * HALF_OPEN_PERIODS).kind, 'half-open')
})

test('攒批：窗口到点或攒够 4 KiB 即触发，后台不触发', () => {
  const batcher = createBatcher<string>()
  assert.equal(batcher.due(0), false, '空批次不触发')

  batcher.push('a', 100, 0)
  assert.equal(batcher.due(49), false)
  assert.equal(batcher.due(50), true, '窗口到点')

  const batch = batcher.take()
  assert.deepEqual(batch, { items: ['a'], bytes: 100 })
  assert.equal(batcher.pending, 0)
  assert.equal(batcher.take(), null, '取过之后是空的')

  // 字节阈值优先：不必等窗口。
  batcher.push('big', 4 * 1024, 0)
  assert.equal(batcher.due(1), true, '攒够 4 KiB 立刻发')

  // 后台不推。
  batcher.setForeground(false)
  assert.equal(batcher.due(1_000), false, '后台不推')
  batcher.setForeground(true)
  assert.equal(batcher.due(1_000), true)
})

test('状态机：白名单迁移，非法迁移抛错', () => {
  const machine = createConnectionMachine()
  assert.equal(machine.state, 'idle')
  assert.equal(machine.acceptsBusinessFrames, false, '握手前不收业务帧')

  machine.to('connecting')
  machine.to('handshake')
  assert.equal(machine.acceptsBusinessFrames, false, '握手完成前仍不收业务帧')
  machine.to('serving')
  assert.equal(machine.acceptsBusinessFrames, true)

  machine.to('closed')
  machine.to('backoff')
  machine.to('connecting')

  // 非法迁移必须响：否则「两条连接同时存在」这类 bug 会静默发生。
  assert.throws(() => createConnectionMachine('idle').to('serving'), IllegalTransitionError)
  assert.throws(() => createConnectionMachine('serving').to('handshake'), IllegalTransitionError)
  assert.throws(() => createConnectionMachine('handshake').to('backoff'), IllegalTransitionError)

  // 主动断开：closed / backoff 都能回 idle，从 idle 只能去 connecting。
  assert.doesNotThrow(() => createConnectionMachine('backoff').to('idle'))
  assert.throws(() => createConnectionMachine('idle').to('closed'), IllegalTransitionError)

  assert.equal(CONNECTION_STATES.length, 6)
})

test('状态机：迁移通知按顺序派发，取消订阅后不再收', () => {
  const machine = createConnectionMachine()
  const seen: string[] = []
  const off = machine.onChange((from, to) => seen.push(`${from}->${to}`))
  machine.to('connecting')
  machine.to('closed')
  off()
  machine.to('idle')
  assert.deepEqual(seen, ['idle->connecting', 'connecting->closed'])
})
