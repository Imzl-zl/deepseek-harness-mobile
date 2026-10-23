/**
 * 交互层内核：提问 / 计划审查的待处理投影与 `interaction.respond` 的应答路由（契约 §6）。
 *
 * 三条约束决定这个模块的长相：
 *
 * 1. **不 import DSH**。宿主能力（`userQuestions.answer`、投影来源、时钟）全部注入，
 *    整层因此能在纯 Node 下用假实现单测，不要求一个活着的 DSH。每一处对 DSH 行为的
 *    判断都在注释里带 `packages/...:行号`，DSH 升级时可逐条回核。
 * 2. **不发明协议**。答案批次与 DSH 的 `AskUserQuestionAnswer` 逐字一致
 *    （`packages/interaction/user-questions/src/types.ts:66-69`），原样转发 ——
 *    翻译层就是漂移层（契约 §6.3.1）。
 * 3. **不发明边界**。这里**没有计时器**：DSH 的审批没有超时概念（浏览器的卡也一直挂着），
 *    所以"等多久、什么时候放弃"不是本层该定的事（契约 §6.2）。
 *
 * 边界：本文件只承载**语义**。把请求推给手机的那一步（`interaction-claims.ts` 的
 * `InteractionPort`）、`ev` 帧的拼装、别名→会话的解析都在别处。
 *
 * **本文件里没有"应答者"**：连接器不再是 host 的 waterfall answerer，而是 gateway 的一个
 * owner client（`dsh/interaction-client.ts`，契约 §6.2）。所以这里既没有 `ctx.on(...)`
 * 也没有看护应答者的包装 —— 只有提问内核。
 * Note: 为什么删掉了应答者那一路 ——
 * `.agents/notes/implemented/2026-10-23-interaction-as-gateway-client.md`。
 */
import { ProtocolError } from './protocol/errors.js'

// ---------------------------------------------------------------------------
// 协议形状（DSH 类型的结构镜像：内核不 import DSH，装配层的真实类型可结构化赋进这些形状）
// ---------------------------------------------------------------------------

/** DSH `AskUserQuestionOption`（`user-questions/src/types.ts:10-15`）。 */
export interface QuestionOption {
  readonly label: string
  readonly description?: string
}

/**
 * DSH `AskUserQuestionIntent`（`types.ts:24-35`）。**意图只改变呈现，不改变协议** ——
 * 计划审查与普通提问共用同一个答案批次（契约 §6.4），所以内核不为它单开一条路。
 */
export interface QuestionIntent {
  readonly kind: 'plan-review'
  readonly approve: string
  readonly callId?: string
}

/** DSH `AskUserQuestionItem`（`types.ts:38-53`）。 */
export interface Question {
  readonly id: string
  readonly question: string
  readonly detail?: string
  readonly header?: string
  readonly options?: readonly QuestionOption[]
  readonly multiSelect?: boolean
  readonly intent?: QuestionIntent
}

/** DSH `AskUserQuestionAnswerItem`（`types.ts:56-63`）。 */
export interface AnswerItem {
  readonly id: string
  readonly selected: readonly string[]
  readonly custom?: string
}

/** DSH `AskUserQuestionAnswer`（`types.ts:66-69`）：一次提问恰好一项。 */
export interface AnswerBatch {
  readonly answers: readonly AnswerItem[]
}

/**
 * DSH `UserQuestionState`（`types.ts:72`）。
 *
 * 两条作答路径由它分开（源码事实，不是本仓的约定）：
 * - `open`：工具调用还在前台等着，答案经 `user-questions/request` waterfall 的 claim
 *   实时返回为工具结果（投影来源 `user-questions/src/projection.ts:256` 的 `tool/call` 分支）；
 * - `continued`：前台等待已超时转 pending，答案只能作为新一轮的用户消息注入
 *   （`answer()` 只在这个集合里找，`user-questions/src/index.ts:146-149,167-168`；
 *   `projection.ts:263-270` 的 `tool/result` 分支把 `open` 翻成 `continued`）。
 */
