/**
 * `session.projections` 的回归（一个方法打开全部只读面）。
 *
 * ## 为什么这几条要钉
 *
 * 1. **按能力位挂**：缺 `sessionProjections` 服务时这个方法**不出现**，
 *    而不是挂上去回 `connector/unsupported` —— `repo.info` 报的是 handler
 *    表的键，"这台没有投影服务"与"这个方法没实现"在手机侧必须长得不一样。
 * 2. **原样透传，不挑字段**：投影的 `viewSchema` 是 zod `.strict()`，
 *    在这里"挑着发"就要预先知道全部键，而那正是会漂移的清单。
 *    挑过一次字段，投影加一个键我们就会静默漏发它。
 *    **唯一的例外是 `subagentCatalog` 的 `id`**（2026-10-19）：它是**子会话的
 *    DSH session id**（`subagent/src/catalog.ts:79` 的 `id: sessionIdSchema`），
 *    而 §5.1 说手机只见 `sid`；不换的话那一列子智能体点了打不开
 *    （`session.subscribe` 走 `requireSession`，原始 id 抛 `session/not-found`）。
 *    这一条也顺手修掉了原先的越线。**除这一个键之外，别的都原样过。**
 * 3. **拆掉 DSH 的信封**：`@Remote('projections')` 的返回类型是
 *    `SessionProjectionValue` 联合（`session-controller/src/index.ts:507`）——
 *    `null` 或 `{kind, asOfSeq, values}`。给手机的是 `values`，
 *    契约 §5.7 承诺的"所有已注册投影的当前值"。
 *    **2026-10-15 直接把信封透传了下去**，于是手机拿到的 Map 的键是
 *    `kind`/`asOfSeq`/`values`，`tokenUsage` / `permissions` / `subagentCatalog`
 *    一个都取不到 —— 统计条、上下文环、子智能体面板在生产里全是空态，
 *    而单测全绿：**替身当时直接返回 `values` 映射，绕开了信封**。
 *    所以本文件的假控制器一律复现 DSH 的真实返回形状（含信封），
 *    这条回归就是钉那件事的。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createHandlers } from '../src/handlers.js'
import { createProjectionsPort } from '../src/dsh/projections.js'
import type { Caps } from '../src/dsh/caps.js'

const CAPS: Caps = {
  sessions: true,
  storage: true,
  approval: false,
  questions: false,
  jobs: false,
  subagents: false,
  settings: false,
  credentials: true,
  direct: false,
}

/**
 * DSH 的 `SessionProjectionValue`：`{kind, asOfSeq, values}`（`sequenced`）
 * 或 `{kind: 'migration-required', values}`，会话不存在时是 `null`。
 *
 * **假控制器必须复现这个形状** —— 见文件头第 3 条。
 */
function dshProjectionResponse(values: Record<string, unknown>, kind = 'sequenced') {
  return { kind, asOfSeq: 42, values }
}

/** 一个返回固定投影包的假控制器（只透传，不做任何事）。 */
function fakeController(response: unknown) {
  return {
    projections: async (request: { sessionId: string }) => {
      assert.equal(typeof request.sessionId, 'string', '请求里必须带 sessionId')
      return response
    },
  } as never
}

function build(response: unknown, withPort: boolean) {
  return createHandlers({
    caps: () => CAPS,
    aliasVersion: () => 0,
    sessions: {
      list: async () => [],
      prompt: async () => ({ accepted: true as const }),
      selectModel: async () => ({ selected: { provider: 'test', model: 'test' } }),
      create: async () => ({ sessionId: 'dsh-new' }),
      updateQueue: async () => ({ accepted: true as const }),
      cancel: () => ({ accepted: true as const }),
    },
    aliases: { ensure: async () => 'sid_1', sessionOf: () => 'dsh-1' },
    devices: () => [],
    ...(withPort ? { projections: createProjectionsPort(fakeController(response)) } : {}),
  })
}

test('有投影服务时:拆掉 DSH 的信封，只把 values 给手机', async () => {
  const values = {
    tokenUsage: { uncachedInputTokens: 1, outputTokens: 2, cacheReadTokens: 3, cacheWriteTokens: 4 },
    sessionStats: { turns: 1, steps: 2 },
    permissions: { currentValue: 'workspace-write' },
    // 一个我们不认识的键也要过去 —— 挑字段就等于静默漏发。
    someFutureProjection: { whatever: true },
  }
  const handlers = build(dshProjectionResponse(values), true)

  const result = await handlers['session.projections']!({ sid: 'sid_1' }, {})

  assert.deepEqual(result, values,
    '必须原样返回 values、且一个投影键都不挑')
  assert.equal('kind' in (result as object), false,
    'DSH 的传输信封（kind / asOfSeq）不过线 —— 2026-10-15 透传它让手机上每个投影键都取不到')
})

