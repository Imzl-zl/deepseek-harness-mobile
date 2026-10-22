/**
 * 设置面（`settings.describe` / `settings.update`）—— 契约 §5.7。
 *
 * 这一组守四件事：
 *
 * 1. **读面是 allowlist**：手机只为三行设置而来，问别的 ns **静默跳过**（不报错、不返回）。
 * 2. **写面是 (ns, path) allowlist**：`mutate` 能写密钥字段，而 `settings.update` 不是
 *    那条通道 —— 越界必须被挡在连接器（`gateway/bad-request`），不能到宿主。
 * 3. **密钥位只有「设没设」**：载荷里 `secrets` 是 `{path, set}`，**没有任何能装值的槽**
 *    （值的脱敏在 `dsh/settings.ts` 的端口里，那里有独立的用例）。
 * 4. `settings` 服务不在时两个方法**根本不挂**（`repo.info` 也不报）。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createHandlers } from '../src/handlers.js'
import type { HandlerDeps } from '../src/handlers.js'
import {
  SettingsConflictError,
  SettingsScopeError,
  WRITABLE_FIELDS,
  createSettingsFace,
} from '../src/dsh/settings-face.js'
import type { SettingsPort, SettingsSnapshot } from '../src/dsh/settings.js'
import { IDEMPOTENT_METHODS, METHODS, isMethod } from '../src/protocol/methods.js'
import { ProtocolError } from '../src/protocol/errors.js'

/** 记录调用的端口替身；快照形状照真的（`values` 已脱敏 + `secrets` 只有 set）。 */
function fakePort(options: {
  conflict?: boolean
  rows?: Record<string, SettingsSnapshot>
} = {}) {
  const calls = { setField: [] as unknown[][] }
  const rows = options.rows ?? {}
  const port: SettingsPort = {
    snapshot: (ns) => rows[ns],
    setField: async (ns, path, value, expectedRevision) => {
      calls.setField.push([ns, path, value, expectedRevision])
      if (options.conflict === true) {
        const error = new Error('conflict') as Error & { code: string }
        error.code = 'SETTINGS_CONFLICT'
        throw error
      }
      // 写完之后宿主那边的新值：替身直接把这一条记进 rows，便于断言"返回改后的快照"。
      const before = rows[ns]
      rows[ns] = {
        ns,
        revision: 'rev-2',
        values: { ...(before?.values as Record<string, unknown> | undefined), [path[0]!]: value },
        secrets: before?.secrets ?? [],
      }
    },
    setSecret: async () => {},
    unsetSecret: async () => {},
    secretStatus: async () => ({ configured: false, writable: false }),
  }
  return { port, calls, rows }
}

/** 三行设置所在的那三个 ns（形状照真快照）。 */
function rows(): Record<string, SettingsSnapshot> {
  return {
    permission: {
      ns: 'permission',
      revision: 'rev-1',
      values: { defaultPreset: 'workspace-write' },
      // 这一行是**密钥位**：只有 set，没有 value。下面那条断言扫的就是它。
      secrets: [{ path: ['apiKey'], set: true }],
    },
    'agent-preset-registry': {
      ns: 'agent-preset-registry',
      revision: 'rev-1',
      values: { selectedDefault: 'standard' },
      secrets: [],
    },
    'session-log-deepseek': {
      ns: 'session-log-deepseek',
      revision: 'rev-1',
      values: { enabled: false },
      secrets: [],
    },
    'some-other-ns': {
      ns: 'some-other-ns',
      revision: 'rev-1',
      values: { whatever: true },
      secrets: [],
    },
  }
}

test('两个方法都在封闭集里；describe 是读、update 带幂等键', () => {
  assert.equal(isMethod('settings.describe'), true)
  assert.equal(isMethod('settings.update'), true)
  assert.ok(METHODS.includes('settings.describe'))
  assert.equal(
    IDEMPOTENT_METHODS.has('settings.describe'),
    false,
    '读方法不带幂等键（重发只是再读一次）',
  )
  assert.equal(
    IDEMPOTENT_METHODS.has('settings.update'),
    true,
    '写方法必须带幂等键（重发不能写两次）',
  )
})

test('describe：只回 allowlist 里的 ns，其余静默跳过', () => {
  const { port } = fakePort({ rows: rows() })
  const face = createSettingsFace(port)
  const sections = face.describe([
    'permission',
    'agent-preset-registry',
    'session-log-deepseek',
    'some-other-ns',
    'never-existed',
  ])
  assert.deepEqual(
    sections.map((section) => section.ns),
    ['permission', 'agent-preset-registry', 'session-log-deepseek'],
    'some-other-ns 不在可读 allowlist 里，never-existed 不存在 —— 都不返回',
  )
})

