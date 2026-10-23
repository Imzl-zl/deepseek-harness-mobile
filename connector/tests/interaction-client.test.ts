/**
 * `dsh/interaction-client.ts`：连接器作为 gateway 的 **owner client** 接 `$events` 转发流。
 *
 * 这条用例的骨架是一个**假 gateway**：`wireStream.open` 返回一条由测试推动的帧流，
 * `createSharedFetchHandler('/api').fetch` 捕获结果请求。于是五条判据全部可以离线证明：
 *
 * 1. 手机答 → 发 `{kind:'result'}`，`value` 与 `interaction.respond` 的批次逐字一致；
 * 2. desktop 结算（`cancel`）→ 手机 claim 撤掉，且不再重投；
 * 3. 不参与 → 回 `{kind:'next'}`（DSH 的委托，不是我们自己发明的沉默）；
 * 4. 缺 `typertGateway` / `connection` → 不挂交互面；
 * 5. 流断开 → 退避重连；重连后 gateway 重投的在途事件仍能被处理。
 *
 * 端口用的是**真实现**（`interaction-claims.ts`）+ 真 presence + 真仲裁 ——
 * 只有宿主那两件（gateway 与 connection）是替身。这样"手机的答复真的落进了 claim、
 * 结算真的变成线上 outcome"这条链在单测里是完整的。
 *
 * 为什么不是"造一个 DSH"：`$events` 的线形状是**别人的**协议（`stream-protocol.ts`），
 * 我们只消费它；把 DSH 整个拉进单测既不必要，也会让替身变成第二个真值。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import type { Session } from '@deepseek-ai/dsh-session'

import {
  APPROVAL_ALLOW_LABEL,
  createInteractionPort,
} from '../src/interaction-claims.js'
import {
  APPROVAL_EVENT,
  QUESTION_EVENT,
  createInteractionClient,
  type InteractionClient,
} from '../src/dsh/interaction-client.js'
import { createDevicePresence } from '../src/presence.js'
import { createBackoff } from '../src/transport/backoff.js'
import { emptySession, openApproval, openCall } from './support/session-log.js'

const AGENT_ID = 'dsh-session-1'
const SID = 'sid_1'
const DEVICE = 'dev-1'

/** 结果请求被捕获到的那一份（`$events/result` 的 args）。 */
interface ResultCall {
  readonly url: string
  readonly method: string
  readonly rpcId: string
  readonly clientId: string
  readonly eventId: string
  readonly outcome: Record<string, unknown>
  readonly peer: unknown
}

interface Stream {
  push(value: unknown): void
  end(): void
  readonly iterate: AsyncIterable<unknown>
}

/** 一条由测试推动的帧流（`open` 返回的可迭代对象）。 */
function createStream(signal: AbortSignal): Stream {
  const buffer: unknown[] = []
  let wake: (() => void) | null = null
  let closed = false
  const notify = (): void => {
    const resume = wake
    wake = null
    resume?.()
  }
  signal.addEventListener('abort', () => {
    closed = true
    notify()
  })
  async function* iterate(): AsyncGenerator<unknown> {
    while (true) {
      const next = buffer.shift()
      if (next !== undefined) {
        yield next
        continue
      }
      if (closed || signal.aborted) return
      await new Promise<void>((resolve) => {
        wake = resolve
      })
    }
  }
  return {
    push(value) {
      buffer.push(value)
      notify()
    },
    end() {
      closed = true
      notify()
    },
    iterate: iterate(),
  }
}

/** 手动推进的计时器（退避重连用）：只有测试调 `fire()` 才会继续。 */
function manualTimers() {
  const box: { fire: (() => void) | null; delay: number | null } = { fire: null, delay: null }
  return {
    box,
    schedule: (fn: () => void, ms: number) => {
      box.fire = fn
      box.delay = ms
      return () => {
        box.fire = null
      }
    },
  }
}

interface Harness {
  client: InteractionClient | null
  port: ReturnType<typeof createInteractionPort>
  results: ResultCall[]
  streams: Stream[]
  opens: { endpoint: string; payload: unknown }[]
  peers: { disposed: boolean }[]
  warnings: string[]
  timers: ReturnType<typeof manualTimers>
  presence: ReturnType<typeof createDevicePresence>
}

