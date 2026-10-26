/**
 * 收口处分支（`session.fork`）。
 *
 * ## 它映射的是 Web 的**同一条链**
 *
 * `ui-chat/src/client/apply.ts:299-305` 的 `forkAt(seq)`：
 * `ctx.sessions.fork({sessionId, atSeq, increaseTitle: true})` → 客户端服务层
 * （`client/sessions/service.ts:463-487`）读源标题 → 宿主 `fork` → `rename` 加后缀。
 * 宿主 `fork` 本身**没有** `increaseTitle`（`types.ts:300-307`），所以这条链只能在
 * 客户端做 —— 连接器就是手机侧的那个客户端。
 *
 * ## 三件必须钉住的事
 *
 * 1. **子会话的 DSH id 不过线**：回 `{sid}`（别名），与 `session.create` 同一条纪律；
 * 2. **标题后缀逐字照 Web**：半角 / 全角编号各加一，没编号加 ` (1)`；
 * 3. **失败如实**：`rename` 失败是错误（fork 已建、桌面也不回滚，`service.ts:484`）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createHandlers } from '../src/handlers.js'
import type { HandlerDeps } from '../src/handlers.js'
import { increasedForkTitle, sourceTitleOf } from '../src/dsh/sessions.js'
import { createDispatcher, IDEMPOTENT_METHODS, METHODS, isMethod } from '../src/protocol/methods.js'

const CAPS = {
  sessions: true,
  storage: true,
  approval: false,
  questions: false,
  jobs: false,
  subagents: false,
  references: false,
  plugins: false,
  files: false,
  changes: false,
  settings: false,
  credentials: true,
  direct: false,
} as const

interface ForkCall {
  sessionId: string
  atSeq?: number
}

interface RenameCall {
  sessionId: string
  title: string
}

/** 一台假电脑：一行源会话（可带标题 / cwd）+ fork / rename 的记录。 */
function host(options: {
  title?: string
  cwd?: string
  renameThrows?: Error
} = {}) {
  const forks: ForkCall[] = []
  const renames: RenameCall[] = []
  const deps = {
    caps: () => ({ ...CAPS }),
    aliasVersion: () => 7,
    devices: () => [],
    aliases: {
      // **别名不透明**（与生产同一纪律）：不把 DSH id 编进去，
      // "id 不过线"的断言才有意义。
      ensure: async (dshSessionId: string) =>
        dshSessionId === 'dsh-child' ? 'sid_childopaque01' : `sid_src`,
      sessionOf: (sid: string) => (sid === 'sid_src' ? 'dsh-src' : undefined),
    },
    sessions: {
      list: async () => [
        {
          dshSessionId: 'dsh-src',
          updatedAt: 1,
          running: false,
          blank: false,
          subagent: false,
          ...(options.cwd === undefined ? {} : { cwd: options.cwd }),
          ...(options.title === undefined
            ? {}
            : {
                projections: {
                  kind: 'cached',
                  asOfSeq: 3,
                  values: { title: options.title },
                },
              }),
        },
      ],
      fork: async (request: ForkCall) => {
        forks.push(request)
        return { childSessionId: 'dsh-child' }
      },
      rename: async (sessionId: string, title: string) => {
        if (options.renameThrows !== undefined) throw options.renameThrows
        renames.push({ sessionId, title })
        return { title, seq: 4 }
      },
    },
  } as unknown as HandlerDeps
  return { handlers: createHandlers(deps), forks, renames }
}

test('方法表里有 session.fork，且不带幂等键（宿主 fork 没有键）', () => {
  assert.equal(isMethod('session.fork'), true)
  assert.ok(METHODS.includes('session.fork'))
  assert.equal(IDEMPOTENT_METHODS.has('session.fork'), false)
})

