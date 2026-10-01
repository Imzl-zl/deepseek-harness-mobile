/**
 * 任务输出订阅的回归（契约 §5.3）。
 *
 * 这一层的每条规则都对应一种"只在真机上偶发"的形状，所以断言写的是**行为次数与顺序**：
 * 宿主流开了几条、某一帧有没有被重发、被替换之后旧流还出不出帧、承诺会不会永远挂着。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createJobSubscriptions } from '../src/job-subscriptions.js'
import type { SendOutcome } from '../src/subscriptions.js'
import type { JobOutputFrame } from '../src/protocol/job-output.js'
import { createControllableSource } from './support/job-stream.js'

const opened = (jobId: string, from = 0): JobOutputFrame => ({
  kind: 'opened',
  jobId,
  from,
  job: { id: jobId, kind: 'shell', label: jobId, status: 'running', startedAt: 0, outputTotal: 0 },
})

const output = (jobId: string, text: string, next: number): JobOutputFrame => ({
  kind: 'output',
  jobId,
  chunks: [{ at: next - text.length, text }],
  next,
})

const status = (jobId: string): JobOutputFrame => ({
  kind: 'status',
  job: {
    id: jobId,
    kind: 'shell',
    label: jobId,
    status: 'completed',
    startedAt: 0,
    outputTotal: 9,
    finishedAt: 5,
  },
  jobId,
})

/** 收集出帧，并可按需把某一帧判成"满窗"。 */
function collector(outcomes: SendOutcome[] = []) {
  const sent: JobOutputFrame[] = []
  let index = 0
  return {
    sent,
    send: (_sid: string, frame: JobOutputFrame): SendOutcome => {
      const forced = outcomes[index]
      index += 1
      if (forced === 'paused' || forced === 'closed') return forced
      sent.push(frame)
      return 'sent'
    },
  }
}

const flush = (): Promise<void> => new Promise((resolve) => setImmediate(resolve))

test('follow：等宿主的 opened 帧，把起点回给手机', async () => {
  const { source, streams } = createControllableSource()
  const sink = collector()
  const subscriptions = createJobSubscriptions({
    source,
    send: sink.send,
    waitWritable: () => Promise.resolve(),
  })

  const pending = subscriptions.follow({ sid: 'sid_1', dshSessionId: 'dsh-1', jobId: 'j1' })
  await flush()
  assert.equal(streams.length, 1, '应当开了恰好一条宿主流')
  assert.deepEqual(streams[0]?.request, { dshSessionId: 'dsh-1', jobId: 'j1' }, 'from 没给就不带')

  streams[0]?.push(opened('j1', 7))
  assert.deepEqual(await pending, { from: 7 })
  assert.equal(sink.sent.length, 1, '开启帧本身也要转给手机')
})

test('follow 幂等：同一个任务重复 follow 不重开流（否则同一段输出推两遍）', async () => {
  const { source, streams } = createControllableSource()
  const sink = collector()
  const subscriptions = createJobSubscriptions({
    source,
    send: sink.send,
    waitWritable: () => Promise.resolve(),
  })

  const first = subscriptions.follow({ sid: 'sid_1', dshSessionId: 'dsh-1', jobId: 'j1' })
  await flush()
  streams[0]?.push(opened('j1', 3))
  assert.deepEqual(await first, { from: 3 })

  const again = subscriptions.follow({ sid: 'sid_1', dshSessionId: 'dsh-1', jobId: 'j1' })
  assert.deepEqual(await again, { from: 3 }, '幂等：回同一个起点')
  assert.equal(streams.length, 1, '不该开第二条宿主流')
  assert.equal(subscriptions.active, 1)
})