function harness(patch: {
  /** `null` = 这个会话没登记给手机。 */
  sid?: string | null
  session?: Session
  gateway?: boolean
  connection?: boolean
  agents?: boolean
  /** 让结果请求回一个业务失败（`{ok:false}`，`api/gateway/src/index.ts:489-492`）。 */
  failResults?: boolean
  /** 第一次 `wireStream.open` 抛错（源还没注册）。 */
  failOpen?: boolean
} = {}): Harness {
  const presence = createDevicePresence({ pairedAtOf: (id) => (id === DEVICE ? 1000 : undefined) })
  presence.online(DEVICE)
  presence.app(DEVICE, 'foreground')
  presence.subscriptions(DEVICE, [SID])

  const port = createInteractionPort()

  const results: ResultCall[] = []
  const streams: Stream[] = []
  const opens: { endpoint: string; payload: unknown }[] = []
  const peers: { disposed: boolean }[] = []
  const warnings: string[] = []
  const timers = manualTimers()
  /** 第一次 `open` 就抛错（模拟 `api/remotes` 还没注册源）。**必须在建客户端之前**设好。 */
  let openError: Error | null =
    patch.failOpen === true ? new Error('forwarded Remote event source is unavailable') : null

  const connection = {
    createPeer: () => {
      const handle = {
        disposed: false,
        // 真实 Peer 的 dispose 是异步的（`peer.ts:50`）；这里记一笔就够断言了。
        dispose: async (): Promise<void> => {
          handle.disposed = true
        },
      }
      peers.push(handle)
      return handle
    },
    createSharedFetchHandler: () => ({
      fetch: async (request: Request, peer: unknown): Promise<Response> => {
        const body = (await request.json()) as {
          type: string
          rpcId: string
          method: string
          payload: { args: { clientId: string; eventId: string; outcome: Record<string, unknown> } }
        }
        results.push({
          url: request.url,
          method: body.method,
          rpcId: body.rpcId,
          clientId: body.payload.args.clientId,
          eventId: body.payload.args.eventId,
          outcome: body.payload.args.outcome,
          peer,
        })
        return new Response(
          JSON.stringify({
            type: 'server-response',
            rpcId: body.rpcId,
            result:
              patch.failResults === true
                ? { ok: false, error: { code: 'internal', message: 'no such client', details: {} } }
                : { ok: true },
          }),
          { status: 200, headers: { 'content-type': 'application/json' } },
        )
      },
    }),
  }

  const gateway = {
    wireStream: {
      open: async (
        endpoint: string,
        payload: unknown,
        _uplink: unknown,
        _peer: unknown,
        signal: AbortSignal,
      ): Promise<AsyncIterable<unknown>> => {
        opens.push({ endpoint, payload })
        if (openError !== null) {
          const failure = openError
          openError = null
          throw failure
        }
        const stream = createStream(signal)
        streams.push(stream)
        return stream.iterate
      },
    },
  }

  // **默认会话里有一条未结算的 `approval/asked`**：审批的身份是它（`ApprovalRequestId`），
  // 不是请求对象里的 `callId`（那个在 DSH 里可选的，`user-approval/src/types.ts:68-69`）。
  // 于是默认的 `approvalFrame()`（带 `callId: 'call-1'`）认出来的是 `i:approval-1`。
  const session = patch.session ?? (() => {
    const fresh = emptySession()
    openApproval(fresh, 'approval-1', 'call-1')
    return fresh
  })()
  const agents = {
    get: (id: string) => (id === AGENT_ID ? { id: AGENT_ID, session } : undefined),
  }

  const ctx = {
    get: (key: string) => {
      if (key === 'connection') return patch.connection === false ? undefined : connection
      if (key === 'typertGateway') return patch.gateway === false ? undefined : gateway
      if (key === 'agents') return patch.agents === false ? undefined : agents
      return undefined
    },
  }

  const client = createInteractionClient(ctx as never, {
    port,
    sidOf: (agentId) => (patch.sid === null ? undefined : patch.sid ?? (agentId === AGENT_ID ? SID : undefined)),
    log: {
      warn: (message: string, detail?: unknown) => {
        warnings.push(detail === undefined ? message : `${message}｜${JSON.stringify(detail)}`)
      },
      debug: () => {},
    },
    schedule: timers.schedule,
    // 抖动为零：`next()` 是确定的 1000 / 2000 / …，断言才可写
    backoff: createBackoff(() => 0.5),
  })

  return {
    client,
    port,
    results,
    streams,
    opens,
    peers,
    warnings,
    timers,
    presence,
  }
}

