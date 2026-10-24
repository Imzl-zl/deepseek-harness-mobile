/**
 * 插件清单与启停（`plugin.list` / `plugin.setEnabled`）。
 *
 * 这一层也是**透传**，用例盯四件事：
 *
 * 1. 行字段以宿主的 `PluginInfo` 为准、**不翻译**（含 `meta` 与 `fiberPhase` 原样）；
 * 2. 空清单就是空数组；
 * 3. 启停回的是**回读后的真值**，不是我们请求的那个 bool
 *    （`application === 'overridden'` 时两者不同 —— 回声就是撒谎）；
 * 4. 宿主抛错原样过线；能力位与"挂不挂方法"同一个判据。
 *
 * `pluginManager` 的服务形状照 `packages/boot/plugin-manager/src/index.ts`
 * （`listPlugins:439`、`setPluginEnabled:796`），`PluginInfo` 照
 * `packages/boot/plugin-manager/src/types.ts:55`。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createHandlers } from '../src/handlers.js'
import type { HandlerDeps } from '../src/handlers.js'
import { createPluginsFace } from '../src/dsh/plugins.js'
import { pluginsAvailable, readCaps } from '../src/dsh/caps.js'
import { createDispatcher, IDEMPOTENT_METHODS, METHODS, isMethod } from '../src/protocol/methods.js'

/** 最小可用的假 DSH 上下文：只按形状回答本插件问到的那几个键。 */
function fakeCtx(services: Record<string, unknown>) {
  return { get: (key: string) => services[key] } as never
}

const NO_SESSIONS = { list: async () => [] } as never
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

/**
 * 两行真形状的 `PluginInfo`：
 * 第一行可改（有 `patchId`），第二行是"管理面才能改"（`readOnlyReason`）。
 * `meta` 的 `title` 故意用**语言表**（`LocalizedText` 的 `{en, zh}` 那一档），
 * 因为"挑哪一档"是界面的事，连接器不该挑。
 */
const PLUGINS_FROM_HOST = [
  {
    entryId: 'entry-a',
    moduleName: '@deepseek-ai/dsh-tool-bash',
    meta: { title: { en: 'Bash tool', zh: 'Bash 工具' }, description: 'Run shell commands' },
    enabled: true,
    fiberPhase: 'active',
    patchId: 'patch-a',
  },
  {
    entryId: 'entry-b',
    moduleName: '@deepseek-ai/dsh-base',
    enabled: false,
    fiberPhase: 'pending',
    readOnlyReason: 'management-required',
  },
]

/** 一个能"启停"的假 pluginManager（状态在内存里，回读拿得到）。 */
function hostCtx(
  overrides: { rows?: Record<string, unknown>[]; setThrows?: Error; application?: string } = {},
) {
  const rows = (overrides.rows ?? PLUGINS_FROM_HOST).map((row) => ({ ...row }))
  return fakeCtx({
    pluginManager: {
      listPlugins: async () => rows,
      // 包清单（`listBundles:463`）：卸载按包名走，手机要先看见包。
      listBundles: async () => [
        {
          name: '@deepseek-ai/dsh-tool-bash',
          version: '0.2.1',
          installed: true,
          enabled: true,
          removable: true,
          rows: [{ rowId: 'bash' }],
          overrides: [],
        },
        {
          name: 'dsh-mobile-connector',
          installed: true,
          enabled: true,
          removable: false,
          readOnlyReason: 'management-required',
          rows: [],
          overrides: [],
        },
      ],
      setPluginEnabled: async (id: string, enabled: boolean) => {
        if (overrides.setThrows !== undefined) throw overrides.setThrows
        for (const row of rows) {
          if (row.entryId === id) {
            // **故意不照请求值写**：模拟 `overridden`（更高优先级的层盖住了）。
            row.enabled = overrides.application === 'overridden' ? !enabled : enabled
          }
        }
        return {
          changed: true,
          application: overrides.application ?? 'applied',
          stage: 'enable',
          target: id,
          enabled,
        }
      },
    },
  })
}

test('方法表里有 plugin.list / plugin.setEnabled；启停带幂等键，清单不带', () => {
  for (const method of ['plugin.list', 'plugin.setEnabled'] as const) {
    assert.equal(isMethod(method), true, `${method} 必须在封闭集里`)
    assert.ok(METHODS.includes(method))
  }
  assert.equal(IDEMPOTENT_METHODS.has('plugin.setEnabled'), true, '启停是用户指令，重发不该写两遍');
  assert.equal(IDEMPOTENT_METHODS.has('plugin.list'), false, '清单是读方法')
})

test('plugin.list：行字段以 PluginInfo 为准（meta / fiberPhase 原样，可改与只读两档都在）', async () => {
  const ctx = hostCtx()
  const handlers = createHandlers({ ...depsWith(ctx), plugins: createPluginsFace(ctx) })
  const result = await handlers['plugin.list']!({}, undefined as never)
  assert.deepEqual(result, {
    plugins: [
      {
        entryId: 'entry-a',
        moduleName: '@deepseek-ai/dsh-tool-bash',
        enabled: true,
        fiberPhase: 'active',
        meta: {
          title: { en: 'Bash tool', zh: 'Bash 工具' },
          description: 'Run shell commands',
        },
        patchId: 'patch-a',
      },
      {
        entryId: 'entry-b',
        moduleName: '@deepseek-ai/dsh-base',
        enabled: false,
        fiberPhase: 'pending',
        readOnlyReason: 'management-required',
      },
    ],
  })
})