test('follow 换起点：先终止旧订阅，且旧流之后取的帧**不许**再出', async () => {
  const { source, streams } = createControllableSource()
  const sink = collector()
  const subscriptions = createJobSubscriptions({
    source,
    send: sink.send,
    waitWritable: () => Promise.resolve(),
  })

  const first = subscriptions.follow({ sid: 'sid_1', dshSessionId: 'dsh-1', jobId: 'j1' })
  await flush()
  streams[0]?.push(opened('j1', 0))
  await first

  const second = subscriptions.follow({
    sid: 'sid_1',
    dshSessionId: 'dsh-1',
    jobId: 'j1',
    from: 100,
  })
  await flush()
  assert.equal(streams.length, 2, '换了起点就换一条流')
  assert.equal(streams[0]?.signal.aborted, true, '旧流必须被中止')

  // 旧流上"已经在路上"的一帧：代数令牌必须拦住它（否则手机的 next 会倒退）。
  const before = sink.sent.length
  streams[0]?.push(output('j1', '旧流的尾巴', 50))
  await flush()
  assert.equal(sink.sent.length, before, '旧订阅的帧不许再出')

  streams[1]?.push(opened('j1', 100))
  assert.deepEqual(await second, { from: 100 })

  // 旧循环的 `finally` 必须**只清自己那一格**：早期版本无条件 `delete(key)`，
  // 会把后来者的条目一起删掉（订阅静悄悄地没了，而手机以为还在推）。
  await flush()
  await flush()
  assert.equal(subscriptions.active, 1, '被替换之后，新的订阅必须还在')
  assert.equal(streams[1]?.signal.aborted, false, '新流不该被旧循环收尾时误伤')
})

test('卡在满窗等待时被收起：旧订阅不发那一帧（靠 abort，不靠"我还是不是当前那一个"）', async () => {
  const { source, streams } = createControllableSource()
  // 第一帧（opened）判成满窗，于是循环会停在 `waitWritable` 上。
  const sink = collector(['paused'])
  let release: () => void = () => {}
  const subscriptions = createJobSubscriptions({
    source,
    send: sink.send,
    waitWritable: () =>
      new Promise<void>((resolve) => {
        release = resolve
      }),
  })

  const pending = subscriptions.follow({ sid: 'sid_1', dshSessionId: 'dsh-1', jobId: 'j1' })
  await flush()
  streams[0]?.push(opened('j1', 0))
  await flush()
  assert.equal(sink.sent.length, 0, '构造前提：那一帧正卡在满窗等待里')

  // 手机收起了面板（或连接断了）：条目清掉并中止。
  assert.equal(subscriptions.unfollow('sid_1', 'j1'), true)
  release()
  await flush()
  await flush()

  assert.equal(sink.sent.length, 0, '被收起之后那一帧不许再补发出去')
  assert.equal(subscriptions.active, 0)
})

test('背压：满窗时重发**同一帧**，且不丢帧、顺序不变', async () => {
  const { source, streams } = createControllableSource()
  // 第一帧（opened）被判成满窗两次，然后放行。
  const sink = collector(['paused', 'paused'])
  let waits = 0
  const subscriptions = createJobSubscriptions({
    source,
    send: sink.send,
    waitWritable: () => {
      waits += 1
      return Promise.resolve()
    },
  })

  const pending = subscriptions.follow({ sid: 'sid_1', dshSessionId: 'dsh-1', jobId: 'j1' })
  await flush()
  streams[0]?.push(opened('j1', 0))
  streams[0]?.push(output('j1', '第二帧', 9))

  // 等它把这一帧发出去（paused 两次 → 第三次 sent）。
  assert.deepEqual(await pending, { from: 0 })
  await flush()
  assert.equal(waits, 2, '被判满窗两次就该等两次')
  assert.deepEqual(
    sink.sent.map((frame) => frame.kind),
    ['opened', 'output'],
    '同一帧重发而不是跳过：顺序与条数都不变',
  )
})

test('连接不在服务态：收工（不重试、不报错），条目清掉', async () => {
  const { source, streams } = createControllableSource()
  const sink = collector(['sent', 'closed'])
  const subscriptions = createJobSubscriptions({
    source,
    send: sink.send,
    waitWritable: () => Promise.resolve(),
  })

  const pending = subscriptions.follow({ sid: 'sid_1', dshSessionId: 'dsh-1', jobId: 'j1' })
  await flush()
  streams[0]?.push(opened('j1', 0))
  streams[0]?.push(output('j1', '发不出去的一帧', 9))
  await pending
  await flush()
  await flush()

  assert.equal(subscriptions.active, 0, '连接没了就该收工')
  assert.equal(sink.sent.length, 1, '被拒的那一帧不该出现在已发列表里')
})

