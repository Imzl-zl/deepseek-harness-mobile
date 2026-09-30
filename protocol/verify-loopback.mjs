/**
 * 本机回环：手机 ⇄ 中转 ⇄ 电脑侧桥接，三个角色真实接线跑一遍。
 *
 * 跑法：node protocol/verify-loopback.mjs
 *
 * fixtures 校验的是单场景语义；这里校验三件事，它们只有接上线才看得出来：
 *   1. 在线投递与离线补课的接线（谁转发、谁回答）；
 *   2. **中转全部状态清空后重启**，手机仍能只凭电脑侧数据收敛；
 *   3. 中转对内容是盲的——把一个不是 JSON 的 box 塞进去，路由与补课照常工作。
 *
 * 不测什么（有意不覆盖）：WebSocket 握手、TLS、真实 X25519/AEAD 封装、推送投递。
 * 这些是适配层，属于落地端各自的测试；本文件只认帧层语义。
 */
import { createBridge } from './reference/bridge.mjs'
import { createRelay } from './reference/relay.mjs'
import { unseal } from './reference/frame.mjs'

const failures = []
let checks = 0
function check(ok, label, detail) {
  checks += 1
  if (!ok) failures.push(detail ? `${label} → ${detail}` : label)
}

// ---- 三个角色 ----
const bridge = createBridge({})
let relay = createRelay(50)
const answers = []

const device = {
  online: false,
  since: new Map(),      // 已落盘游标
  items: new Map(),      // sid -> Map(itemId -> text)
  receivedMax: new Map(),
}

const itemsOf = (sid) => device.items.get(sid) ?? new Map()

function upsert(sid, itemId, text, seq) {
  const map = device.items.get(sid) ?? new Map()
  map.set(itemId, text)
  device.items.set(sid, map)
  device.receivedMax.set(sid, Math.max(device.receivedMax.get(sid) ?? 0, seq))
}

/** 电脑侧 → 中转（反向 WS 上行）；中转再按需转发给在线的手机。 */
function push(frame) {
  relay.put(frame)
  if (device.online) deliver(frame)
}

/** 中转 → 手机：手机侧解封，中转只是搬运。 */
function deliver(frame) {
  if (frame.t !== 'ev') return
  upsert(frame.sid, ...Object.values(unseal(frame.box)), frame.seq)
}

/** 手机重连：先问中转窗口；问不到再问电脑侧。瞬时事实永远来自电脑侧。 */
function reconnect(sid) {
  const since = device.since.get(sid) ?? 0
  const served = relay.since(sid, since)
  let answer
  if (served) {
    for (const frame of served.frames) deliver(frame)
    device.receivedMax.set(sid, Math.max(device.receivedMax.get(sid) ?? 0, served.frames.at(-1).seq))
    answer = { sid, source: 'relay', outcome: 'delta', transient: bridge.transientOf(sid), transientSource: 'bridge' }
    // 覆盖空洞（实测）：这里直接取 transient，绕过了 bridge.hello()，所以「瞬时事实必须回带」
    // 在 relay 分支没有覆盖 —— 把 hello 的 transient 置空，本文件仍全绿。
    // 补法：加一条「游标最新且中转窗口为空」强制走桥接分支的用例。
    // 见 .agents/notes/implemented/2026-09-30-channel-review-corrections.md
  } else {
    answer = { sid, ...bridge.hello(sid, since), transientSource: 'bridge' }
    if (answer.outcome === 'delta') {
      for (const item of answer.items) upsert(sid, item.itemId, item.text, item.seq)
    } else {
      device.items.set(sid, new Map(answer.items.map((item) => [item.itemId, item.text])))
      device.since.set(sid, answer.to)
    }
  }
  answers.push(answer)
  return answer
}

function ack(sid) {
  device.since.set(sid, Math.max(device.since.get(sid) ?? 0, device.receivedMax.get(sid) ?? 0))
}

function converged(sid) {
  const mine = [...itemsOf(sid).entries()].sort()
  const theirs = [...bridge.itemsOf(sid).entries()].sort()
  return JSON.stringify(mine) === JSON.stringify(theirs)
}

// ---- 场景 ----

