/**
 * **整条链**的接线证明：手机连上（`sync.hello` 上报前台+订阅）→ 交互投递 → 端口 →
 * 答复从同一条连接回来。
 *
 * 它**不需要 DSH**：presence 是真实现，端口是真实现，只有 DSH 的 `userQuestions` /
 * `approval` 服务不在场 —— 而它们本来就在端口的外面。
 *
 * Note: "谁参与"没有仲裁这回事了（连接器是 gateway 的一个 client，连着就参与）——
 * 见 `.agents/notes/implemented/2026-10-23-interaction-as-gateway-client.md`。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createConnectionScope, type ConnectionScopeDeps } from '../src/connection-scope.js'
import { createMetrics, silentLogger } from '../src/observability.js'
import { createDevicePresence } from '../src/presence.js'
import { APPROVAL_ALLOW_LABEL, createInteractionPort } from '../src/interaction-claims.js'
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
        jobs: false, subagents: false, references: false, plugins: false, files: false, settings: false, credentials: true,
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

test('整链：sync.hello 上报前台+订阅 → 端口等到人类的回答，答复从同一条连接回来', { timeout: 60_000 }, async () => {
  const { presence, deps, sent, port, streams } = harness()

  // ---- ② 端口与 ③ 的内核先装进方法面（装配顺序：先挂 handler 再建连接）----
  const claims = createInteractionPort()
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

  // ---- ① 的验收：设备状态真的被上报（管理面读的就是它）----
  const devices = presence.devices()
  assert.deepEqual(devices, [
    { id: 'dev-1', pairedAt: 1000, online: true, foreground: true, subscribed: ['sid_dsh-1'] },
  ])

  // ---- ② 端口：claim 之后它真的被触发，并等到人类的回答 ----
  const pending = claims.askApproval({ sid: 'sid_dsh-1', itemId: 'i:approval-1' })
  await settle()
  assert.equal(claims.pending, 1, 'claim 必须在途，否则答复回来时无处可去')

  // ---- ③ 手机答的话从发问的那条连接回来 ----
  scope.handleFrame({
    v: 1, t: 'req', id: 'req-answer', fc: 2,
    box: JSON.stringify({
      method: 'interaction.respond',
      // **幂等键就是手机那张卡的 itemId，必须在请求顶层**（契约 §5.6 / §5.7）：漏了它
      // 分发器在分发之前就回 `protocol/bad-frame`，而那一帧根本到不了端口。
      requestId: 'i:approval-1',
      params: {
        sid: 'sid_dsh-1',
        itemId: 'i:approval-1',
        answers: [{ id: 'i:approval-1', selected: [APPROVAL_ALLOW_LABEL] }],
      },
    }),
  })
  await settle()

  assert.deepEqual(
    await pending,
    { kind: 'answered', value: 'allowed-once' },
    '审批转手机：真机上"手机上答 → 电脑侧继续"就是这一步',
  )
  assert.equal(claims.pending, 0)
  assert.equal(lastResponse(sent).ok, true, '答复要被确认，手机才能把那一项标成已答')

  // 设备断开：端口不结算在途 claim，也**不会**自己超时 —— 只有手机答、gateway 撤、
  // 或插件卸载才收束（原生没有超时）。
  scope.servingEnded()
  assert.equal(presence.liveOf('dev-1'), undefined)
  const stillWaiting = claims.askApproval({ sid: 'sid_dsh-1', itemId: 'i:approval-2' })
  await settle()
  assert.equal(claims.pending, 1, '断开不是收束的理由（claim 挂在 host 上）')
  assert.equal(claims.cancelClaim('i:approval-2'), true, '只有 gateway 说"已经结算了"才放走')
  assert.deepEqual(await stillWaiting, { kind: 'withdrawn' })
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

  const claims = createInteractionPort()
  const pending = claims.askApproval({ sid: 'sid_dsh-1', itemId: 'i:approval-1' })
  await settle()
  scope.servingEnded()
  await settle()
  assert.equal(claims.pending, 1, '断开只撤投递，不结算 —— 与 DSH gateway 的 pendingRemoteEvents 同形')
  assert.equal(
    claims.settleClaim('sid_dsh-1', 'i:approval-1', [{ id: 'i:approval-1', selected: ['allowed-once'] }]),
    true,
    '重连回来的答复仍能落进同一条 claim',
  )
  assert.deepEqual(await pending, { kind: 'answered', value: 'allowed-once' })
})

test('整链：方法面真的挂了 sync.hello 与 interaction.respond（repo.info 报的是表的键）', async () => {
  const { deps, sent, port } = harness()
  // 提问内核也在场（`userQuestions` 服务在时 `index.ts` 会挂它）。
  deps.handlers.interaction = {
    respond: () => ({ itemId: 't:x' }),
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