/** 让出事件循环到"这些异步链都跑完"（客户端是长活的，没有可以 await 的东西）。 */
async function settle(turns = 8): Promise<void> {
  for (let i = 0; i < turns; i += 1) await new Promise((resolve) => setImmediate(resolve))
}

/** 等到某个条件成立（客户端那一侧全是异步的）。 */
async function until(check: () => boolean, label: string): Promise<void> {
  for (let i = 0; i < 200; i += 1) {
    if (check()) return
    await new Promise((resolve) => setImmediate(resolve))
  }
  assert.fail(`等不到：${label}`)
}

/**
 * 起一条流并把它推到 `ready`。
 *
 * `index` 是"第几条流"：`wireStream.open` 在 `createInteractionClient` 里**同步**被调到
 * （读到第一个 `await` 之前就登记了 `streams[0]`），所以第一个测试看到的
 * `streams.length` 已经是 1。重连之后用 `index: 1` 取新一代。
 */
async function openStream(h: Harness, clientId = 'c-1', index = 0): Promise<Stream> {
  await until(() => h.streams.length > index, `第 ${index + 1} 条 $events 流被打开`)
  const stream = h.streams[index]
  assert.ok(stream !== undefined)
  stream.push({ type: 'ready', clientId, host: { home: '/home/u' } })
  await settle()
  return stream
}

const approvalFrame = (patch: Record<string, unknown> = {}): Record<string, unknown> => ({
  type: 'waterfall',
  event: APPROVAL_EVENT,
  eventId: 'e-1',
  agentId: AGENT_ID,
  request: { toolName: 'bash', callId: 'call-1', ...patch },
})

const questionFrame = (patch: Record<string, unknown> = {}): Record<string, unknown> => ({
  type: 'waterfall',
  event: QUESTION_EVENT,
  eventId: 'q-1',
  agentId: AGENT_ID,
  request: { questions: [{ id: 'q1', question: '继续吗', options: [] }], ...patch },
})

// ---------------------------------------------------------------------------
// 判据 4：缺宿主缝 → 不挂交互面
// ---------------------------------------------------------------------------

test('缺 typertGateway / connection → 不挂交互面（不建 peer、不开流、不 claim）', async () => {
  for (const [name, patch] of [
    ['两个都缺', { gateway: false, connection: false }],
    ['缺 gateway', { gateway: false }],
    ['缺 connection', { connection: false }],
  ] as const) {
    const h = harness(patch)
    assert.equal(h.client, null, `${name}：createInteractionClient 必须回 null`)
    assert.equal(h.peers.length, 0, `${name}：不该建 in-process peer`)
    assert.equal(h.opens.length, 0, `${name}：不该打开 $events 流`)
    assert.equal(h.port.pending, 0, `${name}：不该有在途 claim`)
    assert.equal(h.warnings.length, 1, `${name}：不挂要留声（不静默）`)
    assert.match(h.warnings[0] ?? '', /没有 host answerer 兜底/)
    await settle()
  }
})

// ---------------------------------------------------------------------------
// 判据 1：手机答 → 发 result
// ---------------------------------------------------------------------------

test('ready 之后：审批被 claim，手机答「允许一次」→ 发 {kind:result, value:allowed-once}', { timeout: 60_000 }, async () => {
  const h = harness()
  assert.ok(h.client !== null)
  await openStream(h, 'c-1')
  assert.equal(h.client.clientId, 'c-1', 'ready 帧的 clientId 是回写结果的凭据')

  h.streams[0]?.push(approvalFrame())
  await settle()
  assert.equal(h.port.pending, 1, '参与仲裁之后必须在途，否则答复回来时无处可去')

  // 手机侧：`interaction.respond` 的落点（真端口）。
  assert.equal(
    h.port.settleClaim(SID, 'i:approval-1', [{ id: 'i:approval-1', selected: [APPROVAL_ALLOW_LABEL] }]),
    true,
  )
  await until(() => h.results.length === 1, '结果请求')

  const result = h.results[0]
  assert.ok(result !== undefined)
  assert.equal(result.url, 'http://host/api/$events/result')
  assert.equal(result.method, '$events/result')
  assert.equal(result.rpcId, 'result-e-1')
  assert.equal(result.clientId, 'c-1')
  assert.equal(result.eventId, 'e-1')
  assert.deepEqual(result.outcome, { kind: 'result', value: 'allowed-once' })
  assert.equal(result.peer, h.peers[0], '结果必须带**我们那个 peer**：gateway 按 peer 判归属')
  assert.equal(h.port.pending, 0)
})

