import assert from 'node:assert/strict'
import { test } from 'node:test'
import { createConnectionScope, type ConnectionScopeDeps } from '../src/connection-scope.js'
import { createMetrics, silentLogger } from '../src/observability.js'
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
    page: async () => ({ records: [], hasMore: false }), follow: (): never => { throw new Error('本用例不应建立订阅') },
  }
  return {
    logger: silentLogger, metrics: createMetrics(), sessions,
    handlers: {
      caps: () => ({ sessions: true, storage: true, approval: false, questions: false, jobs: false, subagents: false, settings: false, credentials: true }),
      aliasVersion: () => 0, sessions, aliases: { ensure: async () => 's1', sessionOf: () => undefined }, devices: () => [],
    },
    buffer: createSessionBuffer({ pairedDevices: () => [] }), jobControl: null, idempotency: null, ...overrides,
  }
}
const frameTypes = (frames: readonly OutboundFrame[]) => frames.map((frame) => frame.t)
const settle = (): Promise<void> => new Promise((resolve) => setImmediate(resolve))
const persisted = (seq: number, fc: number): WireFrame => ({ v: 1, t: 'persisted', sid: 's1', seq, fc, box: '' })

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
  const endpoint = createPairingEndpoint({ pairing, pcId: 'pc-1', putDevice: async () => { throw new Error('坏 JSON 不得写库') }, announce: async () => {} })
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
