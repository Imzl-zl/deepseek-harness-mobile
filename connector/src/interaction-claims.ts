/**
 * 在途 claim 表（**挂载级**）：`InteractionPort` 的实现 —— "手机答的那一下，落到哪一次交互上"。
 *
 * 名字取 `claims` 而不是 `port`：这一层的**状态**是在途 claim 表，`InteractionPort`
 * 只是它对外的那张脸。叫 `port` 会与 `ConnectionPort`（每连接的那条窄缝）混为一谈。
 *
 * ## 它只做一件事：把答复配给在途的那一次交互
 *
 * 待处理项怎么到手机、卡片怎么画、什么时候关 —— **都不在这里**：审批的 ask 是
 * `approval/asked` 会话事件、提问的 ask 是 `ask_user_question` 的 `tool/call`
 * （`packages/interaction/user-approval/src/index.ts:225`、`tool-ask-user/src/index.ts:98-109`），
 * 它们经 `session-subscriptions.ts` 的正常出帧路径到手机，服务端**不另推一份集合**
 * （契约 §6.3）。
 *
 * ## 结局只有两种，与 DSH 原生一一对应
 *
 * | 结算 | 什么时候 | 调用方（`dsh/interaction-client.ts`）回什么 |
 * |---|---|---|
 * | `answered` | 手机在这个会话上答了 | `{kind:'result', value}` |
 * | `withdrawn` | gateway 说这条 pending event 已经结算（**别人先答 / asker 取消**），或本插件卸载 | **什么都不回** |
 *
 * **没有第三种**：没有看护计时器、没有"未处理"记录、没有 fail-closed 的 outcome ——
 * 那些是上一版（连接器还是 host answerer 时）的自创边界，DSH 原生里都没有：
 *
 * - 浏览器的审批卡**没有超时**，一直挂到有人答或 `signal` 中止
 *   （`packages/client/ui-approval/src/client/index.ts:59-69` 的 `pending.result`）；
 * - 一个 client "不参与"就是 `next()`（委托），**不是**自己发明一种沉默：
 *   `packages/api/gateway/tests/gateway-stream.host.spec.ts:1402` 的用例名就是
 *   "delegates to the Host only after every active Client returns next" —— 一个 client
 *   `next` 之后事件**不结算**，另一个 client 的卡照旧能答；
 * - 全都没答时由 **DSH** 收成 `'unavailable'`
 *   （`packages/interaction/user-approval/src/index.ts:281-283` 的 waterfall 兜底）。
 *
 * Note: 为什么删掉看护计时器与"不参与就沉默" ——
 * `.agents/notes/implemented/2026-10-23-interaction-as-gateway-client.md`。
 */
import type { AskUserQuestionAnswer } from '@deepseek-ai/dsh-user-questions'

import type { Redelivery } from './dsh/ask-event.js'
import type { ApprovalOutcome, AnswerItem } from './interaction-face.js'

/**
 * 审批答复里代表"允许一次"的那个标签。
 *
 * **取值是 DSH 自己的 outcome 词汇表**（`packages/interaction/user-approval/src/types.ts:32`），
 * 不是我们发明的枚举：DSH 的 outcome 集合是封闭的，唯一授权值是 `allowed-once`。
 * 手机端把它渲染成"允许一次"，其余任何标签一律读成拒绝 —— 与 DSH 把词汇表外的返回值
 * 静默归一成 `unavailable`（`src/index.ts:288`）同一个方向：**认不出的就是不允许**。
 *
 * 这个常量是**跨端契约**：`app/lib` 的审批卡发回来的 `selected` 必须含它。
 * 两侧各写一份字符串必然漂移，所以两边各有一条断言钉住同一取值。
 */
export const APPROVAL_ALLOW_LABEL = 'allowed-once'

/**
 * 一次 claim 的请求：**只有端口真正用得上的两样东西**，加一个重投载荷。
 *
 * 为什么不是"把 DSH 的请求对象搬过来"：手机上的卡片内容（工具名 / 理由 / 问题列表 /
 * 选项 / 计划审查的判别标记）**全部来自会话事件**（`approval/asked`、
 * `ask_user_question` 的 `tool/call`），不走这条内存里的路。把同一批字段再拷一份到
 * 这里，就是让同一个事实有两个来源 —— 同步它们的唯一办法是永远只用一处。
 */
export interface ClaimRequest {
  /** 通道别名（中转只看得到它）。 */
  sid: string
  /**
   * claim 的唯一键：**手机那张卡的 `itemId`**（`interaction.respond` 的 `itemId` 也是它）。
   *
   * 取值是 DSH 自己的两个原生身份之一，按交互种类不同：
   *
   * - 审批：`i:<approval/asked.id>`（服务铸的 `ApprovalRequestId`，`user-approval/src/types.ts:13-17`；
   *   手机侧早就在用它当卡 id，`app/lib/data/projection.dart:997,1003`）。**不看 `callId`** ——
   *   那是可选的（`types.ts:68-69`），拿它当键会把"没有 tool call 的审批"整类挡在门外。
   * - 提问：`t:<callId>`（timed 形态的 `wait.callId`；legacy 形态从会话日志里推出**唯一**一条
   *   未结算的 `ask_user_question` `tool/call`，判据见 `dsh/question-call.ts`）。
   *
   * **认不出来就不 claim**（调用方委托）：所以这里必有值。
   */
  itemId: string
  /** 重连重投用：这条 ask 的会话事件（原 seq + body，见 `dsh/ask-event.ts`）。 */
  redeliver?: Redelivery
}