test('describe：密钥位只有 {path, set}，载荷里搜不到任何值', () => {
  const { port } = fakePort({ rows: rows() })
  const face = createSettingsFace(port)
  const sections = face.describe(['permission'])
  const payload = JSON.stringify(sections)
  assert.equal(payload.includes('SEKRET'), false)
  assert.deepEqual(sections[0]?.secrets, [{ path: ['apiKey'], set: true }])
  // 结构上就没有能装值的槽：每个 secret 只有两个键。
  for (const slot of sections[0]?.secrets ?? []) {
    assert.deepEqual(Object.keys(slot).sort(), ['path', 'set'])
  }
})

test('update：只发新值 + 带上 expectedRevision，并返回改完的快照', async () => {
  const { port, calls } = fakePort({ rows: rows() })
  const face = createSettingsFace(port)
  const section = await face.update({
    ns: 'permission',
    path: ['defaultPreset'],
    value: 'full-access',
    expectedRevision: 'rev-1',
  })
  assert.deepEqual(calls.setField, [
    ['permission', ['defaultPreset'], 'full-access', 'rev-1'],
  ])
  assert.equal(section?.revision, 'rev-2', '返回的是**改完**的快照')
  assert.deepEqual(section?.values, { defaultPreset: 'full-access' })
})

test('update：越界字段在连接器就被挡住（不到宿主）', async () => {
  const { port, calls } = fakePort({ rows: rows() })
  const face = createSettingsFace(port)
  await assert.rejects(
    () =>
      face.update({
        ns: 'permission',
        // 同 ns 的另一个字段 —— 正是"按 ns 放行"会漏掉的那种。
        path: ['apiKey'],
        value: 'SEKRET',
      }),
    SettingsScopeError,
  )
  assert.equal(calls.setField.length, 0, '一次都不该调到宿主')
  assert.equal(WRITABLE_FIELDS.length, 3, '可写面就是这三行设置')
})

test('update：乐观锁过期转成 SettingsConflictError', async () => {
  const { port } = fakePort({ rows: rows(), conflict: true })
  const face = createSettingsFace(port)
  await assert.rejects(
    () =>
      face.update({
        ns: 'agent-preset-registry',
        path: ['selectedDefault'],
        value: 'ptc',
        expectedRevision: 'stale',
      }),
    SettingsConflictError,
  )
})

/** 最小可用的假 DSH 上下文（与 `agent-presets.test.ts` 同一个形状）。 */
const NO_SESSIONS = { list: async () => [] } as never
const NO_ALIASES = {
  ensure: async () => 'sid_1',
  sessionOf: () => 'dsh-session-1',
} as never

function depsWith(settings?: ReturnType<typeof createSettingsFace>): HandlerDeps {
  return {
    sessions: NO_SESSIONS,
    aliases: NO_ALIASES,
    ...(settings === undefined ? {} : { settings }),
  } as unknown as HandlerDeps
}

test('handlers：服务在 ⇒ 两个方法挂上，形状与错误码都对', async () => {
  const { port } = fakePort({ rows: rows() })
  const handlers = createHandlers(depsWith(createSettingsFace(port)))

  const described = (await handlers['settings.describe']?.({ namespaces: ['permission'] }, {} as never)) as {
    sections: SettingsSnapshot[]
  }
  assert.equal(described.sections.length, 1)
  assert.equal(described.sections[0]?.ns, 'permission')

  const updated = (await handlers['settings.update']?.(
    {
      ns: 'session-log-deepseek',
      path: ['enabled'],
      value: true,
      expectedRevision: 'rev-1',
    },
    {} as never,
  )) as { section: SettingsSnapshot | null }
  assert.equal(updated.section?.revision, 'rev-2')

  // 越界 ⇒ `gateway/bad-request`（我们发的参数宿主不认）。
  await assert.rejects(
    () =>
      Promise.resolve(
        handlers['settings.update']?.(
          { ns: 'permission', path: ['apiKey'], value: 'x' },
          {} as never,
        ),
      ),
    (error: unknown) =>
      error instanceof ProtocolError && error.code === 'gateway/bad-request',
  )
})

test('handlers：服务不在 ⇒ 两个方法根本不挂（repo.info 也不报）', () => {
  const handlers = createHandlers(depsWith(undefined))
  assert.equal(handlers['settings.describe'], undefined)
  assert.equal(handlers['settings.update'], undefined)
})
