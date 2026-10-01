/**
 * 幂等表（契约 §5.6，不变量 I8）。
 *
 * 语义：同一个幂等键（DSH 侧叫 `requestId`）只接纳一次。
 *
 * **它必须持久化**：内存态在桥接重启后清空，同一幂等键会被二次执行 ——
 * fixture `15-dedupe-must-persist` 就是这条的可执行证据。
 * 本文件只承载表的语义；落盘、容量上界（10000）与 TTL（24h）由 `store/` 负责，
 * 对应设计文档 §1.4 的 `kv:dedupe`。
 *
 * 移植源：`protocol/reference/bridge.mjs` 内部的 `dedupe` Map。
 */

export interface DedupeTable<V> {
  has(requestId: string): boolean
  get(requestId: string): V | undefined
  /** 记录一次生效。返回 false 表示该键此前已存在，调用方据此**拒绝**二次执行。 */
  claim(requestId: string, value: V): boolean
  /** 模拟「去重表丢失」：清空内存态。真实实现里对应落盘被删或首次启动。 */
  clear(): void
  readonly size: number
}

export function createDedupeTable<V>(): DedupeTable<V> {
  const entries = new Map<string, V>()
  return {
    has: (requestId) => entries.has(requestId),
    get: (requestId) => entries.get(requestId),
    claim(requestId, value) {
      if (entries.has(requestId)) return false
      entries.set(requestId, value)
      return true
    },
    clear: () => entries.clear(),
    get size() {
      return entries.size
    },
  }
}