/**
 * 一次 claim 的结算单。
 *
 * `withdrawn` 不是失败，是"不用我们答了"：调用方据此**沉默**。它只由外部触发 ——
 * gateway 的 `cancel`（别人先答 / asker 取消）或本插件卸载。
 */
export type ClaimSettlement<T> =
  | { readonly kind: 'answered'; readonly value: T }
  | { readonly kind: 'withdrawn' }

/** 内部持有形状：答案类型在 `ask` 的泛型处擦掉，`settleClaim` 按 claim 的种类填回。 */
type RawSettlement = { readonly kind: 'answered'; readonly value: unknown } | { readonly kind: 'withdrawn' }

/** 一条在途的 claim。终点只有两个：手机答了，或 gateway 那边结算了。 */
interface Claim {
  readonly kind: 'approval' | 'question'
  readonly sid: string
  readonly redeliver?: Redelivery
  readonly resolve: (settlement: RawSettlement) => void
}

export interface InteractionPort {
  /** 记下这次审批并等手机的答复（**没有超时**：原生就是这样）。 */
  askApproval(request: ClaimRequest): Promise<ClaimSettlement<ApprovalOutcome>>
  /** 记下这次提问并等手机的答复。 */
  askQuestion(request: ClaimRequest): Promise<ClaimSettlement<AskUserQuestionAnswer>>
  /**
   * `interaction.respond` 的落点：这一项是不是一次在途 claim 的答复。
   *
   * @returns `true` = 已收束；`false` = 没有这个 callId 的在途 claim，
   *   调用方继续走提问路由（`continued` 提问正是这条路）。
   */
  settleClaim(sid: string, itemId: string, answers: readonly AnswerItem[]): boolean
  /**
   * gateway 说这条 pending event 已经结算（别人先答 / asker 取消）。
   *
   * 撤掉这条 claim 并**不回应**：结算已经发生。手机上的卡由会话事件
   * （`approval/decided` / `tool/result`）关掉。
   *
   * @returns `true` = 撤掉了一条在途 claim；`false` = 没有（已经结过 / 不是我们的）。
   */
  cancelClaim(itemId: string): boolean
  /**
   * 该会话上仍在途的 ask 事件（重连重投用，见 `dsh/ask-event.ts` 的 `Redelivery`）。
   *
   * 只包含**还等着回答**的 claim：已结算的已经从表里删掉。订阅恢复之后由
   * `session-subscriptions.ts` 按原 seq 再发一遍 —— 与 DSH gateway 的
   * `deliverRemoteEvent(pending, client)` 同形。
   */
  pendingAsks(sid: string): readonly Redelivery[]
  /** 在途 claim 数（指标与测试用）。 */
  readonly pending: number
}

export function createInteractionPort(): InteractionPort {
  /** `itemId → 在途 claim`。一个 itemId 同时只可能有一个 claim（DSH 的应答链保证）。 */
  const claims = new Map<string, Claim>()

  const ask = <T>(kind: Claim['kind'], request: ClaimRequest): Promise<ClaimSettlement<T>> =>
    new Promise((resolve) => {
      claims.set(request.itemId, {
        kind,
        sid: request.sid,
        ...(request.redeliver === undefined ? {} : { redeliver: request.redeliver }),
        resolve: resolve as (settlement: RawSettlement) => void,
      })
    })

  return {
    get pending() {
      return claims.size
    },

    askApproval(request) {
      return ask<ApprovalOutcome>('approval', request)
    },

    askQuestion(request) {
      return ask<AskUserQuestionAnswer>('question', request)
    },

    pendingAsks(sid) {
      const out: Redelivery[] = []
      for (const claim of claims.values()) {
        if (claim.sid !== sid || claim.redeliver === undefined) continue
        out.push(claim.redeliver)
      }
      return out
    },

    cancelClaim(itemId) {
      const claim = claims.get(itemId)
      if (claim === undefined) return false
      // 先摘表再收束（与 `settleClaim` 同一个顺序）：否则"撤掉"与"手机又点了一下"
      // 之间有一拍，那一拍里 `settleClaim` 会认下一条已经不属于任何人的答复。
      claims.delete(itemId)
      claim.resolve({ kind: 'withdrawn' })
      return true
    },

    settleClaim(sid, itemId, answers) {
      const claim = claims.get(itemId)
      if (claim === undefined) return false
      // **会话被替换**：这个 itemId 的在途 claim 属于另一个 `sid` 了。放行它会把
      // 答复写进一个已经不持有这个提问的会话 —— 与 DSH"迟到即丢弃"同构，丢弃。
      if (claim.sid !== sid) return false
      claims.delete(itemId)
      if (claim.kind === 'approval') {
        // **词汇表映射只在这里**：认不出的标签就是拒绝 —— 与 DSH 把词汇表外返回值归一成
        // `unavailable` 同向（`user-approval/src/index.ts:288`）。
        // 回给 gateway 的就是 DSH 的词（`allowed-once` / `rejected`），不是我们自己的枚举。
        const outcome: ApprovalOutcome = answers.some((answer) =>
          answer.selected.includes(APPROVAL_ALLOW_LABEL),
        )
          ? 'allowed-once'
          : 'rejected'
        claim.resolve({ kind: 'answered', value: outcome })
        return true
      }
      // 提问：**答案批次原样转发**，一个字段都不翻译（契约 §6.3.1：翻译层就是漂移层）。
      claim.resolve({
        kind: 'answered',
        value: {
          answers: answers.map((item) => ({
            id: item.id,
            selected: [...item.selected],
            ...(item.custom === undefined ? {} : { custom: item.custom }),
          })),
        },
      })
      return true
    },
  }
}
