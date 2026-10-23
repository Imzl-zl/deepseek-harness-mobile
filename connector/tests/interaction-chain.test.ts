/**
 * **整条链**的接线证明：presence → 仲裁 claim → 端口 → 答复回到在途 claim。
 *
 * 这是「审批转手机」从"永远不触发"变成"真的能通"的那一条用例。接线之前的状态是：
 *
 * ```text
 * 没人写 liveRegistry → liveDevices() 返回 [] → decideTakeover 永不 claim
 * → answerer 永远 next() 交还桌面 → fail-closed 桩根本跑不到
 * ```
 *
 * 所以这条用例的验收口径就是任务书那三句：`liveDevices()` 不再恒为空；
 * `decideTakeover` 第一次真的能 claim；端口第一次真的被触发并等到人类的回答。
 *
 * 它**不需要 DSH**：presence 是真实现，仲裁是真函数（`protocol/takeover.ts`），
 * 端口是真实现，只有 DSH 的 `userQuestions` / `approval` 服务不在场 ——
 * 而它们本来就在端口的外面（answerer 那一侧）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createConnectionScope, type ConnectionScopeDeps } from '../src/connection-scope.js'
import { createMetrics, silentLogger } from '../src/observability.js'
import { createDevicePresence } from '../src/presence.js'
import { decideTakeover } from '../src/protocol/takeover.js'
import { APPROVAL_ALLOW_LABEL, createInteractionPort, type UnhandledInteraction } from '../src/interaction-claims.js'
import { createInteractionFace } from '../src/interaction-face.js'
import { createHandlers } from '../src/handlers.js'
import { createSessionBuffer } from '../src/session-buffer.js'
import { createControllableSessionSource } from './support/session-stream.js'
import type { OutboundFrame } from '../src/transport/connection.js'

/** 一台已配对、未吊销的设备。 */
const PAIRED = { 'dev-1': 1000 }

function harness() {
  const presence = createDevicePresence({ pairedAtOf: (devId) => PAIRED[devId as 'dev-1'] })
  const { source, streams } = createControllableSessionSource()
  const sent: OutboundFrame[] = []
  const port = {
    state: 'serving' as const,
    send: (frame: OutboundFrame) => {
      sent.push(frame)
      return true
    },
    whenWritable: () => Promise.resolve(),
  }

  const deps: ConnectionScopeDeps = {
    logger: silentLogger,
    metrics: createMetrics(),
    sessions: {
      list: async () => [],
      prompt: async () => ({ accepted: true as const }),
      selectModel: async () => ({ selected: { provider: 'test', model: 'test' } }),
      create: async () => ({ sessionId: 'dsh-new' }),
      cancel: () => ({ accepted: true as const }),
      page: async () => ({ records: [], hasMore: false }),
      follow: source.follow,
    } as never,
    buffer: createSessionBuffer({ pairedDevices: () => ['dev-1'] }),
    jobControl: null,
    idempotency: null,
    presence,
    handlers: {
      caps: () => ({
        sessions: true, storage: true, approval: true, questions: true,
        jobs: false, subagents: false, settings: false, credentials: true,
        direct: false,
      }),
      aliasVersion: () => 0,
      sessions: {
        list: async () => [],
        prompt: async () => ({ accepted: true as const }),
        selectModel: async () => ({ selected: { provider: 'test', model: 'test' } }),
        create: async () => ({ sessionId: 'dsh-new' }),
        updateQueue: async () => ({ accepted: true as const }),
        cancel: () => ({ accepted: true as const }),
      },
      aliases: {
        ensure: async (id: string) => `sid_${id}`,
        sessionOf: (sid: string) => (sid === 'sid_dsh-1' ? 'dsh-1' : undefined),
      },
      devices: () => [],
    },
  }
  return { presence, deps, sent, port, streams }
}

