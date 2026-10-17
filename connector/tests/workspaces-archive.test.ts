/**
 * 工作区适配器的归档面回归（契约 §5.7 的 `workspace.list` / `workspace.archive` /
 * `workspace.unarchive`）。
 *
 * 这个文件补两个缺口：
 *
 * 1. `src/dsh/workspaces.ts` 以前**没有测试**（`sessions-adapter.test.ts` 的注释里
 *    记着这件事：走查过映射、但没钉住行为）。
 * 2. **别名只换了一半**这个 bug：`workspace.list` 把 `sessionIds` 换成了手机见的
 *    `sid`，却把 `archivedSessionIds` 原样透传（DSH id）—— 手机永远认不出哪条是归档的，
 *    而症状只是"归档那一档对不上"，不报错。现在两处都走 `aliases.ensure`，这里钉住。
 *
 * 断言写的是**形状**：请求体里有哪些键（`stopActivity` 只在为 true 时出现 ——
 * DSH 判的是 `=== true`，塞一个 `false` 进去是另一种语义）、返回值过没过别名。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import type { WorkspaceController } from '@deepseek-ai/dsh-api-workspace-controller'

import { createHandlers } from '../src/handlers.js'
import {
  createWorkspacesPort,
  type WorkspacesPort,
} from '../src/dsh/workspaces.js'
import type { Caps } from '../src/dsh/caps.js'
import { createFakeAliases } from './support/fake-aliases.js'

/** DSH 的 `WorkspaceController` 是个大 class；测试只假装用到的那几个方法。 */
function fakeController(overrides: Record<string, unknown>): WorkspaceController {
  return overrides as unknown as WorkspaceController
}

/** 只出一次基线帧就结束的 `follow` —— 适配器的 `list()` 就是"取第一帧后中止"。 */
function baselineOnce(items: readonly unknown[], archived: readonly string[]) {
  return () =>
    (async function* () {
      yield { type: 'baseline', value: { items, archivedSessionIds: archived } }
    })()
}

const dshWorkspace = (patch: Record<string, unknown> = {}) => ({
  workspaceId: 'ws-1',
  title: 'dsh-mobile',
  path: 'D:/repo',
  sessionIds: ['dsh-a'],
  ...patch,
})

test('list：工作区与会话 id 过线，归档集是 DSH id（换别名是 handler 的事）', async () => {
  const port = createWorkspacesPort(
    fakeController({ follow: baselineOnce([dshWorkspace()], ['dsh-z']) }),
  )

  assert.deepEqual(await port.list(), {
    workspaces: [
      {
        workspaceId: 'ws-1',
        title: 'dsh-mobile',
        path: 'D:/repo',
        sessionIds: ['dsh-a'],
      },
    ],
    archivedSessionIds: ['dsh-z'],
  })
})

test('archive：`stopActivity` 只在为 true 时进请求体', async () => {
  const seen: unknown[] = []
  const port = createWorkspacesPort(
    fakeController({
      archiveSession: (request: unknown) => {
        seen.push(request)
        return Promise.resolve({ archivedSessionIds: ['dsh-a', 'dsh-z'] })
      },
    }),
  )

  assert.deepEqual(await port.archive('dsh-a', false), ['dsh-a', 'dsh-z'])
  assert.deepEqual(await port.archive('dsh-b', true), ['dsh-a', 'dsh-z'])
  assert.deepEqual(
    seen,
    [{ sessionId: 'dsh-a' }, { sessionId: 'dsh-b', stopActivity: true }],
    '不带 stopActivity 与带 false 是两回事：DSH 判的是 === true',
  )
})

test('unarchive：返回归档全集（宿主侧幂等，没归档过也给空集）', async () => {
  const port = createWorkspacesPort(
    fakeController({
      unarchiveSession: (request: unknown) => {
        assert.deepEqual(request, { sessionId: 'dsh-a' })
        return Promise.resolve({ archivedSessionIds: [] })
      },
    }),
  )

  assert.deepEqual(await port.unarchive('dsh-a'), [])
})

