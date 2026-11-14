/**
 * `session.list` 的分页（契约 §5.7）：**切一段、说清还有没有、别名只给发出去的行**。
 *
 * ## 这一组守什么
 *
 * 一次标题变更原本要重取整表（本机 351 行 ~250 KB）。分页之后请求多了
 * `{limit?, offset?}`、应答多了 `hasMore`，三件事必须钉住：
 *
 * 1. **不传 `limit` = 整表**（老手机的行为一个字不变，`hasMore: false`）；
 * 2. **切在分配别名之前** —— 没发出去的行不许在别名表里留条目，
 *    否则每翻一页都给整表铸一遍别名，分页省下的字节又拿 CPU 还回去；
 * 3. **`hasMore` 按宿主的整份清单算**（不是按 `limit` 的倍数），
 *    手机据此决定还要不要显示"加载更多"。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { ProtocolError } from '../src/protocol/errors.js'
import { createHandlers } from '../src/handlers.js'

/** 120 行的假清单：活动时间递减（宿主按活动排序，我们只是照抄顺序）。 */
function rowsOf(count: number) {
  return Array.from({ length: count }, (_, index) => ({
    dshSessionId: `dsh-${index}`,
    updatedAt: 1000 - index,
    running: false,
    blank: false,
    subagent: false,
  }))
}

function harness(count: number) {
  const aliased: string[] = []
  const sessions = {
    list: async () => rowsOf(count),
    prompt: async () => ({ accepted: true as const }),
    cancel: () => ({ accepted: true as const }),
    updateQueue: async () => ({ accepted: true as const }),
    selectModel: async () => ({ selected: { provider: 'p', model: 'm' } }),
    create: async () => ({ sessionId: 'dsh-new' }),
    fork: async () => ({ childSessionId: 'dsh-child' }),
    rename: async () => ({ title: 't', seq: 1 }),
    page: async () => ({ records: [], hasMore: false }),
    follow: (): never => { throw new Error('本用例不应建立订阅') },
  }
  const handlers = createHandlers({
    caps: () => ({ sessions: true, storage: true, approval: false, questions: false, jobs: false, subagents: false, references: false, plugins: false, files: false, changes: false, settings: false, credentials: true, direct: false, team: false }),
    aliasVersion: () => 0,
    sessions,
    aliases: {
      ensure: async (id: string) => { aliased.push(id); return `sid-${id}` },
      sessionOf: () => undefined,
    },
    devices: () => [],
  })
  const list = handlers['session.list']
  assert.ok(list !== undefined, 'session.list 没挂上')
  return { list, aliased }
}

test('不传 limit = 整表，且 hasMore 为 false（老手机的行为不变）', async () => {
  const { list, aliased } = harness(120)
  const value = (await list({}, undefined as never)) as { sessions: unknown[]; hasMore: boolean }
  assert.equal(value.sessions.length, 120)
  assert.equal(value.hasMore, false)
  assert.equal(aliased.length, 120, '整表时每一行都要有别名')
})

test('limit 切一段，hasMore 按宿主整份清单算；别名只给这一段', async () => {
  const { list, aliased } = harness(120)
  const first = (await list({ limit: 50 }, undefined as never)) as { sessions: { sid: string }[]; hasMore: boolean }
  assert.equal(first.sessions.length, 50)
  assert.equal(first.sessions[0]?.sid, 'sid-dsh-0')
  assert.equal(first.hasMore, true)
  assert.equal(aliased.length, 50, '没发出去的行不许在别名表里留条目')

  const second = harness(120)
  const page2 = (await second.list({ limit: 50, offset: 50 }, undefined as never)) as { sessions: { sid: string }[]; hasMore: boolean }
  assert.equal(page2.sessions[0]?.sid, 'sid-dsh-50')
  assert.equal(page2.hasMore, true)
  assert.deepEqual(
    second.aliased,
    Array.from({ length: 50 }, (_, index) => `dsh-${50 + index}`),
    '第二页只给这 50 行铸别名',
  )

  const third = harness(120)
  const tail = (await third.list({ limit: 50, offset: 100 }, undefined as never)) as { sessions: unknown[]; hasMore: boolean }
  assert.equal(tail.sessions.length, 20)
  assert.equal(tail.hasMore, false, '最后一段要如实说"没有了"')
})

test('越界的 offset 给空段 + hasMore false（不是错误：那是"翻到底了"）', async () => {
  const { list } = harness(120)
  const value = (await list({ limit: 50, offset: 500 }, undefined as never)) as { sessions: unknown[]; hasMore: boolean }
  assert.deepEqual(value.sessions, [])
  assert.equal(value.hasMore, false)
})

test('形状不对一律 bad-frame：负数、小数、非数字', async () => {
  const { list } = harness(3)
  for (const bad of [{ limit: -1 }, { limit: 1.5 }, { limit: '10' }, { offset: -2 }, { offset: null }]) {
    await assert.rejects(
      async () => await list(bad as never, undefined as never),
      (error: unknown) => error instanceof ProtocolError && error.code === 'protocol/bad-frame',
      `${JSON.stringify(bad)} 应当被拦在方法面`,
    )
  }
})
