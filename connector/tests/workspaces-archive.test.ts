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
import { ProtocolError } from '../src/protocol/errors.js'
import { createFakeAliases } from './support/fake-aliases.js'

/** DSH 的 `WorkspaceController` 是个大 class；测试只假装用到的那几个方法。 */
function fakeController(overrides: Record<string, unknown>): WorkspaceController {
  return overrides as unknown as WorkspaceController
}

/** 只出一次基线帧就结束的 `follow` —— 适配器的 `list()` 就是"取第一帧后中止"。 */
function baselineOnce(
  items: readonly unknown[],
  archived: readonly string[],
  pinned: readonly string[] = [],
) {
  return () =>
    (async function* () {
      yield {
        type: 'baseline',
        value: { items, archivedSessionIds: archived, pinnedSessionIds: pinned },
      }
    })()
}

const dshWorkspace = (patch: Record<string, unknown> = {}) => ({
  workspaceId: 'ws-1',
  title: 'dsh-mobile',
  path: 'D:/repo',
  sessionIds: ['dsh-a'],
  ...patch,
})

test('list：工作区、归档集、置顶集都是 DSH id（换别名是 handler 的事）', async () => {
  const port = createWorkspacesPort(
    fakeController({
      follow: baselineOnce([dshWorkspace()], ['dsh-z'], ['dsh-b', 'dsh-a']),
    }),
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
    // 顺序有意义：DSH 的 `pinnedSessionIds` 是「最近置顶的在前」
    //（`types.ts:147-150`），这里**原样保留**，不排序。
    pinnedSessionIds: ['dsh-b', 'dsh-a'],
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

test('insertSessionBefore：有锚点时三键齐全；无锚点时不发 `beforeSessionId`', async () => {
  const seen: unknown[] = []
  const port = createWorkspacesPort(
    fakeController({
      insertSessionBefore: (request: unknown) => {
        seen.push(request)
        return Promise.resolve({
          workspace: {
            workspaceId: 'ws-1',
            title: 'dsh-mobile',
            path: 'D:/repo',
            sessionIds: ['dsh-b', 'dsh-a'],
          },
        })
      },
    }),
  )

  assert.deepEqual(await port.insertSessionBefore('ws-1', 'dsh-a', 'dsh-b'), ['dsh-b', 'dsh-a'])
  assert.deepEqual(await port.insertSessionBefore('ws-1', 'dsh-a'), ['dsh-b', 'dsh-a'])
  assert.deepEqual(
    seen,
    [
      { workspaceId: 'ws-1', sessionId: 'dsh-a', beforeSessionId: 'dsh-b' },
      // 追加到末尾时**不能塞空串或 undefined**：`beforeSessionId?` 的语义是
      // "没给 = 追加"，塞空串会被宿主当成一个不存在的锚点。
      { workspaceId: 'ws-1', sessionId: 'dsh-a' },
    ],
    '只把真实存在的锚点过线',
  )
})

test('pin / unpin：返回置顶全集，且顺序原样保留', async () => {
  const port = createWorkspacesPort(
    fakeController({
      pinSession: (request: unknown) => {
        assert.deepEqual(request, { sessionId: 'dsh-a' })
        return Promise.resolve({ pinnedSessionIds: ['dsh-a', 'dsh-b'] })
      },
      unpinSession: (request: unknown) => {
        assert.deepEqual(request, { sessionId: 'dsh-a' })
        return Promise.resolve({ pinnedSessionIds: ['dsh-b'] })
      },
    }),
  )

  assert.deepEqual(await port.pin('dsh-a'), ['dsh-a', 'dsh-b'])
  assert.deepEqual(await port.unpin('dsh-a'), ['dsh-b'])
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

/** 一个只关心被测量方法的完整端口；其余方法给"无害的空结果"。 */
function portOf(overrides: Partial<WorkspacesPort>): WorkspacesPort {
  return {
    list: () => Promise.resolve({ workspaces: [], archivedSessionIds: [], pinnedSessionIds: [] }),
    archive: () => Promise.resolve([]),
    unarchive: () => Promise.resolve([]),
    insertSessionBefore: () => Promise.resolve([]),
    pin: () => Promise.resolve([]),
    unpin: () => Promise.resolve([]),
    ...overrides,
  }
}

/** 挂上工作区面的 handlers（`workspace.*` 按能力位挂，缺端口就整组不出现）。 */
function build(workspaces: Partial<WorkspacesPort>) {
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
    workspaces: portOf(workspaces),
  })
  return { handlers, aliases }
}

test('workspace.list：归档集与置顶集都换成手机见的 sid（同一份载荷只换一半就是 bug）', async () => {
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
        pinnedSessionIds: ['dsh-z', 'dsh-a'],
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
    pinnedSessionIds: ['sid_dsh-z', 'sid_dsh-a'],
  })
})

test('workspace.archive：sid 反解成 DSH id、stopActivity 过线、回值过别名', async () => {
  const seen: unknown[] = []
  const { handlers, aliases } = build({
    list: () => Promise.resolve({ workspaces: [], archivedSessionIds: [], pinnedSessionIds: [] }),
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
    list: () => Promise.resolve({ workspaces: [], archivedSessionIds: [], pinnedSessionIds: [] }),
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
    list: () => Promise.resolve({ workspaces: [], archivedSessionIds: [], pinnedSessionIds: [] }),
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

test('workspace.insertSessionBefore：workspaceId 透传、两个 sid 都反解、锚点可选', async () => {
  const seen: unknown[] = []
  const { handlers, aliases } = build({
    insertSessionBefore: (workspaceId, sessionId, beforeSessionId) => {
      seen.push({ workspaceId, sessionId, beforeSessionId })
      return Promise.resolve(['dsh-b', 'dsh-a'])
    },
  })
  const sid = await aliases.ensure('dsh-a')
  const beforeSid = await aliases.ensure('dsh-b')

  const handler = handlers['workspace.insertSessionBefore']
  assert.ok(handler !== undefined)
  assert.deepEqual(await handler({ workspaceId: 'ws-1', sid, beforeSid }, {}), {
    sessionIds: ['sid_dsh-b', 'sid_dsh-a'],
  })
  // 不给锚点 = 追加到末尾（DSH 的 `beforeSessionId?` 语义），第三参必须是
  // `undefined`，而不是空串或省略请求键之外的另一种形状。
  assert.deepEqual(await handler({ workspaceId: 'ws-1', sid }, {}), {
    sessionIds: ['sid_dsh-b', 'sid_dsh-a'],
  })
  assert.deepEqual(seen, [
    { workspaceId: 'ws-1', sessionId: 'dsh-a', beforeSessionId: 'dsh-b' },
    { workspaceId: 'ws-1', sessionId: 'dsh-a', beforeSessionId: undefined },
  ])
})

test('workspace.insertSessionBefore：workspaceId / beforeSid 形状不合规回 bad-frame，别名未知回 not-found', async () => {
  const { handlers, aliases } = build({})
  const handler = handlers['workspace.insertSessionBefore']
  assert.ok(handler !== undefined)
  const sid = await aliases.ensure('dsh-a')

  // 形状校验走公共的 `requireString`：文案与其它方法的 `<key> 必填` 一致。
  await assert.rejects(async () => {
    await handler({ sid }, {})
  }, /workspaceId 必填/)
  await assert.rejects(async () => {
    await handler({ workspaceId: 'ws-1', sid, beforeSid: '' }, {})
  }, /beforeSid 必填/)
  await assert.rejects(async () => {
    await handler({ workspaceId: 'ws-1', sid: 'sid_nope' }, {})
  }, /未知的会话别名/)
})

test('workspace.pin / unpin：sid 反解，返回置顶全集并过别名', async () => {
  const seen: unknown[] = []
  const { handlers, aliases } = build({
    pin: (sessionId) => {
      seen.push({ op: 'pin', sessionId })
      return Promise.resolve(['dsh-a', 'dsh-b'])
    },
    unpin: (sessionId) => {
      seen.push({ op: 'unpin', sessionId })
      return Promise.resolve(['dsh-b'])
    },
  })
  const sid = await aliases.ensure('dsh-a')

  const pin = handlers['workspace.pin']
  const unpin = handlers['workspace.unpin']
  assert.ok(pin !== undefined)
  assert.ok(unpin !== undefined)
  assert.deepEqual(await pin({ sid }, {}), {
    pinnedSessionIds: ['sid_dsh-a', 'sid_dsh-b'],
  })
  assert.deepEqual(await unpin({ sid }, {}), { pinnedSessionIds: ['sid_dsh-b'] })
  assert.deepEqual(seen, [
    { op: 'pin', sessionId: 'dsh-a' },
    { op: 'unpin', sessionId: 'dsh-a' },
  ])
})

// 宿主抛的是**它自己的**错误对象，而分发器只保留 `ProtocolError` 的码，
// 其余一律归 `internal`（`protocol/methods.ts:265-275`）。不抬一遍，
// `ERROR_TABLE` 里 'workspace/session-active' 那一行就是死代码，
// 手机收到 `internal` → §3.1 的客户端动作是 log-and-retry，而"会话还在跑"
// 根本不是重试能好的。表里没有的码（如 `workspace/move-invalid`）仍按统一规则
// 降成 internal —— **透传一个手机不认识的码比降级更糟**。
test('宿主封闭错误码抬成协议错误：session-active 原样，表外的码不动', async () => {
  const hostError = (code: string) => Object.assign(new Error(`宿主说：${code}`), { code })

  const activePort = createWorkspacesPort(
    fakeController({
      archiveSession: () => Promise.reject(hostError('workspace/session-active')),
    }),
  )
  await assert.rejects(
    async () => {
      await activePort.archive('dsh-a', false)
    },
    (error: unknown) => {
      assert.ok(error instanceof ProtocolError, '必须抬成 ProtocolError，否则分发器把它降成 internal')
      assert.equal((error as ProtocolError).code, 'workspace/session-active')
      return true
    },
  )

  const movePort = createWorkspacesPort(
    fakeController({
      insertSessionBefore: () => Promise.reject(hostError('workspace/move-invalid')),
    }),
  )
  await assert.rejects(
    async () => {
      await movePort.insertSessionBefore('ws-1', 'dsh-a')
    },
    (error: unknown) => {
      // 表里没有这个码：保持原样抛（由 dispatcher 归一成 internal + 原文），
      // 不在这里发一个手机不认识的码。
      assert.equal(error instanceof ProtocolError, false)
      assert.match(String((error as Error).message), /move-invalid/)
      return true
    },
  )
})