/**
 * 交互的**客户端**接入：连接器作为 gateway 的一个 owner client 接 `$events` 转发流（契约 §6.2）。
 *
 * ## 为什么不再是 host 的应答者
 *
 * 上一版在 host 的 waterfall 里 `prepend` 一个 answerer。claim 之后桌面收不到请求；
 * 手机先答时桌面卡也关不掉 —— 桌面卡的寿命挂在**它自己那条 invocation** 上，唯一的
 * "别处已答"信号是 gateway 的 `cancel`，而 `cancel` 只发给**这条 pending event 的投递对象**
 * （`packages/api/gateway/src/index.ts:734-745`）。我们不在投递表里，就永远收不到它。
 *
 * DSH 自己的多客户端模型正是我们要的（`packages/api/gateway/src/index.ts`）：
 *
 * - 新 client 注册时重投在途事件（`:571`）；
 * - 新事件投给**所有** answerable client（`:676-679`）；
 * - 重复 / 迟到的结果是 no-op（`:696-699`）；
 * - 断线只撤投递、不结算（`:717-721`）；
 * - 结算时给**其余** client 发 `cancel`（`:734-745`）。
 *
 * 于是：桌面弹它自己的卡（不变），手机也弹我们的卡；**两边由同一个触发关闭**：
 *
 * - 手机先答 → 我们回 `{kind:'result'}` → gateway 结算 → 给浏览器发 `cancel` →
 *   `packages/api/gateway/src/client/remote-events.ts:148-149` abort 投递信号 →
 *   `packages/client/ui-approval/src/client/index.ts:59-69` 的 `finally` 撤卡；
 * - 桌面先答 → 我们收到 `cancel` → 撤掉手机的在途 claim（卡由 `approval/decided` 关）。
 *
 * ## 两种"不参与"，一律回 `{kind:'next'}`（原生委托）
 *
 * 1. 这个会话没登记给手机（别名表里没有）；
 * 2. 认不出这一项的原生身份（审批：日志里没有唯一一条未结算的 `approval/asked`；
 *    提问：既没有 `wait.callId`、日志里也没有唯一一条未结算的 `ask_user_question`）。
 *
 * **身份用的是 DSH 自己的 id**：审批 = `ApprovalRequestId`（`approval/asked.id`），
 * 提问 = `tool/call` 的 `callId`；手机那张卡的 `itemId` 就是它们（`i:` / `t:` 前缀，
 * 见 `interaction-face.ts` 的 {@link interactionItemOf}）。**不看审批的 `callId`** ——
 * 它在 DSH 是可选的（`user-approval/src/types.ts:68-69`），浏览器没有它照样弹卡
 * （`client/ui-approval/src/client/index.ts:45-53`）。
 *
 * **没有"档位"**：手机连着就是 client、就参与，和浏览器完全一样。以前那三档
 * （`never` / `foreground` / `always`）是为"抢"服务的 —— 抢到桌面就看不到，所以需要
 * "什么时候抢"。现在两边都收到、谁先答谁赢，没有"谁接管"，档位也就没有意义（2026-10-23 删掉）。
 * 不想让手机参与就把传输通道停掉（手机连不上 = 没有投递），不需要在交互层再加一层开关。
 *
 * `next()` 就是 DSH 的**委托**语义（`packages/interaction/user-approval/src/types.ts:81-82`：
 * "Return an outcome to claim the request or call `next()` to delegate"），**不是**我们自己
 * 发明的一种沉默。gateway 的规则是"**只有所有投递都 `next` 之后**才交还 Host"
 * （`packages/api/gateway/tests/gateway-stream.host.spec.ts:1402`），所以一个 client
 * `next` 之后事件**不结算**、另一个 client 的卡照旧能答；真的没人答时由 DSH 自己兜底成
 * `'unavailable'`（`packages/interaction/user-approval/src/index.ts:281-283`）。
 *
 * **没有超时**：DSH 的审批没有"等多久"这个概念（浏览器的卡一直挂到有人答或 signal 中止），
 * 所以这里也**不造**一个看护计时器。手机答了就回 `result`；谁都没答就一直等。
 *
 * Note: 为什么改、否掉了哪些方案 ——
 * `.agents/notes/implemented/2026-10-23-interaction-as-gateway-client.md`。
 */