export type QuestionState = 'open' | 'continued'

/** DSH `PendingUserQuestion`（`types.ts:75-79`）。 */
export interface PendingQuestion {
  readonly callId: string
  readonly questions: readonly Question[]
  readonly state: QuestionState
}

/** DSH `SettledUserQuestion`（`types.ts:88-93`）。 */
export interface SettledQuestion {
  readonly callId: string
  readonly answers: readonly AnswerItem[]
}

/** DSH `UserQuestionProjectionView`（`types.ts:100-105`）。 */
export interface QuestionProjection {
  readonly active: readonly PendingQuestion[]
  readonly settled: readonly SettledQuestion[]
}

/**
 * 协议里的「待处理项」，随 `ev` / `pending.changed` 下发（契约 §6.3）。
 *
 * `itemId = i:<callId>`：待处理集合是**持久条目的投影**（不变量 I4），有稳定身份、
 * 进快照、upsert，不随连接态变化。注意它与时间线条目不是同一个 id —— 提问在时间线上
 * 是 `t:<callId>`（§5.2），待处理集合用 `i:<callId>`（§6.3）。
 */
export interface PendingItem {
  readonly itemId: string
  readonly sid: string
  readonly callId: string
  readonly questions: readonly Question[]
  readonly state: QuestionState
}

/**
 * 提问归属的 agent 句柄。内核不 import DSH，所以这是个**品牌类型**；装配层把 DSH 的
 * `Agent` 传进来。`answer()` 要求 live root agent（`assertLiveRoot`，
 * `packages/interaction/user-questions/src/index.ts:131-144`）：子代理里的提问答不了，
 * 返回 `undefined` 由本内核映射成 `interaction/not-pending`（契约 §15）。
 */
export type QuestionAgent = { readonly __dshLiveRootAgent: 'branded' }

export interface InteractionLogger {
  warn(message: string, detail?: unknown): void
}

// ---------------------------------------------------------------------------
// 待处理投影
// ---------------------------------------------------------------------------

/** 待处理项的稳定身份（契约 §6.3）。 */
export function itemIdOf(callId: string): string {
  return `i:${callId}`
}

/**
 * 把 DSH 的提问投影翻成协议的待处理项。
 *
 * `state` **原样透传，不在这里判灰**：契约 §6.4 把置灰判据交给手机，而 §6.3.1 又说
 * 「迟到的回答允许」—— 两处对 `continued` 的措辞并不一致（§6.4 说手机据此置灰，
 * §6.3.1 说超时转 pending 后用户仍可答）。内核只如实转述宿主状态，不替手机做这个判断；
 * `settled` 半边不进待处理集合（它已经答完了）。
 */
export function projectPendingQuestions(
  sid: string,
  projection: QuestionProjection,
): readonly PendingItem[] {
  return projection.active.map((question) => ({
    itemId: itemIdOf(question.callId),
    sid,
    callId: question.callId,
    questions: question.questions,
    state: question.state,
  }))
}

// ---------------------------------------------------------------------------
// 应答路由（`interaction.respond`）
// ---------------------------------------------------------------------------

/**
 * 批次必须给每个问题**恰好一项** —— 与 DSH 的校验同形
 * （`packages/interaction/user-questions/src/index.ts:178-185`：缺项 / 多项 / 未知项
 * 都抛 `BAD_ANSWER`）。内核先自己判一遍，是为了在打扰 DSH 之前就把「手机侧的待处理
 * 视图已过期」这种情况变成一次列表刷新，而不是一条宿主错误。
 *
 * **刻意不校验「`selected` / `custom` 至少一个非空」**：DSH 明确把
 * 「`selected` 为空且无 `custom`」定义为**显式跳过**这一合法答案
 * （`packages/interaction/tool-ask-user/src/timed.ts:172-181` 的输出 schema 原文
 * "Empty with no custom means the user explicitly skipped this question"；
 * `packages/interaction/user-questions/tests/user-questions.spec.ts:880` 用
 * `{ answers: [{ id: 'scope', selected: [] }] }` 断言 `answer()` 返回 `true`）。
 * 在连接器里加这条检查等于自造一条 DSH 没有的规则，把合法跳过变成失败。
 *
 * @returns `null` 表示通过；否则是一句给人看的理由。
 */
