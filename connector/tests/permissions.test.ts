/**
 * 权限面：手机上切的权限档必须来自 DSH 的真目录，并且**真的切**。
 *
 * 这一层曾经是**三档手抄**（`app/lib/ui/dsh_composer.dart` 的 `AccessMode`
 * 三个枚举值 + `chat_page.dart` 的 `_setAccessMode` 只改本地字段）——
 * 既与电脑侧无关，也不会影响电脑上的会话。现在接的是 DSH 原生的两扇门，
 * 本用例钉住七件事：
 *
 * 1. 目录**原样过线**（不抄字段）：预设表是部署可配的
 *    （`packages/bundle/base/cordis.patch.yml:262-271`），手抄一份就是第二份真值；
 * 2. 拿不到目录报 `available: false`，**不给空数组**；
 * 3. 写路径拼的是 `/permission <preset>` 这条**命令行**，附件为空数组 ——
 *    与 Web 侧同一个调用（`ui-permission-presets/src/client/index.ts:126`）；
 * 4. DSH 回 `undefined`（命令不存在）与回 `{kind:'error'}`（预设名不对）
 *    是两件事，前者映射成 `matched: false`；
 * 5. 别名不认识 → `session/not-found`，**不去问 DSH**；
 * 6. `preset` 是手机给的字符串，被拼进行命令行 —— 边界校验必须拦在handler；
 * 7. 三个服务键缺任何一个，两个方法**都不挂**（`repo.info` 也不报）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createHandlers } from '../src/handlers.js'
import type { HandlerDeps } from '../src/handlers.js'
import { createPermissionFace } from '../src/dsh/permissions.js'
import type { PermissionFace } from '../src/dsh/permissions.js'
import { METHODS, IDEMPOTENT_METHODS, isMethod } from '../src/protocol/methods.js'

/** 最小可用的假 DSH 上下文：只按形状回答本插件问到的那几个键。 */
function fakeCtx(services: Record<string, unknown>) {
  return { get: (key: string) => services[key] } as never
}

const NO_SESSIONS = { list: async () => [] } as never
const NO_ALIASES = {
  ensure: async () => 'sid_1',
  sessionOf: () => 'dsh-session-1',
} as never

function depsWith(permissions: PermissionFace): HandlerDeps {
  return {
    sessions: NO_SESSIONS,
    aliases: NO_ALIASES,
    permissions,
  } as unknown as HandlerDeps
}

/** 一份够真的目录：三个部署预设，与 `bundle/base/cordis.patch.yml` 一致。 */
const CATALOG = {
  options: [
    { value: 'read-only', name: 'Read Only', description: 'Look, never write.' },
    { value: 'workspace-write', name: 'Workspace Write', description: 'Write inside the workspace.' },
    { value: 'danger-full-access', name: 'Full access', description: 'Full file access.' },
  ],
  defaultOptions: [
    { value: 'read-only', name: 'Read Only' },
    { value: 'workspace-write', name: 'Workspace Write' },
    { value: 'danger-full-access', name: 'Full access' },
  ],
  defaultPreset: 'workspace-write',
}

test('方法表里有 permission.catalog 与 permission.switch，且 switch 带幂等键', () => {
  assert.equal(isMethod('permission.catalog'), true, 'permission.catalog 必须在封闭集里')
  assert.equal(isMethod('permission.switch'), true, 'permission.switch 必须在封闭集里')
  assert.ok(METHODS.includes('permission.catalog'))
  assert.ok(METHODS.includes('permission.switch'))
  assert.equal(IDEMPOTENT_METHODS.has('permission.switch'), true,
    '切权限是写操作：重发不该落两条 command/run 生命周期事件')
  assert.equal(IDEMPOTENT_METHODS.has('permission.catalog'), false, '读方法不带幂等键')
})

test('目录：原样过线，available 跟随能不能拿到', async () => {
  const handlers = createHandlers(
    depsWith({ catalog: async () => CATALOG, switchTo: async () => ({ matched: true }) }),
  )
  const ok = await handlers['permission.catalog']!({}, undefined as never)
  assert.deepEqual(ok, { available: true, catalog: CATALOG },
    '目录必须原样过线 —— 抄一遍字段就多一处会漂移的地方')

  const missing = createHandlers(
    depsWith({ catalog: async () => undefined, switchTo: async () => ({ matched: true }) }),
  )
  const bad = await missing['permission.catalog']!({}, undefined as never)
  assert.deepEqual(bad, { available: false },
    '拿不到目录要明说；给空数组会让手机读成"没有可用预设"')
})

