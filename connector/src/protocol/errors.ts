/**
 * 封闭错误码表（契约 §3.1）。
 *
 * **表是封闭的**：不在表内的错误一律归 `internal`，不允许各端自造码 —— 否则手机侧
 * 无法对错误做穷尽分支（`switch` 会漏），而漏掉的那一支通常正是要靠它决定
 * 「重试 / 回配对页 / 置灰」的那一支。
 *
 * 每个码都带一个 `clientAction`，把「客户端该怎么办」与码一起定死；它同时是产品文案的
 * 依据，避免各端自己解释同一个码。
 *
 * ## 表里有两类码，别混
 *
 * 1. **协议层**（`protocol/*`、`relay/*`、`connector/*`、`rate-limited`）—— 连接自己的事，
 *    动作是连接级的（重连 / 回配对页 / 退避）。
 * 2. **宿主层**（`session/*`、`settings/*`、`credentials/*`、`gateway/*`、`workspace/*`、
 *    `agent-preset/*`、`job/*`）—— DSH 真实返回的码，**原样进表**。它们描述"这一次操作
 *    为什么没成"，动作是操作级的（置灰 / 刷新 / 退避 / 显示原文）。
 *
 * 第 2 类**必须收全**：漏一个的后果不是"走 default"，而是被下面的归一化降级成
 * `internal` → `log-and-retry` → 用户对着一个永远重试也不好的操作反复点。
 * 本仓已经栽过一次（`not-paired` 被报成 `bad-frame`，用户卡在重试上）。
 * 可达码由 `protocol/tools/dsh-error-codes.mjs` 从 DSH 源码机械抽出，`pnpm test` 里断言覆盖。
 */

/** 码 → 客户端行为。行为取值是封闭的，见下面 `ClientAction`。 */
export const ERROR_TABLE = {
  // ---- 协议层:连接自己的事 ----
  'protocol/unsupported-version': 'upgrade-required',
  'protocol/not-paired': 're-pair',
  'protocol/revoked': 're-pair',
  'protocol/bad-frame': 'reconnect-once',
  'protocol/replay': 'reconnect-once',
  'rate-limited': 'backoff-retry',
  'session/not-found': 'drop-from-list',
  'session/window-missed': 'snapshot',
  'session/revision-newer': 'snapshot',
  'interaction/not-pending': 'refresh-pending',
  'job/not-found': 'refresh-jobs',
  'settings/read-only': 'disable-and-annotate',
  'relay/offline': 'show-offline',
  'connector/unsupported': 'disable',
  internal: 'log-and-retry',

  // ---- 宿主层:DSH 在这些方法上真实返回的码(2026-10-09 逐条读源码核实) ----
  // 会话面(session-controller/src/commands.ts、history.ts、list.ts)
  'session/agent-busy': 'backoff-retry', // :372 电脑正忙着，稍后重发
  'session/model-unavailable': 'disable-and-annotate', // :381 先去选模型
  'session/attachment-invalid': 'disable-and-annotate', // :370,:421 这个附件发不出去
  'session/steer-unavailable': 'refresh-pending', // :478 轮次已变，排队项作废
  'session/queue-item-not-found': 'refresh-pending', // :455,:474 那一项已不在队列
  'session/writer-held': 'backoff-retry', // :536 写者被占，稍后
  'session/conflict': 'disable-and-annotate', // :546 预设等冲突
  // 新建会话(commands.ts:107,114)
  'workspace/not-found': 'disable-and-annotate',
  'agent-preset/conflict': 'disable-and-annotate',
  // 网关面(gateway/src/index.ts、settings-controller/src/index.ts)
  'gateway/bad-request': 'report-defect', // 我们发的参数宿主不认 = 我们的缺陷
  // 归档面(workspace-controller/src/commands.ts:172-178)：会话还有在跑的活动，
  // 归档被拒。**不是故障** —— 手机据此弹"停止并归档"，带 `stopActivity` 重试。
  'workspace/session-active': 'disable-and-annotate',
  'gateway/cancelled': 'reconnect-once', // 调用被中止，等价于连接层的事
  'gateway/internal': 'backoff-retry', // 宿主内部错，稍后
  // 设置与凭据(settings-controller/src/index.ts:267、credentials.ts)
  'settings/rejected': 'disable-and-annotate',
  'settings/conflict': 'refresh-settings', // expectedRevision 过期，重新 describe 再改
  'credential/rejected': 'disable-and-annotate',
} as const

export type ErrorCode = keyof typeof ERROR_TABLE

/**
 * 客户端对该错误的处置。刻意是**封闭枚举**而不是自由文本：手机端据此分支，
 * 新增行为要改这张表，不会漏在某个 switch 的 default 里。
 */
export type ClientAction =
  | 'upgrade-required'
  | 're-pair'
  | 'reconnect-once'
  | 'backoff-retry'
  | 'snapshot'
  | 'drop-from-list'
  | 'refresh-pending'
  | 'refresh-jobs'
  | 'disable-and-annotate'
  | 'refresh-settings'
  | 'show-offline'
  | 'disable'
  | 'report-defect'
  | 'log-and-retry'

export const ERROR_CODES = Object.keys(ERROR_TABLE) as readonly ErrorCode[]

const CODE_SET: ReadonlySet<string> = new Set(ERROR_CODES)

export function isErrorCode(value: unknown): value is ErrorCode {
  return typeof value === 'string' && CODE_SET.has(value)
}

export function clientActionOf(code: ErrorCode): ClientAction {
  return ERROR_TABLE[code]
}

/**
 * 协议错误。**码必须来自封闭表**：构造时归一，未知码一律降级成 `internal`
 * 而不是原样透传 —— 透传一个手机端不认识的码，等于逼它走 default 分支，
 * 那正是这张表要消灭的东西。
 */
export class ProtocolError extends Error {
  readonly code: ErrorCode

  constructor(code: string, message?: string) {
    const normalized: ErrorCode = isErrorCode(code) ? code : 'internal'
    super(message ?? normalized)
    this.name = 'ProtocolError'
    this.code = normalized
  }
}
