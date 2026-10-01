/**
 * 幂等表的内存替身（测试用）。
 *
 * 结构与 `store/` 的 `dedupe` 表一致（`get` / `put` / `delete` / `entries` / `size`），
 * 但不落盘 —— 让"命中即回上次结果""并发合流""坏行当未命中"这些语义能在纯 Node 下测到。
 *
 * 用真的 `Map`（而不是普通对象）是为了让 `entries()` 的迭代顺序与真实表一致：
 * 按容量收敛时依赖插入顺序，替身若换一种顺序，测出来的行为就不是产品的行为。
 */
import type { DedupeEntry } from '../../src/store/index.js'
import type { DedupeRows } from '../../src/idempotency.js'

export interface MemoryDedupeRows extends DedupeRows {
  /** 直接看内容（断言"没写进去"用）。 */
  readonly map: Map<string, DedupeEntry>
  /** 写入次数（断言"失败不落盘"用）。 */
  readonly puts: number
}

export function createMemoryDedupeRows(
  initial: Record<string, DedupeEntry> = {},
): MemoryDedupeRows {
  const map = new Map(Object.entries(initial))
  let puts = 0
  return {
    map,
    get puts() {
      return puts
    },
    get: (key) => map.get(key),
    put: (key, value) => {
      puts += 1
      map.set(key, value)
      return Promise.resolve()
    },
    delete: (key) => Promise.resolve(map.delete(key)),
    entries: () => map.entries(),
    get size() {
      return map.size
    },
  }
}
