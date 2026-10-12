/**
 * 恢复判定与快照分页（契约 §5）。
 *
 * 职责：分配修订号（单调、连续、不重编号）、留存**有界**增量缓冲、给出
 * 「完整增量或基线快照」两种回答之一、持有瞬时事实、按幂等键去重、
 * 从持久日志重建待审批集合、按游标分页给快照。
 *
 * 真实实现里修订号直接取 DSH 会话事件的 `seq`（见 `docs/subsystems/remote-channel.md` §5.1）；
 * 这里用一个从 1 开始的计数器代替，语义相同。
 *
 * 本文件只承载**会话层**语义。连接层（握手、fc 计数器、nonce、流控、重放拒绝）
 * 不在 fixtures 的覆盖范围：它由 `protocol/vectors` 的已知答案向量与各端单测覆盖。
 *
 * 移植源：`protocol/reference/bridge.mjs`（行为基准，不是可搬运的代码）。
 */
import { createDedupeTable, type DedupeTable } from './dedupe.js'
import { seal, type Frame } from './frame.js'
import { orderedItems, type ItemRecord, type LogEntry } from './items.js'

/** 恢复只有两种结果（不变量 I3）。 */
export type RecoveryOutcome = 'delta' | 'snapshot'

/**
 * 快照必须**带原因**（契约 §5.4）。
 * `history-rewritten` 预留给真实实现的历史重写检测，参考实现不产生它。
 */
export type SnapshotReason = 'window-missed' | 'revision-newer' | 'history-rewritten' | 'no-session'

/** 瞬时事实：不随修订号推进，恢复时**无条件回带**（不变量 I4）。 */
export interface TransientFacts {
  pendingApprovals?: number
  computerOnline?: boolean
  [key: string]: unknown
}

export interface RecoveryAnswer {
  source: 'bridge'
  outcome: RecoveryOutcome
  sid: string
  items: ItemRecord[]
  transient: TransientFacts
  /** 仅增量有；快照分页续页没有。 */
  to?: number
  from?: number
  reason?: SnapshotReason
  asOfSeq?: number
  hasMore?: boolean
}

interface SnapshotState {
  asOfSeq: number
  cursor: string
  reason: SnapshotReason
}

interface Session {
  /** 下一个待分配的修订号；`next - 1` 即最新修订号。 */
  next: number
  /** 持久事件日志（含 ask / outcome）：待审批集合的重建来源，不受 trim 影响。 */
  log: LogEntry[]
  /** 有界增量缓冲，可被 `trim` 丢弃。 */
  frames: LogEntry[]
  trimmedUpto: number
  /** itemId → text，upsert-only。 */
  items: Map<string, string>
  transient: TransientFacts
  /** callId → payload（可由 `rebuildPending` 重建，不是唯一 owner）。 */
  pending: Map<string, unknown>
  /** 进行中的分页快照。 */
  snapshot: SnapshotState | undefined
}

interface SnapshotPage {
  asOfSeq: number
  hasMore: boolean
  cursor: string | undefined
  items: ItemRecord[]
}

export interface Bridge {
  append(sid: string, itemId: string, text: string): Frame
  /** 发送：同一幂等键只接纳一次（对应 DSH 的 requestId 语义）。被拒时返回 null。 */
  send(sid: string, requestId: string, text: string): Frame | null
  /** 审批 / 提问的 ask：进日志，同时进「当前待处理」。 */
  ask(sid: string, callId: string, payload?: unknown): Frame
  /** 审批 / 提问的 outcome：同 itemId 覆盖 ask，并从待处理集合移除。 */
  answer(sid: string, callId: string, decision: unknown): Frame
  pendingOf(sid: string): Map<string, unknown>
  /** 模拟桥接进程重启：内存派生态清空，再按 keepDedupe 决定去重表是否幸存。 */
  restart(options?: { keepDedupe?: boolean }): void
  /** 从持久日志重建待审批集合（「有 ask、无 outcome」即悬空）。 */
  rebuildPending(): void
  latestSeq(sid: string): number | null
  frameAt(sid: string, seq: number): Frame & LogEntry
  itemsOf(sid: string): Map<string, string>
  transientOf(sid: string): TransientFacts
  setTransient(sid: string, patch: TransientFacts): void
  /** 模拟缓冲上界：丢掉 upto 及之前的帧，之后的补课只能走基线快照。 */
  trim(sid: string, upto: number): void
  /** 快照续页：游标形如 `b:<beforeSeq>`（契约 §5.4）。reason 与首答一致。 */
  snapshotPage(sid: string): RecoveryAnswer
  /** 恢复：只允许两种回答，瞬时事实无条件回带。 */
  hello(sid: string, since: number): RecoveryAnswer
  snapshotItems(sid: string): ItemRecord[]
}

