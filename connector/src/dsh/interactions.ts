/**
 * 交互适配：审批与提问的 claim-or-delegate（契约 §6）。
 *
 * **注册形态是事件监听（`ctx.on`），不是服务方法** —— 两个包都没有 answerer 注册函数
 * （`packages/interaction/user-approval/src/types.ts:87-92`、
 * `packages/interaction/user-questions/src/types.ts:157-161`）。
 *
 * 为什么不学参考实现走 `$events` Remote 流：那套是给**跨进程 / 浏览器**客户端用的
 * （Agents-Anywhere 的 UI 在另一个进程，才需要绕 `$events`，并为此写了 arity 兼容 shim）。
 * 本插件与 DSH **同进程**，直接接 waterfall 少两跳、少一层版本 shim。
 *
 * 本文件只做**判定与词汇表映射**，不持有连接：推给手机那一步通过注入的
 * `RemoteInteractionPort`（依赖注入在边界上，便于单测替换）。
 *
 * 取舍见 `.agents/notes/implemented/2026-10-01-connector-interaction-adapter.md`
 */
import type { Context } from '@deepseek-ai/cordis'
import type { ApprovalOutcome } from '@deepseek-ai/dsh-user-approval'
import type { AskUserQuestionAnswer, AskUserQuestionItem } from '@deepseek-ai/dsh-user-questions'
import { decideTakeover, type TakeoverDevice, type TakeoverMode } from '../protocol/takeover.js'
import { resolveQuestionCall } from './question-call.js'

/**
 * 手机能表达的决定。
 *
 * DSH 的 outcome 词汇表是**封闭**的（`'allowed-once' | 'rejected' | 'cancelled' | 'unavailable'`，
 * `packages/interaction/user-approval/src/types.ts:32`），且**唯一授权值是 `allowed-once`**
 * （`packages/interaction/user-approval/src/index.ts:211`）。映射收敛在本层：返回词汇表以外的
 * 值会被 DSH **静默归一成 `'unavailable'`**（`index.ts:288`，无异常、无日志）。
 */
export type RemoteApprovalDecision = 'allow-once' | 'reject'

export interface ApprovalPrompt {
  /** 通道别名（中转只看得到它）。 */
  sid: string
  callId: string
  toolName: string
  reason?: string
  displayReason?: Readonly<Record<string, string>>
}

export interface QuestionPrompt {
  sid: string
  /**
   * claim 的唯一键：手机发回的答复也以它为键。
   *
   * 应答者总会给一个字符串（legacy 从会话日志推，见 `question-call.ts`）；类型仍留
   * `undefined`，因为端口的 fail-closed 判据长在它上面（`interaction-claims.ts`，
   * 兜底，不是主路径）。
   */
  callId: string | undefined
  questions: readonly AskUserQuestionItem[]
  /**
   * 计划审查的判别标记（`intent.kind === 'plan-review'`）。
   *
   * **不进手机**：`intent` 只活在应答链的请求对象上，投影不映射它
   * （`user-questions/src/projection.ts:148-161`）。本层只用它识别"这次提问是程序化的、
   * 没有 `tool/call`"—— `/exit_plan_mode` 的 `ask()` 就是这种（`plan-mode/src/index.ts:313-330`）。
   */
  planReview?: { approve: string }
}

/** 连接层必须提供的能力。 */
export interface RemoteInteractionPort {
  /**
   * 把审批请求推给手机并等它的决定。
   * 实现方负责看护超时与断开，并以 fail-closed 收束（绝不静默放行）。
   *
   * @param deviceId - §6.2 仲裁选出的那台设备（推送目标）。**调用方已经判定过 claim**，
   *   所以它必然非空；传进来而不是让端口再判一次，是为了"哪台手机接管"只有一个真值。
   */
  askApproval(prompt: ApprovalPrompt, deviceId: string, signal?: AbortSignal): Promise<RemoteApprovalDecision>
  /**
   * 把提问推给手机并等它的回答。
   *
   * **拿不到答案时必须抛错**，绝不返回空答案：`{ answers: [] }` 会被 DSH 当成
   * 「用户跳过了每一题」，而链尾本应是 reject
   * （`packages/interaction/user-questions/src/index.ts:318-321`）。
   *
   * @param deviceId - 同 {@link askApproval}：仲裁选出的推送目标。
   */
  askQuestion(prompt: QuestionPrompt, deviceId: string, signal?: AbortSignal): Promise<AskUserQuestionAnswer>
}

