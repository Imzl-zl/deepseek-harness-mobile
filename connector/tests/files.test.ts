/**
 * 工作区文件面（`file.list` / `file.read`）。
 *
 * 这一层同样是透传，用例盯四件事：
 *
 * 1. 目录清单**逐字段**过线（`name` / `type` / `size` / `truncated`），认不出的类型归 `other`；
 * 2. 空目录就是空数组（不是错误）；
 * 3. `read` 的分页参数原样进宿主、应答形状原样出（`text` / `offset` / `lines` / `eof`）；
 * 4. 宿主抛错原样过线；`caps.files` 与挂载判据同一个函数。
 *
 * scope 走**宿主的 lookup**（`workspaceFileScope`），所以替身也必须按那个形状回答 ——
 * 直接给一个 scope 对象验不出"我们有没有用 lookup"。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createHandlers } from '../src/handlers.js'
import type { HandlerDeps } from '../src/handlers.js'
import { createFilesFace } from '../src/dsh/files.js'
import { filesAvailable, readCaps } from '../src/dsh/caps.js'
import { createDispatcher } from '../src/protocol/methods.js'
import { IDEMPOTENT_METHODS, METHODS, isMethod } from '../src/protocol/methods.js'

function fakeCtx(services: Record<string, unknown>) {
  return { get: (key: string) => services[key] } as never
}

const NO_SESSIONS = { list: async () => [] } as never

/** 别名 → DSH 会话 id（与生产的 `aliases.sessionOf` 同形）。 */
const ALIASES = { ensure: async () => 'sid_1', sessionOf: () => 'dsh-session-1' } as never

function depsWith(ctx: unknown): HandlerDeps {
  return {
    sessions: NO_SESSIONS,
    aliases: ALIASES,
    caps: () => readCaps(ctx as never),
    aliasVersion: () => 0,
    devices: () => [],
  } as unknown as HandlerDeps
}

/** 宿主的清单（`api/workspace-files/src/types.ts:94-123` 的形状）。 */
const LISTING = {
  path: 'src',
  entries: [
    { name: 'index.ts', type: 'file', size: 1234 },
    { name: 'nested', type: 'directory' },
    { name: 'pipe', type: 'other' },
  ],
  truncated: true,
}

/** 宿主的一页文本（`types.ts:48-62`）。 */
const PAGE = { offset: 1, text: '第一行\n第二行', lines: 2, eof: false, bytes: 4096, absolutePath: '/abs/x.ts', version: 'v1' }

/**
 * 一台真形状的电脑：`workspaceFiles` + `typert` 的 `workspaceFileScope` lookup。
 *
 * `read` 会把收到的 range 记下来 —— "分页参数有没有原样进宿主"只有这样才能钉住。
 */
function hostCtx(
  options: {
    listing?: unknown
    page?: unknown
    listThrows?: Error
    scope?: unknown
  } = {},
) {
  const ranges: { offset?: number; limit?: number }[] = []
  const listed: string[] = []
  const resolved: string[] = []
  const ctx = fakeCtx({
    workspaceFiles: {
      list: async (_scope: unknown, path: string) => {
        if (options.listThrows !== undefined) throw options.listThrows
        listed.push(path)
        return options.listing ?? LISTING
      },
      read: async (_scope: unknown, _path: string, range: { offset?: number; limit?: number }) => {
        ranges.push(range)
        return options.page ?? PAGE
      },
    },
    typert: {
      lookups: {
        get: (key: string) =>
          key === 'workspaceFileScope'
            ? {
                resolve: (sessionId: string) => {
                  resolved.push(sessionId)
                  return options.scope ?? { sessionId, workspaceRoot: 'D:\\ws' }
                },
              }
            : undefined,
      },
    },
  })
  return { ctx, ranges, listed, resolved }
}

test('方法表里有 file.list / file.read，且都是读方法（不带幂等键）', () => {
  for (const method of ['file.list', 'file.read'] as const) {
    assert.equal(isMethod(method), true, `${method} 必须在封闭集里`)
    assert.ok(METHODS.includes(method))
    assert.equal(IDEMPOTENT_METHODS.has(method), false, '读方法不带幂等键')
  }
})