test('手机点拒绝 → value 是 DSH 词汇表的 rejected（不是我们自己的词）', { timeout: 60_000 }, async () => {
  const h = harness()
  await openStream(h)
  h.streams[0]?.push(approvalFrame())
  await settle()

  assert.equal(h.port.settleClaim(SID, 'i:approval-1', [{ id: 'i:approval-1', selected: [] }]), true)
  await until(() => h.results.length === 1, '结果请求')
  assert.deepEqual(h.results[0]?.outcome, { kind: 'result', value: 'rejected' })
})

test('提问：value 就是 interaction.respond 的答案批次（一个字段都不翻译）', { timeout: 60_000 }, async () => {
  const h = harness()
  await openStream(h)
  h.streams[0]?.push(questionFrame({ wait: { callId: 'call-q', timed: true } }))
  await settle()

  const answers = [
    { id: 'q1', selected: ['第二个'], custom: '补充一句' },
    { id: 'q2', selected: [] },
  ]
  assert.equal(h.port.settleClaim(SID, 't:call-q', answers), true)
  await until(() => h.results.length === 1, '结果请求')
  assert.deepEqual(h.results[0]?.outcome, { kind: 'result', value: { answers } })
})

// ---------------------------------------------------------------------------
// 判据 2：桌面先答（cancel）→ 撤 claim
// ---------------------------------------------------------------------------

test('gateway 说这条已经结算（cancel）→ 手机 claim 撤掉、不重投、不回话', { timeout: 60_000 }, async () => {
  const h = harness()
  await openStream(h)
  h.streams[0]?.push(approvalFrame())
  await settle()
  assert.equal(h.port.pending, 1)

  h.streams[0]?.push({ type: 'cancel', eventId: 'e-1' })
  await settle()

  assert.equal(h.port.pending, 0, 'cancel 必须撤掉在途 claim（否则手机会一直挂着一张死卡）')
  assert.deepEqual(h.port.pendingAsks(SID), [], '撤掉的 claim 不该再被重投')
  assert.deepEqual(h.results, [], '那边已经结算：我们再回什么都只是迟到的噪声')

  // 结算之后手机上再点也没用 —— 但**不会**产生第二个结果请求。
  assert.equal(h.port.settleClaim(SID, 'i:approval-1', [{ id: 'i:approval-1', selected: [] }]), false)
  await settle()
  assert.deepEqual(h.results, [])
})

test('cancel 指向一个不存在的 eventId 是 no-op（不崩、不回话）', { timeout: 60_000 }, async () => {
  const h = harness()
  await openStream(h)
  h.streams[0]?.push({ type: 'cancel', eventId: 'nope' })
  await settle()
  assert.deepEqual(h.results, [])
  assert.equal(h.client?.clientId, 'c-1', '一条无主的 cancel 不该拆掉流')
})

test('已经委托（next）的那条事件再收到 cancel → 什么都不做（我们本来就不在投递表里）', { timeout: 60_000 }, async () => {
  const h = harness({ sid: null })
  await openStream(h)
  h.streams[0]?.push(approvalFrame())
  await settle()
  assert.deepEqual(h.results.map((entry) => entry.outcome), [{ kind: 'next' }])

  h.streams[0]?.push({ type: 'cancel', eventId: 'e-1' })
  await settle()
  assert.equal(h.results.length, 1, '不追发第二个 outcome')
  assert.equal(h.client?.clientId, 'c-1', '也不拆流')
})

test('答完之后同一条 eventId 再被投递 → 重新 claim（投递状态不粘住）', { timeout: 60_000 }, async () => {
  const h = harness()
  await openStream(h)
  h.streams[0]?.push(approvalFrame())
  await settle()
  assert.equal(h.port.settleClaim(SID, 'i:approval-1', [{ id: 'i:approval-1', selected: [APPROVAL_ALLOW_LABEL] }]), true)
  await until(() => h.results.length === 1, '第一次结果')

  h.streams[0]?.push(approvalFrame())
  await settle()
  assert.equal(h.port.pending, 1, '同一个 eventId 再投过来时要重新等在途答复')
})

