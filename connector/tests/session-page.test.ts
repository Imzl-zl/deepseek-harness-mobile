/**
 * 会话翻页与单条目补取的回归（契约 §5.3）。
 *
 * 这一层的关键是**两个数字的边界**：超过 1 MiB 的条目换成标记（否则大图会把一帧撑爆），
 * 而超过 8 MiB 的东西**绝不发出**（发出即被对端按 `protocol/bad-frame` 关连接）。
 * 阈值做成可注入的，所以测试不必真的造一个 1 MiB 的载荷。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createSessionPager } from '../src/session-page.js'
import type { SessionHistoryRecord } from '@deepseek-ai/dsh-api-session-controller/types'
import { ProtocolError } from '../src/protocol/errors.js'
import type { PageRequest, SessionsPort } from '../src/dsh/sessions.js'
import type { SessionPage } from '@deepseek-ai/dsh-api-session-controller/types'

const record = (seq: number, text = 'x'): SessionHistoryRecord =>
  ({ event: { type: 'user/message', seq, time: seq, text } }) as unknown as SessionHistoryRecord

/**
 * 会话端口替身：`page` 记下每次请求，`list` 供地址解析用
 * （`resolveSessionAddress` 要按清单行判"是不是子会话"）。
 *
 * `subagents` 给"子会话 id → 父会话 id"；缺省时一切都是普通会话。
 */
function fakeSessions(
  answers: SessionPage[],
  subagents: Record<string, string> = {},
): { port: SessionsPort; requests: PageRequest[] } {
  const requests: PageRequest[] = []
  const port = {
    list: () =>
      Promise.resolve(
        Object.entries(subagents).map(([dshSessionId, parentSessionId]) => ({
          dshSessionId,
          updatedAt: 0,
          running: false,
          blank: false,
          subagent: true,
          parentSessionId,
        })),
      ),
    page: (request: PageRequest) => {
      requests.push(request)
      const next = answers.shift()
      if (next === undefined) throw new Error('替身没有准备这么多页')
      return Promise.resolve(next)
    },
  } as unknown as SessionsPort
  return { port, requests }
}

test('page：用缓存的开启帧水位当 throughSeq，并把参数原样递给 DSH', async () => {
  const { port, requests } = fakeSessions([{ records: [record(1), record(2)], hasMore: true }])
  const pager = createSessionPager({ sessions: port, cursorOf: () => 42 })

  const page = await pager.page({ sid: 'sid_1', dshSessionId: 'dsh-1', beforeSeq: 10, maxMessages: 20 })
  assert.equal(page.throughSeq, 42, '回给手机的也是这个切点（它下次翻页继续用）')
  assert.equal(page.hasMore, true)
  assert.deepEqual(
    page.items.map((item) => (item.kind === 'record' ? item.record.event.seq : -1)),
    [1, 2],
  )
  assert.equal(requests[0]?.throughSeq, 42)
  assert.equal(requests[0]?.beforeSeq, 10)
  assert.equal(requests[0]?.maxMessages, 20)
})

test('page：没有水位就回 session/window-missed（那是"走快照刷新"的码），绝不猜一个', async () => {
  const { port, requests } = fakeSessions([])
  const pager = createSessionPager({ sessions: port, cursorOf: () => undefined })

  await assert.rejects(
    () => pager.page({ sid: 'sid_1', dshSessionId: 'dsh-1' }),
    (error: unknown) => error instanceof ProtocolError && error.code === 'session/window-missed',
  )
  assert.equal(requests.length, 0, '没有水位就根本不该去读盘')
})

test('page：超过阈值的条目换成 refetch 标记（大图不该把一帧撑爆）', async () => {
  const small = record(1, 'small')
  const { port } = fakeSessions([
    { records: [small, record(2, 'B'.repeat(64))], hasMore: false },
  ])
  // 阈值取"正好放得下第一条"：不写死数字，免得 payload 形状一变测试就失去意义。
  const threshold = Buffer.byteLength(JSON.stringify(small), 'utf8') + 10
  const pager = createSessionPager({
    sessions: port,
    cursorOf: () => 7,
    refetchThresholdBytes: threshold,
  })

  const page = await pager.page({ sid: 'sid_1', dshSessionId: 'dsh-1' })
  assert.deepEqual(
    page.items.map((item) => item.kind),
    ['record', 'refetch'],
  )
  const marker = page.items[1]
  assert.ok(marker?.kind === 'refetch')
  assert.equal(marker.seq, 2, '标记要带 seq：手机靠它来补取')
  assert.equal(marker.bytes > threshold, true, '把真实字节数也给它（便于显示"这条很大"）')
})

test('refetch：按 seq 取回那一条（对齐到它所在的消息），并原样返回', async () => {
  const { port, requests } = fakeSessions([{ records: [record(9, 'big one')], hasMore: false }])
  const pager = createSessionPager({ sessions: port, cursorOf: () => 100 })

  const fetched = await pager.refetch({ sid: 'sid_1', dshSessionId: 'dsh-1', seq: 9 })
  assert.equal(fetched.record.event.seq, 9)
  assert.equal(requests[0]?.throughSeq, 100, '切点取"水位与 seq 的较大者"（不能超过水位）')
  assert.equal(requests[0]?.beforeSeq, 10, '按消息对齐：把 beforeSeq 放到它后面')
  assert.equal(requests[0]?.maxMessages, 1)
})

test('refetch：补取回来的仍然超过单帧硬上限 → 回 internal，而不是制造一次必然的断连', async () => {
  const { port } = fakeSessions([{ records: [record(9, 'B'.repeat(80))], hasMore: false }])
  const pager = createSessionPager({
    sessions: port,
    cursorOf: () => 100,
    maxFrameBytes: 40,
  })

  await assert.rejects(
    () => pager.refetch({ sid: 'sid_1', dshSessionId: 'dsh-1', seq: 9 }),
    (error: unknown) => error instanceof ProtocolError && error.code === 'internal',
  )
})

test('refetch：取不到那一条 → session/not-found', async () => {
  const { port } = fakeSessions([{ records: [], hasMore: false }])
  const pager = createSessionPager({ sessions: port, cursorOf: () => 5 })

  await assert.rejects(
    () => pager.refetch({ sid: 'sid_1', dshSessionId: 'dsh-1', seq: 3 }),
    (error: unknown) => error instanceof ProtocolError && error.code === 'session/not-found',
  )
})

test('page / refetch：子会话翻页也要带父级地址（与 follow 同一条规则）', async () => {
  // 只修 `follow` 不修 `page` 的话，子会话能看见内容但**翻不动历史** ——
  // 同一类地址规则，两处都得走。
  const { port, requests } = fakeSessions(
    [
      { records: [record(1)], hasMore: false },
      { records: [record(2)], hasMore: false },
    ],
    { 'dsh-child': 'dsh-parent' },
  )
  const pager = createSessionPager({ sessions: port, cursorOf: () => 30 })

  await pager.page({ sid: 'sid_c', dshSessionId: 'dsh-child' })
  assert.deepEqual(requests[0]?.address, {
    kind: 'subagent',
    parentSessionId: 'dsh-parent',
    childSessionId: 'dsh-child',
    mode: 'unknown',
  })

  await pager.refetch({ sid: 'sid_c', dshSessionId: 'dsh-child', seq: 2 })
  assert.deepEqual(requests[1]?.address, {
    kind: 'subagent',
    parentSessionId: 'dsh-parent',
    childSessionId: 'dsh-child',
    mode: 'unknown',
  })
})