test('catalog 读不到时降级成 available:false，不让整个方法失败', async () => {
  // 走**真的 face**（不是手写替身）：降级发生在 `createPermissionFace` 的
  // try/catch 里，绕过它就只测到自己写的假实现。
  const face = createPermissionFace(
    fakeCtx({
      permissionPresets: {
        catalog: () => {
          throw new Error('permissionPresets 读不到')
        },
      },
      commands: { execute: async () => ({}) },
      agents: { get: () => ({}) },
    }),
    { sessionOf: () => 'dsh-1' },
  )
  const handlers = createHandlers(depsWith(face))
  assert.deepEqual(
    await handlers['permission.catalog']!({}, undefined as never),
    { available: false },
    '目录读不到要明说；给空数组会让手机读成"没有可用预设"',
  )
})

test('切换：DSH 的结算原样回给手机，不挑字段', async () => {
  const handlers = createHandlers(
    depsWith({
      catalog: async () => CATALOG,
      switchTo: async (sid, preset) => {
        assert.equal(sid, 'sid_1', '端口收的是通道别名，DSH 会话 id 的解析在端口内')
        assert.equal(preset, 'danger-full-access')
        return {
          matched: true,
          execution: { commandId: 'cmd-1-1', result: { kind: 'success', text: 'preset danger-full-access' } },
        }
      },
    }),
  )

  const result = await handlers['permission.switch']!(
    { sid: 'sid_1', preset: 'danger-full-access' },
    undefined as never,
  )

  assert.deepEqual(result, {
    matched: true,
    execution: { commandId: 'cmd-1-1', result: { kind: 'success', text: 'preset danger-full-access' } },
  }, 'DSH 的结算（commandId + result）原样回给手机，不挑字段')
})

test('switchTo：经 commands.execute 发命令行，附件为空数组', async () => {
  const calls: { line?: string; attachments?: readonly unknown[]; signal?: unknown }[] = []
  const face = createPermissionFace(
    fakeCtx({
      permissionPresets: { catalog: async () => CATALOG },
      commands: {
        execute: async (
          _agent: unknown,
          line: string,
          attachments: readonly unknown[],
          signal: AbortSignal,
        ) => {
          calls.push({ line, attachments, signal })
          return { commandId: 'cmd-1-2', result: { kind: 'success' } }
        },
      },
      agents: { get: (id: string) => ({ id, session: { id } }) },
    }),
    { sessionOf: (sid) => sid.replace('sid-', 'dsh-') },
  )

  const view = await face.switchTo('sid-1', 'read-only')

  assert.equal(calls.length, 1)
  assert.equal(calls[0]?.line, '/permission read-only',
    '命令行形状与 Web 侧逐字一致（ui-permission-presets/src/client/index.ts:126）')
  assert.deepEqual(calls[0]?.attachments, [],
    '斜杠命令不带附件 —— Web 侧同样传空数组（session-controller/.../session.ts:388）')
  assert.ok(calls[0]?.signal instanceof AbortSignal, '要带取消信号')
  assert.deepEqual(view, {
    matched: true,
    execution: { commandId: 'cmd-1-2', result: { kind: 'success' } },
  })
})

test('switchTo：DSH 回 undefined = 这台电脑没有 /permission 命令', async () => {
  const face = createPermissionFace(
    fakeCtx({
      permissionPresets: { catalog: async () => CATALOG },
      commands: { execute: async () => undefined },
      agents: { get: (id: string) => ({ id, session: { id } }) },
    }),
    { sessionOf: () => 'dsh-1' },
  )
  assert.deepEqual(await face.switchTo('sid-1', 'read-only'), { matched: false },
    '与 Web 客户端同一个推导：matched = result.value !== undefined（session.ts:390）')
})

test('switchTo：会话没有活动 agent 时如实抛，不假装切成功', async () => {
  const face = createPermissionFace(
    fakeCtx({
      permissionPresets: { catalog: async () => CATALOG },
      commands: { execute: async () => ({ commandId: 'c', result: { kind: 'success' } }) },
      agents: { get: () => undefined },
    }),
    { sessionOf: () => 'dsh-1' },
  )
  await assert.rejects(
    () => face.switchTo('sid-1', 'read-only'),
    (error: unknown) => {
      assert.match((error as Error).message, /活动 agent/)
      // **不是** `session/not-found`：那个码的客户端动作是"从列表移除"
      // （契约 §3.1），而这个会话是存在的。
      assert.equal((error as { code?: string }).code, 'internal')
      return true
    },
  )
})