test('结算：status 之后循环收口，条目自动清掉', async () => {
  const { source, streams } = createControllableSource()
  const sink = collector()
  const subscriptions = createJobSubscriptions({
    source,
    send: sink.send,
    waitWritable: () => Promise.resolve(),
  })

  const pending = subscriptions.follow({ sid: 'sid_1', dshSessionId: 'dsh-1', jobId: 'j1' })
  await flush()
  streams[0]?.push(opened('j1', 0))
  streams[0]?.push(output('j1', '收尾', 9))
  streams[0]?.push(status('j1'))
  streams[0]?.end()
  await pending
  await flush()

  assert.deepEqual(sink.sent.map((frame) => frame.kind), ['opened', 'output', 'status'])
  assert.equal(subscriptions.active, 0, '结算之后不必再重订')
})

test('宿主流抛错：发一帧 error（手机要显式渲染中断），条目清掉', async () => {
  const { source, streams } = createControllableSource()
  const sink = collector()
  const subscriptions = createJobSubscriptions({
    source,
    send: sink.send,
    waitWritable: () => Promise.resolve(),
  })

  const pending = subscriptions.follow({ sid: 'sid_1', dshSessionId: 'dsh-1', jobId: 'j1' })
  await flush()
  streams[0]?.push(opened('j1', 0))
  await pending
  streams[0]?.fail(new Error('宿主内部炸了'))
  await flush()
  await flush()

  const last = sink.sent.at(-1)
  assert.equal(last?.kind, 'error')
  assert.match(
    last?.kind === 'error' ? last.message : '',
    /实时输出流中断：宿主内部炸了/,
    '宿主没有 error 帧，通道得自己造一条（设计要求手机显式渲染中断）',
  )
  assert.equal(subscriptions.active, 0)
})

test('流结束但没给 status：发一帧 error（不许静默收尾）', async () => {
  const { source, streams } = createControllableSource()
  const sink = collector()
  const subscriptions = createJobSubscriptions({
    source,
    send: sink.send,
    waitWritable: () => Promise.resolve(),
  })

  const pending = subscriptions.follow({ sid: 'sid_1', dshSessionId: 'dsh-1', jobId: 'j1' })
  await flush()
  streams[0]?.push(opened('j1', 0))
  await pending
  streams[0]?.end() // 正常结束，但没有结算帧
  await flush()
  await flush()

  assert.equal(sink.sent.at(-1)?.kind, 'error', '沉默地结束会让手机以为任务还在跑')
})

test('挂起的承诺必须被兑现：unfollow / stopAll 都要拒绝它（否则方法面永远挂着）', async () => {
  const { source } = createControllableSource()
  const sink = collector()
  const subscriptions = createJobSubscriptions({
    source,
    send: sink.send,
    waitWritable: () => Promise.resolve(),
  })

  // 1) 等到 opened 之前就 unfollow。
  const first = subscriptions.follow({ sid: 'sid_1', dshSessionId: 'dsh-1', jobId: 'j1' })
  await flush()
  assert.equal(subscriptions.unfollow('sid_1', 'j1'), true)
  await assert.rejects(() => first, /订阅已终止/)
  assert.equal(subscriptions.unfollow('sid_1', 'j1'), false, '第二次没有可终止的')

  // 2) 等到 opened 之前就 stopAll。
  const second = subscriptions.follow({ sid: 'sid_1', dshSessionId: 'dsh-1', jobId: 'j2' })
  const third = subscriptions.follow({ sid: 'sid_2', dshSessionId: 'dsh-2', jobId: 'j3' })
  await flush()
  assert.equal(subscriptions.active, 2)
  subscriptions.stopAll()
  await assert.rejects(() => second, /订阅已终止/)
  await assert.rejects(() => third, /订阅已终止/)
  assert.equal(subscriptions.active, 0, 'stopAll 之后一个都不该留')
})
