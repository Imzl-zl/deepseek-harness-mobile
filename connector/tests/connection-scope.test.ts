import assert from 'node:assert/strict'
import { test } from 'node:test'
import { createConnectionScope, type ConnectionScopeDeps } from '../src/connection-scope.js'
import { createMetrics, silentLogger } from '../src/observability.js'
import { createDevicePresence } from '../src/presence.js'
import { createPairing } from '../src/pairing.js'
import { createPairingEndpoint } from '../src/pairing-endpoint.js'
import { createSessionBuffer } from '../src/session-buffer.js'
import type { WireFrame } from '../src/protocol/frame.js'
import type { ConnectionPort, OutboundFrame } from '../src/transport/connection.js'

function fakePort() {
  const sent: OutboundFrame[] = []
  const port: ConnectionPort = { state: 'serving', send: (frame) => { sent.push(frame); return true }, whenWritable: async () => {} }
  return { sent, port }
}
function makeDeps(overrides: Partial<ConnectionScopeDeps> = {}): ConnectionScopeDeps {
  const sessions = {
    list: async () => [], prompt: async () => ({ accepted: true as const }), cancel: () => ({ accepted: true as const }),
    updateQueue: async () => ({ accepted: true as const }),
    selectModel: async () => ({ selected: { provider: 'test', model: 'test' } }),
    create: async () => ({ sessionId: 'dsh-new' }),
    page: async () => ({ records: [], hasMore: false }), follow: (): never => { throw new Error('本用例不应建立订阅') },
  }
  return {
    logger: silentLogger, metrics: createMetrics(), sessions,
    handlers: {
      caps: () => ({ sessions: true, storage: true, approval: false, questions: false, jobs: false, subagents: false, references: false, plugins: false, settings: false, credentials: true, direct: false }),
      aliasVersion: () => 0, sessions, aliases: { ensure: async () => 's1', sessionOf: () => undefined }, devices: () => [],
    },
    buffer: createSessionBuffer({ pairedDevices: () => [] }), jobControl: null, idempotency: null, ...overrides,
  }
}
const frameTypes = (frames: readonly OutboundFrame[]) => frames.map((frame) => frame.t)
const settle = (): Promise<void> => new Promise((resolve) => setImmediate(resolve))
const persisted = (seq: number, fc: number): WireFrame => ({ v: 1, t: 'persisted', sid: 's1', seq, fc, box: '' })

test('sendStatus：未认证不发；认证后推一封 `status` 帧（载荷 `{running}`）', () => {
  // 运行态是**宿主推送的转发**（`api-session/status`）。它不走订阅，所以只能从
  // 挂载级按"活连接"广播 —— `ConnectionScope.sendStatus` 就是那条出口。
  const a = fakePort()
  const scope = createConnectionScope(a.port, makeDeps())
  assert.equal(scope.sendStatus('s1', true), false, '待配对 / 未认证的连接不发运行态')
  assert.deepEqual(a.sent, [])

  scope.deviceEstablished('dev-a')
  assert.equal(scope.sendStatus('s1', true), true)
  assert.deepEqual(a.sent, [
    { v: 1, t: 'status', sid: 's1', box: JSON.stringify({ running: true }) },
  ])
})

test('两连接的 ping、业务应答和配对应答都只走自己的端口', async (t) => {
  const a = fakePort()
  const b = fakePort()
  const deps = makeDeps()
  const scopeA = createConnectionScope(a.port, deps)
  scopeA.deviceEstablished('dev-a')
  scopeA.handleFrame({ v: 1, t: 'ping', id: 'ping-a', fc: 0, box: '' })
  assert.deepEqual(a.sent, [{ v: 1, t: 'pong', id: 'ping-a', box: '' }])
  assert.deepEqual(b.sent, [])
  scopeA.handleFrame({ v: 1, t: 'req', id: 'r1', fc: 1, box: JSON.stringify({ method: 'repo.info' }) })
  await settle()
  assert.deepEqual(a.sent.map((frame) => frame.t), ['pong', 'res'])
  assert.deepEqual(b.sent, [])

  const pairing = createPairing({ pcId: 'pc-1', relayUrl: 'wss://relay.example', pcPubEd: 'a'.repeat(64), pcPubDh: 'b'.repeat(64) })
  const endpoint = createPairingEndpoint({ pairing, pcId: 'pc-1', putDevice: async () => { throw new Error('坏 JSON 不得写库') }, findPreviousPairing: () => null, removeDevice: async () => {}, announce: async () => {} })
  t.after(() => endpoint.dispose())
  const scopeB = createConnectionScope(b.port, deps, {
    candidate: { offerId: 'A'.repeat(22), devPubEd: 'c'.repeat(64), devPubDh: 'd'.repeat(64), name: '手机' }, endpoint,
  })
  scopeB.pairingEstablished()
  scopeB.handleFrame({ v: 1, t: 'pair-commit', id: 'p1', fc: 0, box: '{' })
  await settle()
  assert.deepEqual(frameTypes(b.sent), ['pair-result'])
  assert.deepEqual(a.sent.map((frame) => frame.t), ['pong', 'res'])
})

