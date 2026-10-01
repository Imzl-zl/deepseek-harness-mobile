/**
 * 会话适配器的回归（契约 §5、§8）。
 *
 * 这个文件补的是一个**之前没人补的缺口**：`src/dsh/` 下的适配器只有 `caps` 与 `identity`
 * 有测试，`sessions` / `jobs` / `subagents` / `settings` 四份**一个测试都没有**
 * （`layering.test.ts` 只保证它们对着源码写过，不保证行为对）。本轮第一次真正装配
 * 会话适配器，所以先把它的映射钉住；其余三份的缺口记在笔记与 `memory.md` 里。
 *
 * 这里的分工是明确的：**适配器只做映射**（DSH 的形状 → 通道的形状），
 * 所以断言写的都是"哪些字段过来了、哪些没过来、未知帧怎么处理"。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import type { SessionController } from '@deepseek-ai/dsh-api-session-controller'
import type { SessionFollowFrame, SessionSummary } from '@deepseek-ai/dsh-api-session-controller/types'

import { createSessionsAdapter, sessionAddress, type SessionFrame } from '../src/dsh/sessions.js'

/** DSH 的 `SessionController` 是个大 class；测试只假装它用到的那几个方法。 */
function fakeController(overrides: Record<string, unknown>): SessionController {
  return overrides as unknown as SessionController
}

/** DSH 的会话 id 是 branded 类型；测试里把普通字符串标成它。 */
const sid = (value: string): SessionSummary['sessionId'] => value as SessionSummary['sessionId']

const summary = (patch: Partial<SessionSummary> & { sessionId: SessionSummary['sessionId'] }): SessionSummary =>
  ({
    agentAvailable: true,
    updatedAt: 0,
    running: false,
    blank: false,
    // 故意多塞几个 DSH 会有的字段：映射必须**逐字段**，不能把它们带过线。
    projections: { sessionListMetadata: { blank: false, lastPromptAt: 1 } },
    ...patch,
  }) as SessionSummary

test('list：只映射该映射的字段，子代理从 origin 推出，cwd 缺了就不出现', async () => {
  const adapter = createSessionsAdapter(
    fakeController({
      list: () =>
        Promise.resolve({
          items: [
            summary({ sessionId: sid('a'), updatedAt: 300, running: true, cwd: '/repo/a' }),
            summary({ sessionId: sid('b'), updatedAt: 200, origin: 'subagent' }),
            summary({ sessionId: sid('c'), updatedAt: 100, blank: true }),
          ],
        }),
    }),
  )

  const rows = await adapter.list()
  assert.deepEqual(rows, [
    { dshSessionId: 'a', updatedAt: 300, running: true, blank: false, subagent: false, cwd: '/repo/a' },
    { dshSessionId: 'b', updatedAt: 200, running: false, blank: false, subagent: true },
    { dshSessionId: 'c', updatedAt: 100, running: false, blank: true, subagent: false },
  ])
  // 权威自己的顺序就是清单顺序（已按活动排序）—— 本层不再排一遍。
  assert.equal(rows[0]?.dshSessionId, 'a')
  for (const row of rows) {
    assert.equal('agentAvailable' in row, false, 'DSH 的其他字段不该被 spread 过来')
    assert.equal('projections' in row, false)
  }
})

test('list：不传信号时用一个永不中止的信号（不能因此不传）', async () => {
  let signal: AbortSignal | undefined
  const adapter = createSessionsAdapter(
    fakeController({
      list: (_request: unknown, received: AbortSignal) => {
        signal = received
        return Promise.resolve({ items: [] })
      },
    }),
  )

  await adapter.list()
  assert.ok(signal instanceof AbortSignal, 'DSH 的签名要求一个信号')
  assert.equal(signal.aborted, false, '默认信号不该是已中止的')
})

test('follow：三种帧各归各的语义，未知帧跳过而不是让流断掉', async () => {
  const frames: SessionFollowFrame[] = [
    {
      type: 'snapshot',
      cursor: 42,
      header: { id: 'a' },
      records: [],
      hasMore: false,
    } as unknown as SessionFollowFrame,
    { type: 'event', event: { seq: 1 } } as unknown as SessionFollowFrame,
    { type: 'assistant-stream', frame: { revision: 2, index: 0 } } as unknown as SessionFollowFrame,
    // 将来 DSH 加了新帧型：整条订阅流不该因此断掉。
    { type: 'something-new' } as unknown as SessionFollowFrame,
  ]

  const adapter = createSessionsAdapter(
    fakeController({
      follow: () =>
        (async function* () {
          for (const frame of frames) yield frame
        })(),
    }),
  )

  const seen: SessionFrame[] = []
  for await (const frame of adapter.follow(
    { address: sessionAddress('a') },
    new AbortController().signal,
  )) {
    seen.push(frame)
  }

  assert.deepEqual(seen.map((frame) => frame.kind), ['opening', 'event', 'live'])
  assert.equal(seen[0]?.kind === 'opening' ? seen[0].cursor : undefined, 42, '开启帧的 cursor 就是基线水位')
})

test('page / prompt / cancel：把参数按 DSH 的形状递过去', async () => {
  const calls: Record<string, unknown> = {}
  const adapter = createSessionsAdapter(
    fakeController({
      page: (request: unknown) => {
        calls['page'] = request
        return Promise.resolve({ records: [], hasMore: false })
      },
      prompt: (request: unknown, signal: unknown) => {
        calls['prompt'] = request
        calls['promptSignal'] = signal
        return Promise.resolve({ accepted: true })
      },
      cancel: (request: unknown) => {
        calls['cancel'] = request
        return Promise.resolve({ accepted: true })
      },
    }),
  )

  await adapter.page(
    { address: sessionAddress('a'), throughSeq: 42, beforeSeq: 10, maxMessages: 20 },
    new AbortController().signal,
  )
  assert.deepEqual(calls['page'], {
    address: { kind: 'session', sessionId: 'a' },
    throughSeq: 42,
    beforeSeq: 10,
    maxMessages: 20,
  })

  await adapter.prompt('a', 'req-1', [{ type: 'text', text: '你好' }], 'steer')
  assert.deepEqual(calls['prompt'], {
    requestId: 'req-1',
    sessionId: 'a',
    mode: 'steer',
    content: [{ type: 'text', text: '你好' }],
  })
  assert.ok(calls['promptSignal'] instanceof AbortSignal, 'prompt 必须带超时信号（只防挂死）')

  adapter.cancel('a')
  assert.deepEqual(calls['cancel'], { sessionId: 'a' })
})
