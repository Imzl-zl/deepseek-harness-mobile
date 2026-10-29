/**
 * 设置与凭据适配器的回归（契约 §7.5）。
 *
 * 这个文件存在的理由只有一条，但它是安全关键：**密钥值绝不能进这条路径**。
 * 三个默认行为都站在危险一侧（`settings.ts` 的注释里有完整出处），所以断言写成"必须调什么、绝不能调什么"：
 *
 * 1. 裸 `describe()` 会把 `role('secret')` 的明文放进 `value` —— 必须传 `redactSecrets: true`；
 * 2. `replace(ns, 从脱敏文档重建的 section)` 会**静默删掉**客户端从没收到过的每一个密钥 ——
 *    改字段只能走 `mutate`；
 * 3. 凭据面：`describe` 返回的 `CredentialInfo` 里**没有能装值的槽**，密钥只有写面。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import type { CredentialProvider, CredentialRef } from '@deepseek-ai/dsh-credentials'
import type { SettingsForms } from '@deepseek-ai/dsh-settings'

import { createSettingsPort, type SettingsServices } from '../src/dsh/settings.js'

/** 记录调用参数的 settings 替身：`describe` / `update` / `mutate` / `replace` 四面都在，便于断言"没调哪个"。 */
function fakeSettings(rows: unknown[]) {
  const calls = {
    describe: [] as unknown[],
    update: [] as unknown[][],
    mutate: [] as unknown[][],
    replace: [] as unknown[],
  }
  const forms = {
    describe: (options?: unknown) => {
      calls.describe.push(options)
      return rows
    },
    update: (...args: unknown[]) => {
      calls.update.push(args)
      return Promise.resolve()
    },
    mutate: (...args: unknown[]) => {
      calls.mutate.push(args)
      return Promise.resolve()
    },
    replace: (...args: unknown[]) => {
      calls.replace.push(args)
      return Promise.resolve()
    },
  } as unknown as SettingsForms
  return { forms, calls }
}

function fakeCredentials(info: unknown = { configured: true, writable: true }) {
  const calls = { set: [] as unknown[][], unset: [] as unknown[], describe: [] as unknown[] }
  const provider = {
    set: (ref: unknown, value: unknown) => {
      calls.set.push([ref, value])
      return Promise.resolve()
    },
    unset: (ref: unknown) => {
      calls.unset.push(ref)
      return Promise.resolve()
    },
    describe: (ref: unknown) => {
      calls.describe.push(ref)
      return Promise.resolve(info)
    },
  } as unknown as CredentialProvider
  return { provider, calls }
}

const services = (patch: Partial<SettingsServices>): SettingsServices => ({
  settings: undefined,
  credentials: undefined,
  ...patch,
})

test('snapshot：必须传 redactSecrets（裸 describe 会把密钥明文放进 value）', () => {
  const { forms, calls } = fakeSettings([
    {
      ns: 'llm-deepseek',
      revision: 7,
      value: { model: 'x' },
      secrets: [{ path: ['apiKey'], set: true }],
    },
  ])
  const port = createSettingsPort(services({ settings: forms }))

  const snapshot = port.snapshot('llm-deepseek')
  assert.deepEqual(calls.describe, [{ redactSecrets: true }], '这是本文件存在的首要理由')
  assert.deepEqual(snapshot, {
    ns: 'llm-deepseek',
    revision: 7,
    values: { model: 'x' },
    secrets: [{ path: ['apiKey'], set: true }],
  })
  // 密钥位只带"位置 + 设没设"，没有值。
  assert.deepEqual(Object.keys(snapshot?.secrets[0] ?? {}).sort(), ['path', 'set'])
})

test('snapshot：命名空间不存在返回 undefined（而不是造一个空快照）', () => {
  const { forms } = fakeSettings([])
  const port = createSettingsPort(services({ settings: forms }))
  assert.equal(port.snapshot('nope'), undefined)
})

test('setField：走 mutate，且**绝不**走 replace（replace 会静默删密钥）', async () => {
  const { forms, calls } = fakeSettings([])
  const port = createSettingsPort(services({ settings: forms }))

  await port.setField('llm-deepseek', ['model'], 'y', 7)

  assert.deepEqual(calls.mutate, [[
    'llm-deepseek',
    [{ op: 'set', path: ['model'], value: 'y' }],
    7,
  ]])
  assert.deepEqual(calls.replace, [], 'replace 拿脱敏文档重建会删掉客户端没收到过的密钥')
})

test('setFields：一次写多字段走 update（不是循环 mutate，也不是 replace）', async () => {
  const { forms, calls } = fakeSettings([])
  const port = createSettingsPort(services({ settings: forms }))

  await port.setFields('dsh-mobile-connector', { relayUrl: 'wss://r/ws', listenPort: 0 }, 3)

  assert.deepEqual(calls.update, [[
    'dsh-mobile-connector',
    { relayUrl: 'wss://r/ws', listenPort: 0 },
    3,
  ]])
  // 循环 mutate 会让 revision 每次都 +1，第二次必 409；replace 会静默删密钥。
  assert.deepEqual(calls.mutate, [], '一次保存只能有一次写入')
  assert.deepEqual(calls.replace, [])
})

test('凭据：只发新值、删除用 unset；状态查询只有三态布尔（没有能装值的槽）', async () => {
  const { provider, calls } = fakeCredentials({ configured: true, writable: false })
  const port = createSettingsPort(services({ credentials: provider }))
  const ref = 'DEEPSEEK_API_KEY' as CredentialRef

  await port.setSecret(ref, 'sk-new')
  assert.deepEqual(calls.set, [[ref, 'sk-new']], '只发新值 —— 值只朝一个方向过线')

  await port.unsetSecret(ref)
  assert.deepEqual(calls.unset, [ref], '删除走 unset：空值会被拒绝')

  const status = await port.secretStatus(ref)
  assert.deepEqual(status, { configured: true, writable: false })
  assert.deepEqual(Object.keys(status).sort(), ['configured', 'writable'], '状态里没有值这一格')

  const missing = createSettingsPort(
    services({
      // 用独立替身而不是 `fakeCredentials(undefined)`：默认参数会把显式 `undefined` 换成默认值，
      // 于是"没配过"这条路径永远测不到。
      credentials: {
        describe: () => Promise.resolve(undefined),
      } as unknown as CredentialProvider,
    }),
  )
  assert.deepEqual(await missing.secretStatus(ref), { configured: false, writable: false })
})

test('服务缺失：显式抛错（能力位该已把它标成 false），绝不静默什么都不做', async () => {
  const port = createSettingsPort(services({}))

  assert.throws(() => port.snapshot('ns'), /settings 服务不可用/)
  await assert.rejects(() => port.setField('ns', ['a'], 1), /settings 服务不可用/)
  await assert.rejects(() => port.setFields('ns', { a: 1 }, 1), /settings 服务不可用/)
  await assert.rejects(() => port.setSecret('REF' as CredentialRef, 'v'), /credentials 服务不可用/)
  await assert.rejects(() => port.unsetSecret('REF' as CredentialRef), /credentials 服务不可用/)
  await assert.rejects(() => port.secretStatus('REF' as CredentialRef), /credentials 服务不可用/)
})