export interface TakeoverDeps {
  /** 当前接管档位（存手机本地并同步到桥接，契约 §6.2）。 */
  mode(): TakeoverMode
  /** 已认证设备的状态快照；前台态与订阅关系由设备上报。 */
  devices(): readonly TakeoverDevice[]
  /** DSH 会话 id → 通道别名。未登记给手机的会话返回 undefined。 */
  sidOf(dshSessionId: string): string | undefined
}

export interface InteractionLogger {
  warn(message: string, detail?: unknown): void
}

export interface InteractionDeps {
  port: RemoteInteractionPort
  takeover: TakeoverDeps
  log?: InteractionLogger
}

/**
 * 计划审查走的是**提问**通道、不是审批，靠 `intent.kind` 判别
 * （`packages/plan/plan-mode/src/index.ts:320`）。
 */
function planReviewOf(
  questions: readonly AskUserQuestionItem[],
): { approve: string } | undefined {
  for (const question of questions) {
    const intent = question.intent
    if (intent?.kind === 'plan-review' && typeof intent.approve === 'string') {
      return { approve: intent.approve }
    }
  }
  return undefined
}

/**
 * 注册两个 answerer，返回 disposer。
 *
 * 判定顺序对两者一致：**先确认这个会话登记给了手机，再走接管判定**；任一不满足就
 * `return next()` 交还桌面 —— 绝不 claim 之后又答不出来。
 *
 * Note: 端口**呈示不了**时（手机断开 / 看护收束）走的是抛，由下面的 catch 归一成
 * `'unavailable'`，**不是** `'rejected'` —— 后者只代表用户真的点了拒绝。
 * 取舍见 `.agents/notes/implemented/2026-10-13-approval-must-not-fake-rejection.md`。
 *
 * ## 为什么必须 `{ prepend: true }`
 *
 * Cordis 的 waterfall 按**注册顺序**从队首依次问，`next()` 就是 `shift()`
 * （`vendor/cordis/src/events.ts:143`、`:255`：`prepend ? 'unshift' : 'push'`）。
 * DSH 里有一个**先注册且自己不答就不放行**的桌面应答者：
 * `packages/api/remotes/src/index.ts:57-75` 把 `approval/request` /
 * `user-questions/request` 转发给浏览器 GUI（`forwardWaterfall`），
 * 而它**每条 Client 流注册一次**（`api/remotes/README.md:47`）——
 * 浏览器一挂上来就有一条监听器排在当时的队尾。
 *
 * 本插件的应答者是**异步**注册的（`index.ts` 的 `register-answerers` 排在
 * `open-store` 之后），所以只要浏览器比插件先连上，那条转发监听器就排在**我们前面**：
 * 审批被挂在没人点的浏览器对话框上，我们永远问不到，会话停在 `approval/asked`，
 * 手机点「允许一次」也无处可落。2026-10-13 真机实测正是这个形态。
 *
 * `prepend: true` 是 DSH 自己承认的逃生口（`user-approval/src/index.ts:270-274`
 * 专门讨论它，并把 `never` 的判定收进服务自己的 request 路径）。
 * 我们不破坏那条承诺：`never` 仍由 DSH 在 dispatch 之前决定，我们这边也只做
 * "不接管就 `next()`"。
 *
 * Note: `.agents/notes/implemented/2026-10-13-answerer-must-be-prepended.md`。
 */