import type { Context } from '@deepseek-ai/cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import type { SessionEvent } from '@deepseek-ai/dsh-session'
import type { AskUserQuestionItem } from '@deepseek-ai/dsh-user-questions'

import type { InteractionPort } from '../interaction-claims.js'
import { approvalItemId, questionItemId } from '../interaction-face.js'
import { createBackoff, type Backoff } from '../transport/backoff.js'
import { approvalAskEvent, questionAskEvent, redeliverOf } from './ask-event.js'
import { resolveApprovalIdentity } from './approval-call.js'
import { resolveQuestionCall } from './question-call.js'

/** `setTimeout` 语义，返回取消函数（与 `protocol/handshake-driver.ts:108` 的注入形状一致）。 */
export type Schedule = (fn: () => void, ms: number) => () => void

// ---------------------------------------------------------------------------
// 宿主接口（只取本层用到的形状；两个服务键都是可选的，见 `dsh/caps.ts`）
// ---------------------------------------------------------------------------

/**
 * `connection` 服务里本层用到的两件东西。
 *
 * - `createPeer({principal:{kind:'owner'}})`：in-process owner peer
 *   （`packages/client/connection/src/rpc-host.ts:140`；`browserPeer` 也是 `{kind:'owner'}`，`:94`）。
 *   **`interactions` 默认就是 `'answer'`**（`packages/client/connection/src/peer.ts:40`），
 *   而 gateway 对非 answer peer 直接回 `gateway/interactions-forbidden`
 *   （`packages/api/gateway/src/index.ts:1225-1232`）。
 * - `createSharedFetchHandler('/api')`：共享 RPC 通道的 fetch 口（`rpc-host.ts:207-232`），
 *   **必须带 peer**（`:215`）—— 结果请求按 peer 判归属（gateway `:493-498`）。
 */
interface PeerHandle {
  dispose(): Promise<void>
}

interface SharedFetchHandler {
  fetch(request: Request, peer: PeerHandle): Promise<Response>
}

interface ConnectionService {
  createPeer(options: { readonly principal: { readonly kind: 'owner' } }): PeerHandle
  createSharedFetchHandler(channel: '/api'): SharedFetchHandler
}

/**
 * `typertGateway` 的流入口（`packages/api/gateway/src/types.ts:92-109`）。
 *
 * DSH 自己的测试就是这么用的：`api/gateway/tests/gateway-access.host.spec.ts:697`。
 */
interface GatewayService {
  readonly wireStream: {
    open(
      endpoint: string,
      payload: unknown,
      uplink: AsyncIterable<unknown>,
      peer: PeerHandle,
      signal: AbortSignal,
    ): Promise<AsyncIterable<unknown>>
  }
}

/** `agents` 注册表的读取面（`packages/core/agent/src/index.ts:568` 的 `get`）。 */
interface AgentsRegistry {
  get(id: Agent['id']): Agent | undefined
}

// ---------------------------------------------------------------------------
// 线协议常量（`packages/api/gateway/src/stream-protocol.ts`）
// ---------------------------------------------------------------------------

/** 转发流端点名（`:10`）。 */
export const EVENT_STREAM_ENDPOINT = '$events'
/** 回结果的 unary 端点名（`:13`）。 */
export const EVENT_RESULT_ENDPOINT = '$events/result'
/** 只有这两个事件是**交互**：它们是 `api/remotes` 里唯二 `mode: 'waterfall'` 的条目
 * （`packages/api/remotes/src/remote-events.ts:28,54`）。 */
export const APPROVAL_EVENT = 'approval/request'
export const QUESTION_EVENT = 'user-questions/request'

/** 结果请求的地址：只有 pathname 有意义（`createSharedFetchHandler` 自己解 `/api/<endpoint>`）。 */
const RESULT_URL = `http://host/api/${EVENT_RESULT_ENDPOINT}`

/** 下行帧（`stream-protocol.ts:34-64`）。只解出本层要用的字段。 */
type Downlink =
  | { readonly type: 'ready'; readonly clientId: string }
  | { readonly type: 'emit' }
  | {
    readonly type: 'waterfall'
    readonly event: string
    readonly eventId: string
    readonly agentId: string
    readonly request: Readonly<Record<string, unknown>>
  }
  | { readonly type: 'cancel'; readonly eventId: string }