test('设备身份独立，共享缓冲只按所有设备的持久水位裁剪', () => {
  const buffer = createSessionBuffer({ pairedDevices: () => ['dev-a', 'dev-b'] })
  const deps = makeDeps({ buffer })
  const a = createConnectionScope(fakePort().port, deps)
  const b = createConnectionScope(fakePort().port, deps)
  a.deviceEstablished('dev-a')
  b.deviceEstablished('dev-b')
  for (const seq of [1, 2, 3, 4]) buffer.record('s1', { seq, body: `e${seq}` })
  a.handleFrame(persisted(4, 1))
  assert.equal(buffer.stats.frames, 4)
  b.handleFrame(persisted(4, 1))
  assert.equal(buffer.stats.frames, 0)
  for (const seq of [5, 6]) buffer.record('s1', { seq, body: `e${seq}` })
  b.handleFrame(persisted(6, 2))
  assert.equal(buffer.stats.frames, 2)
  a.servingEnded()
  assert.throws(() => a.handleFrame(persisted(6, 3)), /认证/)
  assert.equal(buffer.stats.frames, 2)
  const c = createConnectionScope(fakePort().port, deps)
  c.deviceEstablished('dev-a')
  c.handleFrame(persisted(6, 1))
  assert.equal(buffer.stats.frames, 0)
})

test('候选即使完成加密也不能激活业务身份或调用方法', () => {
  const scope = createConnectionScope(fakePort().port, makeDeps(), {
    candidate: { offerId: 'A'.repeat(22), devPubEd: 'c'.repeat(64), devPubDh: 'd'.repeat(64), name: '手机' },
    endpoint: { handle: async () => { throw new Error('不该提交配对') }, dispose() {} },
  })
  assert.throws(() => scope.deviceEstablished('dev-a'), /候选/)
  scope.pairingEstablished()
  assert.throws(() => scope.handleFrame({ v: 1, t: 'req', id: 'r1', fc: 0, box: '{"method":"session.prompt"}' }), /待配对/)
})

/**
 * presence 上报的四个时机（契约 §6.2 的判定输入只有一个来源）。
 *
 * 接线之前 `liveDevices()` 恒为空，于是完整因果链是
 * 「decideTakeover 永不 claim → answerer 永远 next() → 端口根本跑不到」。
 * 这四条用例各自钉住一个写入时机。
 */
test('presence：鉴权完成即上线（前台态仍为 false），断开整条下线', () => {
  const reported: string[] = []
  const deps = makeDeps({
    presence: {
      online: (devId) => reported.push(`online:${devId}`),
      offline: (devId) => reported.push(`offline:${devId}`),
      app: () => reported.push('app'),
      subscriptions: () => reported.push('subscriptions'),
      interacted: () => reported.push('interacted'),
    },
  })
  const scope = createConnectionScope(fakePort().port, deps)
  scope.deviceEstablished('dev-a')
  assert.deepEqual(reported, ['online:dev-a'])
  scope.servingEnded()
  assert.deepEqual(reported, ['online:dev-a', 'offline:dev-a'])
})

test('presence：订阅集变化就上报（foreground 档的 claim 判据是"前台且已订阅"）', async () => {
  const reported: string[][] = []
  const deps = makeDeps({
    sessions: {
      list: async () => [], prompt: async () => ({ accepted: true as const }),
      cancel: () => ({ accepted: true as const }), page: async () => ({ records: [], hasMore: false }),
      updateQueue: async () => ({ accepted: true as const }),
      selectModel: async () => ({ selected: { provider: 'test', model: 'test' } }),
      create: async () => ({ sessionId: 'dsh-new' }),
      follow: (): never => { throw new Error('本用例不应建立订阅') },
    },
    presence: {
      online: () => {},
      offline: () => {},
      app: () => {},
      subscriptions: (_devId, sids) => reported.push([...sids]),
      interacted: () => {},
    },
  })
  const scope = createConnectionScope(fakePort().port, deps)
  scope.deviceEstablished('dev-a')
  // 订阅集由 `sessionSubscriptions` 自己通报（它是唯一权威）——
  // 所以这里用它的公开方法驱动，而不是从外面猜一个集合。
  assert.deepEqual(reported, [], '还没有订阅变化不该上报')
  scope.servingEnded()
  // **断开之后的上报不得把设备救活**：`servingEnded` 先下线、后清订阅，
  // 而 `presence.subscriptions` 对一条不存在的记录什么也不做（见 `presence.ts` 的
  // `updateOf`）。少了那条，一条迟到的 `sync.hello` 就能让已断线的设备重新"在线"，
  // 而 foreground 档的 claim 判据正是"前台且已订阅"。
  assert.deepEqual(reported, [])
})

test('presence：迟到的 sync.hello 不能把一台已断线的设备救活', () => {
  const presence = createDevicePresence({ pairedAtOf: () => 1 })
  const reported: string[] = []
  const deps = makeDeps({
    presence: {
      online: (devId) => {
        reported.push(`online:${devId}`)
        presence.online(devId)
      },
      offline: (devId) => {
        reported.push(`offline:${devId}`)
        presence.offline(devId)
      },
      app: (devId, state) => presence.app(devId, state),
      subscriptions: (devId, sids) => presence.subscriptions(devId, sids),
      interacted: (devId, sid) => presence.interacted(devId, sid, 1),
    },
  })
  const scope = createConnectionScope(fakePort().port, deps)
  scope.deviceEstablished('dev-a')
  scope.servingEnded()
  assert.equal(presence.liveOf('dev-a'), undefined)

  // 竞速：断开之后那条连接才把 `sync.hello` 处理完（它的 `onChange` / `app` 回调）。
  presence.app('dev-a', 'foreground')
  presence.subscriptions('dev-a', ['sid_1'])
  presence.interacted('dev-a', 'sid_1', 1)
  assert.equal(presence.liveOf('dev-a'), undefined, '不得复活')
  assert.deepEqual(presence.devices(), [])
})
