/**
 * 改动面（`file.changes`）：**桌面的记录原样过线**。
 *
 * ## 这一层不产生数据
 *
 * 真实文件、这一轮改了哪些、增删多少行、是不是二进制 / 超大 —— 全在宿主的
 * `workspaceChanges`（`packages/deliverables/workspace-changes/src/index.ts:116-120`，
 * 服务面 `types.ts:79-97`）。连接器只做三件事：别名 → DSH 会话 id、调服务、
 * **逐字段**构造给手机的形状（不让将来宿主新增的字段悄悄过线）。
 *
 * ## 两个"没有记录"的形态要分清
 *
 * - 会话别名不认识 ⇒ `session/not-found`（手机的动作是"从列表移除"）；
 * - 别名认识、但宿主已经释放了这条会话 / 从没记录过 ⇒ `summary: null`
 *   （**不是失败**：桌面那条 HTTP 路由用 404 表达同一件事，`present-open.ts:131-139`；
 *   我们把它建模成一个显式的空值，手机据此不画卡片）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createHandlers } from '../src/handlers.js'
import type { HandlerDeps } from '../src/handlers.js'
import { createChangesFace, DIFF_MAX_LINES } from '../src/dsh/changes.js'
import { changesAvailable, readCaps } from '../src/dsh/caps.js'
import { createDispatcher, IDEMPOTENT_METHODS, METHODS, isMethod } from '../src/protocol/methods.js'

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

/** 宿主的 summary（`workspace-changes/src/types.ts:25-40` 的形状；cwd/snapshot 不过线）。 */
const SUMMARY = {
  turn: 3,
  cwd: 'D:\\ws',
  files: [
    { path: 'app/lib/main.dart', display: 'app/lib/main.dart', added: 9, deleted: 2 },
    { path: 'assets/logo.png', display: 'assets/logo.png', added: 0, deleted: 0, binary: true },
    { path: 'vendor/huge.bin', display: 'vendor/huge.bin', added: 0, deleted: 0, oversized: true },
  ],
  total: 3,
  added: 9,
  deleted: 2,
  snapshot: { before: 'a', after: 'b' },
}

/** 宿主的文本比对（`types.ts:56-72` 的形状：每行带 `+` / `-` / 空格前缀）。 */
const TEXT_DIFF = {
  kind: 'text',
  path: 'app/lib/main.dart',
  display: 'app/lib/main.dart',
  before: true,
  after: true,
  coarse: false,
  hunks: [
    {
      oldStart: 3,
      oldLines: 3,
      newStart: 3,
      newLines: 4,
      lines: [' a', '-b', '+c', '+d', ' e'],
    },
  ],
}

/** 一台真形状的电脑：`workspaceChanges` 服务 + 记录收到的参数。 */
function hostCtx(
  options: {
    noRecord?: boolean
    summary?: unknown
    throws?: Error
    diff?: unknown
    diffThrows?: Error
  } = {},
) {
  const asked: { sessionId: string; seq: number; index?: number }[] = []
  const ctx = fakeCtx({
    workspaceChanges: {
      summary: (sessionId: string, seq: number) => {
        asked.push({ sessionId, seq })
        if (options.throws !== undefined) throw options.throws
        if (options.noRecord === true) return undefined
        return options.summary === undefined ? SUMMARY : options.summary
      },
      diff: async (sessionId: string, seq: number, index: number) => {
        asked.push({ sessionId, seq, index })
        if (options.diffThrows !== undefined) throw options.diffThrows
        if (options.noRecord === true) return undefined
        return options.diff === undefined ? TEXT_DIFF : options.diff
      },
    },
  })
  return { ctx, asked }
}

test('方法表里有 file.changes，且是读方法（不带幂等键）', () => {
  assert.equal(isMethod('file.changes'), true)
  assert.ok(METHODS.includes('file.changes'))
  assert.equal(IDEMPOTENT_METHODS.has('file.changes'), false, '读方法不带幂等键')
})

test('file.changes：summary 逐字段过线（cwd / snapshot 不过线）', async () => {
  const host = hostCtx()
  const handlers = createHandlers({
    ...depsWith(host.ctx),
    changes: createChangesFace(host.ctx, { sessionOf: () => 'dsh-session-1' }),
  })
  const result = await handlers['file.changes']!({ sid: 'sid_1', seq: 9 }, undefined as never)
  assert.deepEqual(result, {
    summary: {
      turn: 3,
      files: [
        { path: 'app/lib/main.dart', display: 'app/lib/main.dart', added: 9, deleted: 2 },
        { path: 'assets/logo.png', display: 'assets/logo.png', added: 0, deleted: 0, binary: true },
        { path: 'vendor/huge.bin', display: 'vendor/huge.bin', added: 0, deleted: 0, oversized: true },
      ],
      total: 3,
      added: 9,
      deleted: 2,
    },
  })
  const serialized = JSON.stringify(result)
  assert.equal(serialized.includes('D:\\\\ws'), false, '宿主的 cwd 不过线（手机不需要，也少一个泄漏面）')
  assert.equal(serialized.includes('snapshot'), false, '快照 id 不过线')
  // 调宿主时给的是 **DSH 会话 id**（不是别名），seq 原样。
  assert.deepEqual(host.asked, [{ sessionId: 'dsh-session-1', seq: 9 }])
})

