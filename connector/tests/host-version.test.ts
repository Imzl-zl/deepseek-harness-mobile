/**
 * `repo.info.dshVersion`：宿主运行时的 DSH 版本。
 *
 * 守三件事：
 *
 * 1. **取的是运行时真值**：从**已加载的宿主包**的 `package.json` 读，不是连接器
 *    自己 `package.json` 的版本，也不是构建期常量（用户升级 DSH 后同一份产物会跑在新宿主上）。
 * 2. **取不到就不报这个字段** —— 手机那边说"未读到"，不编一个版本号。
 * 3. 桌面版的兜底：`<exe>/resources/runtime/runtime.json` 的 `desktopVersion`。
 */
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { createHandlers } from '../src/handlers.js'
import type { HandlerDeps } from '../src/handlers.js'
import { HOST_PACKAGES, hostDshVersion } from '../src/dsh/host-version.js'

const NO_SESSIONS = { list: async () => [] } as never
const NO_ALIASES = {
  ensure: async () => 'sid_1',
  sessionOf: () => 'dsh-session-1',
} as never

function depsWith(dshVersion?: () => string | undefined): HandlerDeps {
  return {
    sessions: NO_SESSIONS,
    aliases: NO_ALIASES,
    caps: () => ({}) as never,
    aliasVersion: () => 1,
    devices: () => [],
    ...(dshVersion === undefined ? {} : { dshVersion }),
  } as unknown as HandlerDeps
}

test('优先读宿主包（@deepseek-ai/dsh-desktop-host）的 manifest 版本', () => {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-host-version-'))
  const pkgDir = join(dir, 'node_modules', '@deepseek-ai', 'dsh-desktop-host')
  mkdirSync(pkgDir, { recursive: true })
  writeFileSync(join(pkgDir, 'package.json'), JSON.stringify({ version: '9.9.9-run' }))

  const version = hostDshVersion(
    (specifier) => {
      assert.equal(specifier, '@deepseek-ai/dsh-desktop-host/package.json')
      return join(pkgDir, 'package.json')
    },
    join(dir, 'DeepSeek Harness.exe'),
  )
  assert.equal(version, '9.9.9-run')
  assert.equal(HOST_PACKAGES[0], '@deepseek-ai/dsh-desktop-host', '第一候选就是宿主入口那个包')
})

test('宿主包读不到 ⇒ 退到 runtime.json 的 desktopVersion', () => {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-host-version-'))
  // 本机实测的布局：`<安装目录>/resources/runtime/primary-runtime/runtime.json`。
  const runtimeDir = join(dir, 'resources', 'runtime', 'primary-runtime')
  mkdirSync(runtimeDir, { recursive: true })
  writeFileSync(
    join(runtimeDir, 'runtime.json'),
    JSON.stringify({ desktopVersion: '0.2.1-rc.2' }),
  )

  const version = hostDshVersion(
    () => {
      throw new Error('Cannot find module')
    },
    join(dir, 'DeepSeek Harness.exe'),
  )
  assert.equal(version, '0.2.1-rc.2')
})

test('两条都拿不到 ⇒ undefined（不编版本号）', () => {
  const dir = mkdtempSync(join(tmpdir(), 'dsh-host-version-'))
  const version = hostDshVersion(
    () => {
      throw new Error('Cannot find module')
    },
    join(dir, 'nope.exe'),
  )
  assert.equal(version, undefined)
})

test('repo.info：报 dshVersion；拿不到就**不报这个字段**', () => {
  const withVersion = createHandlers(depsWith(() => '0.2.1-rc.2'))
  const info = withVersion['repo.info']?.({}, {} as never) as {
    dshVersion?: string
    methods: string[]
  }
  assert.equal(info.dshVersion, '0.2.1-rc.2')
  assert.ok(
    info.methods.includes('repo.info'),
    'methods 仍是 handler 表的键（这里没挂 settings 面，所以不列 settings.*）',
  );

  const without = createHandlers(depsWith(() => undefined))
  const bare = without['repo.info']?.({}, {} as never) as Record<string, unknown>
  assert.equal('dshVersion' in bare, false, '取不到就不报 —— 手机说"未读到"')
})
