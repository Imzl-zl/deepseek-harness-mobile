/**
 * Agent 预设目录：手机上那枚「模式」chip 的名字必须来自 DSH 的真名单。
 *
 * 这一层与权限档是同一类接线（都是"目录只能从电脑侧取"），但**只有读、没有写** ——
 * 选预设走 `session.create({agentPreset})`，所以方法面只 +1。
 * 本用例钉住四件事：
 *
 * 1. 名单**原样过线**，`broken` 的行**不在这里被过滤** —— "哪些能选"是客户端规则，
 *    而且"选择器只列可用的、管理页列全部"是两件事
 *    （`ui-agent-preset/src/client/settings-store.ts:119-127` 与 `:109-110`）；
 * 2. 拿不到名单报 `available: false`，**不给空数组**；
 * 3. `agentPresets` 服务不在时这个方法**根本不挂**（`repo.info` 也不报）；
 * 4. 它是读方法，**不带幂等键**。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createHandlers } from '../src/handlers.js'
import type { HandlerDeps } from '../src/handlers.js'
import { createAgentPresetsFace } from '../src/dsh/agent-presets.js'
import type { AgentPresetsFace } from '../src/dsh/agent-presets.js'
import { METHODS, IDEMPOTENT_METHODS, isMethod } from '../src/protocol/methods.js'

/** 最小可用的假 DSH 上下文：只按形状回答本插件问到的那几个键。 */
function fakeCtx(services: Record<string, unknown>) {
  return { get: (key: string) => services[key] } as never
}

const NO_SESSIONS = { list: async () => [] } as never
const NO_ALIASES = { ensure: async () => 'sid_1', sessionOf: () => 'dsh-session-1' } as never

function depsWith(agentPresets?: AgentPresetsFace): HandlerDeps {
  return {
    sessions: NO_SESSIONS,
    aliases: NO_ALIASES,
    ...(agentPresets === undefined ? {} : { agentPresets }),
  } as unknown as HandlerDeps
}

/**
 * 一份够真的 roster：四个内置预设（`display.ts:41-44` 的 id）+ 一个用户自建 + 一个坏的。
 * `name` 缺席的正是内置项 —— DSH 的判据是"没有自定义 name 且 id 在表内"
 * （`isBuiltInPreset`，`display.ts:53-55`），所以这份数据同时覆盖了两种显示名来源。
 */
const ROSTER = {
  presets: [
    { id: 'standard', isDefault: true },
    { id: 'ptc', isDefault: false },
    { id: 'minimal', isDefault: false },
    { id: 'cordis', isDefault: false },
    { id: 'team-review', isDefault: false, name: 'Team Review', description: 'Review-only composition.' },
    { id: 'half-built', isDefault: false, broken: 'missing tool: nope' },
  ],
}

test('方法表里有 agentPresets.list，且它是读方法（不带幂等键）', () => {
  assert.equal(isMethod('agentPresets.list'), true, 'agentPresets.list 必须在封闭集里')
  assert.ok(METHODS.includes('agentPresets.list'))
  assert.equal(
    IDEMPOTENT_METHODS.has('agentPresets.list'),
    false,
    '读方法不带幂等键（它是目录，重发只是再读一次）',
  )
})

test('名单原样过线：broken 的行不被连接器丢掉', async () => {
  // **走真的 face，不走手写替身**：替身直接回一份名单时，"连接器有没有偷偷过滤"
  // 这件事根本不在被测路径上（2026-10-17 实测：把过滤加进 `createAgentPresetsFace`
  // 之后，用替身的那一版断言照样全绿）。这与 `session.projections` 的信封 bug
  // 是同一类失误 —— 替身复现的不是真形状，于是门禁看着通过。
  const handlers = createHandlers(
    depsWith(
      createAgentPresetsFace(
        fakeCtx({ agentPresets: { remoteExportList: async () => ROSTER } }),
      ),
    ),
  )
  const result = await handlers['agentPresets.list']!({}, undefined as never)
  assert.deepEqual(
    result,
    { available: true, roster: ROSTER },
    '名单必须整包过线 —— 在连接器里按 broken 过滤一次，就等于替手机决定了'
      + '"这一屏是选择器还是管理页"（Web 两处用的是两份规则）',
  )
  // 那条 broken 的必须还在：它是"过滤没发生"的**唯一**判据 ——
  // 只比 `deepEqual` 全量相等时，一条被丢掉的坏行会让断言红，但若是有人把
  // ROSTER 一起改了就看不出；这条单独点名它。
  const roster = (result as { roster: { presets: { id: string }[] } }).roster
  assert.ok(
    roster.presets.some((row) => row.id === 'half-built'),
    'broken 的行必须原样过线（Web 的选择器与设置页用的是两份不同的过滤规则）',
  )
})

test('名单读不到时降级成 available:false，不让整个方法失败', async () => {
  // 走**真的 face**（不是手写替身）：降级发生在 `createAgentPresetsFace` 的
  // try/catch 里，绕过它就只测到自己写的假实现。
  const face = createAgentPresetsFace(
    fakeCtx({
      agentPresets: {
        remoteExportList: () => {
          throw new Error('agentPresets 读不到')
        },
      },
    }),
  )
  const handlers = createHandlers(depsWith(face))
  assert.deepEqual(
    await handlers['agentPresets.list']!({}, undefined as never),
    { available: false },
    '读不到要明说；给空数组会让手机读成"这个部署一个预设都没有"',
  )
})

test('agentPresets 服务缺席时 face 回 undefined（装配层据此整块不挂）', async () => {
  const face = createAgentPresetsFace(fakeCtx({}))
  assert.equal(await face.roster(), undefined)
})

test('face 调的就是 DSH 的 remoteExportList（@Remote(\'list\')）', async () => {
  // 钉住"读的是哪一个方法"：DSH 上还有 `@Remote('read')`（读某个预设的组成文档），
  // 名字像但用途不同 —— 调错了不报错，只是拿到一份形状不对的东西。
  const seen: string[] = []
  const face = createAgentPresetsFace(
    fakeCtx({
      agentPresets: {
        remoteExportList: async () => {
          seen.push('remoteExportList')
          return ROSTER
        },
      },
    }),
  )
  await face.roster()
  assert.deepEqual(seen, ['remoteExportList'])
})

test('agentPresets 不在时 agentPresets.list 不挂（repo.info 不会报它）', () => {
  const handlers = createHandlers(depsWith())
  assert.equal(
    handlers['agentPresets.list'],
    undefined,
    '缺服务就整块不挂 —— 挂上去再回 unsupported 会让"这台没有预设服务"'
      + '与"这个方法没实现"在手机侧同一种表现',
  )
})
