/**
 * 跑 `protocol/fixtures`（与 Dart 手机侧同一批）。
 *
 * 这是 `protocol/verify-fixtures.mjs` 在 connector 侧的对应物，判据逐条对齐：
 * 形状校验 → 三角色回放（手机 ⇄ 中转 ⇄ 电脑侧桥接）→ 全局不变量 → 逐条期望。
 *
 * **断言数必须与 `verify-fixtures.mjs` 一致（486）**：数量对不上就说明移植时漏了断言
 * （见 `docs/cookbook/channel-bootstrap.md` 第 3 步的判据）。
 *
 * 角色划分：
 * - 电脑侧桥接 ← `src/protocol/`（**产品代码**）；
 * - 中转 ← `tests/support/relay.ts`（测试替身，connector 不实现中转）；
 * - 手机侧（`since` / `received` / `upsert` / `applyAnswer`）← 本文件内的测试替身，
 *   真实实现属于 Dart 侧（`docs/subsystems/app-channel-client.md`）。
 *
 * 本层只测**会话层**语义。连接层（握手、fc 计数器、nonce、流控、重放拒绝）不在这里，
 * 由 `protocol/vectors` 的已知答案向量与各端单测覆盖。
 */
import assert from 'node:assert/strict'
import { readdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

import { ROUTING_KEYS, unseal, type Frame } from '../src/protocol/frame.js'
import type { ItemRecord } from '../src/protocol/items.js'
import { createBridge, type Bridge, type TransientFacts } from '../src/protocol/recovery.js'
import { decideTakeover } from '../src/protocol/takeover.js'
import { createRelay, type Relay, type RelayFrame } from './support/relay.js'

const HERE = dirname(fileURLToPath(import.meta.url))
const FIXTURES_DIR = join(HERE, '..', '..', 'protocol', 'fixtures')

/** `verify-fixtures.mjs` 的断言总数。两侧实现各自跑同一批 fixtures，这个数必须相等。 */
const REFERENCE_CHECK_COUNT = 486

const KNOWN_OPS = new Set([
  'append', 'redeliver', 'hello', 'ack', 'ackSeq', 'snapshotPage',
  'relayEvictAll', 'relayRestart', 'bridgeTrim', 'bridgeRestart', 'sendTwice',
  'setTransient', 'ask', 'answer', 'rebuildPending', 'live', 'takeover',
])
const OUTCOMES = new Set(['delta', 'snapshot'])
const REASONS = new Set(['window-missed', 'revision-newer', 'history-rewritten', 'no-session'])
const SOURCES = new Set(['relay', 'bridge'])

/*
 * fixtures 是运行期读入的动态 JSON，形状由 `validateShape` 校验。
 * 这里刻意用宽松类型，把严格类型留给 src/（产品代码）。
 */
/* eslint-disable @typescript-eslint/no-explicit-any */
type Json = any

interface SnapshotBuffer {
  asOfSeq: number
  buffered: Map<string, { text: string; seq: number }>
  acc: Map<string, { text: string; seq: number }>
}

/**
 * 「设备侧看到的一次恢复应答」。它比电脑侧的 `RecoveryAnswer` 宽：
 * `source` 还可能是 `relay`（中转窗口直接补课），并带一个 `transientSource`
 * 供全局规则校验「瞬时事实永远来自电脑侧」。
 *
 * 注意它**不带 `sid`** —— 与参考实现一致：`sid` 由 `applyAnswer` 在入账时补上，
 * 因为同一个应答对象是从 `recovery(sid)` 里按会话产出的。
 */
interface DeviceAnswer {
  source: 'bridge' | 'relay'
  outcome: 'delta' | 'snapshot'
  items: ItemRecord[]
  transient: TransientFacts
  transientSource: string
  to?: number
  from?: number
  reason?: string
  asOfSeq?: number
  hasMore?: boolean
}

/** 入账后的应答：`applyAnswer` 补上了 `sid`。 */
interface ReceivedAnswer extends DeviceAnswer {
  sid: string
}

test('16 条 fixtures 在 connector 侧跑绿，且断言数与 verify-fixtures.mjs 一致', () => {
  const failures: string[] = []
  let checks = 0

  const check = (ok: boolean, label: string, detail?: string): void => {
    checks += 1
    if (!ok) failures.push(detail ? `${label} → ${detail}` : label)
  }

  function validateShape(file: string, fx: Json): void {
    for (const key of ['name', 'why', 'bridge', 'relay', 'device', 'steps', 'expect']) {
      check(key in fx, `${file}: 缺少字段 ${key}`)
    }
    if (!Array.isArray(fx.steps) || fx.steps.length === 0) check(false, `${file}: steps 必须是非空数组`)
    for (const [i, step] of ((fx.steps ?? []) as Json[]).entries()) {
      check(KNOWN_OPS.has(step.op), `${file}: 第 ${i + 1} 步的 op 未知`, String(step.op))
    }
    for (const [sid, wantOrList] of Object.entries((fx.expect?.recovery ?? {}) as Record<string, Json>)) {
      const list = Array.isArray(wantOrList) ? wantOrList : [wantOrList]
      check(list.length > 0, `${file}: ${sid} 的恢复期望为空`)
      for (const want of list) {
        check(OUTCOMES.has(want.outcome), `${file}: ${sid} 的 outcome 非法`, String(want.outcome))
        check(SOURCES.has(want.source), `${file}: ${sid} 的 source 非法`, String(want.source))
        if (want.outcome === 'snapshot') {
          // 原因只需在首答里写清；后续分页页可以省略（实现侧由全局断言强制每答都带合法 reason）
          if (want.reason !== undefined) check(REASONS.has(want.reason), `${file}: ${sid} 的 reason 非法`, String(want.reason))
        } else {
          check(Number.isInteger(want.from) && Number.isInteger(want.to), `${file}: ${sid} 的增量必须带 from/to`)
        }
      }
    }
  }

  function runFixture(file: string, fx: Json): void {
    const bridge: Bridge = createBridge(fx.bridge ?? {}, { snapshotPageSize: fx.snapshotPageSize ?? 100 })
    let relay: Relay = createRelay(fx.relay?.windowSize ?? 1000)

    const since: Record<string, number> = { ...(fx.device?.since ?? {}) } // 手机侧「已落盘」的游标
    const received: Record<string, number> = { ...since }                  // 手机侧「已收到」的最大序号
    const transient: Record<string, Record<string, unknown>> = {}
    const items = new Map<string, Map<string, string>>()                   // sid -> Map(itemId -> text)
    for (const [sid, seed] of Object.entries((fx.device?.items ?? {}) as Record<string, Record<string, string>>)) {
      items.set(sid, new Map(Object.entries(seed)))                        // 手机侧本地库里已有的条目
    }
    const requests = new Map<string, number>()
    const answers: ReceivedAnswer[] = []
    const snapshots = new Map<string, SnapshotBuffer>()                    // sid -> { asOfSeq, buffered }
    const takeovers: Json[] = []
    const liveSeq = new Map<string, number | null>()                       // sid -> 收到 live 帧前的修订号
    let liveReceived = 0

    const itemsOf = (sid: string): Map<string, string> => items.get(sid) ?? new Map()
    const gaps: Record<string, number> = {}                                // 前向空洞（契约 §5.4 规则 5）
    const duplicates: Record<string, number> = {}                          // 重复投递

    /**
     * 接收端规则（契约 §5.4 规则 5）：
     * - 重复帧（seq ≤ 已收到水位）丢弃；
     * - 前向空洞（seq > 水位 + 1）不入库，记一次 gap —— 真实实现据此触发一次 SyncHello。
     */
    const upsert = (sid: string, itemId: string, text: string, seq: number): void => {
      const seen = received[sid] ?? 0
      if (seq <= seen) { duplicates[sid] = (duplicates[sid] ?? 0) + 1; return }
      if (seq > seen + 1) { gaps[sid] = (gaps[sid] ?? 0) + 1; return }
      const map = items.get(sid) ?? new Map<string, string>()
      map.set(itemId, text)                          // upsert-only：同 itemId 覆盖，不新增
      items.set(sid, map)
      received[sid] = seq
    }

    /** 手机侧落盘水位：只在「渲染/落盘」后推进（快照分页期间不动）。 */
    const commit = (sid: string, seq: number): void => { since[sid] = Math.max(since[sid] ?? 0, seq) }

    const applyAnswer = (sid: string, answer: DeviceAnswer): void => {
      answers.push({ ...answer, sid })
      transient[sid] = answer.transient as Record<string, unknown>
      if (answer.outcome === 'delta') {
        for (const item of answer.items) upsert(sid, item.itemId, item.text, item.seq)
        received[sid] = Math.max(received[sid] ?? 0, answer.to ?? 0)
        snapshots.delete(sid)
        return
      }
      // 快照：分页期间不落盘、不渲染；每页都累积，期间到达的 ev 一律缓存（契约 §5.4 规则 4）
      const state = snapshots.get(sid) ?? { asOfSeq: answer.asOfSeq ?? 0, buffered: new Map(), acc: new Map() }
      state.asOfSeq = answer.asOfSeq ?? state.asOfSeq
      for (const item of answer.items) state.acc.set(item.itemId, { text: item.text, seq: item.seq })
      if (!answer.hasMore) {
        const merged = new Map([...state.acc.entries()].map(([id, entry]) => [id, entry.text]))
        const buffered = [...state.buffered.entries()].sort((a, b) => a[1].seq - b[1].seq)
        for (const [itemId, entry] of buffered) merged.set(itemId, entry.text)
        items.set(sid, merged)
        received[sid] = Math.max(
          state.asOfSeq,
          0,
          ...[...state.acc.values()].map((e) => e.seq),
          ...buffered.map(([, e]) => e.seq),
        )
        commit(sid, received[sid] ?? 0)
        snapshots.delete(sid)
      } else {
        snapshots.set(sid, state)
      }
    }

    const recovery = (sid: string): DeviceAnswer => {
      const from = (since[sid] ?? 0) + 1
      const latest = bridge.latestSeq(sid)
      const transientNow = bridge.transientOf(sid)
      if (latest === null) {
        return {
          source: 'bridge', outcome: 'snapshot', reason: 'no-session',
          asOfSeq: since[sid] ?? 0, hasMore: false, items: [], to: since[sid] ?? 0,
          transient: transientNow, transientSource: 'bridge',
        }
      }
      if ((since[sid] ?? 0) > latest) {
        return { ...bridge.hello(sid, since[sid] ?? 0), transientSource: 'bridge' }
      }
      if (from <= latest) {
        const served = relay.since(sid, since[sid] ?? 0)
        if (served) {
          // 中转给的是不透明帧，解封发生在手机侧（参考实现里 unseal 就是那个占位）
          return {
            source: 'relay', outcome: 'delta', from, to: latest,
            items: served.frames.map((frame: RelayFrame) => ({ seq: frame.seq, ...unseal<{ itemId: string; text: string }>(frame.box) })),
            transient: transientNow, transientSource: 'bridge',
          }
        }
      }
      return { ...bridge.hello(sid, since[sid] ?? 0), transientSource: 'bridge' }
    }

    for (const step of fx.steps as Json[]) {
      switch (step.op) {
        case 'append': {
          const frame = bridge.append(step.sid, step.itemId, step.text)
          relay.put(frame)
          break
        }
        case 'redeliver': {
          const frame = bridge.frameAt(step.sid, step.seq)
          // 重复/并发投递：分页期间只缓存，否则按 upsert 落盘
          const state = snapshots.get(step.sid)
          if (state) state.buffered.set(frame.itemId, { text: frame.text, seq: frame.seq })
          else upsert(step.sid, frame.itemId, frame.text, frame.seq)
          break
        }
        case 'hello': {
          const sids: string[] = step.sid ? [step.sid] : Object.keys(since)
          for (const sid of sids) applyAnswer(sid, recovery(sid))
          break
        }
        case 'snapshotPage': {
          const answer = bridge.snapshotPage(step.sid)
          applyAnswer(step.sid, { ...answer, transientSource: 'bridge' })
          break
        }
        case 'ack': {
          commit(step.sid, received[step.sid] ?? 0)
          break
        }
        case 'ackSeq': {
          commit(step.sid, step.seq)
          break
        }
        case 'relayEvictAll': {
          relay.evictAll()
          break
        }
        case 'relayRestart': {
          relay = createRelay(fx.relay?.windowSize ?? 1000)
          break
        }
        case 'bridgeTrim': {
          bridge.trim(step.sid, step.upto)
          break
        }
        case 'bridgeRestart': {
          bridge.restart({ keepDedupe: step.keepDedupe !== false })
          break
        }
        case 'sendTwice': {
          for (let i = 0; i < 2; i += 1) {
            const frame = bridge.send(step.sid, step.requestId, step.text)
            requests.set(step.requestId, (requests.get(step.requestId) ?? 0) + (frame ? 1 : 0))
            if (frame) relay.put(frame)
          }
          break
        }
        case 'setTransient': {
          bridge.setTransient(step.sid, { pendingApprovals: step.pendingApprovals, computerOnline: step.computerOnline })
          break
        }
        case 'ask': {
          relay.put(bridge.ask(step.sid, step.callId, step.payload ?? {}))
          break
        }
        case 'answer': {
          relay.put(bridge.answer(step.sid, step.callId, step.decision))
          break
        }
        case 'rebuildPending': {
          bridge.rebuildPending()
          break
        }
        case 'live': {
          // live 帧只交给渲染层：不进 items、不动游标、不改修订号（契约 §3）
          liveReceived += 1
          liveSeq.set(step.sid, bridge.latestSeq(step.sid))
          break
        }
        case 'takeover': {
          takeovers.push({ sid: step.sid ?? null, ...decideTakeover({ mode: step.mode, sid: step.sid, devices: step.devices }) })
          break
        }
        default:
          throw new Error(`未实现的步骤: ${step.op}`)
      }
    }

    const relayFramesSeen = relay.routingKeys()

    // ---- 全局规则：恢复只有两种结果，且瞬时事实永远来自电脑侧 ----
    for (const answer of answers) {
      if (process.env.DSH_DEBUG) console.error(`[dbg] ${file} sid=${answer.sid} outcome=${answer.outcome} reason=${answer.reason} source=${answer.source} hasMore=${answer.hasMore} transientSource=${answer.transientSource}`)
      check(OUTCOMES.has(answer.outcome), `${file}: ${answer.sid} 的恢复结果不是两种之一`, answer.outcome)
      if (answer.outcome === 'snapshot') {
        check(REASONS.has(answer.reason as string), `${file}: ${answer.sid} 的快照原因非法`, String(answer.reason))
        check(Number.isInteger(answer.asOfSeq), `${file}: ${answer.sid} 的快照必须带 asOfSeq`, String(answer.asOfSeq))
        check(typeof answer.hasMore === 'boolean', `${file}: ${answer.sid} 的快照必须带 hasMore`)
      }
      check(answer.transientSource === 'bridge', `${file}: ${answer.sid} 的瞬时事实不是电脑侧给的`)
    }

    // ---- 逐条期望 ----
    for (const [sid, wantOrList] of Object.entries((fx.expect?.recovery ?? {}) as Record<string, Json>)) {
      const list = Array.isArray(wantOrList) ? wantOrList : [wantOrList]
      const got = answers.filter((a) => a.sid === sid)
      check(got.length === list.length, `${file}: ${sid} 恢复应答次数`, `期望 ${list.length} 次，实际 ${got.length} 次`)
      list.forEach((want: Json, index: number) => {
        const answer = got[index]
        if (!answer) return
        // 期望里写了什么就断言什么（from/to/reason/asOfSeq/hasMore 一视同仁）
        for (const [key, value] of Object.entries(want as Record<string, unknown>)) {
          if (key === 'items') continue
          check((answer as Json)[key] === value, `${file}: ${sid} 第 ${index + 1} 次 ${key}`, `期望 ${value}，实际 ${(answer as Json)[key]}`)
        }
        if (want.outcome === 'delta' && want.items !== undefined) {
          check(answer.items.length === want.items, `${file}: ${sid} 第 ${index + 1} 次增量条目数`, `期望 ${want.items}，实际 ${answer.items.length}`)
        }
      })
    }

    for (const [sid, want] of Object.entries((fx.expect?.items ?? {}) as Record<string, string[]>)) {
      const got = [...itemsOf(sid).keys()].sort()
      check(JSON.stringify(got) === JSON.stringify([...want].sort()), `${file}: ${sid} 可见条目`, `期望 ${want.join(',')}，实际 ${got.join(',')}`)
    }

    for (const [sid, want] of Object.entries((fx.expect?.itemCount ?? {}) as Record<string, number>)) {
      check(itemsOf(sid).size === want, `${file}: ${sid} 条目数`, `期望 ${want}，实际 ${itemsOf(sid).size}`)
    }

    /** 电脑侧权威条目数：用于「设备没收到帧」但要在权威侧断言去重效果的场景。 */
    for (const [sid, want] of Object.entries((fx.expect?.bridgeItemCount ?? {}) as Record<string, number>)) {
      const size = bridge.itemsOf(sid).size
      check(size === want, `${file}: ${sid} 电脑侧条目数`, `期望 ${want}，实际 ${size}`)
    }

    for (const [sid, want] of Object.entries((fx.expect?.deviceCursor ?? {}) as Record<string, number>)) {
      check(since[sid] === want, `${file}: ${sid} 已落盘游标`, `期望 ${want}，实际 ${since[sid]}`)
    }

    for (const [requestId, want] of Object.entries((fx.expect?.requests ?? {}) as Record<string, number>)) {
      check(requests.get(requestId) === want, `${file}: 幂等键 ${requestId} 生效次数`, `期望 ${want}，实际 ${requests.get(requestId)}`)
    }

    for (const [sid, want] of Object.entries((fx.expect?.transient ?? {}) as Record<string, Record<string, unknown>>)) {
      const got = transient[sid] ?? {}
      for (const [key, value] of Object.entries(want)) {
        check(got[key] === value, `${file}: ${sid} 瞬时事实 ${key}`, `期望 ${value}，实际 ${got[key]}`)
      }
    }

    if (fx.expect?.pending) {
      for (const [sid, want] of Object.entries(fx.expect.pending as Record<string, string[]>)) {
        const got = [...bridge.pendingOf(sid).keys()].sort()
        check(JSON.stringify(got) === JSON.stringify([...want].sort()), `${file}: ${sid} 待审批集合`, `期望 ${want.join(',') || '(空)'}，实际 ${got.join(',') || '(空)'}`)
      }
    }

    if (fx.expect?.takeover) {
      const want: Json[] = Array.isArray(fx.expect.takeover) ? fx.expect.takeover : [fx.expect.takeover]
      check(takeovers.length === want.length, `${file}: 仲裁判定次数`, `期望 ${want.length}，实际 ${takeovers.length}`)
      want.forEach((w: Json, i: number) => {
        const got = takeovers[i]
        if (!got) return
        for (const [key, value] of Object.entries(w as Record<string, unknown>)) {
          check(got[key] === value, `${file}: 仲裁第 ${i + 1} 次 ${key}`, `期望 ${value}，实际 ${got[key]}`)
        }
      })
    }

    if (fx.expect?.liveIgnored) {
      check(liveReceived > 0, `${file}: 期望至少收到一帧 live`)
      for (const [sid, seqBefore] of liveSeq.entries()) {
        check(bridge.latestSeq(sid) === seqBefore, `${file}: ${sid} live 帧不得改变修订号`, `之前 ${seqBefore}，之后 ${bridge.latestSeq(sid)}`)
      }
      for (const [sid, want] of Object.entries((fx.expect.deviceCursor ?? {}) as Record<string, number>)) {
        check(since[sid] === want, `${file}: ${sid} live 帧不得推进落盘水位`, `期望 ${want}，实际 ${since[sid]}`)
      }
    }

    for (const [sid, want] of Object.entries((fx.expect?.gaps ?? {}) as Record<string, number>)) {
      check((gaps[sid] ?? 0) === want, `${file}: ${sid} 空洞次数`, `期望 ${want}，实际 ${gaps[sid] ?? 0}`)
    }

    for (const [sid, want] of Object.entries((fx.expect?.duplicates ?? {}) as Record<string, number>)) {
      check((duplicates[sid] ?? 0) === want, `${file}: ${sid} 重复丢弃次数`, `期望 ${want}，实际 ${duplicates[sid] ?? 0}`)
    }

    if (fx.expect?.converged) {
      for (const sid of Object.keys(since)) {
        if (bridge.latestSeq(sid) === null) continue
        const mine = [...itemsOf(sid).entries()].sort()
        const theirs = [...bridge.itemsOf(sid).entries()].sort()
        check(JSON.stringify(mine) === JSON.stringify(theirs), `${file}: ${sid} 手机侧与电脑侧未收敛`, `手机 ${JSON.stringify(mine)} / 电脑 ${JSON.stringify(theirs)}`)
      }
    }

    if (fx.expect?.relayRoutingKeysOnly) {
      const clean = relayFramesSeen.every((keys) => keys.every((k) => (ROUTING_KEYS as readonly string[]).includes(k)))
      check(clean, `${file}: 中转的路由视图里出现了路由以外的字段`, JSON.stringify(relayFramesSeen))
    }
  }

  // ---- 主流程 ----
  const files = readdirSync(FIXTURES_DIR).filter((f) => f.endsWith('.json')).sort()
  check(files.length > 0, 'protocol/fixtures 下没有 fixture')

  for (const file of files) {
    const fx: Json = JSON.parse(readFileSync(join(FIXTURES_DIR, file), 'utf8'))
    validateShape(file, fx)
    try {
      runFixture(file, fx)
    } catch (error) {
      check(false, `${file}: 运行抛错`, (error as Error).message)
    }
  }

  if (failures.length > 0 || checks !== REFERENCE_CHECK_COUNT) {
    const head = `${files.length} 条 fixture；${failures.length}/${checks} 项不通过；` +
      `断言数期望 ${REFERENCE_CHECK_COUNT}，实际 ${checks}`
    assert.fail([head, ...failures.map((line) => `  - ${line}`)].join('\n'))
  }
})
