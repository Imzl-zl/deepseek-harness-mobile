/**
 * 拨号接线的端到端回归（契约 §2.2）。
 *
 * **这是本项目第一次让连接层真的跑起来**：起一个真的 WebSocket 服务端当对端，
 * 走完 `idle → connecting → handshake → serving`，收发真帧，然后让服务端把连接掐掉、
 * 观察退避重连。前面的单元测试都只验了零件，这里验的是**接线**。
 *
 * 用短周期（心跳 40 ms、攒批 30 ms）让整套链路在一秒内跑完。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import type { WireFrame } from '../src/protocol/frame.js'
import { createConnection, type Connection } from '../src/transport/connection.js'
import { startPeer, waitFor, type Peer } from './support/peer.js'

/**
 * 这组用例只关心「接线」，所以心跳一律拉到 5 s：握手阶段本来就一帧都不发，
 * 用 40 ms 这种真实周期会让半开判据在握手走完之前就把连接关掉 ——
 * 那种失败随机器负载时红时绿，而它检验的并不是用例想测的东西。
 */
const TRANSPORT_DEFAULTS = { heartbeatMs: 5_000, batchMs: 30 } as const

/** 取 `fc`（不是每个帧变体都有它）。 */
const fcOf = (frame: WireFrame | undefined): number | undefined =>
  frame !== undefined && 'fc' in frame ? frame.fc : undefined

/**
 * 建一条连接，并**注册清理**。
 *
 * 清理必须挂在测试上下文上而不是写在用例末尾：一旦某个 `waitFor` 超时抛错，
 * 后面的 `stop()` 就不会执行，而连接内部的定时器链会把整个测试进程吊住不退出 ——
 * 表现是"测试失败了但命令永不返回"，非常难查。
 */
function track(
  t: { after(fn: () => void | Promise<void>): void },
  peer: Peer,
  build: (url: string) => Connection,
): Connection {
  const connection = build(peer.url)
  t.after(async () => {
    connection.stop()
    await peer.close()
  })
  return connection
}

test('端到端：建连 → 握手 → serving → 收帧', async (t) => {
  const peer = await startPeer()
  const frames: WireFrame[] = []
  const states: string[] = []

  const connection = track(t, peer, (url) =>
    createConnection({
      url,
      dial: (target) => new WebSocket(target) as never,
      onFrame: (frame) => frames.push(frame),
      onStateChange: (from, to) => states.push(`${from}->${to}`),
      ...TRANSPORT_DEFAULTS,
    }),
  )

  connection.start()
  await waitFor('进入 handshake', () => connection.state === 'handshake')
  // 鉴权在 WSS 建立时已完成，握手由上层驱动（§4.1 三条消息）。
  connection.markHandshakeDone()
  assert.equal(connection.state, 'serving')

  // 服务端发一帧过来。
  peer.send({ v: 1, t: 'presence', computer: 'online' })
  await waitFor('收到服务端的帧', () => frames.length > 0)
  assert.deepEqual(frames[0], { v: 1, t: 'presence', computer: 'online' })

  // 只断言前三次迁移：之后心跳或断开可能再补迁移，但那不是本用例要锁的东西。
  assert.deepEqual(states.slice(0, 3), [
    'idle->connecting',
    'connecting->handshake',
    'handshake->serving',
  ])
})

test('端到端：出站帧的 fc 单调递增（重放防护的前提）', async (t) => {
  const peer = await startPeer()
  const connection = track(t, peer, (url) =>
    createConnection({
      url,
      dial: (target) => new WebSocket(target) as never,
      onFrame: () => {},
      ...TRANSPORT_DEFAULTS,
    }),
  )

  connection.start()
  await waitFor('进入 handshake', () => connection.state === 'handshake')
  connection.markHandshakeDone()

  // 连续发控制帧。`fc` 是每连接的计数器、也是 nonce 来源：
  // 一旦有重复或回退，对端会按 `protocol/replay` 直接拒绝（§4.2）。
  // 调用方故意传一个会被覆盖的 `fc`，证明分配权确实在连接层。
  for (let i = 0; i < 5; i += 1) {
    assert.equal(connection.send({ v: 1, t: 'credit', fc: 99, box: '' }), true)
  }
  await waitFor('服务端收到 5 帧', () => peer.received.length >= 5)

  assert.deepEqual(
    peer.received.slice(0, 5).map(fcOf),
    [0, 1, 2, 3, 4],
    'fc 必须由连接层从 0 开始单调分配，忽略调用方传的值',
  )
})

test('端到端：ev 攒批后到达，控制帧立刻到达', async (t) => {
  const peer = await startPeer()
  const connection = track(t, peer, (url) =>
    createConnection({
      url,
      dial: (target) => new WebSocket(target) as never,
      onFrame: () => {},
      heartbeatMs: 5_000, // 拉长心跳，免得 ping 混进来干扰计数
      batchMs: 60,
    }),
  )

  connection.start()
  await waitFor('进入 handshake', () => connection.state === 'handshake')
  connection.markHandshakeDone()

  // 控制帧立刻走。
  connection.send({ v: 1, t: 'credit', box: '' })
  await waitFor('控制帧立刻到达', () => peer.received.length === 1)

  // ev 进攒批窗口，不该立刻出现。
  connection.send({ v: 1, t: 'ev', sid: 's1', seq: 1, box: 'x' })
  connection.send({ v: 1, t: 'ev', sid: 's1', seq: 2, box: 'y' })
  await new Promise((resolve) => setTimeout(resolve, 20))
  assert.equal(peer.received.length, 1, 'ev 必须等攒批窗口，不逐帧推')

  // 窗口到了，两帧一起到。
  await waitFor('攒批的 ev 到达', () => peer.received.length === 3)
  assert.deepEqual(peer.received.slice(1).map((f) => f.t), ['ev', 'ev'])
})

