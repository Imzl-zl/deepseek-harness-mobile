/**
 * 后台任务适配器的回归（契约 §7）。
 *
 * 这份适配器把三个**反直觉**点固化成端口契约，所以断言也围着它们转：
 *
 * 1. `list(caller)` 会把**无主任务并进每个会话** —— 端口必须自己再排一遍；
 * 2. `read`（而不是 `readAt`）会把**模型的游标推到底**，等于吞掉模型该看的输出 ——
 *    端口只暴露非消耗式的 `readAt`，且 `caller` 是**第三个**参数；
 * 3. `events.subscribe` **没有合并窗口**，且无主事件有两种形状（`job.owner` 与事件自己的 `owner`）。
 *
 * 这三条都是"写错不会报错、只会表现成内容错乱"的那类，所以逐条钉。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import type { JobEvent, JobRegistry, JobView } from '@deepseek-ai/dsh-jobs'

import { createJobsPort } from '../src/dsh/jobs.js'

/** DSH 的 `JobId` 是 branded 类型；测试里把普通字符串标成它。 */
const jobId = (value: string): JobView['id'] => value as JobView['id']

const view = (patch: Omit<Partial<JobView>, 'id'> & { id: string }): JobView =>
  ({
    kind: 'shell',
    label: patch.id,
    status: 'running',
    startedAt: 0,
    output: { total: 0 },
    ...patch,
    id: jobId(patch.id),
  }) as JobView

function fakeRegistry(overrides: Record<string, unknown>): JobRegistry {
  return overrides as unknown as JobRegistry
}

test('listOwnedBy：排掉无主任务（list(caller) 会把它们并进每个会话）', () => {
  const calls: unknown[] = []
  const port = createJobsPort(
    fakeRegistry({
      list: (caller: unknown) => {
        calls.push(caller)
        return [
          view({ id: 'j1', owner: { id: 'sess-1' } as never, progress: '2/5' }),
          // 无主：`list(caller)` 会把它一起返回。
          view({ id: 'j-orphan' }),
          view({ id: 'j2', owner: { id: 'sess-1' } as never, finishedAt: 99, detail: 'ok' }),
        ]
      },
    }),
  )

  const rows = port.listOwnedBy('sess-1')
  assert.deepEqual(rows.map((row) => row.id), ['j1', 'j2'], '无主任务不算"属于本会话"')
  assert.deepEqual(calls, ['sess-1'], 'caller 必须传：不传只返回无主任务，不是全集')
  // 逐字段映射：缺的键不出现。
  assert.deepEqual(rows[0], {
    id: 'j1',
    kind: 'shell',
    label: 'j1',
    status: 'running',
    startedAt: 0,
    outputTotal: 0,
    progress: '2/5',
  })
  assert.deepEqual(Object.keys(rows[1] ?? {}).sort(), [
    'detail',
    'finishedAt',
    'id',
    'kind',
    'label',
    'outputTotal',
    'startedAt',
    'status',
  ])
})

test('readOutput：走 readAt（非消耗式），caller 是第三个参数，lossy 如实上报', () => {
  const calls: unknown[][] = []
  const port = createJobsPort(
    fakeRegistry({
      readAt: (...args: unknown[]) => {
        calls.push(args)
        return { chunks: [{ text: 'hi' }], next: 12, lossy: true }
      },
    }),
  )

  const output = port.readOutput('j1', 4, 'sess-1')
  assert.deepEqual(calls, [['j1', 4, 'sess-1']], 'readAt(id, from, caller) —— caller 在第三位')
  assert.deepEqual(output, { chunks: [{ text: 'hi' }], next: 12, lossy: true })
  assert.equal(output.lossy, true, '有缺口必须显式上报，不许静默拼接')
})

test('kill：原样转达，返回受理与否（不乐观更新）', () => {
  const calls: unknown[][] = []
  const port = createJobsPort(
    fakeRegistry({
      kill: (...args: unknown[]) => {
        calls.push(args)
        return args[0] === 'j-done' ? 'already-finished' : 'requested'
      },
    }),
  )

  assert.equal(port.kill('j1', 'sess-1'), 'requested')
  assert.equal(port.kill('j-done', 'sess-1'), 'already-finished')
  assert.deepEqual(calls, [
    ['j1', 'sess-1'],
    ['j-done', 'sess-1'],
  ])
})

test('subscribe：无主事件两种形状都要排掉（含 output —— 它把 owner 放在事件自己身上）', () => {
  let deliver: (event: JobEvent) => void = () => {}
  let disposed = 0
  const port = createJobsPort(
    fakeRegistry({
      events: {
        subscribe: (_filter: unknown, listener: (event: JobEvent) => void) => {
          deliver = listener
          return () => {
            disposed += 1
          }
        },
      },
    }),
  )

  const seen: JobEvent[] = []
  const unsubscribe = port.subscribe('sess-1', (event) => seen.push(event))

  const events: JobEvent[] = [
    { type: 'progress', job: view({ id: 'j1', owner: { id: 'sess-1' } as never }) },
    // 无主 + 有 job：排掉。
    { type: 'progress', job: view({ id: 'j-orphan' }) },
    { type: 'settled', job: view({ id: 'j-orphan' }), cause: 'kill', awaited: false } as JobEvent,
    // 无主 + owner 在事件自己身上：**同样要排掉** —— 漏了它，无主任务的输出会插进每个会话。
    { type: 'output', id: jobId('j-orphan'), total: 10 } as JobEvent,
    { type: 'output', id: jobId('j1'), owner: { id: 'sess-1' } as never, total: 12 } as JobEvent,
  ]
  for (const event of events) deliver(event)

  assert.deepEqual(
    seen.map((event) => (event.type === 'output' ? `output:${event.id}` : `job:${event.job.id}`)),
    ['job:j1', 'output:j1'],
  )

  unsubscribe()
  assert.equal(disposed, 1, '退订要把注册器给的 disposer 转出去')
})
