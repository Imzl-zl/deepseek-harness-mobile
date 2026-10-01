/**
 * 重连退避（契约 §2.2、§10）。
 *
 * `1s → 2s → 4s → … → 30s` 封顶，**抖动 ±20%**。两个取值各有依据：
 * 指数是为了避免惊群；30 s 上界是为了「回到前台能快速恢复」。
 *
 * 抖动**必须真的随机**：多台设备同时掉线时，固定间隔会让它们排着队在同一毫秒重连。
 * 所以 `random` 是注入的 —— 测试里给确定值，生产里给 `Math.random`。
 *
 * 另一条纪律在调用方：**只在 App 前台重连**；切后台要主动断开并停表（§2.2）。
 * 本文件不判断前台态，只负责「下一次该等多久」。
 */

/** 首次退避（毫秒）。 */
export const BACKOFF_BASE_MS = 1_000
/** 退避上界（毫秒）。 */
export const BACKOFF_MAX_MS = 30_000
/** 抖动幅度：±20%。 */
export const BACKOFF_JITTER = 0.2

export interface Backoff {
  /** 取下一次退避时长并推进（含抖动）。 */
  next(): number
  /** 回到起点。连接成功进入 `serving` 后必须调用，否则下次掉线会从上次的大间隔开始。 */
  reset(): void
  /** 已经连续失败多少次。 */
  readonly attempt: number
}

/**
 * @param random - 返回 `[0, 1)`；注入以便测试确定化。
 */
export function createBackoff(random: () => number = Math.random): Backoff {
  let attempt = 0

  /** 第 n 次（0 起）的**未抖动**间隔：base * 2^n，封顶 max。 */
  const rawAt = (n: number): number => {
    // 先算指数再封顶：`1 << 30` 早就溢出了，所以用乘法并在每一步夹住上界。
    let value = BACKOFF_BASE_MS
    for (let i = 0; i < n && value < BACKOFF_MAX_MS; i += 1) value *= 2
    return Math.min(value, BACKOFF_MAX_MS)
  }

  return {
    next() {
      const raw = rawAt(attempt)
      attempt += 1
      // `[0,1) → [-1,1)`，再乘幅度。抖动后仍夹住上界：上界是"回到前台能快速恢复"的保证，
      // 不能被抖动顶破。
      const jitter = (random() * 2 - 1) * BACKOFF_JITTER
      return Math.min(BACKOFF_MAX_MS, Math.max(0, Math.round(raw * (1 + jitter))))
    },
    reset() {
      attempt = 0
    },
    get attempt() {
      return attempt
    },
  }
}