/** 解出最近一帧 `res` 的结果（`ok:true`）或错误码（`ok:false`）。 */
function lastResponse(sent: readonly OutboundFrame[]): { ok: boolean; payload: Record<string, unknown> } {
  const responses = sent.filter((frame) => frame.t === 'res')
  const last = responses.at(-1)
  assert.ok(last !== undefined && last.t === 'res', '应当有一帧 res')
  const body = JSON.parse(last.box) as Record<string, unknown>
  return {
    ok: last.ok,
    // 信封是 `{ok:true, result}` / `{ok:false, code, message}`（契约 §5.7）。
    payload: last.ok ? ((body['result'] ?? {}) as Record<string, unknown>) : body,
  }
}

const settle = (): Promise<void> => new Promise((resolve) => setImmediate(resolve))

test('整链：sync.hello 上报前台+订阅 → decideTakeover 真的 claim → 端口等到人类的回答', { timeout: 60_000 }, async () => {
  const { presence, deps, sent, port, streams } = harness()

  // ---- ② 端口与 ③ 的内核先装进方法面（装配顺序：先挂 handler 再建连接）----
  const unhandled: UnhandledInteraction[] = []
  const claims = createInteractionPort({
    presence,
    onUnhandled: (record) => unhandled.push(record),
  })
  const face = createInteractionFace({
    answer: () => assert.fail('这一项是在途审批，不该走到 DSH 的 answer()'),
    agentOf: () => undefined,
    projectionOf: () => undefined,
    settleClaim: (sid, callId, answers) => claims.settleClaim(sid, callId, answers),
  })
  deps.handlers.interaction = face

  const scope = createConnectionScope(port, deps)
  scope.deviceEstablished('dev-1')

  // ---- ① presence：鉴权完成只让设备"在线"，前台态仍为 false ----
  assert.deepEqual(presence.devices(), [
    { id: 'dev-1', pairedAt: 1000, online: true, foreground: false, subscribed: [] },
  ])
  const beforeClaim = decideTakeover({ mode: 'foreground', sid: 'sid_dsh-1', devices: presence.devices() })
  assert.equal(beforeClaim.claim, false, '没上报前后台态之前不 claim（fail-closed 的方向）')

  // 手机发 `sync.hello`：声明前台 + 订阅集。
  scope.handleFrame({
    v: 1, t: 'req', id: 'req-hello', fc: 1,
    box: JSON.stringify({
      method: 'sync.hello',
      params: { app: 'foreground', sessions: [{ sid: 'sid_dsh-1', since: 0 }] },
    }),
  })
  await settle()
  streams[0]?.push({ kind: 'opening', cursor: 0, header: { id: 'dsh-1' } as never, records: [], hasMore: false })
  await settle()

  // ---- ① 的验收：liveDevices() 不再恒为空 ----
  const devices = presence.devices()
  assert.deepEqual(devices, [
    { id: 'dev-1', pairedAt: 1000, online: true, foreground: true, subscribed: ['sid_dsh-1'] },
  ])

  // ---- ② 的验收：decideTakeover 第一次真的能 claim ----
  const claim = decideTakeover({ mode: 'foreground', sid: 'sid_dsh-1', devices })
  assert.deepEqual(claim, { claim: true, deviceId: 'dev-1', reason: 'foreground-claimed' })

  // ---- ② 端口：claim 之后它真的被触发，并等到人类的回答 ----
  const pending = claims.askApproval(
    { sid: 'sid_dsh-1', callId: 'call-1', toolName: 'bash' },
    claim.deviceId ?? '',
  )
  await settle()
  assert.equal(claims.pending, 1, 'claim 必须在途，否则答复回来时无处可去')

  // ---- ③ 手机答的话从发问的那条连接回来 ----
  scope.handleFrame({
    v: 1, t: 'req', id: 'req-answer', fc: 2,
    box: JSON.stringify({
      method: 'interaction.respond',
      // **幂等键 `i:<callId>` 必须在请求顶层**（契约 §5.6 / §5.7）：漏了它分发器
      // 在分发之前就回 `protocol/bad-frame`，而那一帧根本到不了端口。
      requestId: 'i:call-1',
      params: {
        sid: 'sid_dsh-1',
        callId: 'call-1',
        answers: [{ id: 'call-1', selected: [APPROVAL_ALLOW_LABEL] }],
      },
    }),
  })
  await settle()

  assert.equal(await pending, 'allow-once', '审批转手机：真机上"手机上答 → 电脑侧继续"就是这一步')
  assert.equal(claims.pending, 0)
  assert.equal(unhandled.length, 0, '等到回答就不该有未处理记录')
  assert.equal(lastResponse(sent).ok, true, '答复要被确认，手机才能把那一项标成已答')

  // 断开之后端口不再接受任何 claim（不等满一个看护周期）。
  scope.servingEnded()
  assert.equal(presence.liveOf('dev-1'), undefined)
  // **抛，不是 `'reject'`**：`'rejected'` 在 DSH 原生语义里只代表用户点了拒绝
  // （`ui-approval/contract/slots.ts`）。我们呈示不了就 reject，等于替用户做一个
  // 他没做过的决定；抛出去由 `interactions.ts` 归一成 `'unavailable'` 才是实话。
  await assert.rejects(
    () =>
      claims.askApproval(
        { sid: 'sid_dsh-1', callId: 'call-2', toolName: 'bash' },
        'dev-1',
      ),
  )
  assert.equal(unhandled.at(-1)?.end, 'disconnected', '断开之后立刻 fail-closed 并留证')
})

