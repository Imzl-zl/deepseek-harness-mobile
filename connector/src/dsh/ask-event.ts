/**
 * 找一次**在途** ask 的会话事件（用于重连重投，见 `interaction-claims.ts` 的 `pendingAsks`）。
 *
 * ## 为什么需要它
 *
 * DSH 的 gateway 把在途交互当成 host-held pending：新客户端连上来会**重新投递**同一条请求
 * （`packages/api/gateway/src/index.ts:571`、`:685-689`），断线只撤投递（`:717-721`）。
 * 我们的"投递"是会话事件 —— 手机那张卡来自 `approval/asked` / `tool/call`，所以重投就是
 * **按原 seq 再发一次那条事件**：App 按 `itemId` upsert，天然幂等。
 *
 * ## 判据
 *
 * - 提问：`tool/call` 里 `name === 'ask_user_question'` 且 `callId` 相同（取最后一条）。
 * - 审批：`approval/asked` 里 `id` 相同、且没有同 `id` 的 `approval/decided`（取最后一条）。
 *   匹配键是**审批自己的 id**（`ApprovalRequestId`，`user-approval/src/types.ts:13-17`），
 *   不是 `callId` —— 后者是可选的（`types.ts:68-69`），拿它当键会让"没有 tool call 的审批"
 *   连重投都拿不到。id 由服务铸、会话内唯一（`src/index.ts:224`）。
 */
import type { SessionEvent } from '@deepseek-ai/dsh-session'

import { ASK_USER_QUESTION_TOOL } from './question-call.js'

/**
 * 一条"重连重投"载荷：那次 ask 的会话事件（原 seq + 线上 body）。
 *
 * 形状与 `ev` 帧的载荷逐字一致（`session-subscriptions.ts` 的 `JSON.stringify(event)`），
 * 所以重投走的是**已有的**出帧路径 —— 不新增帧类型、不新增方法。App 按 `itemId` upsert，
 * 重发天然幂等（与 DSH gateway 的 `deliverRemoteEvent` 同形）。
 */
export interface Redelivery {
  readonly seq: number
  readonly body: string
}

/** 把一次 ask 的会话事件收成重投载荷；事件不在时回 `undefined`（不重投）。 */
export function redeliverOf(event: SessionEvent | undefined): Redelivery | undefined {
  return event === undefined ? undefined : { seq: event.seq, body: JSON.stringify(event) }
}

/** 提问那条 `tool/call` 事件；找不到回 `undefined`（不猜）。 */
export function questionAskEvent(
  events: readonly SessionEvent[],
  callId: string,
): SessionEvent | undefined {
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index]
    if (event === undefined || event.type !== 'tool/call') continue
    if (event.data.name !== ASK_USER_QUESTION_TOOL || event.data.callId !== callId) continue
    return event
  }
  return undefined
}

/** 审批那条 `approval/asked` 事件（还没被 `approval/decided` 收口）；找不到回 `undefined`。 */
export function approvalAskEvent(
  events: readonly SessionEvent[],
  approvalId: string,
): SessionEvent | undefined {
  const decided = new Set<string>()
  for (const event of events) {
    if (event.type === 'approval/decided') decided.add(event.data.id)
  }
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index]
    if (event === undefined || event.type !== 'approval/asked') continue
    if (event.data.id !== approvalId || decided.has(event.data.id)) continue
    return event
  }
  return undefined
}