test('file.list：清单逐字段过线（认不出的类型归 other，truncated 照报）', async () => {
  const host = hostCtx()
  const handlers = createHandlers({
    ...depsWith(host.ctx),
    files: createFilesFace(host.ctx, { sessionOf: () => 'dsh-session-1' }),
  })
  const result = await handlers['file.list']!({ sid: 'sid_1', path: 'src' }, undefined as never)
  assert.deepEqual(result, {
    listing: {
      path: 'src',
      entries: [
        { name: 'index.ts', type: 'file', size: 1234 },
        { name: 'nested', type: 'directory' },
        { name: 'pipe', type: 'other' },
      ],
      truncated: true,
    },
  })
  // 绝对路径与 version **不过线**（手机不需要，少一个泄漏面）。
  assert.equal(JSON.stringify(result).includes('/abs/x.ts'), false)
  // scope 走的是宿主的 lookup，键是 DSH 会话 id（不是别名）。
  assert.deepEqual(host.resolved, ['dsh-session-1'])
})

test('file.list：空目录就是空数组；空 path 归一成工作区根（`.`）', async () => {
  const host = hostCtx({ listing: { path: '', entries: [], truncated: false } })
  const handlers = createHandlers({
    ...depsWith(host.ctx),
    files: createFilesFace(host.ctx, { sessionOf: () => 'dsh-session-1' }),
  })
  const result = await handlers['file.list']!({ sid: 'sid_1', path: '' }, undefined as never)
  assert.deepEqual(result, { listing: { path: '', entries: [], truncated: false } })
  assert.deepEqual(host.listed, ['.'], '空串 = 工作区根，交给宿主的就是 `.`')
})

test('file.read：分页参数原样进宿主，应答只带手机要的字段', async () => {
  const host = hostCtx()
  const handlers = createHandlers({
    ...depsWith(host.ctx),
    files: createFilesFace(host.ctx, { sessionOf: () => 'dsh-session-1' }),
  })
  const result = await handlers['file.read']!(
    { sid: 'sid_1', path: 'src/index.ts', offset: 41, limit: 20 },
    undefined as never,
  )
  assert.deepEqual(host.ranges, [{ offset: 41, limit: 20 }])
  assert.deepEqual(result, {
    page: { text: '第一行\n第二行', offset: 1, lines: 2, eof: false, bytes: 4096 },
  })
})

test('file.read：宿主抛错原样过线（码归 internal、文字是宿主的原话）', async () => {
  const host = hostCtx({ listThrows: new Error('workspace-file/not-directory: "x" is a file') })
  const handlers = createHandlers({
    ...depsWith(host.ctx),
    files: createFilesFace(host.ctx, { sessionOf: () => 'dsh-session-1' }),
  })
  const reply = await createDispatcher(handlers).dispatch({
    method: 'file.list',
    params: { sid: 'sid_1', path: 'x' },
  })
  assert.equal(reply.ok, false)
  assert.equal(reply.ok === false ? reply.code : undefined, 'internal')
  assert.equal(
    reply.ok === false ? reply.message : undefined,
    'workspace-file/not-directory: "x" is a file',
    '宿主自己的码与原文都要在 —— 手机不翻译',
  )
})

test('caps.files 与两个方法同一个判据：两个服务键在 ⇒ 都报；缺一个 ⇒ 能力位 false 且都不挂', async () => {
  const host = hostCtx()
  assert.equal(filesAvailable(host.ctx), true)
  const handlers = createHandlers({
    ...depsWith(host.ctx),
    files: createFilesFace(host.ctx, { sessionOf: () => 'dsh-session-1' }),
  })
  const info = (await handlers['repo.info']!({}, undefined as never)) as {
    caps: { files: boolean }
    methods: string[]
  }
  assert.equal(info.caps.files, true)
  assert.ok(info.methods.includes('file.list'))
  assert.ok(info.methods.includes('file.read'))

  for (const services of [
    { workspaceFiles: {} },
    { typert: {} },
  ]) {
    const partial = fakeCtx(services)
    assert.equal(filesAvailable(partial), false)
    assert.equal(readCaps(partial).files, false)
    const oldHandlers = createHandlers(depsWith(partial))
    const oldInfo = (await oldHandlers['repo.info']!({}, undefined as never)) as {
      caps: { files: boolean }
      methods: string[]
    }
    assert.equal(oldInfo.caps.files, false)
    assert.equal(oldInfo.methods.includes('file.list'), false)
    assert.equal(oldInfo.methods.includes('file.read'), false)
  }
})