// 1) 手机在线：事件即时到达
device.online = true
push(bridge.append('s1', 'm1', '一'))
push(bridge.append('s1', 'm2', '二'))
check(itemsOf('s1').size === 2, '在线投递', `期望 2 条，实际 ${itemsOf('s1').size}`)
ack('s1')

// 2) 手机离线：事件堆在中转窗口里，重连补课走中转
device.online = false
push(bridge.append('s1', 'm3', '三'))
push(bridge.append('s1', 'm4', '四'))
const first = reconnect('s1')
check(first.source === 'relay', '离线补课走中转窗口', `实际 ${first.source}`)
check(itemsOf('s1').size === 4, '补课后条目数', `实际 ${itemsOf('s1').size}`)
check(converged('s1'), '补课后与电脑侧一致')

// 3) 手机只落盘到 seq=2 就崩了；此时中转被清空并重启
device.since.set('s1', 2)                       // 崩溃前的已落盘游标
relay = createRelay(50)                         // 删掉中转全部业务状态后重启
device.online = true
push(bridge.append('s1', 'm5', '五'))
const second = reconnect('s1')
check(second.source === 'bridge', '中转重启后由电脑侧回答', `实际 ${second.source}`)
check(second.outcome === 'delta' && second.from === 3 && second.to === 5, '增量区间', `${second.from}..${second.to}`)
check(itemsOf('s1').size === 5, '重启后不丢也不重', `实际 ${itemsOf('s1').size}`)
check(converged('s1'), '中转重启后与电脑侧一致')
ack('s1')

// 4) 幂等重发：同一 requestId 经中转送两次，只产生一条消息
const r1 = bridge.send('s1', 'req-1', '你好')
const r2 = bridge.send('s1', 'req-1', '你好')
if (r1) push(r1)
if (r2) push(r2)
check(r2 === null, '第二次同幂等键被拒', String(r2))
check([...itemsOf('s1').keys()].filter((k) => k === 'req:req-1').length === 1, '幂等重发只留一条')

// 5) 瞬时事实不随修订号推进：游标已最新也要回带
bridge.setTransient('s1', { pendingApprovals: 1, computerOnline: true })
const third = reconnect('s1')
check(third.transient?.pendingApprovals === 1, '游标最新时仍回带待审批')
check(third.transientSource === 'bridge', '瞬时事实来自电脑侧')

// 5b) 强制走桥接分支：中转窗口清空 + 游标已最新 ⇒ 只能由 hello() 回答。
// 这条是"瞬时事实必须回带"的**权威断言**：relay 分支会旁路 hello()（见上面注释），
// 只有这里能证明桥接自己回带了瞬时事实。
ack('s1')
relay = createRelay(50)
const fourth = reconnect('s1')
check(fourth.source === 'bridge', '窗口为空时由电脑侧回答', String(fourth.source))
check(fourth.transient?.pendingApprovals === 1, '走桥接分支时仍回带待审批')
check(fourth.transient?.computerOnline === true, '走桥接分支时回带在线态')
check(fourth.transientSource === 'bridge', '瞬时事实必须来自电脑侧，不能由调用方旁路')

// 6) 中转对内容是盲的：塞一个不是 JSON 的 box，路由与补课照常
relay.put({ t: 'ev', sid: 's9', seq: 1, box: '这不是 JSON，中转不该看懂它' })
const blind = relay.since('s9', 0)
check(blind?.frames?.length === 1, '不透明内容照常路由', JSON.stringify(blind))
check(relay.routingKeys().every((keys) => keys.every((k) => ['t', 'sid', 'seq'].includes(k))), '中转路由视图只有路由字段')

// 7) 全局：恢复只有两种结果
for (const answer of answers) {
  check(['delta', 'snapshot'].includes(answer.outcome), '恢复结果是两种之一', String(answer.outcome))
  check(answer.transientSource === 'bridge', '瞬时事实来源', String(answer.transientSource))
}

if (failures.length > 0) {
  console.error(`FAIL ${failures.length}/${checks} 项不通过\n`)
  for (const line of failures) console.error(`  - ${line}`)
  process.exit(1)
}
console.log(`ALL CHECKS PASSED — ${checks} 项断言（回环：手机 ⇄ 中转 ⇄ 电脑侧桥接）`)