export function registerInteractions(ctx: Context, deps: InteractionDeps): () => void {
  const { port, takeover, log } = deps

  const claimFor = (sid: string) =>
    decideTakeover({ mode: takeover.mode(), sid, devices: takeover.devices() })

  const offApproval = ctx.on(
    'approval/request',
    async (request, next): Promise<ApprovalOutcome> => {
      // 会话 id 只能从 agent 上取：请求对象里**没有** sessionId 字段
      // （`packages/interaction/user-approval/src/types.ts:63-76`；`Agent.id` 即 `SessionId`）。
      const sid = takeover.sidOf(request.agent.id)
      if (sid === undefined) return next()
      if (request.callId === undefined) return next()
      const claim = claimFor(sid)
      if (!claim.claim || claim.deviceId === null) return next()

      try {
        const decision = await port.askApproval(
          {
            sid,
            callId: request.callId,
            toolName: request.toolName,
            ...(request.reason === undefined ? {} : { reason: request.reason }),
            ...(request.displayReason === undefined
              ? {}
              : { displayReason: request.displayReason as Readonly<Record<string, string>> }),
          },
          claim.deviceId,
          // 传的是 asker 的**原** signal，绝不替换：取消语义整个挂在它上面
          // （`packages/interaction/user-approval/src/index.ts:293-306`）。
          request.signal,
        )
        return decision === 'allow-once' ? 'allowed-once' : 'rejected'
      } catch (error) {
        // DSH 会把 answerer 抛出的异常**静默**归一成 `'unavailable'`
        // （`packages/interaction/user-approval/src/index.ts:291`）。
        // 这里先接住并记一笔：既保住 fail-closed，又不让失败无声无息。
        log?.warn('审批转手机失败，按 fail-closed 收束为 unavailable', error)
        return 'unavailable'
      }
    },
    // 见上面的「为什么必须 `{ prepend: true }`。
    { prepend: true },
  )

  const offQuestions = ctx.on(
    'user-questions/request',
    async (request, next): Promise<AskUserQuestionAnswer> => {
      // 无 agent 的请求走 unscoped dispatch，不归本桥接管
      // （`packages/interaction/user-questions/src/index.ts:322-324`）。
      if (request.agent === undefined) return next()
      const sid = takeover.sidOf(request.agent.id)
      if (sid === undefined) return next()
      const claim = claimFor(sid)
      if (!claim.claim || claim.deviceId === null) return next()

      const planReview = planReviewOf(request.questions)

      // **身份**：timed 形态自带 `wait.callId`；legacy 形态**没有** —— legacy 工具调
      // `ask()` 时根本不传 `wait`（`packages/interaction/tool-ask-user/src/index.ts:98-109`），
      // 于是只能从会话日志里认：唯一一条没有 `tool/result` 的 `ask_user_question` `tool/call`。
      // 判据、并发语义与失败方向见 `question-call.ts` 的文件头。
      //
      // 认不出就交还桌面（`next()`）：**不抛**（抛等于让这次提问变成工具失败），
      // 也**不猜**一个 id（猜错会把答案写进另一次调用）。`next()` 只是兜底，不是修复 ——
      // 手机上的卡会因 `settleClaim` 认不下而回 `interaction/not-pending`，所以主路径
      // 必须是"推出唯一 id"。程序化提问（如 `/exit_plan_mode` 的 `ask()`，不产生
      // `tool/call`）也落这一支：它在手机上本来就没有卡。
      // Note: 为什么从日志推、为什么认不出要 next() —— 见
      // `.agents/notes/implemented/2026-10-23-legacy-question-identity-from-session-log.md`。
      const identity = request.wait?.callId === undefined
        ? resolveQuestionCall(request.agent.session.snapshotEvents())
        : ({ kind: 'found', callId: request.wait.callId } as const)
      if (identity.kind !== 'found') {
        // 计划审查是**程序化**提问（`/exit_plan_mode` 的 `ask()`）：它本来就没有
        // `tool/call`，所以"认不出"是正常形态，不该留 warn。其余情况是异常，要留声。
        if (planReview === undefined) {
          log?.warn('提问认不出唯一的 tool call 身份，交还桌面', {
            sid,
            reason: identity.kind,
            ...(identity.kind === 'ambiguous' ? { callIds: identity.callIds } : {}),
          })
        }
        return next()
      }

      const prompt: QuestionPrompt = {
        sid,
        callId: identity.callId,
        questions: request.questions,
        ...(planReview === undefined ? {} : { planReview }),
      }

      try {
        return await port.askQuestion(prompt, claim.deviceId, request.signal)
      } catch (error) {
        // 提问侧没有 `'unavailable'` 这种返回值，只能抛；**绝不**返回空答案伪装成
        // 「用户全跳过」—— 那会被 batch 校验与定时工具误判。
        log?.warn('提问转手机失败，按 fail-closed 抛出（不用空答案伪装）', error)
        throw error
      }
    },
    // 与审批同一条理由：桌面转发监听器可能先注册，见上面的说明。
    { prepend: true },
  )

  return () => {
    offApproval()
    offQuestions()
  }
}