test('plugin.listBundles：只带手机用得上的字段（卸载按包名，removable 由宿主说）', async () => {
  const ctx = hostCtx()
  const handlers = createHandlers({ ...depsWith(ctx), plugins: createPluginsFace(ctx) })
  const result = await handlers['plugin.listBundles']!({}, undefined as never)
  assert.deepEqual(result, {
    bundles: [
      {
        name: '@deepseek-ai/dsh-tool-bash',
        version: '0.2.1',
        installed: true,
        enabled: true,
        removable: true,
      },
      {
        name: 'dsh-mobile-connector',
        installed: true,
        enabled: true,
        removable: false,
        readOnlyReason: 'management-required',
      },
    ],
  })
  // 宿主的 `rows` / `overrides` 不过线（手机不渲染包内行）。
  assert.equal(JSON.stringify(result).includes('rowId'), false)
})

test('plugin.list：宿主没有插件时是空数组（不是错误）', async () => {
  const ctx = hostCtx({ rows: [] })
  const handlers = createHandlers({ ...depsWith(ctx), plugins: createPluginsFace(ctx) })
  const result = await handlers['plugin.list']!({}, undefined as never)
  assert.deepEqual(result, { plugins: [] })
})

test('plugin.setEnabled：回的是**回读后的真值**，并带上宿主的 application', async () => {
  const ctx = hostCtx()
  const handlers = createHandlers({ ...depsWith(ctx), plugins: createPluginsFace(ctx) })
  const reply = await createDispatcher(handlers).dispatch({
    method: 'plugin.setEnabled',
    params: { id: 'entry-a', enabled: false },
    requestId: 'plug-1',
  })
  assert.equal(reply.ok, true)
  assert.deepEqual(reply.ok === true ? reply.result : null, {
    name: '@deepseek-ai/dsh-tool-bash',
    enabled: false,
    application: 'applied',
  })
})

test('plugin.setEnabled：application 是 overridden 时，回的是宿主的终态而不是我们请求的 bool', async () => {
  const ctx = hostCtx({ application: 'overridden' })
  const handlers = createHandlers({ ...depsWith(ctx), plugins: createPluginsFace(ctx) })
  const reply = await createDispatcher(handlers).dispatch({
    method: 'plugin.setEnabled',
    params: { id: 'entry-a', enabled: false },
    requestId: 'plug-2',
  })
  assert.equal(reply.ok, true)
  // 我们请求 `false`，宿主回 `overridden` 且那一行仍是 `true` —— 回执必须是 `true`。
  assert.deepEqual(reply.ok === true ? reply.result : null, {
    name: '@deepseek-ai/dsh-tool-bash',
    enabled: true,
    application: 'overridden',
  })
})

test('plugin.setEnabled：宿主抛错原样过线（码归 internal、文字是宿主的原话）', async () => {
  const ctx = hostCtx({ setThrows: new Error('unknown-plugin') })
  const handlers = createHandlers({ ...depsWith(ctx), plugins: createPluginsFace(ctx) })
  const reply = await createDispatcher(handlers).dispatch({
    method: 'plugin.setEnabled',
    params: { id: 'entry-zzz', enabled: true },
    requestId: 'plug-3',
  })
  assert.equal(reply.ok, false)
  assert.equal(reply.ok === false ? reply.code : undefined, 'internal')
  assert.equal(reply.ok === false ? reply.message : undefined, 'unknown-plugin')
})

test('caps.plugins 与两个方法同一个判据：服务在 ⇒ 都报；不在 ⇒ 能力位 false 且都不挂', async () => {
  const withService = hostCtx()
  assert.equal(pluginsAvailable(withService), true)
  const handlers = createHandlers({
    ...depsWith(withService),
    plugins: createPluginsFace(withService),
  })
  const info = (await handlers['repo.info']!({}, undefined as never)) as {
    caps: { plugins: boolean }
    methods: string[]
  }
  assert.equal(info.caps.plugins, true)
  assert.ok(info.methods.includes('plugin.list'))
  assert.ok(info.methods.includes('plugin.setEnabled'))

  const without = fakeCtx({})
  assert.equal(pluginsAvailable(without), false)
  assert.equal(readCaps(without).plugins, false)
  const oldHandlers = createHandlers(depsWith(without))
  const oldInfo = (await oldHandlers['repo.info']!({}, undefined as never)) as {
    caps: { plugins: boolean }
    methods: string[]
  }
  assert.equal(oldInfo.caps.plugins, false)
  assert.equal(oldInfo.methods.includes('plugin.list'), false)
  assert.equal(oldInfo.methods.includes('plugin.setEnabled'), false)
})