test('file.changes：宿主没有这条记录 ⇒ {summary:null}，不是失败', async () => {
  const host = hostCtx({ noRecord: true })
  const handlers = createHandlers({
    ...depsWith(host.ctx),
    changes: createChangesFace(host.ctx, { sessionOf: () => 'dsh-session-1' }),
  })
  const reply = await createDispatcher(handlers).dispatch({
    method: 'file.changes',
    params: { sid: 'sid_1', seq: 9 },
  })
  assert.deepEqual(reply, { ok: true, result: { summary: null } })
})

test('file.changes：别名不认识 ⇒ session/not-found（手机据此从列表移除）', async () => {
  const host = hostCtx()
  const handlers = createHandlers({
    ...depsWith(host.ctx),
    changes: createChangesFace(host.ctx, { sessionOf: () => undefined }),
  })
  const reply = await createDispatcher(handlers).dispatch({
    method: 'file.changes',
    params: { sid: 'sid_unknown', seq: 9 },
  })
  assert.equal(reply.ok, false)
  assert.equal(reply.ok === false ? reply.code : undefined, 'session/not-found')
})

test('file.changes：宿主抛错原样过线（码归 internal、文字是宿主的原话）', async () => {
  const host = hostCtx({ throws: new Error('snapshot read failed: EACCES') })
  const handlers = createHandlers({
    ...depsWith(host.ctx),
    changes: createChangesFace(host.ctx, { sessionOf: () => 'dsh-session-1' }),
  })
  const reply = await createDispatcher(handlers).dispatch({
    method: 'file.changes',
    params: { sid: 'sid_1', seq: 9 },
  })
  assert.equal(reply.ok === false && reply.code, 'internal')
  assert.equal(
    reply.ok === false ? reply.message : undefined,
    'snapshot read failed: EACCES',
    '宿主的原文要保留 —— 手机不翻译',
  )
})

test('file.changes：seq 必须是安全非负整数（形状不对 = bad-frame）', async () => {
  const host = hostCtx()
  const handlers = createHandlers({
    ...depsWith(host.ctx),
    changes: createChangesFace(host.ctx, { sessionOf: () => 'dsh-session-1' }),
  })
  for (const seq of [undefined, '9', -1, 1.5]) {
    const reply = await createDispatcher(handlers).dispatch({
      method: 'file.changes',
      params: { sid: 'sid_1', seq },
    })
    assert.equal(reply.ok, false, `seq=${String(seq)} 应被拒`)
    assert.equal(reply.ok === false ? reply.code : undefined, 'protocol/bad-frame')
  }
})

test('caps.changes 与挂载判据同一个函数：服务在 ⇒ 都报；不在 ⇒ 能力位 false 且不挂', async () => {
  const host = hostCtx()
  assert.equal(changesAvailable(host.ctx), true)
  const handlers = createHandlers({
    ...depsWith(host.ctx),
    changes: createChangesFace(host.ctx, { sessionOf: () => 'dsh-session-1' }),
  })
  const info = (await handlers['repo.info']!({}, undefined as never)) as {
    caps: { changes: boolean }
    methods: string[]
  }
  assert.equal(info.caps.changes, true)
  assert.ok(info.methods.includes('file.changes'))

  const absent = fakeCtx({})
  assert.equal(changesAvailable(absent), false)
  assert.equal(readCaps(absent).changes, false)
  const old = createHandlers(depsWith(absent))
  const oldInfo = (await old['repo.info']!({}, undefined as never)) as {
    caps: { changes: boolean }
    methods: string[]
  }
  assert.equal(oldInfo.caps.changes, false)
  assert.equal(oldInfo.methods.includes('file.changes'), false)
})

// ---------------------------------------------------------------------------
// file.diff：逐行比对（坐标 seq + 下标，形态 text / binary / oversized）
// ---------------------------------------------------------------------------

function diffHandlers(host: { ctx: unknown }) {
  return createHandlers({
    ...depsWith(host.ctx),
    changes: createChangesFace(host.ctx as never, {
      sessionOf: () => 'dsh-session-1',
    }),
  })
}

test('方法表里有 file.diff，且是读方法（不带幂等键）', () => {
  assert.equal(isMethod('file.diff'), true)
  assert.ok(METHODS.includes('file.diff'))
  assert.equal(IDEMPOTENT_METHODS.has('file.diff'), false)
})

