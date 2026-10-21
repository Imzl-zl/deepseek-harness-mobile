/**
 * 会话订阅的回归（契约 §5.3）。
 *
 * 会话面与任务面共用一套骨架（背压/终止/承诺兑现 —— 那些由 `job-subscriptions.test.ts`
 * 与 `subscriptions` 的用例一起兜着），所以这里只钉**会话特有**的四件事：
 * 快照必须逐条展开、`stream` 必须单调、`rev` 用宿主的 `index`、中断**不补** error 帧。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createSessionSubscriptions, type SessionOutbound } from '../src/session-subscriptions.js'
import { createSessionBuffer } from '../src/session-buffer.js'
import type { SessionFrame } from '../src/dsh/sessions.js'
import type { SendOutcome } from '../src/subscriptions.js'
import { createControllableSessionSource } from './support/session-stream.js'

function collector(outcomes: SendOutcome[] = []) {
  const sent: SessionOutbound[] = []
  let index = 0
  return {
    sent,
    send: (frame: SessionOutbound) => {
      const forced = outcomes[index]
      index += 1
      if (forced === 'paused' || forced === 'closed') return forced
      sent.push(frame)
      return 'sent' as const
    },
  }
}

const event = (seq: number): SessionFrame => ({
  kind: 'event',
  event: { type: 'user/message', seq, time: seq } as never,
})

const record = (seq: number): { event: { seq: number } } => ({ event: { seq } })

const opening = (cursor: number, records: number[], hasMore = false): SessionFrame => ({
  kind: 'opening',
  cursor,
  header: { id: 'dsh-1' } as never,
  records: records.map(record) as never,
  hasMore,
})

const flush = (): Promise<void> => new Promise((resolve) => setImmediate(resolve))

test('subscribe：开启快照的补课事件**逐条**展开成 ev，并回水位与 hasMore', async () => {
  const { source, streams, addressOf } = createControllableSessionSource()
  const sink = collector()
  const subscriptions = createSessionSubscriptions({
    source,
    addressOf,
    send: sink.send,
    waitWritable: () => Promise.resolve(),
  })

  const pending = subscriptions.subscribe({ sid: 'sid_1', dshSessionId: 'dsh-1' })
  await flush()
  assert.deepEqual(
    streams[0]?.request,
    { address: { kind: 'session', sessionId: 'dsh-1' }, assistantStream: true },
    '要 assistant 流：否则手机看不到流式输出',
  )

  streams[0]?.push(opening(100, [98, 99, 100], true))
  assert.deepEqual(await pending, { since: 100, hasMore: true }, '水位与"还有更早的历史"都要回给手机')
  assert.deepEqual(
    sink.sent.map((frame) => [frame.t, frame.t === 'ev' ? frame.seq : undefined]),
    [
      ['ev', 98],
      ['ev', 99],
      ['ev', 100],
    ],
    '少发一条补课事件，手机从旧水位恢复时就丢一条事件',
  )
})

test('subscribe：后续事件继续走 ev；assistant 流用**电脑侧分配**的 stream 与宿主的 index 当 rev', async () => {
  const { source, streams, addressOf } = createControllableSessionSource()
  const sink = collector()
  const subscriptions = createSessionSubscriptions({
    source,
    addressOf,
    send: sink.send,
    waitWritable: () => Promise.resolve(),
  })

  const pending = subscriptions.subscribe({ sid: 'sid_1', dshSessionId: 'dsh-1' })
  await flush()
  streams[0]?.push(opening(5, []))
  await pending

  streams[0]?.push(event(6))
  streams[0]?.push({
    kind: 'live',
    frame: { type: 'start', attemptId: 'att-1', revision: 1, startedAfterSeq: 6, turn: 1, step: 0 } as never,
  })
  streams[0]?.push({
    kind: 'live',
    frame: { type: 'chunk', attemptId: 'att-1', revision: 1, index: 1, time: 10, chunk: { text: '你' } } as never,
  })
  streams[0]?.push({
    kind: 'live',
    frame: { type: 'chunk', attemptId: 'att-1', revision: 1, index: 2, time: 11, chunk: { text: '好' } } as never,
  })
  await flush()

  const live = sink.sent.filter((frame) => frame.t === 'live')
  assert.deepEqual(live.map((frame) => frame.rev), [0, 1, 2], 'rev 必须 +1 递增（手机侧据此追加）')
  assert.deepEqual(
    live.map((frame) => frame.stream),
    [1, 1, 1],
    '一次尝试一条流',
  )
  // 换了尝试就换号（手机侧判据是"号变大 ⇒ 换流"）。
  streams[0]?.push({
    kind: 'live',
    frame: { type: 'start', attemptId: 'att-2', revision: 2, startedAfterSeq: 7, turn: 2, step: 0 } as never,
  })
  await flush()
  assert.deepEqual(
    sink.sent.filter((frame) => frame.t === 'live').map((frame) => frame.stream),
    [1, 1, 1, 2],
  )
})

test('重订走增量：缓冲覆盖得到就补发那一段，并跳过快照里重复的 seq', async () => {
  const { source, streams, addressOf } = createControllableSessionSource()
  const sink = collector()
  const buffer = createSessionBuffer({ pairedDevices: () => ['dev-1'] })
  const subscriptions = createSessionSubscriptions({
    source,
    addressOf,
    send: sink.send,
    waitWritable: () => Promise.resolve(),
    buffer,
  })

  // 第一次订阅：快照给了 1、2，随后又来一条 3。这三条都进了缓冲（发之前记）。
  const first = subscriptions.subscribe({ sid: 'sid_1', dshSessionId: 'dsh-1' })
  await flush()
  streams[0]?.push(opening(2, [1, 2]))
  await first
  streams[0]?.push(event(3))
  await flush()
  assert.deepEqual(
    sink.sent.filter((frame) => frame.t === 'ev').map((frame) => (frame.t === 'ev' ? frame.seq : 0)),
    [1, 2, 3],
  )

  // 断线重连（订阅没了，缓冲还在）：手机报它手里的水位是 2。
  subscriptions.unsubscribe('sid_1')
  const again = subscriptions.subscribe({ sid: 'sid_1', dshSessionId: 'dsh-1', since: 2 })
  await flush()
  assert.equal(streams.length, 2, '重订要开新的会话流')

  // 宿主的快照**不知道我们手里有什么**：它照样给 1、2、3。重复的必须按 seq 跳掉。
  streams[1]?.push(opening(3, [1, 2, 3]))
  assert.deepEqual(await again, { since: 3, hasMore: false })
  await flush()

  const seqsAfterResume = sink.sent
    .filter((frame) => frame.t === 'ev')
    .map((frame) => (frame.t === 'ev' ? frame.seq : 0))
  assert.deepEqual(seqsAfterResume, [1, 2, 3, 3], '补发的那条 3 只出现一次；快照里的 1..3 全被跳过')
  assert.deepEqual(
    buffer.tailFrom('sid_1', 2)?.map((item) => item.seq),
    [3],
    '补发过的内容仍在缓冲里（裁剪权在手机手里）',
  )
})

test('subscribe：中断**不补** error 帧（会话内容有持久副本，重订即自愈）', async () => {
  const { source, streams, addressOf } = createControllableSessionSource()
  const sink = collector()
  const subscriptions = createSessionSubscriptions({
    source,
    addressOf,
    send: sink.send,
    waitWritable: () => Promise.resolve(),
  })

  const pending = subscriptions.subscribe({ sid: 'sid_1', dshSessionId: 'dsh-1' })
  await flush()
  streams[0]?.push(opening(1, []))
  await pending

  const before = sink.sent.length
  streams[0]?.fail(new Error('宿主内部炸了'))
  await flush()
  await flush()
  assert.equal(sink.sent.length, before, '会话面不发明中断帧（这一点与任务输出**刻意不同**）')
  assert.equal(subscriptions.active, 0, '条目要清掉')
})

test('subscribe 幂等 / unsubscribe：同一会话不重开流，退订即中止', async () => {
  const { source, streams, addressOf } = createControllableSessionSource()
  const sink = collector()
  const subscriptions = createSessionSubscriptions({
    source,
    addressOf,
    send: sink.send,
    waitWritable: () => Promise.resolve(),
  })

  const first = subscriptions.subscribe({ sid: 'sid_1', dshSessionId: 'dsh-1' })
  await flush()
  streams[0]?.push(opening(42, []))
  assert.deepEqual(await first, { since: 42, hasMore: false })

  const again = subscriptions.subscribe({ sid: 'sid_1', dshSessionId: 'dsh-1' })
  assert.deepEqual(await again, { since: 42, hasMore: false }, '幂等：回同一个水位')
  assert.equal(streams.length, 1, '不该开第二条会话流')

  // 给了不同的 since：换流（手机明确要求从别处恢复）。
  const resumed = subscriptions.subscribe({ sid: 'sid_1', dshSessionId: 'dsh-1', since: 7 })
  await flush()
  assert.equal(streams.length, 2)
  assert.equal(streams[0]?.signal.aborted, true)
  streams[1]?.push(opening(7, []))
  assert.deepEqual(await resumed, { since: 7, hasMore: false })

  assert.equal(subscriptions.unsubscribe('sid_1'), true)
  assert.equal(streams[1]?.signal.aborted, true, '退订必须真的中止会话流')
  assert.equal(subscriptions.unsubscribe('sid_1'), false)
  assert.equal(subscriptions.active, 0)
})

test('subscribe：子会话用**带父级**的地址（否则宿主只回一句拒绝，手机进去一片空白）', async () => {
  // 宿主原文 "subagent Sessions require their durable parent address"
  // （`session-controller/src/history.ts:347-352`）。2026-10-21 真机：子会话白屏。
  const { source, streams, addressOf } = createControllableSessionSource({
    subagents: { 'dsh-child': 'dsh-parent' },
  })
  const sink = collector()
  const subscriptions = createSessionSubscriptions({
    source,
    addressOf,
    send: sink.send,
    waitWritable: () => Promise.resolve(),
  })

  const pending = subscriptions.subscribe({ sid: 'sid_c', dshSessionId: 'dsh-child' })
  await flush()
  assert.deepEqual(
    streams[0]?.request.address,
    {
      kind: 'subagent',
      parentSessionId: 'dsh-parent',
      childSessionId: 'dsh-child',
      mode: 'unknown',
    },
    '子会话的地址必须带父级；mode 用 unknown（跳过模式校验，不用先读 catalog）',
  )
  streams[0]?.push(opening(3, []))
  await pending
})