test('答完之后迟到的 cancel → 不追发第二个 outcome', { timeout: 60_000 }, async () => {
  const h = harness()
  await openStream(h)
  h.streams[0]?.push(approvalFrame())
  await settle()
  assert.equal(h.port.settleClaim(SID, 'i:approval-1', [{ id: 'i:approval-1', selected: [APPROVAL_ALLOW_LABEL] }]), true)
  await until(() => h.results.length === 1, '第一次结果')

  h.streams[0]?.push({ type: 'cancel', eventId: 'e-1' })
  await settle()
  assert.equal(h.results.length, 1)
  assert.deepEqual(h.results[0]?.outcome, { kind: 'result', value: 'allowed-once' })
})

test('换代窗口：还在等手机时流断了 → **不撤 claim**（claim 挂在挂载上，不挂在传输上）', { timeout: 60_000 }, async () => {
  const h = harness()
  await openStream(h, 'c-1')
  h.streams[0]?.push(approvalFrame())
  await settle()
  assert.equal(h.port.pending, 1)

  h.streams[0]?.end()
  await settle()
  assert.deepEqual(h.results, [], '没有可回写的投递对象：不发明 outcome')
  assert.equal(
    h.port.pending,
    1,
    'claim 不撤：DSH 换代只撤投递、不结算（`api/gateway/src/index.ts:717-721`），新 client 上来还会重投',
  )
  assert.equal(h.port.cancelClaim('i:approval-1'), true, '要撤只有两条路：gateway 的 cancel 或卸载')
})

test('换代窗口里手机答了 → 结果等下一代 ready 再用新 clientId 发出去（不吞掉）', { timeout: 60_000 }, async () => {
  const h = harness()
  await openStream(h, 'c-1')
  h.streams[0]?.push(approvalFrame())
  await settle()

  h.streams[0]?.end()
  await settle()
  // 传输还没回来，手机就答了。
  assert.equal(
    h.port.settleClaim(SID, 'i:approval-1', [{ id: 'i:approval-1', selected: [APPROVAL_ALLOW_LABEL] }]),
    true,
  )
  await settle()
  assert.equal(h.results.length, 0, '这一代没有投递对象：先端着，不发明一个 outcome')

  h.timers.box.fire?.()
  await settle()
  await openStream(h, 'c-2', 1)
  await until(() => h.results.length === 1, '换代之后的结果请求')
  assert.equal(h.results[0]?.clientId, 'c-2', '结果用**新一代**的 clientId 发（gateway 按它判投递）')
  assert.deepEqual(h.results[0]?.outcome, { kind: 'result', value: 'allowed-once' })
})

// ---------------------------------------------------------------------------
// 判据 3：不参与 → 委托（{kind:'next'}）
// ---------------------------------------------------------------------------

test('会话没登记给手机 → 不 claim，回 {kind:next}', { timeout: 60_000 }, async () => {
  const h = harness({ sid: null })
  await openStream(h)
  h.streams[0]?.push(approvalFrame())
  await settle()

  assert.equal(h.port.pending, 0, '不该 claim')
  assert.deepEqual(
    h.results.map((entry) => entry.outcome),
    [{ kind: 'next' }],
    '**委托**（原生 next）—— 只有所有投递都 next 之后 gateway 才交还 Host',
  )
})

test('没有 callId 的审批：日志里有唯一一条未结算的 approval/asked → 照样 claim（身份是 ApprovalRequestId）', { timeout: 60_000 }, async () => {
  // **这是本轮删掉的那条规则**：以前"没有 callId 就委托"。而 DSH 的浏览器在
  // `callId === undefined` 时照样弹卡照样答（`client/ui-approval/src/client/index.ts:45-53,59-65`）——
  // 身份从来不是 callId，是服务铸的 `ApprovalRequestId`（`user-approval/src/types.ts:13-17`）。
  const slow = harness()
  await openStream(slow)
  // 请求里完全没有 callId（`{}` 与 `''` 都要走到日志推断那一步）。
  slow.streams[0]?.push(approvalFrame({ callId: undefined }))
  await settle()
  assert.equal(slow.port.pending, 1, '认得出唯一一条未结算的 approval/asked 就要 claim')
  assert.equal(
    slow.port.settleClaim(SID, 'i:approval-1', [{ id: 'i:approval-1', selected: [APPROVAL_ALLOW_LABEL] }]),
    true,
  )
  await until(() => slow.results.length === 1, '结果请求')
  assert.deepEqual(slow.results[0]?.outcome, { kind: 'result', value: 'allowed-once' })
})

