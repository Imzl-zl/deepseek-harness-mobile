/**
 * 每连接装配（`createConnectionScope`）的用例。
 *
 * 它守的是一条**断言**：每连接的活物只通过**给它的那个 port** 往外走 —— 这正是
 * "监听面 accept 第二条 socket 就能多一台设备"的全部依据。没有这条用例，抽取的收益
 * 只是"代码更整齐"，而"两条连接串台"不会有任何东西变红 —— 串台的表现是帧发到了另一台手机上。
 *
 * 顺带钉住一处**取舍**：增量缓冲是**挂载级共享**的（理由见 `src/connection-scope.ts` 的文件头），
 * 所以两条连接的水位进的是同一张表，而"这是哪台设备"由**各自握手**决定（§5.5 的裁剪点
 * 是全部配对设备水位的最小值，那本来就是一个跨设备的量）。
 *
 * 笔记：`.agents/notes/implemented/2026-10-01-per-connection-scope-is-an-extraction.md`
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createConnectionScope, type ConnectionScopeDeps } from '../src/connection-scope.js'
import { createMetrics, silentLogger } from '../src/observability.js'
import { createPairing } from '../src/pairing.js'
import { createSessionBuffer, type SessionBuffer } from '../src/session-buffer.js'
import type { Caps } from '../src/dsh/caps.js'
import type { WireFrame } from '../src/protocol/frame.js'
import type { ConnectionPort, OutboundFrame } from '../src/transport/connection.js'

/** 一个假连接：只记下从这个端口出去的帧。 */
interface FakePort {
  port: ConnectionPort
  /** 业务出帧口（`send`）。 */
  sent: OutboundFrame[]
  /** 配对出帧口（`sendPairingFrame`）—— 它**不是**业务口，两者混用是协议错误。 */
  paired: WireFrame[]
}

function fakePort(state: 'serving' | 'closed' = 'serving'): FakePort {
  const sent: OutboundFrame[] = []
  const paired: WireFrame[] = []
  return {
    sent,
    paired,
    port: {
      send: (frame) => {
        sent.push(frame)
        return true
      },
      sendPairingFrame: (frame) => {
        paired.push(frame)
      },
      whenWritable: () => Promise.resolve(),
      state,
    },
  }
}

const CAPS: Caps = {
  sessions: true,
  storage: true,
  approval: false,
  questions: false,
  jobs: false,
  subagents: false,
  settings: false,
  credentials: true,
}

/** 永不结束的 `follow`（本套用例不建立订阅；被调到就是装配写错了）。 */
const NO_FOLLOW = (): never => {
  throw new Error('本用例不该建立订阅')
}

function makeDeps(overrides: Partial<ConnectionScopeDeps> = {}): ConnectionScopeDeps {
  return {
    logger: silentLogger,
    metrics: createMetrics(),
    handlers: {
      caps: () => CAPS,
      aliasVersion: () => 0,
      sessions: { list: async () => [], prompt: async () => ({ accepted: true as const }) },
      aliases: { ensure: async () => 's1', sessionOf: () => undefined },
      devices: () => [],
    },
    sessions: {
      list: async () => [],
      follow: NO_FOLLOW,
      page: async () => ({ records: [], hasMore: false }),
      prompt: async () => ({ accepted: true as const }),
      cancel: () => ({ accepted: true as const }),
    },
    buffer: createSessionBuffer({ pairedDevices: () => [] }),
    jobControl: null,
    pairing: createPairing({ relayUrl: 'wss://relay.example', pcPubEd: 'aa', pcPubDh: 'bb' }),
    putDevice: async () => {},
    idempotency: null,
    ...overrides,
  }
}

/** 让异步收尾（方法面/配对的 `.then`）跑完。 */
const settle = (): Promise<void> => new Promise((resolve) => setImmediate(resolve))

const persisted = (sid: string, seq: number, fc: number): WireFrame => ({
  v: 1,
  t: 'persisted',
  sid,
  seq,
  fc,
  box: '',
})

