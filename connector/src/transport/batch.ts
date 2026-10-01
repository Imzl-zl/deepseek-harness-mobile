/**
 * 批量合并（契约 §9、§10）。
 *
 * **不逐 token 推帧**：按 **50–100 ms 或累计 ≥4 KiB** 触发一批。
 * 取值依据是实测（§10）：事件中位 253 B、每 turn ≈ 21 事件，合并后每帧约 1–4 KB ——
 * 也就是一个 turn 的事件大致能凑成一两批，而不是 21 个网络帧。
 *
 * 两条纪律：
 *
 * - **前台用小间隔，后台不推**（§9）。切后台本来就该断开连接（§2.2），
 *   所以 `setForeground(false)` 之后 `due()` 恒为 false。
 * - **合并的是发送时机，不是内容顺序**。调用方按顺序 `push`，`take()` 按顺序还回来；
 *   本文件不做去重、不做重排 —— 那是会话层的事。
 *
 * 时间同样由调用方传入，便于测试。
 */

/** 前台合并窗口（毫秒）。§10 给的是 50–100 的区间，取小值。 */
export const BATCH_FLUSH_MS = 50
/** 累计到这么多字节就立刻发一批，不等窗口。 */
export const BATCH_FLUSH_BYTES = 4 * 1024

export interface Batch<T> {
  items: readonly T[]
  bytes: number
}

export interface Batcher<T> {
  /** 入队一项及其字节数；`now` 用于计算窗口起点。 */
  push(item: T, sizeBytes: number, now: number): void
  /** 现在该不该发一批。 */
  due(now: number): boolean
  /** 取出并清空当前批次（空批次返回 `null`）。 */
  take(): Batch<T> | null
  /** 前台态变化。非前台时 `due()` 恒为 false。 */
  setForeground(foreground: boolean): void
  readonly pending: number
}

export interface BatcherOptions {
  flushMs?: number
  flushBytes?: number
}

export function createBatcher<T>(options: BatcherOptions = {}): Batcher<T> {
  const flushMs = options.flushMs ?? BATCH_FLUSH_MS
  const flushBytes = options.flushBytes ?? BATCH_FLUSH_BYTES

  let items: T[] = []
  let bytes = 0
  /** 当前批次第一项的入队时刻；空批次时为 NaN。 */
  let openedAt = Number.NaN
  let foreground = true

  return {
    push(item, sizeBytes, now) {
      if (items.length === 0) openedAt = now
      items.push(item)
      bytes += sizeBytes
    },

    due(now) {
      if (!foreground || items.length === 0) return false
      // 字节阈值优先：攒够 4 KiB 就别再等窗口，否则大 turn 会一直等到窗口关闭。
      if (bytes >= flushBytes) return true
      return now - openedAt >= flushMs
    },

    take() {
      if (items.length === 0) return null
      const batch: Batch<T> = { items, bytes }
      items = []
      bytes = 0
      openedAt = Number.NaN
      return batch
    },

    setForeground(next) {
      foreground = next
    },

    get pending() {
      return items.length
    },
  }
}