test('审批认不出身份（日志里一条 approval/asked 都没有）→ 委托，且留一声', { timeout: 60_000 }, async () => {
  const h = harness({ session: emptySession() })
  await openStream(h)
  h.streams[0]?.push(approvalFrame())
  await settle()
  assert.equal(h.port.pending, 0, '认不出就不猜一个 id')
  assert.deepEqual(h.results.map((entry) => entry.outcome), [{ kind: 'next' }])
  assert.match(h.warnings.join('\n'), /认不出对应的 approval\/asked 身份/)
})

test('审批不唯一（两条未结算的 approval/asked）→ 委托（不猜是哪一条）', { timeout: 60_000 }, async () => {
  const session = emptySession()
  openApproval(session, 'approval-1', 'call-1')
  openApproval(session, 'approval-2', 'call-2')
  const h = harness({ session })
  await openStream(h)
  // 请求里不带 callId ⇒ 无法在两条之间分辨。
  h.streams[0]?.push(approvalFrame({ callId: undefined }))
  await settle()
  assert.equal(h.port.pending, 0)
  assert.deepEqual(h.results.map((entry) => entry.outcome), [{ kind: 'next' }])
  assert.match(h.warnings.join('\n'), /ambiguous/)
})

test('审批：重投载荷是那条 approval/asked 的原 seq 与 body', { timeout: 60_000 }, async () => {
  const session = emptySession()
  const seq = openApproval(session, 'ap-1', 'call-1')
  const h = harness({ session })
  await openStream(h)
  h.streams[0]?.push(approvalFrame())
  await settle()

  const asks = h.port.pendingAsks(SID)
  assert.equal(asks.length, 1, '在途审批要留下重投载荷（订阅恢复后按原 seq 再发一遍）')
  assert.equal(asks[0]?.seq, seq, '原 seq —— 重投不推进水位')
  assert.equal(JSON.parse(asks[0]?.body ?? '{}').type, 'approval/asked')
})

test('不是交互的事件（emit / 别的事件名）→ 忽略', { timeout: 60_000 }, async () => {
  const h = harness()
  await openStream(h)
  h.streams[0]?.push({ type: 'emit', event: 'api-session/added', args: [] })
  h.streams[0]?.push({ ...approvalFrame(), event: 'commands/change', eventId: 'x-1' })
  await settle()
  assert.equal(h.port.pending, 0)
  assert.deepEqual(h.results, [])
})

// ---------------------------------------------------------------------------
// legacy 提问：身份从会话日志推（`dsh/question-call.ts`）
// ---------------------------------------------------------------------------

test('legacy 提问（没有 wait.callId）：身份从日志推出，claim 键是 t:<真 call id>，重投载荷是那条 tool/call', { timeout: 60_000 }, async () => {
  const session = emptySession()
  const seq = openCall(session, 'call-7')
  const h = harness({ session })
  await openStream(h)

  h.streams[0]?.push(questionFrame({ eventId: 'q-7' }))
  await settle()
  assert.equal(h.port.pending, 1, '认出唯一身份就要 claim')

  const asks = h.port.pendingAsks(SID)
  assert.equal(asks.length, 1, '重投载荷存进 claim（订阅恢复后按原 seq 再发一遍）')
  assert.equal(asks[0]?.seq, seq, '原 seq —— 重投不推进水位')
  assert.equal(JSON.parse(asks[0]?.body ?? '{}').data.callId, 'call-7')

  assert.equal(h.port.settleClaim(SID, 't:call-7', [{ id: 'q1', selected: [] }]), true)
  await until(() => h.results.length === 1, '结果请求')
  assert.deepEqual(h.results[0]?.outcome, {
    kind: 'result',
    value: { answers: [{ id: 'q1', selected: [] }] },
  })
})

test('legacy 提问：两条并发 → 不参与且留声（不猜一个 id）', { timeout: 60_000 }, async () => {
  const session = emptySession()
  openCall(session, 'call-7')
  openCall(session, 'call-8')
  const h = harness({ session })
  await openStream(h)

  h.streams[0]?.push(questionFrame())
  await settle()
  assert.equal(h.port.pending, 0)
  assert.deepEqual(h.results.map((entry) => entry.outcome), [{ kind: 'next' }], '认不出就委托')
  assert.match(h.warnings.join('\n'), /认不出唯一的 tool call 身份/)
})

