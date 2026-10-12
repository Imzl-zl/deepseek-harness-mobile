/**
 * 参考实现：电脑侧桥接（真值源）。
 *
 * 职责：分配修订号（单调、连续）、留存有界增量缓冲、给出「完整增量或基线快照」两种
 * 回答之一、持有瞬时事实、按幂等键去重、从日志重建待审批集合、按游标分页给快照。
 *
 * 真实实现里修订号直接取 DSH 会话事件的 `seq`（见 docs/subsystems/remote-channel.md §5.1）；
 * 这里用一个从 1 开始的计数器代替，语义相同：单调、连续、不重编号。
 *
 * 本文件只承载**会话层**语义（契约 §5）。连接层（握手、fc 计数器、nonce、流控、重放拒绝）
 * 不在 fixtures 的覆盖范围：它由 protocol/vectors 的已知答案向量与各端单测覆盖。
 * 产品实现的中继路由视图比这里多一个 `fc` 字段。
 */
import { seal } from './frame.mjs'

export function createBridge(initial = {}, options = {}) {
  const snapshotPageSize = options.snapshotPageSize ?? 100
  const sessions = new Map()
  let dedupe = new Map()

  function ensure(sid) {
    let session = sessions.get(sid)
    if (!session) {
      session = {
        next: 1,
        log: [],                 // 持久事件日志（含 ask / outcome）：待审批集合的重建来源
        frames: [],              // 有界增量缓冲（可被 trim）
        trimmedUpto: 0,
        items: new Map(),        // itemId -> text（upsert-only）
        transient: {},
        pending: new Map(),      // callId -> payload（可被重建，不是唯一 owner）
        snapshot: undefined,     // 进行中的分页快照 { asOfSeq, cursor }
      }
      sessions.set(sid, session)
    }
    return session
  }

  function record(session, itemId, text) {
    const seq = session.next
    session.next += 1
    const entry = { seq, itemId, text }
    session.log.push(entry)
    session.frames.push(entry)
    session.items.set(itemId, text)      // upsert-only：同 itemId 覆盖，不新增
    return { t: 'ev', sid: undefined, seq, box: seal({ itemId, text }) }
  }

  function append(sid, itemId, text) {
    const frame = record(ensure(sid), itemId, text)
    return { ...frame, sid }
  }

  for (const [sid, seed] of Object.entries(initial)) {
    for (const event of seed.events ?? []) append(sid, event.itemId, event.text)
  }

  /** 按 itemId 最后出现的 seq 升序排列（快照的拼接顺序）。 */
  function orderedItems(session) {
    const last = new Map()
    for (const entry of session.log) last.set(entry.itemId, entry.seq)
    return [...session.items.entries()]
      .map(([itemId, text]) => ({ itemId, text, seq: last.get(itemId) ?? 0 }))
      .sort((a, b) => a.seq - b.seq)
  }

  function takeTail(session, all, asOfSeq) {
    const page = all.slice(-snapshotPageSize)
    const rest = all.slice(0, Math.max(0, all.length - snapshotPageSize))
    return {
      asOfSeq,
      hasMore: rest.length > 0,
      cursor: rest.length > 0 ? `b:${rest.at(-1).seq}` : undefined,
      items: page,
    }
  }

  return {
    append,

    /** 发送：同一幂等键只接纳一次（对应 DSH 的 requestId 语义）。 */
    send(sid, requestId, text) {
      if (dedupe.has(requestId)) return null
      const frame = append(sid, `req:${requestId}`, text)
      dedupe.set(requestId, frame)
      return frame
    },

    /** 审批 / 提问的 ask：进日志，同时进"当前待处理"。 */
    ask(sid, callId, payload = {}) {
      const frame = append(sid, `i:${callId}`, JSON.stringify({ kind: 'ask', payload }))
      ensure(sid).pending.set(callId, payload)
      return frame
    },

    /**
     * 提问 / 计划审查的 outcome：答案批次（与 DSH 的 `AskUserQuestionAnswer` 同形）。
     *
     * 为什么是批次而不是一个「决策」：一次 `ask` 可以带多个问题，每个问题可能是多选、
     * 还可能带自由文本。标量决策带不下这些，而「计划审查」在 DSH 侧只是问题的一个
     * 展示标签（`intent.kind === 'plan-review'`），**答案编码与普通提问完全一样** ——
     * 所以一个批次形状覆盖全部三种，不需要决策枚举。
     * 同 itemId 覆盖 ask，并从待处理集合移除。
     */
    answer(sid, callId, answers) {
      const frame = append(sid, `i:${callId}`, JSON.stringify({ kind: 'outcome', answers }))
      ensure(sid).pending.delete(callId)
      return frame
    },

    pendingOf(sid) {
      return new Map(ensure(sid).pending)
    },

    /** 模拟桥接进程重启：内存派生态清空，再按 keepDedupe 决定去重表是否幸存。 */
    restart({ keepDedupe = true } = {}) {
      for (const session of sessions.values()) {
        session.frames = []
        session.trimmedUpto = 0
        session.pending = new Map()
        session.snapshot = undefined
        session.transient = {}
      }
      if (!keepDedupe) dedupe = new Map()
    },

    /** 从持久日志重建待审批集合（"有 ask、无 outcome"即悬空）。 */
    rebuildPending() {
      for (const session of sessions.values()) {
        const open = new Map()
        const payloadOf = new Map()
        for (const entry of session.log) {
          if (!entry.itemId.startsWith('i:')) continue
          const callId = entry.itemId.slice(2)
          const body = JSON.parse(entry.text)
          if (body.kind === 'ask') { open.set(callId, true); payloadOf.set(callId, body.payload) }
          else open.delete(callId)
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
      const frame = session?.frames.find((f) => f.seq === seq) ?? session?.log.find((f) => f.seq === seq)
      if (!frame) throw new Error(`没有 seq=${seq} 的帧（sid=${sid}）`)
      return { ...frame, sid, box: seal({ itemId: frame.itemId, text: frame.text }) }
    },

    itemsOf(sid) {
      return new Map(sessions.get(sid)?.items ?? [])
    },

    transientOf(sid) {
      return { ...(sessions.get(sid)?.transient ?? {}) }
    },

    setTransient(sid, patch) {
      const session = ensure(sid)
      session.transient = { ...session.transient, ...patch }
    },

    /** 模拟缓冲上界：丢掉 upto 及之前的帧，之后的补课只能走基线快照。 */
    trim(sid, upto) {
      const session = ensure(sid)
      session.trimmedUpto = Math.max(session.trimmedUpto, upto)
      session.frames = session.frames.filter((f) => f.seq > session.trimmedUpto)
    },

    /** 快照续页：游标形如 `b:<beforeSeq>`（契约 §5.4）。reason 与首答一致。 */
    snapshotPage(sid) {
      const session = ensure(sid)
      if (!session.snapshot) throw new Error(`没有进行中的快照（sid=${sid}）`)
      const before = Number(session.snapshot.cursor.slice(2))
      const all = orderedItems(session).filter((item) => item.seq <= before)
      const page = takeTail(session, all, session.snapshot.asOfSeq)
      const reason = session.snapshot.reason
      session.snapshot = page.hasMore ? { asOfSeq: session.snapshot.asOfSeq, cursor: page.cursor, reason } : undefined
      return { source: 'bridge', outcome: 'snapshot', reason, sid, ...page, transient: this.transientOf(sid) }
    },

    /**
     * 恢复：只允许两种回答——完整增量，或明确要求基线快照（带水位与分页）。
     * 瞬时事实无条件回带（它不随修订号推进）。
     */
    hello(sid, since) {
      const session = sessions.get(sid)
      const transient = this.transientOf(sid)
      if (!session) {
        return { source: 'bridge', outcome: 'snapshot', reason: 'no-session', sid, asOfSeq: since, hasMore: false, items: [], to: since, transient }
      }
      const latest = session.next - 1
      if (since > latest || since + 1 < session.trimmedUpto + 1) {
        const reason = since > latest ? 'revision-newer' : 'window-missed'
        const page = takeTail(session, orderedItems(session), latest)
        session.snapshot = page.hasMore ? { asOfSeq: latest, cursor: page.cursor, reason } : undefined
        return { source: 'bridge', outcome: 'snapshot', reason, sid, ...page, to: latest, transient }
      }
      const items = session.frames
        .filter((f) => f.seq > since)
        .map((f) => ({ seq: f.seq, itemId: f.itemId, text: f.text }))
      return { source: 'bridge', outcome: 'delta', from: since + 1, to: latest, sid, items, transient }
    },

    snapshotItems(sid) {
      const session = sessions.get(sid)
      if (!session) return []
      return orderedItems(session)
    },
  }
}