test('两条连接各走各的端口：一条上的 ping / req / pair 不会出现在另一条上', async () => {
  const a = fakePort()
  const b = fakePort()
  // 一份 deps 喂两条连接 —— 这正是将来的监听面（同一个桥接接受多条 socket）。
  const deps = makeDeps()
  const scopeA = createConnectionScope(a.port, deps)
  const scopeB = createConnectionScope(b.port, deps)

  scopeA.handleFrame({ v: 1, t: 'ping', fc: 1, box: '' })
  assert.deepEqual(a.sent.map((frame) => frame.t), ['pong'], 'ping 要在**本条**连接上回 pong')
  assert.deepEqual(b.sent, [], 'B 什么都没收到，却收到了 A 的 pong')

  scopeA.handleFrame({
    v: 1,
    t: 'req',
    id: 'r1',
    fc: 2,
    box: JSON.stringify({ method: 'repo.info' }),
  })
  await settle()
  assert.deepEqual(a.sent.map((frame) => frame.t), ['pong', 'res'], '应答只落在发请求的那条连接上')
  assert.deepEqual(b.sent, [], '应答跑到另一条连接上 = 另一台手机收到别人的回复')

  // 配对帧走**配对出帧口**（`send` 在服务态之前恒为 false，配对必须在握手之前出得去）。
  scopeB.handleFrame({ v: 1, t: 'pair', id: 'p1', box: '{' })
  await settle()
  assert.deepEqual(b.paired.map((frame) => frame.t), ['pair-ack'], '配对回执要走配对口')
  assert.deepEqual(b.sent, [], '配对回执不该从业务口出去')
  assert.deepEqual(a.paired, [], '配对回执不该跑到另一条连接上')
})

test('设备身份是每连接的；增量缓冲是挂载级共享的（§5.5 的裁剪点是跨设备的最小值）', () => {
  const buffer: SessionBuffer = createSessionBuffer({ pairedDevices: () => ['dev-a', 'dev-b'] })
  const a = fakePort()
  const b = fakePort()
  const deps = makeDeps({ buffer })
  const scopeA = createConnectionScope(a.port, deps)
  const scopeB = createConnectionScope(b.port, deps)

  for (const seq of [1, 2, 3, 4]) buffer.record('s1', { seq, body: `e${seq}` })

  // 两条连接各自握手出各自的设备。水位进的是**同一张**缓冲表。
  scopeA.deviceEstablished('dev-a')
  scopeB.deviceEstablished('dev-b')

  scopeA.handleFrame(persisted('s1', 4, 1))
  assert.equal(buffer.stats.frames, 4, '只有一台设备确认时必须一行都不裁（§5.5 逐设备水位）')

  scopeB.handleFrame(persisted('s1', 4, 1))
  assert.equal(buffer.stats.frames, 0, '两台设备都确认过才允许裁 —— 它们分属两条连接')

  // 新的一段：只让慢的那台（dev-a）落后，才能观察到"A 的水位有没有被推进"。
  for (const seq of [5, 6]) buffer.record('s1', { seq, body: `e${seq}` })
  scopeB.handleFrame(persisted('s1', 6, 2))
  assert.equal(buffer.stats.frames, 2, 'dev-a 还停在 4，5..6 不许裁')

  // A 离开服务态 → 身份作废：此后再来的 `persisted` 不许替 dev-a 记水位
  //（连接没了，"这台设备"就不成立；新连接会重新握手）。
  scopeA.servingEnded()
  scopeA.handleFrame(persisted('s1', 6, 3))
  assert.equal(buffer.stats.frames, 2, '脱离服务态的连接还在推进水位 = 用旧身份替新连接背书')

  // 反面对照：一条**在服务态**的连接带同一个设备 id 确认，就会裁掉 —— 证明上一条断言有意义。
  const c = fakePort()
  const scopeC = createConnectionScope(c.port, deps)
  scopeC.deviceEstablished('dev-a')
  scopeC.handleFrame(persisted('s1', 6, 1))
  assert.equal(buffer.stats.frames, 0, '在服务态的连接确认后应当裁掉（否则上一条断言空过）')
})