test('fork：atSeq 原样进宿主，回的是**别名**（DSH 子 id 不过线）', async () => {
  const h = host({ title: 'Greeting' })
  const result = await h.handlers['session.fork']!(
    { sid: 'sid_src', atSeq: 9 },
    undefined as never,
  )
  assert.deepEqual(result, { sid: 'sid_childopaque01' })
  assert.deepEqual(h.forks, [{ sessionId: 'dsh-src', atSeq: 9 }])
  assert.equal(
    JSON.stringify(result).includes('dsh-child'),
    false,
    'DSH 会话 id 不能出现在应答里',
  )
})

test('fork：不给 atSeq 时**不进请求体**（宿主自己取最近的已完成轮次）', async () => {
  const h = host({ title: 'Greeting' })
  await h.handlers['session.fork']!({ sid: 'sid_src' }, undefined as never)
  assert.deepEqual(h.forks, [{ sessionId: 'dsh-src' }])
})

test('fork：标题后缀逐字照 Web（半角 / 全角 / 没编号）', async () => {
  assert.equal(increasedForkTitle('Greeting'), 'Greeting (1)')
  assert.equal(increasedForkTitle('Greeting (2)'), 'Greeting (3)')
  assert.equal(increasedForkTitle('调研（9）'), '调研（10）')
  assert.equal(increasedForkTitle('a (1) (2)'), 'a (1) (3)')

  const h = host({ title: 'Greeting (2)' })
  await h.handlers['session.fork']!({ sid: 'sid_src' }, undefined as never)
  assert.deepEqual(h.renames, [
    { sessionId: 'dsh-child', title: 'Greeting (3)' },
  ])
})

test('fork：源标题缺失时用 cwd 目录名（与 Web 的 displayTitleOf 同一套）', async () => {
  assert.equal(sourceTitleOf(undefined, '/repo/a'), 'a')
  assert.equal(sourceTitleOf(undefined, 'D:\\ws\\proj'), 'proj')
  assert.equal(sourceTitleOf(undefined, undefined), undefined)
  assert.equal(sourceTitleOf('T', '/repo/a'), 'T', '持久标题优先')

  const h = host({ cwd: '/repo/a' })
  await h.handlers['session.fork']!({ sid: 'sid_src' }, undefined as never)
  assert.deepEqual(h.renames, [{ sessionId: 'dsh-child', title: 'a (1)' }])
})

test('fork：源会话既没标题也没 cwd ⇒ 不改名（不编一个）', async () => {
  const h = host()
  await h.handlers['session.fork']!({ sid: 'sid_src' }, undefined as never)
  assert.deepEqual(h.renames, [])
})

test('fork：rename 失败如实回错误（fork 已建，桌面也不回滚）', async () => {
  const h = host({
    title: 'Greeting',
    renameThrows: new Error('session/writer-held: busy'),
  })
  const reply = await createDispatcher(h.handlers).dispatch({
    method: 'session.fork',
    params: { sid: 'sid_src' },
  })
  assert.equal(reply.ok, false)
  assert.equal(reply.ok === false ? reply.code : undefined, 'internal')
  assert.equal(
    reply.ok === false ? reply.message : undefined,
    'session/writer-held: busy',
    '宿主的原话要保留',
  )
})

test('fork：别名不认识 ⇒ session/not-found；atSeq 形状不对 ⇒ bad-frame', async () => {
  const h = host({ title: 'Greeting' })
  const missing = await createDispatcher(h.handlers).dispatch({
    method: 'session.fork',
    params: { sid: 'sid_unknown' },
  })
  assert.equal(missing.ok === false && missing.code, 'session/not-found')

  for (const atSeq of ['9', -1, 1.5]) {
    const reply = await createDispatcher(h.handlers).dispatch({
      method: 'session.fork',
      params: { sid: 'sid_src', atSeq },
    })
    assert.equal(reply.ok, false, `atSeq=${String(atSeq)} 应被拒`)
    assert.equal(reply.ok === false ? reply.code : undefined, 'protocol/bad-frame')
  }
})

