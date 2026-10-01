/**
 * 中转能看到的协议词汇（**只到这里为止**，I10）。
 *
 * 中转不依赖连接器的任何实现（方向不对：连接器是中转的客户端），
 * 所以它自己声明"我能看到什么"：帧类型、`sid`、`seq`、`fc`。
 *
 * ## 已知问题：这是第三份帧类型清单
 *
 * 另两份在 `connector/src/protocol/frame.ts` 与 `protocol/`（参考侧 fixtures/tools）。
 * 三份清单会漂移，而漂移的症状是"某种帧在中转这里被判成未知" —— 与连接器那边
 * 已经修过两次的是同一类问题（帧类型清单、攒批集合）。
 *
 * **正解**是把这份词汇抽成一个共享 TS 包（三端都 import 它）。之所以现在没做：
 * 本仓目前没有 workspace 根（AGENTS.md 明说没有 `package.json` 根与 CI），
 * 为此新建 workspace 是一次独立的重构。在它之前，本文件是**唯一的第二份**，
 * 而且只包含"中转真的要看"的那几个字段 —— 不再扩散。
 */

/** 线上帧类型（与契约 §3 的联合一致）。 */
export const FRAME_TYPES = [
  'hello',
  'hello-ack',
  'confirm',
  'pair',
  'pair-ack',
  'ping',
  'pong',
  'credit',
  'req',
  'res',
  'ev',
  'live',
  'job',
  'persisted',
  'presence',
] as const

export type FrameType = (typeof FRAME_TYPES)[number]

const KNOWN: ReadonlySet<string> = new Set(FRAME_TYPES)

export function isKnownFrameType(value: unknown): value is FrameType {
  return typeof value === 'string' && KNOWN.has(value)
}

/**
 * 从一行线上 JSON 里取出**路由视图**。
 *
 * 这是中转与载荷之间唯一的接口：它返回 `{t, sid, seq}`，**丢弃其余一切**。
 * 想越界读载荷，就必须绕过这个函数 —— 而它没有给出任何回传载荷的口子。
 */
export function routingViewOf(
  raw: string,
): { t: FrameType; sid: string; seq: number; id?: string } | undefined {
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return undefined
  }
  if (typeof parsed !== 'object' || parsed === null) return undefined
  const record = parsed as Record<string, unknown>
  if (!isKnownFrameType(record['t'])) return undefined
  const sid = typeof record['sid'] === 'string' ? record['sid'] : ''
  const seq = typeof record['seq'] === 'number' ? record['seq'] : 0
  // `id` 也在可见字段里（契约 §1 的 I10）：配对帧没有 `sid`，回执只能靠它找回来 ——
  // 它是**不透明的关联标记**，不携带任何内容信息。
  const id = typeof record['id'] === 'string' ? record['id'] : undefined
  return { t: record['t'], sid, seq, ...(id === undefined ? {} : { id }) }
}
