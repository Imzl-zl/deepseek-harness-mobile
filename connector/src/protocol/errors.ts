/**
 * 封闭错误码表（契约 §3.1）。
 *
 * **表是封闭的**：不在表内的错误一律归 `internal`，不允许各端自造码 —— 否则手机侧
 * 无法对错误做穷尽分支（`switch` 会漏），而漏掉的那一支通常正是要靠它决定
 * 「重试 / 回配对页 / 置灰」的那一支。
 *
 * 每个码都带一个 `clientAction`，把「客户端该怎么办」与码一起定死；它同时是产品文案的
 * 依据，避免各端自己解释同一个码。
 */

/** 码 → 客户端行为。行为取值是封闭的，见下面 `ClientAction`。 */
export const ERROR_TABLE = {
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
  | 'show-offline'
  | 'disable'
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