export function validateAnswerBatch(
  questions: readonly Question[],
  answers: readonly AnswerItem[],
): string | null {
  const answered = new Set(answers.map((item) => item.id))
  if (answered.size !== answers.length) return '同一个问题在批次里出现了多次'
  if (questions.length !== answers.length) {
    return `批次有 ${answers.length} 项，而这个提问有 ${questions.length} 个问题`
  }
  const unanswered = questions.filter((question) => !answered.has(question.id))
  if (unanswered.length > 0) {
    return `有问题没被答到：${unanswered.map((question) => question.id).join(', ')}`
  }
  return null
}

/**
 * `interaction.respond` 的载荷（契约 §5.7）。`answers` 与 DSH 的答案批次逐字一致。
 *
 * 这是**校验通过后**的形状：运行期入参是封箱解出来的 JSON、不可信，所以
 * {@link InteractionFace.respond} 收 `unknown` 并逐个字段校验，这个接口只是给装配层
 * 与手机侧对照的契约。
 */
export interface RespondParams {
  readonly sid: string
  readonly callId: string
  readonly answers: readonly AnswerItem[]
}

export interface RespondOk {
  readonly itemId: string
}

export interface InteractionFaceDeps {
  /**
   * DSH `ctx.get('userQuestions').answer(agent, callId, batch)` 的注入替身
   * （`packages/interaction/user-questions/src/index.ts:164-206`，带 `@Remote`，
   * 内部 `agent.steer()` 把答案注入为用户消息）。返回 `false` 表示提问已结束。
   */
  answer(agent: QuestionAgent, callId: string, batch: AnswerBatch): boolean
  /** 会话别名 → live root agent。子代理 / 已被替换的会话返回 `undefined`。 */
  agentOf(sid: string): QuestionAgent | undefined
  /**
   * 提问投影来源（装配层接 DSH 的
   * `sessionProjections.stateOf(session, 'userQuestions').questions`）。
   * 返回 `undefined` 表示这个会话当前没有投影快照可读。
   */
  projectionOf(sid: string): QuestionProjection | undefined
  /**
   * **在途 claim 的收束面**（装配层接 `interaction-claims.ts` 的在途表）。
   *
   * 契约 §5.7 只有一个应答入口，而 §6.3.1 的两条路径在 DSH 侧共用答案批次这一种形状 ——
   * 所以分叉点不在方法名上，而在"这一项是不是一次在途的 claim"（在途审批，或
   * `open` 态被应答链堵着的提问）。那个判据只有挂载级的端口知道（它握着 claim 与看护），
   * 因此作为钩子注在这里。
   *
   * 在**形状校验之后**调用（那时 `sid` / `callId` / `answers` 都已确认合法），
   * 在投影比对与 `agentOf` 之前：审批项不在 `userQuestions` 投影里，
   * 走投影比对只会被跳过，而 `agentOf` 对子代理会话的拒绝对审批是错的
   * （审批的 live root 判据在 DSH 的应答链里，不在这里）。
   *
   * @returns `true` = 这一项已作为在途 claim 的答复收束，不要再走提问路由。
   */
  settleClaim?(sid: string, callId: string, answers: readonly AnswerItem[]): boolean
  log?: InteractionLogger
}

