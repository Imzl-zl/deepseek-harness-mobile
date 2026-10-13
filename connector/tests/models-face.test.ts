/**
 * 模型面：手机上显示的模型必须来自 DSH 的真投影，而不是占位。
 *
 * 这一层曾经是**写死的**（`app/lib/ui/chat_page.dart` 里 `modelName: 'claude-opus'`
 * 加一份手抄的四个模型列表），于是手机上显示的模型与电脑侧真实状态毫无关系。
 * 现在接的是 DSH 原生的两条通道，本用例钉住三件事：
 *
 * 1. `session.modelCatalog` 把 DSH 的目录**原样**过线（不抄字段、不改形状）；
 * 2. 目录拿得到就报 `available: true`，拿不到就 `available: false` ——
 *    **不给空数组**：空数组会被手机读成"没有可用模型"，而真实原因可能是 key 没配；
 * 3. 每会话当前模型取投影的 `next ?? lastUsed`；两者都没有就**不给 `model` 字段**
 *    （手机显示"未选择"，而不是猜一个）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createHandlers } from '../src/handlers.js'
import type { HandlerDeps } from '../src/handlers.js'
import { createModelFace } from '../src/dsh/models.js'
import type { ModelFace } from '../src/dsh/models.js'
import { METHODS, isMethod } from '../src/protocol/methods.js'

/** 最小可用的假 DSH 上下文：只按形状回答本插件问到的那几个键。 */
function fakeCtx(services: Record<string, unknown>) {
  return { get: (key: string) => services[key] } as never
}

const NO_SESSIONS = { list: async () => [] } as never
const NO_ALIASES = {
  ensure: async () => 'sid_1',
  sessionOf: () => 'dsh-session-1',
} as never

function depsWith(models: ModelFace): HandlerDeps {
  return {
    sessions: NO_SESSIONS,
    aliases: NO_ALIASES,
    models,
  } as unknown as HandlerDeps
}

/** 一份够真的目录：两个 provider、其中一个带 reasoning efforts。 */
const CATALOG = {
  default: { provider: 'lightvela-free', model: 'auto' },
  routableProviders: ['lightvela-free', 'deepseek-official'],
  groups: [
    { id: 'lightvela-free', name: 'Lightvela (free)', models: [{ id: 'auto', name: 'auto' }] },
    {
      id: 'deepseek-official',
      name: 'DeepSeek',
      models: [
        {
          id: 'deepseek-flash',
          name: 'DeepSeek-V41-Flash',
          reasoning: { efforts: [{ id: 'high', name: 'High' }], defaultEffort: 'high' },
        },
      ],
    },
  ],
}

test('方法表里有 session.modelCatalog，且它要过能力位', () => {
  assert.equal(isMethod('session.modelCatalog'), true, 'session.modelCatalog 必须在封闭集里')
  assert.ok(METHODS.includes('session.modelCatalog'))
})

test('目录：原样过线，available 跟随能不能拿到', async () => {
  const handlers = createHandlers(
    depsWith({
      catalog: async () => CATALOG,
      modelOf: () => undefined,
    }),
  )
  const ok = await handlers['session.modelCatalog']!({}, undefined as never)
  assert.deepEqual(ok, { available: true, catalog: CATALOG },
    '目录必须原样过线 —— 抄一遍字段就多一处会漂移的地方')

  const missing = createHandlers(
    depsWith({ catalog: async () => undefined, modelOf: () => undefined }),
  )
  const bad = await missing['session.modelCatalog']!({}, undefined as never)
  assert.deepEqual(bad, { available: false },
    '拿不到目录要明说；给空数组会让手机读成"没有可用模型"')
})

test('models 缺席时整个方法不挂（repo.info 自然也不报它）', () => {
  const handlers = createHandlers({
    sessions: NO_SESSIONS,
    aliases: NO_ALIASES,
  } as unknown as HandlerDeps)
  assert.equal(handlers['session.modelCatalog'], undefined,
    '能力位为 false 时不该挂这个方法（契约 §7）')
})

test('session.list 的行带当前模型；取不到就不带这个字段', async () => {
  const rows = [
    { dshSessionId: 'a', updatedAt: 1, running: false, blank: false, subagent: false },
    { dshSessionId: 'b', updatedAt: 2, running: true, blank: false, subagent: false },
  ]
  const withModel = createHandlers({
    sessions: { list: async () => rows } as never,
    aliases: {
      ensure: async (id: string) => `sid-${id}`,
      sessionOf: (sid: string) => sid.replace('sid-', ''),
    } as never,
    models: {
      catalog: async () => undefined,
      // 只给第一个会话模型：第二个必须**没有** model 字段，而不是继承第一个的
      modelOf: (sid: string) =>
        sid === 'sid-a' ? { provider: 'lightvela-free', model: 'auto' } : undefined,
    },
  } as unknown as HandlerDeps)
  const listed = (await withModel['session.list']!({}, undefined as never)) as {
    sessions: { sid: string; model?: unknown }[]
  }
  assert.deepEqual(listed.sessions[0]?.model, { provider: 'lightvela-free', model: 'auto' })
  assert.equal('model' in (listed.sessions[1] ?? {}), false,
    '拿不到当前模型就不给这个字段 —— 猜一个就是把"看起来连着"当成"连着"')
})

test('modelOf：next 优先于 lastUsed；两者都无返回 undefined', () => {
  // 投影的线格式是 `{lastUsed, next}`；`next` 是"下一次请求将用哪个"。
  const views: Record<string, unknown> = {
    'dsh-has-next': { lastUsed: { provider: 'p', model: 'old' }, next: { provider: 'p', model: 'new' } },
    'dsh-only-last': { lastUsed: { provider: 'p', model: 'old' }, next: null },
    'dsh-neither': { lastUsed: null, next: null },
  }
  const face = createModelFace(
    fakeCtx({
      sessionProjections: {
        stateOf: (session: unknown) => views[session as string],
      },
      agents: { get: (id: string) => ({ session: id }) },
      sessionController: { modelCatalog: async () => CATALOG },
    }),
    { sessionOf: (sid) => sid.replace('sid-', 'dsh-') },
  )
  assert.deepEqual(face.modelOf('sid-has-next'), { provider: 'p', model: 'new' },
    '有待定的选择时用它 —— 那才是下一次请求会用的')
  assert.deepEqual(face.modelOf('sid-only-last'), { provider: 'p', model: 'old' },
    '没有待定就退回到上一次实际用过的')
  assert.equal(face.modelOf('sid-neither'), undefined, '两者都没有就是不知道，别猜')
  assert.equal(face.modelOf('sid-unknown'), undefined, '别名不认识时也是不知道')
})

test('modelOf：投影或 agents 缺席时返回 undefined（不抛）', () => {
  const onlyProjections = createModelFace(
    fakeCtx({ sessionProjections: { stateOf: () => ({ next: { provider: 'p', model: 'm' } }) } }),
    { sessionOf: () => 'dsh-1' },
  )
  assert.equal(onlyProjections.modelOf('sid-1'), undefined,
    '够不着 live Session 时就承认不知道 —— 裸读 ctx.agents 会抛，那会让整个 session.list 失败')
})
