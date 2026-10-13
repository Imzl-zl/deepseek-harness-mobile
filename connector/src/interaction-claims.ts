/**
 * 在途 claim 的看护与收束（**挂载级**）：`RemoteInteractionPort` 的实现，也就是
 * "把 prompt 送到哪条连接、并看护到人类回答或 fail-closed"的那一层（契约 §6.2）。
 *
 * 名字取 `claims` 而不是 `port`：这一层的**状态**是在途 claim 表，`RemoteInteractionPort`
 * 只是它对外的那张脸。叫 `port` 会与 `ConnectionPort`（每连接的那条窄缝）混为一谈。
 *
 * ## 它为什么在挂载级
 *
 * 两个 answerer（`dsh/interactions.ts`）是**每请求**的：一次 `approval/request` 调一次。
 * 而"哪台手机在线、哪条连接活着、哪个 claim 还在等回答"全是**跨请求**的状态 ——
 * 放进 answerer 会让它在两次调用之间莫名其妙地共享东西。所以端口在挂载时建一次，
 * answerer 只把仲裁结果（`deviceId`）递进来。
 *
 * ## 待处理项怎么到手机：**不推，让它乘会话事件流**
 *
 * 契约 §6.3 的原话是"待处理集合是**会话事件的投影**,随 `ev` 帧一起到手机"，而这不是比喻：
 *
 * - 审批的 ask 在 DSH 侧就是一条 `approval/asked` **会话事件**
 *   （`packages/interaction/user-approval/src/index.ts:225`，`request()` 在 dispatch 之前 append）；
 * - 提问的 ask 是 `ask_user_question` 的 `tool/call` 事件（§5.2 的推导表）。
 *
 * 两者都经 `session-subscriptions.ts` 的正常出帧路径到手机。于是本层**不需要新的帧类型**，
 * 也不自己拼一份待处理集合 —— 那份集合的权威在 DSH 的会话日志里（§6.3 第一条）。
 * 本层真正负责的三件事因此是：
 *
 * 1. **选中那条连接**：仲裁给出的 `deviceId` → presence 里那条活着的记录；
 * 2. **看护它**：看护计时器 + 断开 + 取消，全部 fail-closed；
 * 3. **把答复交回在途的 claim**：`settleClaim` 由 `interaction.respond` 调进来。
 *
 * ## 一个如实的缺口
 *
 * `always` 档只要求"在线"，不要求"已订阅该会话"。于是一台没打开这个会话的手机
 * 收不到 `approval/asked` 事件，也就看不到卡片 —— 看护会走到超时并 fail-closed。
 * 这是契约 §6.2 的既有定义（`always` = 只要在线就接管），修它要么加一种推送帧
 * （契约变更），要么让连接器替手机订阅（订阅的 owner 是手机，那是错的）。
 * **这里不偷偷补**：超时后会留一条未处理记录并推通知，用户知道发生了什么。 *
 * ## fail-closed 的两侧形状
 *
 * | 结局 | 审批 | 提问 |
 * |---|---|---|
 * | 看护超时 / 断开 / 取消 / 没有活连接 | `reject` | **抛错** |
 * | 会话被替换（别名指向了别的会话） | `reject` | **抛错** |
 *
 * 提问侧**绝不返回空答案**：`{answers: []}` 会被 DSH 当成"用户跳过了每一题"
 * （`packages/interaction/user-questions/src/index.ts:318-321`），而链尾本应是 reject。
 *
 * Note: 为什么待处理项不在这里推送、为什么 `always` 档有一个如实缺口 ——
 * 见 `.agents/notes/implemented/2026-10-10-interaction-to-phone-chain.md`。
 */
import type { AskUserQuestionAnswer } from '@deepseek-ai/dsh-user-questions'

import type { Schedule } from './interaction-face.js'
import {
  createWatchdog,
  type ApprovalDecision,
  type AnswerItem,
  type WatchdogRecord,
} from './interaction-face.js'
import type {
  ApprovalPrompt,
  QuestionPrompt,
  RemoteApprovalDecision,
} from './dsh/interactions.js'
import type { DevicePresence } from './presence.js'
import { clientActionOf, type ClientAction } from './protocol/errors.js'

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

/** 未处理记录（看护没能等到人类的回答，契约 §6.2 的"推一条通知"）。 */
export interface UnhandledInteraction {
  readonly kind: 'approval' | 'question'
  readonly sid: string
  readonly callId: string
  readonly deviceId: string
  readonly end: WatchdogRecord['end']
  readonly at: number
  readonly code: 'interaction/not-pending'
  readonly clientAction: ClientAction
}

export interface InteractionPortDeps {
  /** 设备瞬时状态（在线判定 + 断开通知）。 */
  presence: DevicePresence
  /** 未处理留证 + 通知。**必填**：少了它，fail-closed 就变成无声的。 */
  onUnhandled(record: UnhandledInteraction): void
  /** 看护上限（契约 §10 参数表，默认 10 min）。 */
  guardMs?: number
  now?: () => number
  schedule?: Schedule
  log?: { warn(message: string, detail?: unknown): void }
}

