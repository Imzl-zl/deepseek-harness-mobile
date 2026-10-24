/**
 * `@` 候选的两个只读面（`refs.files` / `refs.sessions`）。
 *
 * 这一层是**透传**，所以用例盯的全是"我们有没有擅自改宿主的答案"：
 *
 * 1. 有候选 → 原样给（顺序、条数、`kind`、`mention` 都不动）；
 * 2. 空 → **空数组**（不是"没有这个方法"，也不是一个假的占位行）；
 * 3. 宿主抛错 → 原样过线（码归 `internal`、文字保留宿主的原话）；
 * 4. `caps.references` 与两个方法**同一个判据**（三个服务键在不在）——
 *    这套用例证明"说了有能力就一定有方法、没有能力就一个都不出现"。
 *
 * **走真的 face**（`createReferencesFace`）而不是手写一个回固定值的替身：
 * 替身绕开"候选形状认不认得出"这段，而那正是会漂的地方
 * （`session.projections` 的信封 bug 与 `agentPresets.list` 的过滤 bug 都是同一类）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createHandlers } from '../src/handlers.js'
import type { HandlerDeps } from '../src/handlers.js'
import { createReferencesFace } from '../src/dsh/references.js'
import type { ReferencesFace } from '../src/dsh/references.js'
import { readCaps, referencesAvailable } from '../src/dsh/caps.js'
import {
  createDispatcher,
  IDEMPOTENT_METHODS,
  METHODS,
  isMethod,
} from '../src/protocol/methods.js'

/** 最小可用的假 DSH 上下文：只按形状回答本插件问到的那几个键。 */
function fakeCtx(services: Record<string, unknown>) {
  return { get: (key: string) => services[key] } as never
}

const NO_SESSIONS = { list: async () => [] } as never
const ALIASES = {
  ensure: async () => 'sid_1',
  sessionOf: () => 'dsh-session-1',
} as never

function depsWith(references?: ReferencesFace, ctx?: unknown): HandlerDeps {
  return {
    sessions: NO_SESSIONS,
    aliases: ALIASES,
    caps: () => readCaps((ctx ?? fakeCtx({})) as never),
    aliasVersion: () => 0,
    devices: () => [],
    ...(references === undefined ? {} : { references }),
  } as unknown as HandlerDeps
}

/** 宿主的一行文件候选（形状照 `file-reference/src/types.ts:8-18`）。 */
const FILES_FROM_HOST = [
  { path: 'src/', kind: 'directory' },
  { path: 'src/index.ts', kind: 'file' },
  { path: 'README.md', kind: 'file' },
]

/**
 * 宿主的两行会话候选（形状照 `session-reference/src/types.ts` 的
 * `SessionReferenceMentionCandidate`）。第一行有 `displayTitle`（子会话的创建标签），
 * 第二行只有 `label` —— 标题口径必须是 `displayTitle ?? label`（宿主拼 mention 时同一句）。
 */
const SESSIONS_FROM_HOST = [
  {
    sessionId: 'dsh-session-9',
    label: 'opaque',
    displayTitle: '重构输入栏',
    sameWorkspace: true,
    createdAt: 1,
    mention: '@[重构输入栏](dsh-session:ImRzaC1zZXNzaW9uLTki)',
  },
  {
    sessionId: 'dsh-session-1',
    label: '看下用量页',
    sameWorkspace: false,
    createdAt: 2,
    mention: '@[看下用量页](dsh-session:ImRzaC1zZXNzaW9uLTEi)',
  },
]

/** 一个真形状的宿主面：`fileReferences` + `sessionReferenceResolver` + `agents`。 */
function hostCtx(
  options: {
    files?: () => Promise<readonly { path: string; kind: 'file' | 'directory' }[]>
    sessions?: () => Promise<readonly unknown[]>
  } = {},
) {
  return fakeCtx({
    fileReferences: {
      list: options.files ?? (async () => FILES_FROM_HOST),
    },
    sessionReferenceResolver: {
      remoteExportCandidates: options.sessions ?? (async () => SESSIONS_FROM_HOST),
    },
    agents: { get: (id: string) => (id === 'dsh-session-1' ? { id } : undefined) },
  })
}

/** 生产里那条"先查再分配"的别名路径（`index.ts` 的 `ensureSid`）。 */
function ensureSidOf(known: Record<string, string>) {
  const allocated: string[] = []
  return {
    allocated,
    ensureSid: async (dshSessionId: string): Promise<string> => {
      const existing = known[dshSessionId]
      if (existing !== undefined) return existing
      allocated.push(dshSessionId)
      const sid = `sid_${allocated.length}`
      known[dshSessionId] = sid
      return sid
    },
  }
}

test('方法表里有 refs.files / refs.sessions，且它们都是读方法（不带幂等键）', () => {
  for (const method of ['refs.files', 'refs.sessions'] as const) {
    assert.equal(isMethod(method), true, `${method} 必须在封闭集里`)
    assert.ok(METHODS.includes(method))
    assert.equal(
      IDEMPOTENT_METHODS.has(method),
      false,
      '读方法不带幂等键（它只是再查一次候选）',
    )
  }
})

