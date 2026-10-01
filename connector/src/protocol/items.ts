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

/**
 * 事件的最小结构。itemId 推导只看类型、序号与载荷。
 *
 * DSH 的 `SessionWireEvent`（`packages/api/session-controller/src/types.ts:458-468`）
 * 结构上满足它，但本层**不 import 它的类型** —— `src/protocol/` 保持零 DSH 依赖。
 */
export interface EventLike {
  type: string
  seq: number
  data: unknown
}

/** 载荷里带消息本体的事件。`user/message` 的载荷**就是**消息，其余放在 `data.message`。 */
const MESSAGE_EVENTS = new Set([
  'user/message',
  'system/message',
  'developer/message',
  'assistant/message',
])

function fieldOf(value: unknown, key: string): unknown {
  return typeof value === 'object' && value !== null
    ? (value as Record<string, unknown>)[key]
    : undefined
}

function nonEmptyString(value: unknown): string | undefined {
  return typeof value === 'string' && value !== '' ? value : undefined
}

/**
 * itemId 由事件自身推导（契约 §5.2 表）。
 *
 * **不得用 `seq` 当主键**（不变量 I9）。`<type>:<seq>` 只是规格明确许可的兜底，
 * 仅用于没有更稳定身份的事件类型。
 *
 * 已知类型缺了身份字段时**直接抛错**，不静默退化成 `<type>:<seq>`：那会让一条本该
 * 稳定的条目随读路径换 id，正是 I9 要防的形态。宁可让这一帧失败，也不要静默造出
 * 一个会漂移的身份。
 */
export function itemIdOf(event: EventLike): string {
  const { type, seq, data } = event

  if (MESSAGE_EVENTS.has(type)) {
    // `user/message` 是特例：载荷本身就是消息，其余类型在 `data.message` 上
    // （packages/core/session/src/index.ts:343）。
    const holder = type === 'user/message' ? data : fieldOf(data, 'message')
    // `MessageId` 是「跨每个表示边界保持的稳定身份」
    // （packages/llm/llm/src/message.ts:139-148）。
    const messageId = nonEmptyString(fieldOf(holder, 'id'))
    if (messageId === undefined) {
      throw new Error(`${type}(seq=${seq}) 缺少 message.id：无法推导稳定 itemId`)
    }
    return `m:${messageId}`
  }

  if (type === 'tool/call') {
    // packages/core/session/src/types.ts:361
    const callId = nonEmptyString(fieldOf(data, 'callId'))
    if (callId === undefined) throw new Error(`tool/call(seq=${seq}) 缺少 callId`)
    return `t:${callId}`
  }

  if (type === 'tool/result') {
    // 结果与调用共用同一个 itemId，靠 `toolCallId` 配对
    // （packages/llm/llm/src/message.ts:173-177、packages/core/session/src/types.ts:375-384）。
    const callId = nonEmptyString(fieldOf(fieldOf(data, 'message'), 'toolCallId'))
    if (callId === undefined) {
      throw new Error(`tool/result(seq=${seq}) 缺少 message.toolCallId：无法与 tool/call 配对`)
    }
    return `t:${callId}`
  }

  if (type === 'approval/asked' || type === 'approval/decided') {
    // ask 与 outcome 共用同一个 id，后者覆盖前者即「已决定」
    // （packages/interaction/user-approval/src/index.ts:225,232）。
    const approvalId = nonEmptyString(fieldOf(data, 'id'))
    if (approvalId === undefined) throw new Error(`${type}(seq=${seq}) 缺少 id`)
    return `i:${approvalId}`
  }

  // 规格许可的兜底：仅用于没有更稳定身份的事件类型（契约 §5.2）。
  return `${type}:${seq}`
}