test('subagentCatalog 的子会话 id 换成别名（§5.1；换来才点得开）', async () => {
  // 不复用 `build`：那里 `ensure` 恒回 'sid_1'，看不出"换成了哪个"。
  const aliased: string[] = []
  const handlers = createHandlers({
    caps: () => CAPS,
    aliasVersion: () => 0,
    sessions: {
      list: async () => [],
      prompt: async () => ({ accepted: true as const }),
      selectModel: async () => ({ selected: { provider: 'test', model: 'test' } }),
      create: async () => ({ sessionId: 'dsh-new' }),
      updateQueue: async () => ({ accepted: true as const }),
      cancel: () => ({ accepted: true as const }),
    },
    aliases: {
      // 一个**能看出方向**的别名表：别名由 id 派生，且与 id 无字面关系。
      ensure: async (dshSessionId: string) => {
        aliased.push(dshSessionId)
        return `sid-${aliased.length}`
      },
      sessionOf: () => 'dsh-1',
    },
    devices: () => [],
    projections: createProjectionsPort(
      fakeController(
        dshProjectionResponse({
          subagentCatalog: [
            { id: 'dsh-child-a', createdAt: 1, mode: 'one-shot' },
            { id: 'dsh-child-b', createdAt: 2, mode: 'continuable', label: '研究' },
          ],
          // 别的投影键**不动**（这条与"原样透传"那条一起看才完整）。
          tokenUsage: { uncachedInputTokens: 7 },
        }),
      ),
    ),
  })

  const result = (await handlers['session.projections']!({ sid: 'sid_1' }, {})) as {
    subagentCatalog: { id: string; createdAt: number; mode: string; label?: string }[]
    tokenUsage: unknown
  }

  assert.deepEqual(
    aliased,
    ['dsh-child-a', 'dsh-child-b'],
    '两个子会话 id 都要过别名（顺序按 catalog 原序）',
  )
  assert.deepEqual(
    result.subagentCatalog.map((e) => e.id),
    ['sid-1', 'sid-2'],
    '过线的是别名 —— 原始 DSH id 会让 session.subscribe 抛 session/not-found',
  )
  // **其余字段一个不少**：换 id 不是"挑字段"。
  assert.deepEqual(result.subagentCatalog[0], { id: 'sid-1', createdAt: 1, mode: 'one-shot' })
  assert.deepEqual(result.subagentCatalog[1], {
    id: 'sid-2',
    createdAt: 2,
    mode: 'continuable',
    label: '研究',
  })
  assert.deepEqual(result.tokenUsage, { uncachedInputTokens: 7 }, '别的投影原样过')
})

test('没有 subagentCatalog 的投影包：原样返回（不造空键）', async () => {
  const handlers = build(dshProjectionResponse({ tokenUsage: { uncachedInputTokens: 5 } }), true)
  const result = await handlers['session.projections']!({ sid: 'sid_1' }, {})
  assert.deepEqual(result, { tokenUsage: { uncachedInputTokens: 5 } })
  assert.equal('subagentCatalog' in (result as object), false)
})

test('migration-required 的应答同样只给 values', async () => {  const handlers = build(
    dshProjectionResponse({ tokenUsage: { uncachedInputTokens: 9 } }, 'migration-required'),
    true,
  )
  const result = await handlers['session.projections']!({ sid: 'sid_1' }, {})
  assert.deepEqual(result, { tokenUsage: { uncachedInputTokens: 9 } })
})

test('DSH 回 null（会话不存在）：给空映射，不是 null', async () => {
  const handlers = build(null, true)
  const result = await handlers['session.projections']!({ sid: 'sid_1' }, {})
  assert.deepEqual(result, {},
    '空映射让所有只读面一致地显示空态；回 null 会让手机早退，于是上一次的旧值继续显示')
})

test('没有投影服务时:这个方法根本不出现', () => {
  const handlers = build(dshProjectionResponse({}), false)
  assert.equal(handlers['session.projections'], undefined)
  // `repo.info` 报的是表的键 —— 所以"没有这个方法"必须在 `methods` 里看得出来。
  const info = handlers['repo.info']!({}, {}) as { methods: string[] }
  assert.equal(info.methods.includes('session.projections'), false)
})

test('别名不认识的 sid:回 session/not-found，不去问 DSH', async () => {
  let asked = false
  const handlers = createHandlers({
    caps: () => CAPS,
    aliasVersion: () => 0,
    sessions: {
      list: async () => [],
      prompt: async () => ({ accepted: true as const }),
      selectModel: async () => ({ selected: { provider: 'test', model: 'test' } }),
      create: async () => ({ sessionId: 'dsh-new' }),
      updateQueue: async () => ({ accepted: true as const }),
      cancel: () => ({ accepted: true as const }),
    },
    aliases: { ensure: async () => 'sid_1', sessionOf: () => undefined },
    devices: () => [],
    projections: createProjectionsPort({
      projections: async () => {
        asked = true
        return {}
      },
    } as never),
  })

  // 用 try/catch 而不是 `assert.rejects`：handler 的静态返回类型是
  // `Promise<unknown> | unknown`（`MethodHandler`），`assert.rejects` 只收 Promise。
  let caught: { code?: string; message: string } | undefined
  try {
    await handlers['session.projections']!({ sid: 'sid_unknown' }, {})
  } catch (error) {
    caught = error as { code?: string; message: string }
  }
  // 断在**错误码**上，不是文案：文案会说人话，码才是手机据此分派动作的那个。
  assert.equal(caught?.code, 'session/not-found')
  assert.equal(asked, false, '别名都不认识,不该去问 DSH')
})