test('refs.files：候选原样过线（顺序与 kind 都不动）', async () => {
  const ctx = hostCtx()
  const face = createReferencesFace(ctx, { sessionOf: () => 'dsh-session-1', ensureSid: async () => 'sid_1' })
  const handlers = createHandlers(depsWith(face, ctx))
  const result = await handlers['refs.files']!({ sid: 'sid_1', query: 'src' }, undefined as never)
  assert.deepEqual(result, { files: FILES_FROM_HOST })
})

test('refs.files：宿主没有匹配时是空数组（不是错误、也没有占位行）', async () => {
  const ctx = hostCtx({ files: async () => [] })
  const face = createReferencesFace(ctx, { sessionOf: () => 'dsh-session-1', ensureSid: async () => 'sid_1' })
  const handlers = createHandlers(depsWith(face, ctx))
  const result = await handlers['refs.files']!({ sid: 'sid_1', query: '' }, undefined as never)
  assert.deepEqual(result, { files: [] })
})

test('refs.sessions：mention 原样、标题取 displayTitle 优先、行里带的是本通道的 sid', async () => {
  const ctx = hostCtx()
  const known: Record<string, string> = { 'dsh-session-1': 'sid_1' }
  const { ensureSid, allocated } = ensureSidOf(known)
  const face = createReferencesFace(ctx, { sessionOf: () => 'dsh-session-1', ensureSid })
  const handlers = createHandlers(depsWith(face, ctx))
  const result = await handlers['refs.sessions']!({ sid: 'sid_1', query: '重' }, undefined as never)
  assert.deepEqual(result, {
    sessions: [
      // `displayTitle` 优先 —— 与宿主拼 mention 时的 `candidate.displayTitle ?? candidate.label`
      // 是同一句（`session-reference/src/index.ts:290-293`）
      {
        sid: 'sid_1',
        title: '重构输入栏',
        mention: '@[重构输入栏](dsh-session:ImRzaC1zZXNzaW9uLTki)',
      },
      // 第二行只有 `label`
      { sid: 'sid_1', title: '看下用量页', mention: '@[看下用量页](dsh-session:ImRzaC1zZXNzaW9uLTEi)' },
    ],
  })
  // 已经有别名的会话**不再分配**：只有 `dsh-session-9` 是新面孔。
  assert.deepEqual(allocated, ['dsh-session-9'], '已分过别名的会话不该被重复分配')
})

test('refs.sessions：宿主没有匹配时是空数组', async () => {
  const ctx = hostCtx({ sessions: async () => [] })
  const face = createReferencesFace(ctx, { sessionOf: () => 'dsh-session-1', ensureSid: async () => 'sid_1' })
  const handlers = createHandlers(depsWith(face, ctx))
  const result = await handlers['refs.sessions']!({ sid: 'sid_1', query: 'zzz' }, undefined as never)
  assert.deepEqual(result, { sessions: [] })
})

test('宿主抛错原样过线：码归 internal、文字是宿主的原话', async () => {
  const ctx = hostCtx({
    files: async () => {
      throw new Error('file-reference-local: EACCES reading /root/secret')
    },
  })
  const face = createReferencesFace(ctx, { sessionOf: () => 'dsh-session-1', ensureSid: async () => 'sid_1' })
  const dispatcher = createDispatcher(createHandlers(depsWith(face, ctx)))
  const reply = await dispatcher.dispatch({ method: 'refs.files', params: { sid: 'sid_1', query: '' } })
  assert.equal(reply.ok, false, '宿主失败不能装作成功')
  assert.equal(reply.ok === false ? reply.code : undefined, 'internal')
  assert.equal(
    reply.ok === false ? reply.message : undefined,
    'file-reference-local: EACCES reading /root/secret',
    '宿主的原话必须过线 —— 手机侧显示的原因不能是我们编的一句',
  )
})

test('caps.references 与两个方法同一个判据：三个服务键齐 ⇒ 都报', async () => {
  const ctx = hostCtx()
  assert.equal(referencesAvailable(ctx), true)
  const face = createReferencesFace(ctx, { sessionOf: () => 'dsh-session-1', ensureSid: async () => 'sid_1' })
  const handlers = createHandlers(depsWith(face, ctx))
  const info = (await handlers['repo.info']!({}, undefined as never)) as {
    caps: { references: boolean }
    methods: string[]
  }
  assert.equal(info.caps.references, true)
  assert.ok(info.methods.includes('refs.files'))
  assert.ok(info.methods.includes('refs.sessions'))
})

test('caps.references 与两个方法同一个判据：缺任一服务 ⇒ 能力位 false 且两个方法都不挂', async () => {
  // 三种缺法各判一次（`agents` 缺是"有候选服务但换不到 agent"那一档，同样不该挂）。
  const partial: Record<string, unknown>[] = [
    { sessionReferenceResolver: {}, agents: {} },
    { fileReferences: {}, agents: {} },
    { fileReferences: {}, sessionReferenceResolver: {} },
  ]
  for (const services of partial) {
    const ctx = fakeCtx(services)
    assert.equal(referencesAvailable(ctx), false)
    assert.equal(readCaps(ctx).references, false)
    // 装配层按同一个函数决定挂不挂 —— 这里模拟它的结论：不挂。
    const handlers = createHandlers(depsWith(undefined, ctx))
    const info = (await handlers['repo.info']!({}, undefined as never)) as {
      caps: { references: boolean }
      methods: string[]
    }
    assert.equal(info.caps.references, false)
    assert.equal(info.methods.includes('refs.files'), false)
    assert.equal(info.methods.includes('refs.sessions'), false)
  }
})