export interface InteractionFace {
  /** 待处理项（供连接器随 `ev` / `pending.changed` 下发）。 */
  pendingOf(sid: string): readonly PendingItem[]
  /**
   * `interaction.respond` 的校验与路由。**失败抛 `ProtocolError`**（分发器把它转成
   * `ok:false` 信封，结构化错误不关连接，契约 §9）；成功返回该项的 `itemId`。
   *
   * 两条目的地：**在途 claim**（{@link InteractionFaceDeps.settleClaim} 认下它）
   * 与 **`continued` 提问**（路由到 DSH 的 `userQuestions.answer`）。`open` 提问不走这里 ——
   * 它由实时投递（`dsh/interaction-client.ts` 从 `$events` 流收到的 `waterfall`）处理。
   *
   * @param params - 封箱后解出来的原始载荷，**不可信**，逐个字段校验。
   */
  respond(params: unknown): RespondOk
}

function isAnswerItem(value: unknown): value is AnswerItem {
  if (typeof value !== 'object' || value === null) return false
  const record = value as Record<string, unknown>
  if (typeof record['id'] !== 'string' || record['id'] === '') return false
  const selected = record['selected']
  if (!Array.isArray(selected) || !selected.every((label) => typeof label === 'string')) return false
  const custom = record['custom']
  return custom === undefined || typeof custom === 'string'
}

/** 取 DSH `UserQuestionError` 的 `code`（`user-questions/src/index.ts:46-51`）。 */
function codeOf(error: unknown): string | undefined {
  if (typeof error !== 'object' || error === null) return undefined
  const code = (error as { code?: unknown }).code
  return typeof code === 'string' ? code : undefined
}

/**
 * 提问 / 计划审查的内核：投影 + 应答路由。
 *
 * 提问**没有看护计时器**（契约 §6.2.1：它是 fire-and-forget 的投影，超时由 DSH 自己转
 * pending），所以这里只有校验与路由，没有定时器。
 */