/**
 * 解析一帧下行。
 *
 * 这是**别人的线形状**，所以逐个字段校验（与 DSH 自己的客户端同一个口径：
 * `api/gateway/src/client/remote-events.ts:264-314`）。认不出的 `type` 只留声、不抛 ——
 * 新增一种帧不该让我们把整条流拆掉；**已知帧但字段不全**才抛（continue 只会把结果
 * 错配到别的事件上）。
 */
function parseDownlink(value: unknown): Downlink | { readonly type: 'unknown'; readonly raw: unknown } {
  if (!isRecord(value)) throw new TypeError('交互 $events 流收到一个非对象帧')
  switch (value['type']) {
    case 'ready': {
      const clientId = value['clientId']
      if (typeof clientId !== 'string' || clientId === '') throw new TypeError('ready 帧缺少 clientId')
      return { type: 'ready', clientId }
    }
    case 'emit':
      return { type: 'emit' }
    case 'cancel': {
      const eventId = value['eventId']
      if (typeof eventId !== 'string' || eventId === '') throw new TypeError('cancel 帧缺少 eventId')
      return { type: 'cancel', eventId }
    }
    case 'waterfall': {
      const event = value['event']
      const eventId = value['eventId']
      const agentId = value['agentId']
      const request = value['request']
      if (typeof event !== 'string' || event === '') throw new TypeError('waterfall 帧缺少 event')
      if (typeof eventId !== 'string' || eventId === '') throw new TypeError('waterfall 帧缺少 eventId')
      if (typeof agentId !== 'string' || agentId === '') throw new TypeError('waterfall 帧缺少 agentId')
      if (!isRecord(request)) throw new TypeError('waterfall 帧缺少 request 对象')
      return { type: 'waterfall', event, eventId, agentId, request }
    }
    default:
      return { type: 'unknown', raw: value }
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * 计划审查走的是**提问**通道、不是审批，靠 `intent.kind` 判别
 * （`packages/plan/plan-mode/src/index.ts:320-329`）。
 *
 * 三件**都只能从请求里读**：
 *
 * - 题 id —— 答案批次按它回（宿主的 `REVIEW_ID = 'plan-review'`，`:73`）；
 * - 同意标签 —— `intent.approve`（`:76,329`），plan-mode 用它判"同意"（`:346-350`）；
 * - 那次工具调用的 `callId` —— `intent.callId`（`:329`），手机那张计划卡的 id 就是它。
 *
 * 手机只看得到 `exit_plan_mode` 的 `tool/call`（`presentCall` 只给正文与标题，`:364-369`），
 * 选项与标签从来不会到手机。所以"能否认出这是计划审查"必须在这一层判，**不猜**。
 */
function planReviewOf(
  questions: readonly AskUserQuestionItem[],
):
  | { questionId: string; approve: string; callId?: string }
  | undefined {
  for (const question of questions) {
    const intent = question.intent
    if (intent?.kind !== 'plan-review') continue
    if (typeof intent.approve !== 'string' || intent.approve === '') continue
    if (typeof question.id !== 'string' || question.id === '') continue
    return {
      questionId: question.id,
      approve: intent.approve,
      ...(typeof intent.callId === 'string' && intent.callId !== ''
        ? { callId: intent.callId }
        : {}),
    }
  }
  return undefined
}

// ---------------------------------------------------------------------------
// 客户端
// ---------------------------------------------------------------------------

export interface InteractionClientLogger {
  warn(message: string, detail?: unknown): void
  debug?(message: string, detail?: unknown): void
}

export interface InteractionClientDeps {
  /** 在途 claim 的看护（`interaction-claims.ts`）。 */
  port: InteractionPort
  /** DSH 会话 id → 通道别名。未登记给手机的会话返回 `undefined`（那条交互就委托出去）。 */
  sidOf(dshSessionId: string): string | undefined
  log?: InteractionClientLogger
  /** 退避计时器（测试注入确定值）。 */
  schedule?: Schedule
  backoff?: Backoff
}

export interface InteractionClient {
  /** 当前这一代 client 的 id；还没接上时为 `null`（指标与测试用）。 */
  readonly clientId: string | null
  /** 断开当前流、停掉重连并释放 owner peer（卸载用）。 */
  dispose(): Promise<void>
}

/** 默认计时器（与 `interaction-face.ts` 的 `Schedule` 同形）。 */
const defaultSchedule: Schedule = (fn, ms) => {
  const handle = setTimeout(fn, ms)
  return () => {
    clearTimeout(handle)
  }
}

/**
 * 建交互客户端。
 *
 * @returns `null` = 宿主缺 `typertGateway` / `connection`（这两个服务在不在，见 `dsh/caps.ts`）。
 *   那时**不做手机交互**：不转发、不 claim，也**不保留**第二套 host answerer 兜底 ——
 *   两条路并存时"手机先答桌面卡关不掉"会以另一种形状回来。
 */
export function createInteractionClient(
  ctx: Context,
  deps: InteractionClientDeps,
): InteractionClient | null {
  const connection = ctx.get('connection') as ConnectionService | undefined
  const gateway = ctx.get('typertGateway') as GatewayService | undefined
  if (connection === undefined || gateway === undefined) {
    deps.log?.warn(
      'typertGateway / connection 服务不在：手机交互不挂（没有 host answerer 兜底）',
      { gateway: gateway !== undefined, connection: connection !== undefined },
    )
    return null
  }
  const log = deps.log
  const schedule = deps.schedule ?? defaultSchedule
  const backoff = deps.backoff ?? createBackoff()
  const peer = connection.createPeer({ principal: { kind: 'owner' } })
  const fetchHandler = connection.createSharedFetchHandler('/api')

  /**
   * `eventId → 这条投递的取消开关`。
   *
   * **只由 `cancel` 帧与 `dispose()` 触发** —— 流换代**不**撤它：claim 的生命周期挂在
   * 挂载（Host 上那条 pending event）上，不挂在某一条传输上。DSH 自己就是这样：
   * 换代只撤投递、不结算，新 client 上来还会把在途事件**重投**给新 client
   * （`packages/api/gateway/src/index.ts:717-721`、`:571`）。
   */
  const deliveries = new Map<string, AbortController>()
  /** 正在进行的分批任务（不阻塞读流：一条 claim 可能等十分钟的人）。**寿命 = 挂载**。 */
  const tasks = new Set<Promise<void>>()
  let generation: AbortController | null = null
  let clientId: string | null = null
  /** 这一代的 `ready`（`reply` 在换代窗口里等它：结果等传输回来再发，不吞掉）。 */
  let ready = deferClientId()
  let stopped = false
  let stopTimer: (() => void) | null = null
  let wake: (() => void) | null = null

  function deferClientId(): { readonly promise: Promise<string>; resolve(id: string): void } {
    let resolveOne!: (id: string) => void
    const promise = new Promise<string>((resolve) => {
      resolveOne = resolve
    })
    return {
      promise,
      resolve: (id) => {
        resolveOne(id)
      },
    }
  }

  /** gateway 的 `agentId` 就是 `Agent.id`（`packages/core/agent/src/index.ts:568` 的键）。 */
  const eventsOf = (agentId: string): readonly SessionEvent[] | undefined => {
    const agents = ctx.get('agents') as AgentsRegistry | undefined
    return agents?.get(agentId as Agent['id'])?.session.snapshotEvents()
  }

  /** 登记一条在途投递。`cancel` 帧与 `dispose()` 经由它撤掉手机侧的在途 claim。 */
  const track = (eventId: string, itemId: string): void => {
    const controller = new AbortController()
    controller.signal.addEventListener(
      'abort',
      () => {
        deps.port.cancelClaim(itemId)
      },
      { once: true },
    )
    deliveries.set(eventId, controller)
  }

  /** 回给 gateway 的一个 outcome（`stream-protocol.ts:88-95`）。 */
  type Outcome = { readonly kind: 'result'; readonly value: unknown } | { readonly kind: 'next' }

  /**
   * 把 outcome 回给 gateway（`$events/result`，`stream-protocol.ts:12-13`）。
   *
   * `next` 是**委托**（不是沉默）：一个 client `next` 之后事件不结算，别的 client 照旧能答
   * （`packages/api/gateway/tests/gateway-stream.host.spec.ts:1402`）。
   */
  const reply = async (eventId: string, outcome: Outcome): Promise<void> => {
    // **换代窗口**：这一代已经结束、下一代还没 ready。**等它**，而不是把结果吞掉 ——
    // 这是补通道（传输短暂不在），不是替宿主决定：结果要么发出去，要么在卸载时放弃。
    const forClient = clientId ?? await ready.promise
    if (forClient === '') {
      // `dispose()` 把等待中的 ready 解成空串：没有可回写的投递对象。
      log?.warn('交互结果没有可回写的 client（交互客户端已卸载）', { eventId })
      return
    }
    const response = await fetchHandler.fetch(
      new Request(RESULT_URL, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          type: 'client-request',
          rpcId: `result-${eventId}`,
          method: EVENT_RESULT_ENDPOINT,
          payload: { args: { clientId: forClient, eventId, outcome } },
        }),
      }),
      peer,
    )
    const body = (await response.json()) as {
      result?: { ok?: boolean; error?: { code?: string; message?: string } }
    }
    if (body.result?.ok === true) return
    // 结果没被接纳：gateway 那边可能已经结算（`receiveRemoteEventResult` 对迟到的结果是
    // no-op，`:696-699`），也可能我们已经不是投递对象。**不重试** —— 重试会被读成
    // "用户又答了一次"。留声即可。
    log?.warn('交互结果没有被 gateway 接纳', { eventId, error: body.result?.error })
  }

  /** 一条审批：认身份 → claim → 手机答了就回 `allowed-once` / `rejected`。 */
  const answerApproval = async (
    frame: Extract<Downlink, { type: 'waterfall' }>,
    sid: string,
  ): Promise<void> => {
    const request = frame.request
    const requestCallId = typeof request['callId'] === 'string' && request['callId'] !== ''
      ? request['callId']
      : undefined
    const events = eventsOf(frame.agentId)
    // **身份**：请求对象里没有审批 id（`user-approval/src/types.ts:63-76`），而服务在 dispatch
    // 之前就把带 id 的 `approval/asked` 落盘了（`src/index.ts:224-231`）—— 从日志里取它。
    // 带 `callId` 时按 callId 精确配，不带时才退到"唯一一条未结算"，认不出就委托。
    // 判据与失败方向见 `approval-call.ts` 的文件头。
    const identity = events === undefined
      ? ({ kind: 'none' } as const)
      : resolveApprovalIdentity(events, requestCallId)
    if (identity.kind !== 'found') {
      log?.warn('审批认不出对应的 approval/asked 身份：这条委托出去（桌面照常答）', {
        sid,
        reason: identity.kind,
        ...(identity.kind === 'ambiguous' ? { ids: identity.ids } : {}),
      })
      await reply(frame.eventId, { kind: 'next' })
      return
    }
    const itemId = approvalItemId(identity.id)
    // 重连重投：那条 `approval/asked` 的原 seq 与 body 随请求进 claim（`ask-event.ts`）。
    const redeliver = events === undefined ? undefined : redeliverOf(approvalAskEvent(events, identity.id))

    track(frame.eventId, itemId)
    try {
      const settlement = await deps.port.askApproval({
        sid,
        itemId,
        ...(redeliver === undefined ? {} : { redeliver }),
      })
      if (settlement.kind !== 'answered') return
      await reply(frame.eventId, { kind: 'result', value: settlement.value })
    } finally {
      deliveries.delete(frame.eventId)
    }
  }

  /** 一条提问：身份（timed 自带 / legacy 从日志推）→ claim → 手机答了就回答案批次。 */
  const answerQuestion = async (
    frame: Extract<Downlink, { type: 'waterfall' }>,
    sid: string,
  ): Promise<void> => {
    const request = frame.request
    const questions = request['questions']
    if (!Array.isArray(questions)) {
      await reply(frame.eventId, { kind: 'next' })
      return
    }
    // **原样透传**：手机上是 DSH 的形状，翻译层就是漂移层（契约 §6.3.1）。
    const items = questions as readonly AskUserQuestionItem[]
    const events = eventsOf(frame.agentId)
    const wait = request['wait']
    const waitCallId =
      isRecord(wait) && typeof wait['callId'] === 'string' && wait['callId'] !== ''
        ? wait['callId']
        : undefined
    // **身份**，按优先级三条：
    //
    // 1. **计划审查的 `intent.callId`**（`plan-mode/src/index.ts:329`）：它是那次
    //    `exit_plan_mode` 的 tool call id，**手机侧那张计划卡正是用它建出来的**
    //    （`app/lib/data/projection.dart` 从 `tool/call` 造 plan item，id = `t:<callId>`）。
    //    2026-10-24 之前这里刻意不读它，理由是"手机上没有那张卡"—— 那个理由随
    //    "卡来自请求"落地而失效（契约 §6.3.1）。
    // 2. timed 形态的 `wait.callId`。
    // 3. legacy 形态：从会话日志里推（唯一一条没有 `tool/result` 的 `ask_user_question`
    //    `tool/call`，判据见 `question-call.ts`）。认不出就**委托**，不抛也不猜。
    const plan = planReviewOf(items)
    const identity = plan?.callId !== undefined
      ? ({ kind: 'found', callId: plan.callId } as const)
      : waitCallId !== undefined
        ? ({ kind: 'found', callId: waitCallId } as const)
        : events === undefined
          ? ({ kind: 'none' } as const)
          : resolveQuestionCall(events)
    if (identity.kind !== 'found') {
      // 计划审查是**程序化**提问（`/exit_plan_mode` 的 `ask()`）：它本来就没有
      // `ask_user_question` 的 `tool/call`，所以"认不出"是正常形态，不该留 warn。其余情况是异常，要留声。
      if (plan === undefined) {
        log?.warn('提问认不出唯一的 tool call 身份：这条委托出去（桌面照常答）', {
          sid,
          reason: identity.kind,
          ...(identity.kind === 'ambiguous' ? { callIds: identity.callIds } : {}),
        })
      }
      await reply(frame.eventId, { kind: 'next' })
      return
    }
    const itemId = questionItemId(identity.callId)
    const redeliver =
      events === undefined ? undefined : redeliverOf(questionAskEvent(events, identity.callId))

    track(frame.eventId, itemId)
    try {
      const settlement = await deps.port.askQuestion({
        sid,
        itemId,
        ...(redeliver === undefined ? {} : { redeliver }),
        // 计划审查：手机只表达"同意 / 继续规划"，题 id 与"同意"标签由**请求**定
        // （见 `interaction-claims.ts` 的 `ClaimRequest.planReview`）。
        ...(plan === undefined
          ? {}
          : { planReview: { questionId: plan.questionId, approve: plan.approve } }),
      })
      if (settlement.kind !== 'answered') return
      await reply(frame.eventId, { kind: 'result', value: settlement.value })
    } finally {
      deliveries.delete(frame.eventId)
    }
  }

  /** 一条 `waterfall` 帧的完整去路：参与就等手机，不参与就**委托**（`next`）。 */
  const answer = async (frame: Extract<Downlink, { type: 'waterfall' }>): Promise<void> => {
    // 只认两种交互；其余转发事件不是我们要答的（`api/remotes` 的 allowlist 里也只有这两种
    // 是 `mode: 'waterfall'`，`packages/api/remotes/src/remote-events.ts:28,54`）。
    if (frame.event !== APPROVAL_EVENT && frame.event !== QUESTION_EVENT) return
    // 同一个 `eventId` 已经有一条在途投递：**不重复 claim**。重复登记会把第一条 claim
    // 从表里挤掉，而它那个 await 永远不会结算（一条挂死的等待 + 一张关不掉的手卡）。
    if (deliveries.has(frame.eventId)) return
    const sid = deps.sidOf(frame.agentId)
    if (sid === undefined) {
      // 这个会话没登记给手机：委托（原生 next），桌面照常答。
      await reply(frame.eventId, { kind: 'next' })
      return
    }
    if (frame.event === APPROVAL_EVENT) await answerApproval(frame, sid)
    else await answerQuestion(frame, sid)
  }

  /** 撤销一条在途投递（gateway 说这条 pending event 已经结算）。 */
  const cancelDelivery = (eventId: string): void => {
    const controller = deliveries.get(eventId)
    if (controller === undefined) return
    deliveries.delete(eventId)
    controller.abort(new Error('gateway 已结算这条交互'))
  }

  const waitForRetry = (ms: number): Promise<void> =>
    new Promise((resolve) => {
      wake = resolve
      stopTimer = schedule(() => {
        stopTimer = null
        wake = null
        resolve()
      }, ms)
    })

  /** 一条流的寿命：读到 `ready` 之后逐帧分派，流结束（或被 abort）时返回。 */
  const runGeneration = async (): Promise<void> => {
    const lifetime = new AbortController()
    generation = lifetime
    try {
      const stream = await gateway.wireStream.open(
        EVENT_STREAM_ENDPOINT,
        // 空 `args` 是**唯一**合法载荷（`api/gateway/src/index.ts:535-547`）。
        { args: {} },
        // gateway 拥有这条流、不读 uplink（`:517-520`），给一个立刻结束的迭代器即可。
        (async function* () {})(),
        peer,
        lifetime.signal,
      )
      for await (const value of stream) {
        const frame = parseDownlink(value)
        if (clientId === null) {
          // 开启帧必须先是 `ready`（`stream-protocol.ts:34-39`）。
          if (frame.type !== 'ready') throw new TypeError('交互 $events 流的第一帧不是 ready')
          clientId = frame.clientId
          ready.resolve(frame.clientId)
          backoff.reset()
          log?.debug?.('交互已作为 owner client 接入 gateway', { clientId })
          continue
        }
        switch (frame.type) {
          case 'ready':
            throw new TypeError('同一条 $events 流里出现了第二个 ready')
          case 'emit':
            // 通知不是交互：待处理项走会话事件流（`ev` 帧），不走这里。
            break
          case 'cancel':
            cancelDelivery(frame.eventId)
            break
          case 'waterfall': {
            // **不 await**：一条 claim 可能等十分钟的人，读流不能被它堵住。
            const task = answer(frame)
              .catch((error: unknown) => {
                log?.warn('处理一条转发交互失败（不拆流）', error)
              })
              .finally(() => {
                tasks.delete(task)
              })
            tasks.add(task)
            break
          }
          case 'unknown':
            log?.warn('交互 $events 流里有一种认不出的帧，已忽略', frame.raw)
            break
        }
      }
    } finally {
      generation = null
      clientId = null
      // **这一代的投递不撤**：claim 挂在挂载（Host 上那条 pending event）上，不挂在传输上。
      // 与 DSH 同构 —— 断线只撤投递、不结算（`api/gateway/src/index.ts:717-721`），
      // 新 client 上来会把在途事件重投给新 client（`:571`），那时 `deliveries` 里已有的
      // eventId 会直接跳过、不重复 claim（`answer` 开头那条）。
      // 在途的答复也不用等：它们在 `reply` 里等下一代的 `ready`（见那里的注释）。
      ready = deferClientId()
    }
  }

  /** 断流 → 退避重连。gateway 会把在途事件重投给新 client（`:571`），重连即恢复。 */
  const run = async (): Promise<void> => {
    while (!stopped) {
      try {
        await runGeneration()
      } catch (error) {
        if (stopped) return
        // 第一次连接失败（例如 `api/remotes` 还没注册）要吵；之后的重复只进 debug —
        // 一个服务一直不在时，每 30 秒一行 warn 会把真正的告警淹掉。
        if (backoff.attempt === 0) log?.warn('交互 $events 流未接上，准备重连', error)
        else log?.debug?.('交互 $events 流仍未接上', error)
      }
      if (stopped) return
      await waitForRetry(backoff.next())
    }
  }

  const running = run()

  return {
    get clientId() {
      return clientId
    },
    async dispose() {
      stopped = true
      // **卸载才是终态**：在途投递全部作废（结果再也发不回去），等待中的 `ready` 解成空串，
      // 再等挂载级的分批任务收束。这一条与"断线只撤投递"是两件事：
      // 断线时我们还会回来，卸载时不会。
      ready.resolve('')
      generation?.abort(new Error('交互客户端已卸载'))
      for (const eventId of [...deliveries.keys()]) cancelDelivery(eventId)
      stopTimer?.()
      stopTimer = null
      const wakeNow = wake
      wake = null
      wakeNow?.()
      await running
      await Promise.allSettled([...tasks])
      await peer.dispose()
    },
  }
}
