/**
 * 协议 fixtures 一致性校验（唯一规格源的可执行部分）。
 *
 * 跑法：node protocol/verify-fixtures.mjs
 *
 * 它做四件事：
 * 1. 校验每条 fixture 的形状（字段、步骤、期望值取值域）；
 * 2. 用 `reference/` 下的参考实现把每条 fixture 跑一遍，比对期望；
 * 3. 全局守住不变量：恢复只有两种结果（I3）、瞬时事实只有在线态与能力位（I4）、
 *    条目 upsert-only（I9）、中转可被清空（I7）；
 * 4. 覆盖不该影响恢复状态的东西：live 帧不推进游标、不产生条目（契约 §3）。
 *
 * 本层只测**会话层**语义。连接层（握手、fc 计数器、nonce、流控、重放拒绝）不在这里，
 * 由 protocol/vectors 的已知答案向量与各端单测覆盖。
 *
 * 两侧实现（电脑侧插件用 TS、手机端用 Dart）各自对着同一批 fixtures 跑，
 * 不允许任何一侧自己维护一份协议说明。
 */
import { readdirSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { createBridge } from './reference/bridge.mjs'
import { createRelay } from './reference/relay.mjs'
import { ROUTING_KEYS, unseal } from './reference/frame.mjs'
import { decideTakeover } from './reference/takeover.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const FIXTURES_DIR = join(HERE, 'fixtures')

const KNOWN_OPS = new Set([
  'append', 'redeliver', 'hello', 'ack', 'ackSeq', 'snapshotPage',
  'relayEvictAll', 'relayRestart', 'bridgeTrim', 'bridgeRestart', 'sendTwice',
  'setTransient', 'ask', 'answer', 'rebuildPending', 'live', 'takeover',
])
const OUTCOMES = new Set(['delta', 'snapshot'])
const REASONS = new Set(['window-missed', 'revision-newer', 'history-rewritten', 'no-session'])
const SOURCES = new Set(['relay', 'bridge'])

const failures = []
let checks = 0

function check(ok, label, detail) {
  checks += 1
  if (!ok) failures.push(detail ? `${label} → ${detail}` : label)
}

function validateShape(file, fx) {
  for (const key of ['name', 'why', 'bridge', 'relay', 'device', 'steps', 'expect']) {
    check(key in fx, `${file}: 缺少字段 ${key}`)
  }
  if (!Array.isArray(fx.steps) || fx.steps.length === 0) check(false, `${file}: steps 必须是非空数组`)
  for (const [i, step] of (fx.steps ?? []).entries()) {
    check(KNOWN_OPS.has(step.op), `${file}: 第 ${i + 1} 步的 op 未知`, String(step.op))
  }
  for (const [sid, wantOrList] of Object.entries(fx.expect?.recovery ?? {})) {
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

function runFixture(file, fx) {
  const bridge = createBridge(fx.bridge ?? {}, { snapshotPageSize: fx.snapshotPageSize ?? 100 })
  let relay = createRelay(fx.relay?.windowSize ?? 1000)

  const since = { ...(fx.device?.since ?? {}) }   // 手机侧「已落盘」的游标
  const received = { ...since }                    // 手机侧「已收到」的最大序号
  const transient = {}
  const items = new Map()                          // sid -> Map(itemId -> text)
  for (const [sid, seed] of Object.entries(fx.device?.items ?? {})) {
    items.set(sid, new Map(Object.entries(seed)))   // 手机侧本地库里已有的条目
  }
  const requests = new Map()
  const answers = []
  const snapshots = new Map()                      // sid -> { asOfSeq, buffered: Map }
  const takeovers = []
  const liveSeq = new Map()                        // sid -> 收到 live 帧前的修订号
  let liveReceived = 0
  let relayFramesSeen = []

  const itemsOf = (sid) => items.get(sid) ?? new Map()
  const gaps = {}                                  // 前向空洞（契约 §5.4 规则 5）
  const duplicates = {}                            // 重复投递

  /**
   * 接收端规则（契约 §5.4 规则 5）：
   * - 重复帧（seq ≤ 已收到水位）丢弃；
   * - 前向空洞（seq > 水位 + 1）不入库，记一次 gap —— 真实实现据此触发一次 SyncHello。
   */
  const upsert = (sid, itemId, text, seq) => {
    const seen = received[sid] ?? 0
    if (seq <= seen) { duplicates[sid] = (duplicates[sid] ?? 0) + 1; return }
    if (seq > seen + 1) { gaps[sid] = (gaps[sid] ?? 0) + 1; return }
    const map = items.get(sid) ?? new Map()
    map.set(itemId, text)                          // upsert-only：同 itemId 覆盖，不新增
    items.set(sid, map)
    received[sid] = seq
  }

  /** 手机侧落盘水位：只在"渲染/落盘"后推进（快照分页期间不动）。 */
  const commit = (sid, seq) => { since[sid] = Math.max(since[sid] ?? 0, seq) }

  const applyAnswer = (sid, answer) => {
    answers.push({ sid, ...answer })
    transient[sid] = answer.transient
    if (answer.outcome === 'delta') {
      for (const item of answer.items) upsert(sid, item.itemId, item.text, item.seq)
      received[sid] = Math.max(received[sid] ?? 0, answer.to)
      snapshots.delete(sid)
      return
    }
    // 快照：分页期间不落盘、不渲染；每页都累积，期间到达的 ev 一律缓存（契约 §5.4 规则 4）
    const state = snapshots.get(sid) ?? { asOfSeq: answer.asOfSeq, buffered: new Map(), acc: new Map() }
    state.asOfSeq = answer.asOfSeq
    for (const item of answer.items) state.acc.set(item.itemId, { text: item.text, seq: item.seq })
    if (!answer.hasMore) {
      const merged = new Map([...state.acc.entries()].map(([id, entry]) => [id, entry.text]))
      const buffered = [...state.buffered.entries()].sort((a, b) => a[1].seq - b[1].seq)
      for (const [itemId, entry] of buffered) merged.set(itemId, entry.text)
      items.set(sid, merged)
      received[sid] = Math.max(state.asOfSeq, 0, ...[...state.acc.values()].map((e) => e.seq), ...buffered.map(([, e]) => e.seq))
      commit(sid, received[sid])
      snapshots.delete(sid)
    } else {
      snapshots.set(sid, state)
    }
  }

  const recovery = (sid) => {
    const from = (since[sid] ?? 0) + 1
    const latest = bridge.latestSeq(sid)
    const transientNow = bridge.transientOf(sid)
    if (latest === null) {
      return { source: 'bridge', outcome: 'snapshot', reason: 'no-session', asOfSeq: since[sid] ?? 0, hasMore: false, items: [], to: since[sid] ?? 0, transient: transientNow, transientSource: 'bridge' }
    }
    if (since[sid] > latest) {
      const answer = bridge.hello(sid, since[sid])
      return { ...answer, transientSource: 'bridge' }
    }
    if (from <= latest) {
      const served = relay.since(sid, since[sid])
      if (served) {
        // 中转给的是不透明帧，解封发生在手机侧（参考实现里 unseal 就是那个占位）
        return {
          source: 'relay', outcome: 'delta', from, to: latest,
          items: served.frames.map((frame) => ({ seq: frame.seq, ...unseal(frame.box) })),
          transient: transientNow, transientSource: 'bridge',
        }
      }
    }
    const answer = bridge.hello(sid, since[sid])
    return { ...answer, transientSource: 'bridge' }
  }

  for (const step of fx.steps) {
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
        const sids = step.sid ? [step.sid] : Object.keys(since)
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

  relayFramesSeen = relay.routingKeys()

  // ---- 全局规则：恢复只有两种结果，且瞬时事实永远来自电脑侧 ----
  for (const answer of answers) {
    if (process.env.DSH_DEBUG) console.error(`[dbg] ${file} sid=${answer.sid} outcome=${answer.outcome} reason=${answer.reason} source=${answer.source} hasMore=${answer.hasMore} transientSource=${answer.transientSource}`)
    check(OUTCOMES.has(answer.outcome), `${file}: ${answer.sid} 的恢复结果不是两种之一`, answer.outcome)
    if (answer.outcome === 'snapshot') {
      check(REASONS.has(answer.reason), `${file}: ${answer.sid} 的快照原因非法`, String(answer.reason))
      check(Number.isInteger(answer.asOfSeq), `${file}: ${answer.sid} 的快照必须带 asOfSeq`, String(answer.asOfSeq))
      check(typeof answer.hasMore === 'boolean', `${file}: ${answer.sid} 的快照必须带 hasMore`)
    }
    check(answer.transientSource === 'bridge', `${file}: ${answer.sid} 的瞬时事实不是电脑侧给的`)
  }

  // ---- 逐条期望 ----
  for (const [sid, wantOrList] of Object.entries(fx.expect?.recovery ?? {})) {
    const list = Array.isArray(wantOrList) ? wantOrList : [wantOrList]
    const got = answers.filter((a) => a.sid === sid)
    check(got.length === list.length, `${file}: ${sid} 恢复应答次数`, `期望 ${list.length} 次，实际 ${got.length} 次`)
    list.forEach((want, index) => {
      const answer = got[index]
      if (!answer) return
      // 期望里写了什么就断言什么（from/to/reason/asOfSeq/hasMore 一视同仁）
      for (const [key, value] of Object.entries(want)) {
        if (key === 'items') continue
        check(answer[key] === value, `${file}: ${sid} 第 ${index + 1} 次 ${key}`, `期望 ${value}，实际 ${answer[key]}`)
      }
      if (want.outcome === 'delta' && want.items !== undefined) {
        check(answer.items.length === want.items, `${file}: ${sid} 第 ${index + 1} 次增量条目数`, `期望 ${want.items}，实际 ${answer.items.length}`)
      }
    })
  }

  for (const [sid, want] of Object.entries(fx.expect?.items ?? {})) {
    const got = [...itemsOf(sid).keys()].sort()
    check(JSON.stringify(got) === JSON.stringify([...want].sort()), `${file}: ${sid} 可见条目`, `期望 ${want.join(',')}，实际 ${got.join(',')}`)
  }

  for (const [sid, want] of Object.entries(fx.expect?.itemCount ?? {})) {
    check(itemsOf(sid).size === want, `${file}: ${sid} 条目数`, `期望 ${want}，实际 ${itemsOf(sid).size}`)
  }

  /** 电脑侧权威条目数：用于"设备没收到帧"但要在权威侧断言去重效果的场景。 */
  for (const [sid, want] of Object.entries(fx.expect?.bridgeItemCount ?? {})) {
    const size = bridge.itemsOf(sid).size
    check(size === want, `${file}: ${sid} 电脑侧条目数`, `期望 ${want}，实际 ${size}`)
  }

  for (const [sid, want] of Object.entries(fx.expect?.deviceCursor ?? {})) {
    check(since[sid] === want, `${file}: ${sid} 已落盘游标`, `期望 ${want}，实际 ${since[sid]}`)
  }

  for (const [requestId, want] of Object.entries(fx.expect?.requests ?? {})) {
    check(requests.get(requestId) === want, `${file}: 幂等键 ${requestId} 生效次数`, `期望 ${want}，实际 ${requests.get(requestId)}`)
  }

  for (const [sid, want] of Object.entries(fx.expect?.transient ?? {})) {
    const got = transient[sid] ?? {}
    for (const [key, value] of Object.entries(want)) {
      check(got[key] === value, `${file}: ${sid} 瞬时事实 ${key}`, `期望 ${value}，实际 ${got[key]}`)
    }
  }

  if (fx.expect?.pending) {
    for (const [sid, want] of Object.entries(fx.expect.pending)) {
      const got = [...bridge.pendingOf(sid).keys()].sort()
      check(JSON.stringify(got) === JSON.stringify([...want].sort()), `${file}: ${sid} 待审批集合`, `期望 ${want.join(',') || '(空)'}，实际 ${got.join(',') || '(空)'}`)
    }
  }

  if (fx.expect?.takeover) {
    const want = Array.isArray(fx.expect.takeover) ? fx.expect.takeover : [fx.expect.takeover]
    check(takeovers.length === want.length, `${file}: 仲裁判定次数`, `期望 ${want.length}，实际 ${takeovers.length}`)
    want.forEach((w, i) => {
      const got = takeovers[i]
      if (!got) return
      for (const [key, value] of Object.entries(w)) {
        check(got[key] === value, `${file}: 仲裁第 ${i + 1} 次 ${key}`, `期望 ${value}，实际 ${got[key]}`)
      }
    })
  }

  if (fx.expect?.liveIgnored) {
    check(liveReceived > 0, `${file}: 期望至少收到一帧 live`)
    for (const [sid, seqBefore] of liveSeq.entries()) {
      check(bridge.latestSeq(sid) === seqBefore, `${file}: ${sid} live 帧不得改变修订号`, `之前 ${seqBefore}，之后 ${bridge.latestSeq(sid)}`)
    }
    for (const [sid, want] of Object.entries(fx.expect.deviceCursor ?? {})) {
      check(since[sid] === want, `${file}: ${sid} live 帧不得推进落盘水位`, `期望 ${want}，实际 ${since[sid]}`)
    }
  }

  for (const [sid, want] of Object.entries(fx.expect?.gaps ?? {})) {
    check((gaps[sid] ?? 0) === want, `${file}: ${sid} 空洞次数`, `期望 ${want}，实际 ${gaps[sid] ?? 0}`)
  }

  for (const [sid, want] of Object.entries(fx.expect?.duplicates ?? {})) {
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
    const clean = relayFramesSeen.every((keys) => keys.every((k) => ROUTING_KEYS.includes(k)))
    check(clean, `${file}: 中转的路由视图里出现了路由以外的字段`, JSON.stringify(relayFramesSeen))
  }
}

// ---- 主流程 ----
const files = readdirSync(FIXTURES_DIR).filter((f) => f.endsWith('.json')).sort()
check(files.length > 0, 'protocol/fixtures 下没有 fixture')

for (const file of files) {
  const fx = JSON.parse(readFileSync(join(FIXTURES_DIR, file), 'utf8'))
  validateShape(file, fx)
  try {
    runFixture(file, fx)
  } catch (error) {
    check(false, `${file}: 运行抛错`, error.message)
  }
}

if (failures.length > 0) {
  console.error(`FAIL ${failures.length}/${checks} 项不通过（${files.length} 条 fixture）\n`)
  for (const line of failures) console.error(`  - ${line}`)
  process.exit(1)
}
console.log(`ALL CHECKS PASSED — ${checks} 项断言，${files.length} 条 fixture`)