test('端到端：链路被掐断后退避重连，stop 之后不再重连', async (t) => {
  const peer = await startPeer()
  const states: string[] = []

  const connection = track(t, peer, (url) =>
    createConnection({
      url,
      dial: (target) => new WebSocket(target) as never,
      onFrame: () => {},
      onStateChange: (from, to) => states.push(`${from}->${to}`),
      random: () => 0, // 退避取确定值，免得抖动让断言随机
      heartbeatMs: 5_000,
      batchMs: 30,
    }),
  )

  connection.start()
  await waitFor('进入 handshake', () => connection.state === 'handshake')
  connection.markHandshakeDone()

  // 掐断：服务端仍在监听，所以退避到点会重连成功。
  const firstSocketCount = peer.sockets.length
  peer.dropCurrent()
  await waitFor('回到 backoff', () => connection.state === 'backoff')
  await waitFor(
    '重连并再次进入 handshake',
    () => connection.state === 'handshake' && peer.sockets.length > firstSocketCount,
  )

  // 重连后 fc 必须从 0 重数 —— 新连接新密钥（§4.2）。
  connection.markHandshakeDone()
  peer.received.length = 0
  connection.send({ v: 1, t: 'credit', box: '' })
  await waitFor('新连接上的帧到达', () => peer.received.length > 0)
  assert.equal(
    fcOf(peer.received.at(-1)),
    0,
    '重连后 fc 必须从 0 重数（跨连接复用计数器会重用 nonce）',
  )

  // stop 之后不再重连。
  connection.stop()
  const socketsAfterStop = peer.sockets.length
  peer.dropCurrent()
  await new Promise((resolve) => setTimeout(resolve, 80))
  assert.equal(peer.sockets.length, socketsAfterStop, 'stop 之后不该再拨号')
  assert.equal(connection.state, 'idle')
})

test('端到端：握手前收到业务帧，连接被关闭', async (t) => {
  const peer = await startPeer()
  const warnings: string[] = []

  const connection = track(t, peer, (url) =>
    createConnection({
      url,
      dial: (target) => new WebSocket(target) as never,
      onFrame: () => {},
      log: { info: () => {}, warn: (message) => warnings.push(message) },
      heartbeatMs: 5_000,
      batchMs: 30,
    }),
  )

  connection.start()
  await waitFor('进入 handshake', () => connection.state === 'handshake')

  // 握手还没走完就发业务帧 —— 这是攻击面，必须关闭而不是"先收着"。
  peer.send({ v: 1, t: 'credit', fc: 0 })
  await waitFor(
    '连接已被关闭',
    () => connection.state !== 'handshake' && connection.state !== 'serving',
  )
  assert.equal(warnings.length > 0, true, '应记录一次拒绝')
})

test('端到端：发帧也重置空闲计时（半开判据是「任一方向」）', async (t) => {
  const peer = await startPeer()
  // 短心跳：半开阈值 = 2 × 40 = 80 ms，用例几百毫秒内就能给出结论。
  const connection = track(t, peer, (url) =>
    createConnection({
      url,
      dial: (target) => new WebSocket(target) as never,
      onFrame: () => {},
      heartbeatMs: 40,
      batchMs: 30,
    }),
  )

  connection.start()
  await waitFor('进入 handshake', () => connection.state === 'handshake')
  connection.markHandshakeDone()

  // **只发不收**：对端一个字节都不回。若发帧不算「有动静」，80 ms 后就会被判半开 ——
  // 而契约 §2.2 写的是「任一方向」。
  const until = Date.now() + 300
  while (Date.now() < until) {
    assert.equal(connection.send({ v: 1, t: 'credit', box: '' }), true)
    await new Promise((resolve) => setTimeout(resolve, 15))
    assert.equal(connection.state, 'serving', '发帧期间不该被判半开')
  }
  assert.equal(peer.received.filter((f) => f.t === 'credit').length > 5, true)
})

test('端到端：完全空闲仍会判半开（ping 不许把空闲计时重置掉）', async (t) => {
  const peer = await startPeer()
  const connection = track(t, peer, (url) =>
    createConnection({
      url,
      dial: (target) => new WebSocket(target) as never,
      onFrame: () => {},
      heartbeatMs: 40,
      batchMs: 30,
    }),
  )

  connection.start()
  await waitFor('进入 handshake', () => connection.state === 'handshake')
  connection.markHandshakeDone()

  // 一个周期后该发探针，两个周期后该判半开。
  // 如果连 `ping` 自己都重置空闲计时，这里会永远停在 `serving`：
  // 每个周期都发一次 ping，沉默时间永远攒不满两个周期。
  await waitFor('发出探针 ping', () => peer.received.some((f) => f.t === 'ping'))
  await waitFor('判定半开并进入退避', () => connection.state === 'backoff')
})
