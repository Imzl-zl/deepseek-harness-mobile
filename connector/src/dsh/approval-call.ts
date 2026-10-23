/**
 * 从会话日志里认出「这一次审批是哪一条 `approval/asked`」。
 *
 * ## 为什么需要它
 *
 * DSH 的审批**没有把身份放进请求对象**：`ApprovalRequestEvent` 只有
 * `agent` / `toolName` / `callId?` / `reason?` / `displayReason?` / `signal?`
 * （`packages/interaction/user-approval/src/types.ts:63-76`）—— 没有 `ApprovalRequestId`。
 * 而服务在 dispatch **之前**就把 `approval/asked`（带那个服务铸的 id）落盘了
 * （`src/index.ts:224-231`），随后才 `await this.decide(...)`；成对的
 * `approval/decided` 与它同 id（`types.ts:44-58`）。
 *
 * 手机那张审批卡的 `itemId` 正是 `i:<approval/asked.id>`
 * （`app/lib/data/projection.dart:997,1003`），所以"手机答的是哪一条"必须落在这个 id 上。
 * 而 `callId` 是**可选**的（`types.ts:68-69`，落盘时"有才写"，`src/index.ts:228`）——
 * 拿它当唯一身份，就会把"没有 tool call 的审批"整类挡在门外（浏览器照样弹卡：
 * `packages/client/ui-approval/src/client/index.ts:45-53`）。
 *
 * ## 判据（机械）
 *
 * 未结算 = 有 `approval/asked`、没有同 id 的 `approval/decided`。
 *
 * - 请求里带 `callId` ⇒ 在未结算里取 `callId` 相同的那条（正常路径，唯一）。
 * - 不带 ⇒ **恰好一条**未结算时用它；0 条 / ≥2 条都算认不出。
 *
 * 认不出时调用方 `return next()`（**委托**，DSH 的原生语义：
 * `types.ts:81-82` "Return an outcome to claim the request or call `next()` to delegate"），
 * **绝不猜一个 id** —— 猜错会把"允许一次"写进另一条审批。委托之后桌面照常答；
 * 若一个 answerer 都没有，DSH 自己兜底成 `'unavailable'`
 * （`src/index.ts:281-283`）。
 *
 * ## 为什么复用这条读法
 *
 * 与 `question-call.ts` 同一个理由：这是唯一能拿到"此刻在途的那条 ask"的缝，
 * 且 DSH 自己查 prompt 的 `rpcId` 也走同一条已废弃的同步读
 * （`packages/api/session-controller/src/commands.ts:591-595`）。
 */
import type { SessionEvent } from '@deepseek-ai/dsh-session'

/** 认身份的结果。`ambiguous` 带 id 只为留证；调用方对它的动作与 `none` 相同。 */
export type ApprovalIdentity =
  | { readonly kind: 'found'; readonly id: string }
  | { readonly kind: 'none' }
  | { readonly kind: 'ambiguous'; readonly ids: readonly string[] }

/**
 * 认出这一次审批对应的 `approval/asked.id`。
 *
 * @param events - 会话事件快照（`agent.session.snapshotEvents()`）。
 * @param callId - 请求对象里的 `request.callId`（可选：只有 asker 有 tool call 时才给）。
 * @returns `found` = 这一条审批的原生身份；`none` / `ambiguous` = 认不出，调用方委托。
 */
export function resolveApprovalIdentity(
  events: readonly SessionEvent[],
  callId?: string,
): ApprovalIdentity {
  const decided = new Set<string>()
  for (const event of events) {
    if (event.type === 'approval/decided') decided.add(event.data.id)
  }

  /** 未结算的 `approval/asked`（按 id 去重：同一 id 只可能有一条）。 */
  const open = new Map<string, string | undefined>()
  for (const event of events) {
    if (event.type !== 'approval/asked') continue
    if (decided.has(event.data.id)) continue
    open.set(event.data.id, event.data.callId)
  }

  if (open.size === 0) return { kind: 'none' }
  if (callId === undefined) {
    const [only] = open.keys()
    if (only === undefined) return { kind: 'none' }
    return open.size === 1 ? { kind: 'found', id: only } : { kind: 'ambiguous', ids: [...open.keys()] }
  }
  // 带 callId 的正常路径：**它可能对应 0 条**（日志还没写到那一条），那就是认不出。
  const matched = [...open.entries()].filter(([, askedCallId]) => askedCallId === callId)
  const [only] = matched
  if (only === undefined) return { kind: 'none' }
  return matched.length === 1
    ? { kind: 'found', id: only[0] }
    : { kind: 'ambiguous', ids: matched.map(([id]) => id) }
}