test('file.diff：文本比对逐字段过线（hunks 的行前缀原样），坐标是 seq + 下标', async () => {
  const host = hostCtx()
  const handlers = diffHandlers(host)
  const result = await handlers['file.diff']!(
    { sid: 'sid_1', seq: 9, index: 1 },
    undefined as never,
  )
  assert.deepEqual(result, {
    diff: {
      kind: 'text',
      path: 'app/lib/main.dart',
      display: 'app/lib/main.dart',
      before: true,
      after: true,
      coarse: false,
      hunks: [
        { oldStart: 3, oldLines: 3, newStart: 3, newLines: 4, lines: [' a', '-b', '+c', '+d', ' e'] },
      ],
    },
  })
  assert.deepEqual(host.asked, [
    { sessionId: 'dsh-session-1', seq: 9, index: 1 },
  ])
})

test('file.diff：binary / oversized 原样（没有行，不编）', async () => {
  for (const kind of ['binary', 'oversized'] as const) {
    const host = hostCtx({
      diff: { kind, path: 'assets/logo.png', display: 'assets/logo.png' },
    })
    const result = (await diffHandlers(host)['file.diff']!(
      { sid: 'sid_1', seq: 9, index: 0 },
      undefined as never,
    )) as { diff: Record<string, unknown> }
    assert.deepEqual(result, {
      diff: { kind, path: 'assets/logo.png', display: 'assets/logo.png' },
    })
    assert.equal('hunks' in result.diff, false, `${kind} 不该带 hunks`)
  }
})

test('file.diff：宿主没有这条记录 ⇒ {diff:null}（不是失败）', async () => {
  const host = hostCtx({ noRecord: true })
  const reply = await createDispatcher(diffHandlers(host)).dispatch({
    method: 'file.diff',
    params: { sid: 'sid_1', seq: 9, index: 0 },
  })
  assert.deepEqual(reply, { ok: true, result: { diff: null } })
})

test('file.diff：seq / index 必须是安全非负整数（形状不对 = bad-frame）', async () => {
  const host = hostCtx()
  for (const params of [
    { sid: 'sid_1', seq: 9 },
    { sid: 'sid_1', seq: -1, index: 0 },
    { sid: 'sid_1', seq: 9, index: '0' },
    { sid: 'sid_1', seq: 9, index: 1.5 },
  ]) {
    const reply = await createDispatcher(diffHandlers(host)).dispatch({
      method: 'file.diff',
      params,
    })
    assert.equal(reply.ok, false, `${JSON.stringify(params)} 应被拒`)
    assert.equal(reply.ok === false ? reply.code : undefined, 'protocol/bad-frame')
  }
})

test('file.diff：超长按手机自己的上限裁（1000 行），并如实报 shown/total', async () => {
  // 用**生产常量**造边界：第一条 hunk 700 行（整条收），第二条 700 行（只收 300）。
  const line = (prefix: string, at: number): string => `${prefix}line ${at}`;
  const big = {
    ...TEXT_DIFF,
    hunks: [
      { oldStart: 1, oldLines: 700, newStart: 1, newLines: 700, lines: Array.from({ length: 700 }, (_, at) => line(' ', at)) },
      { oldStart: 701, oldLines: 700, newStart: 701, newLines: 700, lines: Array.from({ length: 700 }, (_, at) => line('+', at)) },
    ],
  }
  const host = hostCtx({ diff: big })
  const result = (await diffHandlers(host)['file.diff']!(
    { sid: 'sid_1', seq: 9, index: 0 },
    undefined as never,
  )) as {
    diff: {
      hunks: { lines: string[] }[]
      truncated?: { shownLines: number; totalLines: number }
    }
  }
  assert.equal(
    result.diff.hunks.reduce((sum, hunk) => sum + hunk.lines.length, 0),
    DIFF_MAX_LINES,
    '发出的行数必须等于上限（不多发一行）',
  )
  assert.deepEqual(result.diff.truncated, {
    shownLines: DIFF_MAX_LINES,
    totalLines: 1400,
  })
  // 第一条整条在（700 行），第二条切到 300 行 —— 与桌面 renderedHunks 同一条切法。
  assert.equal(result.diff.hunks.length, 2)
  assert.equal(result.diff.hunks[0]!.lines.length, 700)
  assert.equal(result.diff.hunks[1]!.lines.length, DIFF_MAX_LINES - 700)
})

test('file.diff：没超上限时**不出现** truncated（不假装截断）', async () => {
  const host = hostCtx()
  const result = (await diffHandlers(host)['file.diff']!(
    { sid: 'sid_1', seq: 9, index: 0 },
    undefined as never,
  )) as { diff: Record<string, unknown> }
  assert.equal('truncated' in result.diff, false)
})
