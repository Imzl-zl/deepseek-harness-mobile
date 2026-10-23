/**
 * 心跳与半开检测（契约 §2.2、§9、§10）。
 *
 * 两条规则：
 *
 * 1. **仅在前台且连接空闲时每 60 s 发一次心跳**；任一方向有帧时不额外发，切后台即停
 *    （§9）。60 s 这个值的依据是 RFC 5382 REQ-5 与 SIGCOMM 2011 的运营商级实测对照
 *    （§10 有完整推导）。
 * 2. **半开判据：`serving` 期间任一方向连续 2 个心跳周期无任何帧 → 视为断开，重连**
 *    （§2.2）。TCP 半开连接不会报错 —— 写进去没人管、也没有 FIN，只有靠这个判据发现，
 *    否则用户会看到「连着但什么都收不到」。
 *
 * **时间一律由调用方传入**（`onFrame(now)` / `tick(now)`），本文件既不读时钟也不起定时器。
 * 「上一次有帧是什么时候」必须是**真收到帧的那一刻**，不能用「上一次 tick 的时刻」代替 ——
 * 后者会把空闲计时系统性地推迟一整个 tick 周期，而半开判据正是拿它做阈值的。
 */

/** 心跳周期（毫秒）。 */
export const HEARTBEAT_MS = 60_000
/** 连续多少个心跳周期没有任何帧就判半开。 */
export const HALF_OPEN_PERIODS = 2

export type KeepaliveAction =
  /** 什么都不做。 */
  | { kind: 'idle' }
  /** 该发一次心跳。 */
  | { kind: 'ping' }
  /** 判定为半开，调用方应关闭并重连。 */
  | { kind: 'half-open'; silentMs: number }

export interface Keepalive {
  /** 收到或发出**任何**帧时调用，带上当时的时间。 */
  onFrame(now: number): void
  /** 周期性调用（真实时钟驱动，间隔自定；判定只依赖传入的 `now`）。 */
  tick(now: number): KeepaliveAction
  // **没有 `setForeground`**：心跳不分前后台（契约 §9）。后台连接是否维持由
  // "前台服务活着"那一条决定（§13 的安卓例外），而不是靠"后台别发心跳"——
  // 停掉心跳只会让一条健康连接在 2 个周期后被自己判成半开。
  /** 距离上一次帧过了多久。 */
  silentFor(now: number): number
}

export interface KeepaliveOptions {
  /** 起始时间；不传则以第一次 `onFrame` / `tick` 为准。 */
  startedAt?: number
  heartbeatMs?: number
  halfOpenPeriods?: number
}

export function createKeepalive(options: KeepaliveOptions = {}): Keepalive {
  const heartbeatMs = options.heartbeatMs ?? HEARTBEAT_MS
  const periods = options.halfOpenPeriods ?? HALF_OPEN_PERIODS
  /** 半开阈值：连续这么多毫秒没有任何帧。 */
  const halfOpenAfterMs = heartbeatMs * periods

  let lastFrameAt = options.startedAt ?? Number.NaN
  /** 已经发过心跳、还没等到任何帧 —— 用来避免同一个空闲期反复发 ping。 */
  let pingedInThisIdle = false

  return {
    onFrame(now) {
      lastFrameAt = now
      pingedInThisIdle = false
    },

    tick(now) {
      if (Number.isNaN(lastFrameAt)) lastFrameAt = now

      const silentMs = now - lastFrameAt
      if (silentMs >= halfOpenAfterMs) return { kind: 'half-open', silentMs }

      if (silentMs < heartbeatMs || pingedInThisIdle) return { kind: 'idle' }

      // 心跳本身是我们**发出**的一帧，所以它重置空闲计时 —— 否则会在对端还没回 pong
      // 之前就自己判半开。同时记下"这个空闲期已经 ping 过"，避免每 tick 都发。
      pingedInThisIdle = true
      lastFrameAt = now
      return { kind: 'ping' }
    },

    silentFor(now) {
      return Number.isNaN(lastFrameAt) ? 0 : now - lastFrameAt
    },
  }
}
