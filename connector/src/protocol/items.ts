/**
 * 条目（itemId）推导与 upsert 排序（契约 §5.2）。
 *
 * 条目是 **upsert-only** 的：同一个 itemId 再出现只覆盖内容、不新增条目。
 * 因此快照的拼接顺序取每个 itemId **最后**出现的修订号，而不是首次出现。
 *
 * 移植源：`protocol/reference/bridge.mjs` 的 `orderedItems`。
 */

/** 持久事件日志里的一条：修订号 + 条目号 + 内容。 */
export interface LogEntry {
  seq: number
  itemId: string
  text: string
}

/** 快照 / 增量里对外暴露的条目视图。 */
export interface ItemRecord {
  itemId: string
  text: string
  seq: number
}

/**
 * 按 itemId 最后出现的 seq 升序排列 —— 快照的拼接顺序。
 *
 * @param log - 持久事件日志（含已被 trim 出内存缓冲的那些，故顺序信息取自它）
 * @param items - 当前条目表（itemId → text）
 */
export function orderedItems(
  log: readonly LogEntry[],
  items: ReadonlyMap<string, string>,
): ItemRecord[] {
  const lastSeqOf = new Map<string, number>()
  for (const entry of log) lastSeqOf.set(entry.itemId, entry.seq)
  return [...items.entries()]
    .map(([itemId, text]) => ({ itemId, text, seq: lastSeqOf.get(itemId) ?? 0 }))
    .sort((a, b) => a.seq - b.seq)
}