test('别名不认识的 sid：回 session/not-found，不去问 DSH', async () => {
  let asked = false
  const handlers = createHandlers({
    sessions: NO_SESSIONS,
    aliases: { ensure: async () => 'sid_1', sessionOf: () => undefined },
    permissions: {
      catalog: async () => CATALOG,
      switchTo: async () => {
        asked = true
        return { matched: true }
      },
    },
  } as unknown as HandlerDeps)

  let caught: { code?: string; message: string } | undefined
  try {
    await handlers['permission.switch']!({ sid: 'sid_unknown', preset: 'read-only' }, undefined as never)
  } catch (error) {
    caught = error as { code?: string; message: string }
  }
  assert.equal(caught?.code, 'session/not-found')
  assert.equal(asked, false, '别名都不认识,不该去问 DSH')
})

test('preset 的边界校验：空串与首尾空白都拦在 handler，不进命令行', async () => {
  let asked = false
  const handlers = createHandlers(
    depsWith({
      catalog: async () => CATALOG,
      switchTo: async () => {
        asked = true
        return { matched: true }
      },
    }),
  )
  for (const bad of ['', '   ', ' read-only', 'read-only ']) {
    let caught: { code?: string } | undefined
    try {
      await handlers['permission.switch']!({ sid: 'sid_1', preset: bad }, undefined as never)
    } catch (error) {
      caught = error as { code?: string }
    }
    assert.equal(caught?.code, 'protocol/bad-frame', `preset=${JSON.stringify(bad)} 应被拒`)
  }
  assert.equal(asked, false, '坏参数不该走到 DSH')
})

test('preset 缺失或不是字符串：protocol/bad-frame', async () => {
  const handlers = createHandlers(
    depsWith({ catalog: async () => CATALOG, switchTo: async () => ({ matched: true }) }),
  )
  for (const params of [{ sid: 'sid_1' }, { sid: 'sid_1', preset: 7 }, { preset: 'read-only' }]) {
    let caught: { code?: string } | undefined
    try {
      await handlers['permission.switch']!(params, undefined as never)
    } catch (error) {
      caught = error as { code?: string }
    }
    assert.equal(caught?.code, 'protocol/bad-frame', `${JSON.stringify(params)} 应被拒`)
  }
})

test('permissions 缺席时两个方法都不挂（repo.info 自然也不报）', () => {
  const handlers = createHandlers({
    caps: () => ({
      sessions: true, storage: true, approval: false, questions: false,
      jobs: false, subagents: false, settings: false, credentials: true, direct: false,
    }),
    aliasVersion: () => 0,
    sessions: NO_SESSIONS,
    aliases: NO_ALIASES,
    devices: () => [],
  } as unknown as HandlerDeps)
  assert.equal(handlers['permission.catalog'], undefined, '能力位为 false 时不该挂（契约 §7）')
  assert.equal(handlers['permission.switch'], undefined)
  const info = handlers['repo.info']!({}, undefined as never) as { methods: string[] }
  assert.equal(info.methods.includes('permission.catalog'), false)
  assert.equal(info.methods.includes('permission.switch'), false,
    '手机据此隐藏权限控件 —— 与 DSH "键缺席即隐藏控件" 同一条规则')
})

test('createPermissionFace：三个服务键缺任何一个，对应能力就退化成"不知道"', async () => {
  // 缺 commands：catalog 仍可用（它只问 permissionPresets），switchTo 如实抛。
  const noCommands = createPermissionFace(
    fakeCtx({ permissionPresets: { catalog: async () => CATALOG }, agents: { get: () => ({}) } }),
    { sessionOf: () => 'dsh-1' },
  )
  assert.deepEqual(await noCommands.catalog(), CATALOG)
  await assert.rejects(() => noCommands.switchTo('sid-1', 'read-only'), /commands 服务不在/)

  // 缺 permissionPresets：catalog 回 undefined（调用方据此报 available:false）。
  const noPresets = createPermissionFace(
    fakeCtx({ commands: { execute: async () => ({}) }, agents: { get: () => ({}) } }),
    { sessionOf: () => 'dsh-1' },
  )
  assert.equal(await noPresets.catalog(), undefined)
})