/** 一条在途的 claim。两种终点：审批给标量决定，提问给答案批次。 */
type Claim =
  | { kind: 'approval'; sid: string; deviceId: string; settle: (decision: ApprovalDecision) => void }
  | { kind: 'question'; sid: string; deviceId: string; settle: (answer: AskUserQuestionAnswer) => void }

export interface InteractionPort {
  askApproval(
    prompt: ApprovalPrompt,
    deviceId: string,
    signal?: AbortSignal,
  ): Promise<RemoteApprovalDecision>
  askQuestion(
    prompt: QuestionPrompt,
    deviceId: string,
    signal?: AbortSignal,
  ): Promise<AskUserQuestionAnswer>
  /**
   * `interaction.respond` 的落点：这一项是不是一次在途 claim 的答复。
   *
   * @returns `true` = 已收束；`false` = 没有这个 callId 的在途 claim，
   *   调用方继续走提问路由（`continued` 提问正是这条路）。
   */
  settleClaim(sid: string, callId: string, answers: readonly AnswerItem[]): boolean
  /** 在途 claim 数（指标与测试用）。 */
  readonly pending: number
}

export function createInteractionPort(deps: InteractionPortDeps): InteractionPort {
  const { presence, onUnhandled, log } = deps
  /** `callId → 在途 claim`。一个 callId 同时只可能有一个 claim（DSH 的应答链保证）。 */
  const claims = new Map<string, Claim>()

  const watchdogOf = () =>
    createWatchdog({
      ...(deps.guardMs === undefined ? {} : { guardMs: deps.guardMs }),
      ...(deps.now === undefined ? {} : { now: deps.now }),
      ...(deps.schedule === undefined ? {} : { schedule: deps.schedule }),
    })

  /** 看护没能等到回答：留证 + 通知。调用方按各自的 fail-closed 形状收束。 */
  const reportUnhandled = (
    kind: 'approval' | 'question',
    sid: string,
    callId: string,
    deviceId: string,
    end: WatchdogRecord['end'],
  ): void => {
    const record: UnhandledInteraction = {
      kind,
      sid,
      callId,
      deviceId,
      end,
      at: deps.now?.() ?? Date.now(),
      code: 'interaction/not-pending',
      clientAction: clientActionOf('interaction/not-pending'),
    }
    onUnhandled(record)
    log?.warn(`交互看护以 ${end} 收束（${kind}），fail-closed`, record)
  }

  /** 设备不在线：立刻收束并留证（等下去只是让工具调用白挂满一个看护周期）。 */
  const offlineOf = (deviceId: string): boolean => {
    const live = presence.liveOf(deviceId)
    return live === undefined || !live.online
  }

  return {
    get pending() {
      return claims.size
    },

    /**
     * 把一次审批送到手机上，看护到人类回答或 fail-closed。
     *
     * ## 为什么"呈示不了"是抛，而不是 `return 'reject'`
     *
     * 参照 DSH 自己的浏览器客户端（`packages/client/ui-approval/src/client/index.ts`
     * 的 `answerApproval`，以及 `contract/slots.ts` 的 `PendingApproval`）：
     * 它只有三个出口 —— **用户答了**（`answer`）、**我呈示不了**（`delegate → next()`）、
     * **我的寿命结束了**（`abort → 抛`）。`'rejected'` 在原生语义里**只代表用户点了拒绝**。
     *
     * 我们曾经在"手机不在线 / 看护被断开"时 `return 'reject'`，后果有两层，都坏：
     *
     * 1. **替用户做一个他没做过的决定**。模型收到的话是
     *    *"the user rejected … so stop and explain instead of working around it"* ——
     *    而用户什么都没点。`'unavailable'` 才会说"没人能答"。
     * 2. **挡住桌面**。本应答者是 `prepend` 的（见
     *    `.agents/notes/implemented/2026-10-13-answerer-must-be-prepended.md`），
     *    我们一 `reject`，排在后面的桌面应答者就永远问不到。
     *
     * 真机实测正是这个形状：`approval/decided` 在 **322ms** 后回来 `rejected` ——
     * 远快于人手点按、也远快于看护的 10 分钟，只可能是进端口时设备已被判定离线。
     *
     * 改成抛之后，`interactions.ts` 的 catch 会把它归一成 `'unavailable'`
     * （与提问侧 `askQuestion` 完全一致 —— 那边本来就是对得）。
     */
    async askApproval(prompt, deviceId, signal) {
      if (offlineOf(deviceId)) {
        log?.warn('审批要推给的设备不在线，fail-closed 抛出（不替用户决定）', {
          sid: prompt.sid,
          deviceId,
        })
        reportUnhandled('approval', prompt.sid, prompt.callId, deviceId, 'disconnected')
        throw new Error(`审批目标设备不在线：${deviceId}`)
      }

      const watchdog = watchdogOf()
      const claim: Claim = {
        kind: 'approval',
        sid: prompt.sid,
        deviceId,
        settle: (): void => {},
      }
      claims.set(prompt.callId, claim)

      // **断开就收束**：看护的语义是"手机不看了就立刻还桌面"，而不是等满 10 分钟。
      const cancelOffline = presence.onOffline(deviceId, () => watchdog.disconnect())
      // asker 的**原** signal 继续管取消语义（绝不替换，`user-approval/src/index.ts:293-306`）。
      const onAbort = (): void => watchdog.disconnect()
      if (signal !== undefined) signal.addEventListener('abort', onAbort, { once: true })

      try {
        const settlement = await watchdog.awaitAnswer(
          () =>
            new Promise<ApprovalDecision>((resolve) => {
              claim.settle = resolve
            }),
        )
        if (settlement.record.end !== 'answered' || settlement.value === undefined) {
          reportUnhandled('approval', prompt.sid, prompt.callId, deviceId, settlement.record.end)
          // **抛，不 `reject`**：理由见 `askApproval` 的文件头。
          // `'rejected'` 只能来自用户真的点了拒绝（`settleClaim` 里那个分支）。
          throw new Error(`审批看护以 ${settlement.record.end} 收束，未得到人的决定`)
        }
        return settlement.value === 'allow-once' ? 'allow-once' : 'reject'
      } finally {
        cancelOffline()
        if (signal !== undefined) signal.removeEventListener('abort', onAbort)
        claims.delete(prompt.callId)
      }
    },

    async askQuestion(prompt, deviceId, signal) {
      // 没有 `callId` 就没有稳定身份：答复回来时无从知道它属于哪一次 ask。
      // 与审批侧同一条规则（`interactions.ts` 的 `request.callId === undefined → next()`）。
      if (prompt.callId === undefined) {
        log?.warn('提问没有 callId（未计时的前台等待），无法从手机收答复，fail-closed 抛出', {
          sid: prompt.sid,
        })
        throw new Error('提问缺少 callId：无法为手机答复建立稳定身份')
      }
      if (offlineOf(deviceId)) {
        log?.warn('提问要推给的设备不在线，立刻 fail-closed 抛出', { sid: prompt.sid, deviceId })
        reportUnhandled('question', prompt.sid, prompt.callId, deviceId, 'disconnected')
        // **抛，不返回空答案**：空答案会被 DSH 读成"用户跳过了每一题"。
        throw new Error('提问要推给的设备不在线：不能返回空答案伪装成「用户全跳过」')
      }

      const watchdog = watchdogOf()
      const claim: Claim = {
        kind: 'question',
        sid: prompt.sid,
        deviceId,
        settle: (): void => {},
      }
      claims.set(prompt.callId, claim)

      const cancelOffline = presence.onOffline(deviceId, () => watchdog.disconnect())
      const onAbort = (): void => watchdog.disconnect()
      if (signal !== undefined) signal.addEventListener('abort', onAbort, { once: true })

      try {
        const settlement = await watchdog.awaitAnswer(
          () =>
            new Promise<AskUserQuestionAnswer>((resolve) => {
              claim.settle = resolve
            }),
        )
        if (settlement.record.end !== 'answered' || settlement.value === undefined) {
          reportUnhandled('question', prompt.sid, prompt.callId, deviceId, settlement.record.end)
          throw new Error(
            `提问看护以 ${settlement.record.end} 收束：不能返回空答案伪装成「用户全跳过」`,
          )
        }
        return settlement.value
      } finally {
        cancelOffline()
        if (signal !== undefined) signal.removeEventListener('abort', onAbort)
        claims.delete(prompt.callId)
      }
    },

    settleClaim(sid, callId, answers) {
      const claim = claims.get(callId)
      if (claim === undefined) return false
      // **会话被替换**：这个 callId 的在途 claim 属于另一个 `sid` 了。放行它会把
      // 答复写进一个已经不持有这个提问的会话 —— 与 DSH"迟到即丢弃"同构，丢弃。
      // 看护随后自己走到超时并留证，不会无声无息。
      if (claim.sid !== sid) {
        log?.warn('答复的 sid 与在途 claim 不一致，按会话被替换丢弃', {
          sid,
          callId,
          claimSid: claim.sid,
        })
        return false
      }
      claims.delete(callId)
      if (claim.kind === 'approval') {
        // 认不出的标签就是不允许（与 DSH 把词汇表外返回值归一成 unavailable 同向）。
        const picked = answers.some((answer) => answer.selected.includes(APPROVAL_ALLOW_LABEL))
        claim.settle(picked ? 'allow-once' : 'reject')
        return true
      }
      // 提问：**答案批次原样转发**，一个字段都不翻译（契约 §6.3.1：翻译层就是漂移层）。
      // 内核已经校验过"每个问题恰好一项"，这里的形状与 DSH 的 `AskUserQuestionAnswer`
      // 逐字一致，所以直接结构化赋过去。
      claim.settle({
        answers: answers.map((item) => ({
          id: item.id,
          selected: [...item.selected],
          ...(item.custom === undefined ? {} : { custom: item.custom }),
        })),
      })
      return true
    },
  }
}