test('整链：手机断开 → claim 保留（不结算），重连后答复仍能落', { timeout: 60_000 }, async () => {
  const { presence, deps, port } = harness()
  const scope = createConnectionScope(port, deps)
  scope.deviceEstablished('dev-1')
  scope.handleFrame({
    v: 1, t: 'req', id: 'req-hello', fc: 1,
    box: JSON.stringify({
      method: 'sync.hello',
      params: { app: 'foreground', sessions: [{ sid: 'sid_dsh-1', since: 0 }] },
    }),
  })
  await settle()

  const unhandled: unknown[] = []
  const claims = createInteractionPort({
    presence,
    onUnhandled: (record) => unhandled.push(record),
    guardMs: 10 * 60_000,
  })
  const pending = claims.askApproval(
    { sid: 'sid_dsh-1', callId: 'call-1', toolName: 'bash' },
    'dev-1',
  )
  await settle()
  scope.servingEnded()
  await settle()
  assert.equal(claims.pending, 1, '断开只撤投递，不结算 —— 与 DSH gateway 的 pendingRemoteEvents 同形')
  assert.equal(
    claims.settleClaim('sid_dsh-1', 'call-1', [{ id: 'call-1', selected: ['allowed-once'] }]),
    true,
    '重连回来的答复仍能落进同一条 claim',
  )
  assert.equal(await pending, 'allow-once')
  assert.deepEqual(unhandled, [], '答上了就不是未处理')
})

test('整链：方法面真的挂了 sync.hello 与 interaction.respond（repo.info 报的是表的键）', async () => {
  const { deps, sent, port } = harness()
  // 提问内核也在场（`userQuestions` 服务在时 `index.ts` 会挂它）。
  deps.handlers.interaction = {
    pendingOf: () => [],
    respond: () => ({ itemId: 'i:x' }),
  }
  const scope = createConnectionScope(port, deps)
  scope.deviceEstablished('dev-1')
  scope.handleFrame({
    v: 1, t: 'req', id: 'req-info', fc: 1,
    box: JSON.stringify({ method: 'repo.info' }),
  })
  await settle()

  const info = lastResponse(sent)
  assert.equal(info.ok, true)
  const methods = info.payload['methods'] as string[]
  assert.ok(methods.includes('sync.hello'), '恢复握手必须在表里')
  assert.ok(methods.includes('interaction.respond'), '应答入口必须在表里')
})