test('计划审查（程序化提问，没有 tool/call）→ 委托，且**不 warn**', { timeout: 60_000 }, async () => {
  const h = harness()
  await openStream(h)
  h.streams[0]?.push(
    questionFrame({
      questions: [
        { id: 'plan', question: '批准吗', options: [], intent: { kind: 'plan-review', approve: 'yes' } },
      ],
    }),
  )
  await settle()
  assert.equal(h.port.pending, 0)
  assert.deepEqual(h.results.map((entry) => entry.outcome), [{ kind: 'next' }])
  assert.deepEqual(h.warnings, [], '计划审查本来就没有 tool/call —— 这不是异常')
})

// ---------------------------------------------------------------------------
// 判据 5：断流 → 退避重连，在途事件仍能被处理
// ---------------------------------------------------------------------------

test('流断开 → 退避重连；在途 claim 不断，重投的同一 eventId 不造第二条 claim', { timeout: 60_000 }, async () => {
  const h = harness()
  await openStream(h, 'c-1')

  // 第一代：一条在途审批还没人答，流就断了。
  h.streams[0]?.push(approvalFrame())
  await settle()
  assert.equal(h.port.pending, 1)
  h.streams[0]?.end()
  await settle()

  assert.equal(h.client?.clientId, null, '流没了就没有 clientId')
  assert.equal(
    h.port.pending,
    1,
    'claim 还在：断线只撤投递（`api/gateway/src/index.ts:717-721`），手机重连回来还能答',
  )
  assert.equal(h.timers.box.fire !== null, true, '应当排了一次退避重连')
  assert.equal(h.timers.box.delay, 1000, '首次退避 1 s（抖动为 0）')

  h.timers.box.fire?.()
  await settle()
  assert.equal(h.opens.length, 2, '重连就是重开一条流')
  const second = await openStream(h, 'c-2', 1)
  assert.equal(h.client?.clientId, 'c-2')

  // gateway 把同一条 pending event（同一个 eventId）重投给新 client（`api/gateway/src/index.ts:571`）。
  second.push(approvalFrame())
  await settle()
  assert.equal(h.port.pending, 1, '重投同一 eventId 不该造出第二条 claim')
  assert.equal(h.port.settleClaim(SID, 'i:approval-1', [{ id: 'i:approval-1', selected: [APPROVAL_ALLOW_LABEL] }]), true)
  await until(() => h.results.length === 1, '重连之后的结果请求')
  assert.equal(h.results[0]?.clientId, 'c-2', '结果必须带**当前这一代**的 clientId')
  assert.equal(h.results[0]?.eventId, 'e-1', 'eventId 跨代不变（gateway 的 pending 表按它索引）')
})

test('流还没注册（open 抛 service-unavailable）→ 退避重试，接上就照常工作', { timeout: 60_000 }, async () => {
  // 第一次 open 抛错：`api/remotes` 还没注册源（`api/gateway/src/index.ts:548-555`）。
  const h = harness({ failOpen: true })
  await until(() => h.opens.length === 1, '第一次尝试')
  await settle()
  assert.match(h.warnings.join('\n'), /未接上/, '第一次失败要吵（后面的重复只进 debug）')
  assert.equal(h.streams.length, 0, '第一次没拿到流')
  assert.equal(h.timers.box.fire !== null, true)

  h.timers.box.fire?.()
  await openStream(h)
  assert.equal(h.client?.clientId, 'c-1')
})

test('认不出的帧类型 → 忽略并留声，不拆流', { timeout: 60_000 }, async () => {
  const h = harness()
  await openStream(h)
  h.streams[0]?.push({ type: 'something-new', value: 1 })
  await settle()
  assert.match(h.warnings.join('\n'), /认不出的帧/)
  assert.equal(h.client?.clientId, 'c-1')

  // 之后仍能正常处理交互
  h.streams[0]?.push(approvalFrame())
  await settle()
  assert.equal(h.port.pending, 1)
})

// ---------------------------------------------------------------------------
// 卸载与失败的可见性
// ---------------------------------------------------------------------------

