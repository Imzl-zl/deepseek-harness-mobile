/**
 * 出站字节**按帧类型记账**的恒等式（纯观测，契约 §1.2）。
 *
 * 这条用例存在的理由是一次真机归因：一次"回前台、什么都没变"出站 230 864 B，
 * 而当时按帧类型拆出来的只有 `ev`（45%）与各方法的 `res`（合计 54%）——
 * **30% 没有任何账本认领**（`status` / `job` / `host` / `presence` / `pong` /
 * `credit` / 握手帧）。根因不是"漏记了某几类"，而是记账点分散在各自发送点上：
 * `credit` / `ping` / 握手帧由连接层自己产生，那些点永远看不见它们。
 *
 * 现在记账收在连接层的唯一出帧点（`emit`），于是有一条**可核对**的性质：
 *
 * ```text
 * Σ connector.bytes.out_frame.*  ===  connector.bytes.outbound
 * ```
 *
 * 这条用例钉的就是它 —— 谁把记账点搬回某个发送点、或新增一条绕过 `emit`
 * 的出帧路径，这里会红，而且会说清差额是多少。
 *
 * 口径是**线上字节**（`encodeFrame` 之后的 UTF-8 长度，含封箱与 base64 放大）：
 * 那正是中转计费与"这一次多贵"要回答的数。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createConnection, type Connection } from '../src/transport/connection.js'
import {
  METRIC,
  createMetrics,
  createOutboundByteMeter,
  outFrameBytesMetric,
} from '../src/observability.js'
import { startPeer, waitFor, type Peer } from './support/peer.js'

const TRANSPORT_DEFAULTS = { heartbeatMs: 5_000, batchMs: 20 } as const

type Metrics = ReturnType<typeof createMetrics>

/** 一条已进 `serving` 的连接（不配 `secure`，免得为了量字节先跑一遍握手）。 */
async function serving(
  t: { after(fn: () => void | Promise<void>): void },
  peer: Peer,
): Promise<{ connection: Connection; metrics: Metrics }> {
  const metrics = createMetrics()
  const connection = createConnection({
    url: peer.url,
    dial: (target) => new WebSocket(target) as never,
    onFrame: () => {},
    // **与生产装配同一个函数**：两份写法会各自漂移，而漂移的症状是
    // "生产上少了 30%，测试里差额是 0"。
    onBytesOut: createOutboundByteMeter(metrics),
    ...TRANSPORT_DEFAULTS,
  })
  t.after(async () => {
    connection.stop()
    await peer.close()
  })
  connection.start()
  // 不配 `secure` 的连接由上层推进握手（`connection.test.ts` 同一手法）：
  // 这组用例量的是字节，不是握手。
  await waitFor('进入 handshake', () => connection.state === 'handshake')
  connection.markHandshakeDone()
  await waitFor('进 serving', () => connection.state === 'serving')
  return { connection, metrics }
}

/** 从快照里取出所有按帧类型的账（去掉前缀），便于求和与查单个类型。 */
function frameBytes(snapshot: Readonly<Record<string, number>>): Map<string, number> {
  const prefix = 'connector.bytes.out_frame.'
  const out = new Map<string, number>()
  for (const [name, value] of Object.entries(snapshot)) {
    if (name.startsWith(prefix)) out.set(name.slice(prefix.length), value)
  }
  return out
}

test('Σ out_frame.* === outbound：每一帧都有人认领，差额恒为 0', async (t) => {
  const peer = await startPeer()
  const { connection, metrics } = await serving(t, peer)

  // 五类**只在某一条路径上出现**的帧，各自发一次：
  // `res`（方法面）、`status` / `host`（挂载级广播）、`job`（任务输出，可攒批）、
  // `ev`（会话事件，可攒批）。
  connection.send({ v: 1, t: 'res', id: 'a', ok: true, box: JSON.stringify({ ok: true }) })
  connection.send({ v: 1, t: 'status', sid: 'sid-1', box: JSON.stringify({ running: true }) })
  connection.send({ v: 1, t: 'host', box: JSON.stringify({ keys: ['session.list'] }) })
  connection.send({ v: 1, t: 'job', sid: 'sid-1', box: JSON.stringify({ kind: 'status' }) })
  connection.send({ v: 1, t: 'ev', sid: 'sid-1', seq: 1, box: JSON.stringify({ type: 'x' }) })
  // 对端发一帧 → 本端回 `credit`：**连接层自己产生的那一类**，正是早先漏掉的。
  // 必须带 `fc`：回执的判据是"收到了一帧已编号的业务帧"（§4.3）。
  peer.send({ v: 1, t: 'pong', id: 'b', fc: 1, box: '' })

  await waitFor('两类可攒批的帧与 credit 都发出去', () => {
    const types = frameBytes(metrics.snapshot())
    return (types.get('job') ?? 0) > 0
      && (types.get('ev') ?? 0) > 0
      && (types.get('credit') ?? 0) > 0
  })

  const snapshot = metrics.snapshot()
  const byType = frameBytes(snapshot)
  const outbound = snapshot[METRIC.bytesOutbound] ?? 0

  // 逐类都在：漏一类就是"这一类又变成无主"。
  for (const type of ['res', 'status', 'host', 'job', 'ev', 'credit'] as const) {
    assert.ok((byType.get(type) ?? 0) > 0, `${type} 帧没有被计入 ${outFrameBytesMetric(type)}`)
  }

  // **恒等式**：总账与逐类账来自同一次 `emit`，差额只能是 0。
  const sum = [...byType.values()].reduce((total, value) => total + value, 0)
  assert.equal(sum, outbound, `逐类合计 ${sum} ≠ 总账 ${outbound}`)
})

test('明文帧同样被计入（`presence` 不上锁，但也是一帧）', async (t) => {
  const peer = await startPeer()
  const { connection, metrics } = await serving(t, peer)

  // `presence` 不经过方法面、也不经过会话订阅 —— 它是早先那 30% 里的一类。
  connection.send({ v: 1, t: 'presence', computer: 'online' })
  await waitFor('presence 发出', () => (frameBytes(metrics.snapshot()).get('presence') ?? 0) > 0)

  const snapshot = metrics.snapshot()
  const byType = frameBytes(snapshot)
  assert.ok((byType.get('presence') ?? 0) > 0)
  const sum = [...byType.values()].reduce((total, value) => total + value, 0)
  assert.equal(sum, snapshot[METRIC.bytesOutbound] ?? 0)
})