export function createInteractionFace(deps: InteractionFaceDeps): InteractionFace {
  const { log } = deps

  return {
    pendingOf(sid) {
      const projection = deps.projectionOf(sid)
      // 没有投影快照 = 这个会话当前没有待处理提问；空列表，不是错误
      return projection === undefined ? [] : projectPendingQuestions(sid, projection)
    },

    respond(params) {
      // ---- 形状：请求本身不合法 → protocol/bad-frame ----
      // 契约 §5.7 对 `sid` 立过同一条规则（"缺失或形状不对 → protocol/bad-frame，
      // 它是请求本身不合法，不是数据不存在"），这里把它同理推到批次上。
      if (typeof params !== 'object' || params === null || Array.isArray(params)) {
        throw new ProtocolError('protocol/bad-frame', 'interaction.respond 的载荷必须是对象')
      }
      const record = params as Record<string, unknown>
      const sid = record['sid']
      const callId = record['callId']
      const answers = record['answers']
      if (typeof sid !== 'string' || sid === '') {
        throw new ProtocolError('protocol/bad-frame', 'interaction.respond 缺少 sid')
      }
      if (typeof callId !== 'string' || callId === '') {
        throw new ProtocolError('protocol/bad-frame', 'interaction.respond 缺少 callId')
      }
      if (!Array.isArray(answers)) {
        throw new ProtocolError('protocol/bad-frame', 'interaction.respond 的 answers 必须是数组')
      }
      const items: AnswerItem[] = []
      for (const raw of answers) {
        if (!isAnswerItem(raw)) {
          throw new ProtocolError('protocol/bad-frame', '答案项必须形如 { id, selected[], custom? }')
        }
        items.push(raw)
      }

      // ---- 在途 claim？先问端口 ----
      // 形状已合法，可以安全地把批次交给它。端口答"是"就此收束：
      // 审批的词汇表映射（哪个标签等于 `allowed-once`）与看护都在端口那一侧，
      // 内核不认识审批（`interaction-face.ts` 只承载提问语义）。
      if (deps.settleClaim?.(sid, callId, items) === true) {
        return { itemId: itemIdOf(callId) }
      }

      // ---- 批次 vs 提问：投影认得这个 call 时才先判一遍 ----
      // 投影不认得时**仍然调用 DSH**：投影可能是装配层的缓存，而 DSH 是自己的权威
      // （不变量 I1）。缺问题列表时跳过本地校验，让 DSH 的 BAD_ANSWER / false 说话。
      const pending = deps.projectionOf(sid)?.active.find((question) => question.callId === callId)
      if (pending !== undefined) {
        const reason = validateAnswerBatch(pending.questions, items)
        if (reason !== null) {
          // 手机侧的待处理视图与投影不一致 —— 刷新即可恢复，不是缺陷
          // （`interaction/not-pending` 的客户端行为正是「刷新待处理列表」）。
          // 留一句声：它反复出现就说明投影下发与手机渲染之间掉了链子。
          log?.warn('答案批次与提问对不上，待处理视图可能过期', { sid, callId, reason })
          throw new ProtocolError('interaction/not-pending', reason)
        }
      }

      // ---- 没有 live root agent：答不了 ----
      // 子代理里的提问（assertLiveRoot 的 DELEGATED_CALLER，契约 §15）与已被替换的
      // 会话都落在这一支；按 §3.1 的措辞同属「不属于本设备」。
      const agent = deps.agentOf(sid)
      if (agent === undefined) {
        log?.warn('提问答复找不到 live root agent', { sid, callId })
        throw new ProtocolError(
          'interaction/not-pending',
          `会话 ${sid} 当前没有可作答的 live root agent（子代理里的提问答不了）`,
        )
      }

      // ---- 路由到 DSH ----
      let accepted: boolean
      try {
        accepted = deps.answer(agent, callId, { answers: items })
      } catch (error) {
        // DSH 的错误码 → 我们的错误码。前三项都是「这一项已经不在了」：
        // REPLY_QUEUED（已排队再答，:172-174）是幂等键 I8 的兜底；
        // BAD_ANSWER 只在投影过期时到这里（本地校验已先拦了一次）；
        // CALLER_NOT_LIVE / DELEGATED_CALLER（:131-144）是 live root 判据。
        // 客户端行为一律是 refresh-pending：刷新待处理列表即恢复。
        const code = codeOf(error)
        if (code === 'REPLY_QUEUED') {
          throw new ProtocolError('interaction/not-pending', '这个提问已经有一个回复在排队')
        }
        if (code === 'BAD_ANSWER') {
          throw new ProtocolError('interaction/not-pending', '批次与提问对不上，待处理列表可能已过期')
        }
        if (code === 'CALLER_NOT_LIVE' || code === 'DELEGATED_CALLER') {
          throw new ProtocolError('interaction/not-pending', '这个提问不属于可作答的 live root agent')
        }
        // 其余（例如 steer 抛错，:199-204）原样上交：分发器归 internal → 退避重试。
        // 吞掉它会让手机以为答成功了，而答案从未进入会话。
        throw error
      }
      if (!accepted) {
        // DSH：提问已结束（不在 continued 集合）→ 返回 false，**不是错误**（:168）。
        // 手机据此把那一项标成"已过期"；客户端行为是刷新列表，不弹错误框。
        throw new ProtocolError('interaction/not-pending', `提问 ${callId} 已结束，答案不再被接纳`)
      }
      return { itemId: itemIdOf(callId) }
    },
  }
}

// ---------------------------------------------------------------------------
// 审批的 outcome 词汇表（DSH 的，不是我们的）
// ---------------------------------------------------------------------------

/** DSH `ApprovalOutcome` 词汇表（`user-approval/src/types.ts:32`），封闭；唯一授权值是 `allowed-once`（`src/index.ts:211`）。 */
export type ApprovalOutcome = 'allowed-once' | 'rejected' | 'cancelled' | 'unavailable'