test('dispose：断开流、停掉重连、释放 owner peer', { timeout: 60_000 }, async () => {
  const h = harness()
  await openStream(h)
  const peer = h.peers[0]
  assert.ok(peer !== undefined)

  await h.client?.dispose()
  await settle()

  assert.equal(peer.disposed, true, 'in-process peer 是进程内信任面：卸载要释放')
  assert.equal(h.client?.clientId, null)
  const opensBefore = h.opens.length
  assert.equal(h.timers.box.fire, null, '不该再排一次重连')
  await settle()
  assert.equal(h.opens.length, opensBefore, '卸载之后不许再开流')
})

test('结果没被接纳（result.ok !== true）→ 留声，且**不重试**（重试会被读成"又答了一次"）', { timeout: 60_000 }, async () => {
  const h = harness({ failResults: true })
  await openStream(h)
  h.streams[0]?.push(approvalFrame())
  await settle()
  assert.equal(h.port.settleClaim(SID, 'i:approval-1', [{ id: 'i:approval-1', selected: [APPROVAL_ALLOW_LABEL] }]), true)
  await until(() => h.results.length === 1, '结果请求')

  await settle(16)
  assert.equal(h.results.length, 1, '结果只发一次')
  assert.match(h.warnings.join('\n'), /没有被 gateway 接纳/)
})

test('第一帧不是 ready → 拆掉这条流并退避重连（不猜它的形状）', { timeout: 60_000 }, async () => {
  const h = harness()
  await until(() => h.streams.length === 1, '第一条流')
  h.streams[0]?.push(approvalFrame())
  await settle()

  assert.match(h.warnings.join('\n'), /未接上/, '首帧不对要吵')
  assert.equal(h.port.pending, 0, '没拿到 clientId 之前什么都不 claim')
  assert.equal(h.timers.box.fire !== null, true, '应当排一次重连')
  assert.equal(h.client?.clientId, null)
})

test('同一 eventId 重投到同一个 client → 不重复 claim（第一条 await 不能被挤掉）', { timeout: 60_000 }, async () => {
  const h = harness()
  await openStream(h)
  h.streams[0]?.push(approvalFrame())
  await settle()
  assert.equal(h.port.pending, 1)

  h.streams[0]?.push(approvalFrame())
  await settle()
  assert.equal(h.port.pending, 1, '重复投递不该造出第二条 claim')

  // 手机上答一次就好：第一条 claim 收到了答案、回了话，且只回一次。
  assert.equal(h.port.settleClaim(SID, 'i:approval-1', [{ id: 'i:approval-1', selected: [APPROVAL_ALLOW_LABEL] }]), true)
  await until(() => h.results.length === 1, '结果请求')
  await settle(16)
  assert.equal(h.results.length, 1)
})

test('审批与提问同时到达 → 两条 claim 各按自己的 eventId 回话', { timeout: 60_000 }, async () => {
  const h = harness()
  await openStream(h)
  h.streams[0]?.push(approvalFrame())
  h.streams[0]?.push(questionFrame({ eventId: 'q-1', wait: { callId: 'call-q', timed: true } }))
  await settle()
  assert.equal(h.port.pending, 2, '两条不同的交互各一条 claim')

  assert.equal(h.port.settleClaim(SID, 't:call-q', [{ id: 'q1', selected: ['甲'] }]), true)
  assert.equal(h.port.settleClaim(SID, 'i:approval-1', [{ id: 'i:approval-1', selected: [APPROVAL_ALLOW_LABEL] }]), true)
  await until(() => h.results.length === 2, '两条结果请求')

  const byEvent = new Map(h.results.map((entry) => [entry.eventId, entry]))
  assert.deepEqual(byEvent.get('q-1')?.outcome, {
    kind: 'result',
    value: { answers: [{ id: 'q1', selected: ['甲'] }] },
  })
  assert.deepEqual(byEvent.get('e-1')?.outcome, { kind: 'result', value: 'allowed-once' })
})

test('dispose 撤掉在途 claim（不留一张关不掉的手卡）', { timeout: 60_000 }, async () => {
  const h = harness()
  await openStream(h)
  h.streams[0]?.push(approvalFrame())
  await settle()
  assert.equal(h.port.pending, 1)

  await h.client?.dispose()
  await settle()
  assert.equal(h.port.pending, 0, '卸载时在途 claim 必须收口（否则看护计时器白挂 10 分钟）')
  assert.deepEqual(h.results, [], '卸载不是回答，什么都不回')
})
