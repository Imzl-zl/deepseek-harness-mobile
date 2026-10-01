/**
 * 连接状态机（契约 §2.2）。
 *
 * ```text
 *   idle ──建连──▶ connecting ──鉴权通过──▶ handshake ──握手完成──▶ serving
 *                     │                        │                      │
 *                  失败/超时                 失败/超时              断开/错误
 *                     ▼                        ▼                      ▼
 *                   closed ◀───────────────────┴──────────────────────┘
 *                     │ 连接结束
 *                     ▼
 *                  backoff ──计时到且前台──▶ connecting
 * ```
 *
 * **迁移表是白名单**：不在表里的迁移一律抛错。状态机的全部价值就在于「非法迁移会响」——
 * 如果允许任意跳转，它就退化成一个字符串字段，而真正的 bug（比如从 `idle` 直接进
 * `serving`、或 `backoff` 里又开一条连接）会静默发生，表现为两条连接同时存在。
 *
 * 本文件不碰 I/O、不碰定时器：它只回答「现在能不能去那个状态」。
 */

/** 状态取值（契约 §2.2）。 */
export const CONNECTION_STATES = [
  'idle',
  'connecting',
  'handshake',
  'serving',
  'closed',
  'backoff',
] as const

export type ConnectionState = (typeof CONNECTION_STATES)[number]

/**
 * 允许的迁移（白名单）。
 *
 * - `idle → connecting`：发起建连。
 * - `connecting → handshake`：WSS 建好且鉴权通过。
 * - `handshake → serving`：§4.1 的三条消息走完。
 * - `* → closed`：失败、超时、断开、错误。
 * - `closed → backoff`：连接结束，进入退避计时。
 * - `closed → idle` / `backoff → idle`：**主动断开**（切后台、插件卸载），不再重连。
 */
const TRANSITIONS: Record<ConnectionState, readonly ConnectionState[]> = {
  idle: ['connecting'],
  connecting: ['handshake', 'closed'],
  handshake: ['serving', 'closed'],
  serving: ['closed'],
  closed: ['backoff', 'idle'],
  backoff: ['connecting', 'idle'],
}

export class IllegalTransitionError extends Error {
  constructor(from: ConnectionState, to: ConnectionState) {
    super(`非法的连接状态迁移：${from} → ${to}（允许的去向：${TRANSITIONS[from].join(', ') || '无'}）`)
    this.name = 'IllegalTransitionError'
  }
}

export interface ConnectionMachine {
  readonly state: ConnectionState
  /** 迁移；非法则抛 {@link IllegalTransitionError}。 */
  to(next: ConnectionState): void
  /** 当前是否处于该状态。 */
  is(...states: readonly ConnectionState[]): boolean
  /**
   * 收到帧时是否合法。
   *
   * **未完成握手的连接只接受握手帧**，其余一律 `protocol/bad-frame` 并关闭（§2.2）——
   * 所以这里把「能不能收业务帧」也做成状态机的一个查询，而不是散在对端的 if 里。
   */
  readonly acceptsBusinessFrames: boolean
  /** 订阅迁移（用于日志与指标）。返回取消订阅。 */
  onChange(listener: (from: ConnectionState, to: ConnectionState) => void): () => void
}

export function createConnectionMachine(
  initial: ConnectionState = 'idle',
): ConnectionMachine {
  let state = initial
  const listeners = new Set<(from: ConnectionState, to: ConnectionState) => void>()

  return {
    get state() {
      return state
    },

    to(next) {
      if (!TRANSITIONS[state].includes(next)) throw new IllegalTransitionError(state, next)
      const from = state
      state = next
      for (const listener of listeners) listener(from, next)
    },

    is(...states) {
      return states.includes(state)
    },

    get acceptsBusinessFrames() {
      return state === 'serving'
    },

    onChange(listener) {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
  }
}