export interface BridgeSeed {
  events?: ReadonlyArray<{ itemId: string; text: string }>
}

export function createBridge(
  initial: Record<string, BridgeSeed> = {},
  options: { snapshotPageSize?: number } = {},
): Bridge {
  const snapshotPageSize = options.snapshotPageSize ?? 100
  const sessions = new Map<string, Session>()
  let dedupe: DedupeTable<Frame> = createDedupeTable<Frame>()

  function ensure(sid: string): Session {
    let session = sessions.get(sid)
    if (!session) {
      session = {
        next: 1,
        log: [],
        frames: [],
        trimmedUpto: 0,
        items: new Map(),
        transient: {},
        pending: new Map(),
        snapshot: undefined,
      }
      sessions.set(sid, session)
    }
    return session
  }

  function record(session: Session, itemId: string, text: string): Frame {
    const seq = session.next
    session.next += 1
    const entry: LogEntry = { seq, itemId, text }
    session.log.push(entry)
    session.frames.push(entry)
    session.items.set(itemId, text) // upsert-only：同 itemId 覆盖，不新增
    return { t: 'ev', sid: '', seq, box: seal({ itemId, text }) }
  }

  function append(sid: string, itemId: string, text: string): Frame {
    return { ...record(ensure(sid), itemId, text), sid }
  }

  function transientOf(sid: string): TransientFacts {
    return { ...(sessions.get(sid)?.transient ?? {}) }
  }

  function snapshotPageOf(all: readonly ItemRecord[], asOfSeq: number): SnapshotPage {
    const cut = Math.max(0, all.length - snapshotPageSize)
    const rest = all.slice(0, cut)
    const page = all.slice(cut)
    const tail = rest.at(-1)
    return {
      asOfSeq,
      hasMore: rest.length > 0,
      cursor: rest.length > 0 && tail !== undefined ? `b:${tail.seq}` : undefined,
      items: page,
    }
  }

  for (const [sid, seed] of Object.entries(initial)) {
    for (const event of seed.events ?? []) append(sid, event.itemId, event.text)
  }

  return {
    append,

    send(sid, requestId, text) {
      if (dedupe.has(requestId)) return null
      const frame = append(sid, `req:${requestId}`, text)
      dedupe.claim(requestId, frame)
      return frame
    },

    ask(sid, callId, payload = {}) {
      const frame = append(sid, `i:${callId}`, JSON.stringify({ kind: 'ask', payload }))
      ensure(sid).pending.set(callId, payload)
      return frame
    },

    /**
     * 提问 / 计划审查的 outcome：**答案批次**,与 DSH 的 `AskUserQuestionAnswer` 同形
     * (`{ answers: [{ id, selected[], custom? }] }`)。
     *
     * 为什么是批次而不是一个「决策」:一次 `ask` 可以带多个问题,每个可能多选、还可能带
     * 自由文本;标量决策带不下这些。而「计划审查」在 DSH 侧只是问题的一个展示标签
     * (`intent.kind === 'plan-review'`,且注释明说 "an intent changes presentation only,
     * never the protocol"),**答案编码与普通提问完全一样** —— 于是一个批次形状覆盖
     * 审批 / 提问 / 计划审查三种,不需要决策枚举,也不需要为计划审查单开一条路。
     * 同 itemId 覆盖 ask,并从待处理集合移除。
     */
    answer(sid, callId, answers) {
      const frame = append(sid, `i:${callId}`, JSON.stringify({ kind: 'outcome', answers }))
      ensure(sid).pending.delete(callId)
      return frame
    },

    pendingOf(sid) {
      return new Map(ensure(sid).pending)
    },

    restart({ keepDedupe = true }: { keepDedupe?: boolean } = {}) {
      for (const session of sessions.values()) {
        session.frames = []
        session.trimmedUpto = 0
        session.pending = new Map()
        session.snapshot = undefined
        session.transient = {}
      }
      if (!keepDedupe) dedupe = createDedupeTable<Frame>()
    },

    rebuildPending() {
      for (const session of sessions.values()) {
        const open = new Map<string, true>()
        const payloadOf = new Map<string, unknown>()
        for (const entry of session.log) {
          if (!entry.itemId.startsWith('i:')) continue
          const callId = entry.itemId.slice(2)
          const body = JSON.parse(entry.text) as { kind: string; payload?: unknown }
          if (body.kind === 'ask') {
            open.set(callId, true)
            payloadOf.set(callId, body.payload)
          } else {
            open.delete(callId)
          }
        }
        session.pending = new Map([...open.keys()].map((callId) => [callId, payloadOf.get(callId)]))
      }
    },

    latestSeq(sid) {
      const session = sessions.get(sid)
      return session ? session.next - 1 : null
    },

    frameAt(sid, seq) {
      const session = sessions.get(sid)
      const frame =
        session?.frames.find((f) => f.seq === seq) ?? session?.log.find((f) => f.seq === seq)
      if (!frame) throw new Error(`没有 seq=${seq} 的帧（sid=${sid}）`)
      return { t: 'ev', sid, seq: frame.seq, box: seal({ itemId: frame.itemId, text: frame.text }), itemId: frame.itemId, text: frame.text }
    },

    itemsOf(sid) {
      return new Map(sessions.get(sid)?.items ?? [])
    },

    transientOf,

    setTransient(sid, patch) {
      const session = ensure(sid)
      session.transient = { ...session.transient, ...patch }
    },

    trim(sid, upto) {
      const session = ensure(sid)
      session.trimmedUpto = Math.max(session.trimmedUpto, upto)
      session.frames = session.frames.filter((f) => f.seq > session.trimmedUpto)
    },

    snapshotPage(sid) {
      const session = ensure(sid)
      if (!session.snapshot) throw new Error(`没有进行中的快照（sid=${sid}）`)
      const before = Number(session.snapshot.cursor.slice(2))
      const all = orderedItems(session.log, session.items).filter((item) => item.seq <= before)
      const page = snapshotPageOf(all, session.snapshot.asOfSeq)
      const reason = session.snapshot.reason
      session.snapshot = page.hasMore
        ? { asOfSeq: session.snapshot.asOfSeq, cursor: page.cursor ?? '', reason }
        : undefined
      return { source: 'bridge', outcome: 'snapshot', reason, sid, ...page, transient: transientOf(sid) }
    },

    hello(sid, since) {
      const session = sessions.get(sid)
      const transient = transientOf(sid)
      if (!session) {
        return {
          source: 'bridge',
          outcome: 'snapshot',
          reason: 'no-session',
          sid,
          asOfSeq: since,
          hasMore: false,
          items: [],
          to: since,
          transient,
        }
      }
      const latest = session.next - 1
      // 参考实现写作 `since + 1 < session.trimmedUpto + 1`，两边同减 1 即 `since < trimmedUpto`。
      if (since > latest || since < session.trimmedUpto) {
        const reason: SnapshotReason = since > latest ? 'revision-newer' : 'window-missed'
        const page = snapshotPageOf(orderedItems(session.log, session.items), latest)
        session.snapshot = page.hasMore
          ? { asOfSeq: latest, cursor: page.cursor ?? '', reason }
          : undefined
        return { source: 'bridge', outcome: 'snapshot', reason, sid, ...page, to: latest, transient }
      }
      const items: ItemRecord[] = session.frames
        .filter((f) => f.seq > since)
        .map((f) => ({ seq: f.seq, itemId: f.itemId, text: f.text }))
      return { source: 'bridge', outcome: 'delta', from: since + 1, to: latest, sid, items, transient }
    },

    snapshotItems(sid) {
      const session = sessions.get(sid)
      if (!session) return []
      return orderedItems(session.log, session.items)
    },
  }
}