const CAPS: Caps = {
  sessions: true,
  storage: true,
  approval: false,
  questions: false,
  jobs: false,
  subagents: false,
  settings: false,
  credentials: false,
  direct: false,
}

/** 挂上工作区面的 handlers（`workspace.*` 按能力位挂，缺端口就整组不出现）。 */
function build(workspaces: WorkspacesPort) {
  const aliases = createFakeAliases()
  const handlers = createHandlers({
    caps: () => CAPS,
    aliasVersion: () => 7,
    devices: () => [],
    sessions: {
      list: () => Promise.resolve([]),
      prompt: () => Promise.resolve({ accepted: true }),
      selectModel: async () => ({ selected: { provider: 'test', model: 'test' } }),
      create: async () => ({ sessionId: 'dsh-new' }),
      updateQueue: async () => ({ accepted: true as const }),
      cancel: () => ({ accepted: true as const }),
    },
    aliases,
    workspaces,
  })
  return { handlers, aliases }
}

test('workspace.list：归档集也换成手机见的 sid（同一份载荷两种 id 约定只换一半就是 bug）', async () => {
  const { handlers } = build({
    list: () =>
      Promise.resolve({
        workspaces: [
          {
            workspaceId: 'ws-1',
            title: 'dsh-mobile',
            path: 'D:/repo',
            sessionIds: ['dsh-a'],
          },
        ],
        archivedSessionIds: ['dsh-a', 'dsh-z'],
      }),
    archive: () => Promise.resolve([]),
    unarchive: () => Promise.resolve([]),
  })

  const handler = handlers['workspace.list']
  assert.ok(handler !== undefined)
  assert.deepEqual(await handler({}, {}), {
    workspaces: [
      {
        workspaceId: 'ws-1',
        title: 'dsh-mobile',
        path: 'D:/repo',
        sessionIds: ['sid_dsh-a'],
      },
    ],
    archivedSessionIds: ['sid_dsh-a', 'sid_dsh-z'],
  })
})

test('workspace.archive：sid 反解成 DSH id、stopActivity 过线、回值过别名', async () => {
  const seen: unknown[] = []
  const { handlers, aliases } = build({
    list: () => Promise.resolve({ workspaces: [], archivedSessionIds: [] }),
    archive: (sessionId, stopActivity) => {
      seen.push({ sessionId, stopActivity })
      return Promise.resolve(['dsh-z'])
    },
    unarchive: () => Promise.resolve([]),
  })
  const sid = await aliases.ensure('dsh-z')
  assert.equal(sid, 'sid_dsh-z')

  const handler = handlers['workspace.archive']
  assert.ok(handler !== undefined)
  assert.deepEqual(await handler({ sid, stopActivity: true }, {}), {
    archivedSessionIds: ['sid_dsh-z'],
  })
  assert.deepEqual(seen, [{ sessionId: 'dsh-z', stopActivity: true }])
})

test('workspace.archive：别名未知回 session/not-found（不是空结果）', async () => {
  const { handlers } = build({
    list: () => Promise.resolve({ workspaces: [], archivedSessionIds: [] }),
    archive: () => Promise.resolve([]),
    unarchive: () => Promise.resolve([]),
  })

  const handler = handlers['workspace.archive']
  assert.ok(handler !== undefined)
  await assert.rejects(
    async () => {
      await handler({ sid: 'sid_nope' }, {})
    },
    /未知的会话别名/,
  )
})

test('workspace.unarchive：同样反解 sid 并过别名', async () => {
  const { handlers, aliases } = build({
    list: () => Promise.resolve({ workspaces: [], archivedSessionIds: [] }),
    archive: () => Promise.resolve([]),
    unarchive: (sessionId) => {
      assert.equal(sessionId, 'dsh-z')
      return Promise.resolve([])
    },
  })
  const sid = await aliases.ensure('dsh-z')

  const handler = handlers['workspace.unarchive']
  assert.ok(handler !== undefined)
  assert.deepEqual(await handler({ sid }, {}), { archivedSessionIds: [] })
})