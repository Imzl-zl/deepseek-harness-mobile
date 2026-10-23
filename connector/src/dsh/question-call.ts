/**
 * 从会话日志里认出「这一次提问是哪一次 tool call」。
 *
 * ## 为什么需要它
 *
 * legacy 形态的 `ask_user_question` 在 waterfall 请求里**没有** `wait.callId`
 * （`packages/interaction/tool-ask-user/src/index.ts:98-109` 调 `ask()` 时根本不传 `wait`；
 * 只有 timed 形态才带 —— `timed.ts:200-203` 的无限等待与 `user-questions/src/index.ts:251`
 * 的 `askTimed` 都带）。而 claim 表以 `callId` 为键（`interaction-claims.ts`），手机发回的
 * 答复也以 `callId` 为键：那张卡的 `itemId` 是 `t:<callId>`（`app/lib/data/projection.dart:1020-1033`），
 * 发回来的 `callId` 就是会话事件 `tool/call` 里的真 id（`app/lib/data/app_model.dart:3148-3160`）。
 * 所以 legacy 下必须从日志里把它认出来，否则一次提问会变成工具失败。
 *
 * ## 判据（机械）
 *
 * 取 `tool/call` 里 `name === 'ask_user_question'` 的 callId，去掉已有 `tool/result` 的
 * （`tool/result.data.message.toolCallId`，`packages/core/session/src/types.ts:376-386`、
 * `packages/llm/llm/src/message.ts:177`），剩下的**恰好一个**才算认出来。
 * 0 个 = 日志里还没有这一次调用（程序化提问就没有）；≥2 个 = 不唯一（同一 step 里并行发了
 * 两次提问）。崩溃留下的悬空调用不算：DSH 在加载时会给它补一条合成结果
 * （`packages/core/session/src/repair.ts:18-29`）。两种都**不猜**。
 *
 * ## 并发语义
 *
 * 同一会话里一次只该有一个未结算的 `ask_user_question`：legacy 工具是阻塞的，
 * 第二个只能来自同一 step 的并行工具调用。并行时先跑到的应答者可能只看到自己那一条
 * （认领自己，正确），后跑到的会看到两条（不唯一，交还桌面）—— 取决于循环调度
 * （`packages/core/agent-loop/src/tool-calls.ts:165-213`），但**任何调度都不会认错 id**。
 * 本函数是**纯函数**（无时钟、无 IO、无缓存），每次调用都读调用方给的快照，
 * 所以它不会比日志更旧。
 *
 * ## 失败方向
 *
 * 认不出时调用方 `return next()`（交还桌面），**绝不抛、绝不猜一个 id**：
 * 抛会让这次提问变成工具失败；猜错会把答案写进另一次调用。
 *
 * ## 为什么读的是已废弃的同步读
 *
 * `Session.snapshotEvents()` 在 DSH 侧已标记 deprecated
 * （`.agents/notes/implemented/architecture/2026-09-09-deprecate-synchronous-session-event-reads.md`：
 * "new calls are prohibited"），而"此刻正在执行的那次 tool call"没有别的非废弃缝 ——
 * DSH 自己查 prompt 的 `rpcId` 也走这条读（`packages/api/session-controller/src/commands.ts:591-595`，
 * 带一行 line-scoped waiver）。本处沿用同一条读法；本仓没有 oxlint 门禁，所以没有那行 waiver，
 * 理由就是本段 —— 提问是低频的人机交互，扫描成本可忽略。
 *
 * ## 不做的事
 *
 * 不看 PTC 子调用（`tool/ptc-dispatch*`）：那类调用没有 `tool/call` 事件，手机上也没有
 * 对应的卡（卡的 id 来自 `tool/call`），所以认不出就 `next()` —— 与"日志里没有"同一档。
 *
 * Note: 为什么身份从日志推、为什么不是把部署改成 `mode: timed` ——
 * 见 `.agents/notes/implemented/2026-10-23-legacy-question-identity-from-session-log.md`。
 */
import type { SessionEvent } from '@deepseek-ai/dsh-session'

/** 本仓认的提问工具名（DSH `tool-ask-user` 注册的那个，`tool-ask-user/src/index.ts:39`）。 */
export const ASK_USER_QUESTION_TOOL = 'ask_user_question'

/**
 * 认身份的结果。
 *
 * `ambiguous` 带上两个以上的 id 只为留证（日志里说得出"是哪几次"）；
 * 调用方对它的动作与 `none` 完全相同。
 */
export type QuestionCallResolution =
  | { readonly kind: 'found'; readonly callId: string }
  | { readonly kind: 'none' }
  | { readonly kind: 'ambiguous'; readonly callIds: readonly string[] }

/**
 * 认出这一次提问对应的 tool call id。
 *
 * @param events - 会话事件快照（`agent.session.snapshotEvents()`）。
 * @returns `found` = 唯一未结算的提问调用；`none` / `ambiguous` = 认不出，调用方交还桌面。
 */
export function resolveQuestionCall(events: readonly SessionEvent[]): QuestionCallResolution {
  // 先收已结算的 callId：`tool/result` 与 `tool/call` 的配对键是 `message.toolCallId`。
  const settled = new Set<string>()
  for (const event of events) {
    if (event.type === 'tool/result') settled.add(event.data.message.toolCallId)
  }

  const open = new Set<string>()
  for (const event of events) {
    if (event.type !== 'tool/call') continue
    if (event.data.name !== ASK_USER_QUESTION_TOOL) continue
    if (settled.has(event.data.callId)) continue
    open.add(event.data.callId)
  }

  const [only] = open
  if (only === undefined) return { kind: 'none' }
  if (open.size > 1) return { kind: 'ambiguous', callIds: [...open] }
  return { kind: 'found', callId: only }
}
