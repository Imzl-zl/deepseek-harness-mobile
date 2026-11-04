/**
 * 注册名额（`auth.registration.maxAccounts`）。
 *
 * 四件必须同时成立的事：
 * 1. 没满时照常注册，`/api/auth/config` 的 `registration.full` 为 false；
 * 2. 满了以后**三处一起拦**：config 的 `full`、发码 403、注册 409；
 * 3. 名额口径是 `COUNT(*) FROM users`，**含 suspended**（停用不是注销）；
 * 4. `closed` 与 `full` 是两种状态（各自的状态码与文案），而**重置密码不受影响**。
 *
 * 并发那条用例盯的是"数一遍 + 插入在同一个事务里"：两个请求都通过入口预检，
 * 但只有一个能拿到最后一个位置。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  createAccountsFace,
  createAccountsLimiters,
  type AccountsReply,
  type ConsoleBridge,
} from '../src/accounts/face.ts'
import { parseAuthConfig, type AuthConfig } from '../src/accounts/config.ts'
import { createAccountsDb, publicUserOf } from '../src/accounts/db.ts'
import { createCodeStore, type MailMessage } from '../src/accounts/email.ts'

const CONFIG: AuthConfig = {
  mode: 'accounts',
  baseUrl: 'https://relay.test',
  dbPath: ':memory:',
  serverName: '测试中转',
  registration: { mode: 'open', requireEmailVerification: false, emailDomains: [], maxAccounts: null },
  limits: { defaultMaxConnectors: 2, defaultQuotaBytes: 1024 },
  adminEmails: [],
  trustProxy: false,
  sessionDays: 30,
}

function harness(registration: Partial<AuthConfig['registration']> = {}, withMailer = false) {
  const config: AuthConfig = { ...CONFIG, registration: { ...CONFIG.registration, ...registration } }
  const db = createAccountsDb(':memory:')
  const sent: MailMessage[] = []
  const bridge: ConsoleBridge = {
    state(user) {
      return {
        v: 1,
        now: 0,
        user: publicUserOf(user),
        limits: { maxConnectors: 2, usedConnectors: 0 },
        quota: { period: 'month', used: 0, limit: 1024, enforce: 'cut' },
        connectors: [],
        devices: [],
      }
    },
    async createConnector() { return { token: 'tok-1', id: 'tk_1' } },
    async renameConnector() { return 'ok' },
    async setConnectorEnabled() { return 'ok' },
    async removeConnector() { return 'ok' },
    async resetBinding() { return 'ok' },
  }
  const face = createAccountsFace({
    db,
    config,
    ...(withMailer ? { mailer: { async send(message: MailMessage) { sent.push(message) } } } : {}),
    console: bridge,
    limiters: createAccountsLimiters(),
    secureCookies: false,
    codes: createCodeStore({ generate: () => '246810', cooldownMs: 0, ttlMs: 60_000 }),
  })
  let cookie = ''
  let csrf = ''
  const absorb = (setCookie: string | string[] | undefined): void => {
    const list = Array.isArray(setCookie) ? setCookie : setCookie === undefined ? [] : [setCookie]
    const pairs: string[] = []
    for (const item of list) {
      const [pair] = item.split(';')
      if (pair === undefined) continue
      const index = pair.indexOf('=')
      if (index <= 0) continue
      const name = pair.slice(0, index)
      const value = pair.slice(index + 1)
      if (name === 'dsh_relay_session' && value !== '') pairs.push(pair)
      if (name === 'dsh_relay_csrf') csrf = value
    }
    if (pairs.length > 0) cookie = pairs.join('; ')
    if (csrf !== '' && !cookie.includes('dsh_relay_csrf=')) {
      cookie = `${cookie}${cookie === '' ? '' : '; '}dsh_relay_csrf=${csrf}`
    }
  }
  const call = async (method: string, path: string, body?: Record<string, unknown>): Promise<AccountsReply> => {
    const reply = await face.handle({
      method,
      path,
      search: new URLSearchParams(),
      headers: {
        ...(cookie === '' ? {} : { cookie }),
        ...(csrf === '' ? {} : { 'x-csrf-token': csrf }),
        'user-agent': 'test',
      },
      ...(body === undefined ? {} : { body }),
      remoteAddress: '203.0.113.9',
    })
    assert.ok(reply !== undefined)
    absorb(reply.headers?.['set-cookie'])
    return reply
  }
  return { face, db, config, sent, call }
}

const record = (reply: AccountsReply): Record<string, unknown> =>
  reply.body !== null && typeof reply.body === 'object' ? reply.body as Record<string, unknown> : {}

const configOf = async (h: ReturnType<typeof harness>): Promise<Record<string, unknown>> => {
  const reply = await h.call('GET', '/api/auth/config')
  assert.equal(reply.status, 200)
  return record(reply)['registration'] as Record<string, unknown>
}

const register = (h: ReturnType<typeof harness>, email: string, password = '1234567890') =>
  h.call('POST', '/api/auth/register', { email, password })

test('未满：config 的 full 为 false，注册照常', async () => {
  const h = harness({ maxAccounts: 2 })
  assert.equal((await configOf(h))['full'], false)
  assert.equal((await register(h, 'a@qq.com')).status, 201)
  assert.equal((await configOf(h))['full'], false, '一个账号还没占满两个名额')
  assert.equal((await register(h, 'b@qq.com')).status, 201)
  assert.equal((await configOf(h))['full'], true, '到上限后 full 立刻变真（不缓存）')
})

test('满了：发码 403 registration-full、注册 409 registration-full（不在第二步才失败）', async () => {
  const h = harness({ maxAccounts: 1, requireEmailVerification: true }, true)
  assert.equal((await h.call('POST', '/api/auth/email-code', { email: 'a@qq.com', purpose: 'register' })).status, 202)
  assert.equal(
    (await h.call('POST', '/api/auth/register', { email: 'a@qq.com', code: '246810', password: '1234567890' })).status,
    201,
  )

  const code = await h.call('POST', '/api/auth/email-code', { email: 'b@qq.com', purpose: 'register' })
  assert.equal(code.status, 403)
  assert.equal(record(code)['error'], 'registration-full')
  assert.equal(h.sent.length, 1, '名额满时不该再发信（白让用户等一封邮件）')

  const registered = await h.call('POST', '/api/auth/register', {
    email: 'b@qq.com', code: '246810', password: '1234567890',
  })
  assert.equal(registered.status, 409)
  assert.equal(record(registered)['error'], 'registration-full')
  assert.equal(h.db.countUsers(), 1, '被拒的那次不许写进库')
})

test('口径含 suspended：停用一个再注册仍然算满（停用不是注销）', async () => {
  const h = harness({ maxAccounts: 2 })
  assert.equal((await register(h, 'a@qq.com')).status, 201)
  assert.equal((await register(h, 'b@qq.com')).status, 201)
  const suspended = h.db.findByEmail('b@qq.com')
  assert.ok(suspended !== undefined)
  h.db.setStatus(suspended.id, 'suspended')
  assert.equal(h.db.countUsers(), 2, 'suspended 仍算在 COUNT(*) 里')

  assert.equal((await configOf(h))['full'], true)
  const code = await h.call('POST', '/api/auth/email-code', { email: 'c@qq.com', purpose: 'register' })
  assert.equal(code.status, 403)
  assert.equal(record(code)['error'], 'registration-full')
  assert.equal((await register(h, 'c@qq.com')).status, 409)
})

test('并发：两个请求都过入口预检，只有一个能拿到最后一个位置', async () => {
  const h = harness({ maxAccounts: 1 })
  const [first, second] = await Promise.all([register(h, 'a@qq.com'), register(h, 'b@qq.com')])
  const statuses = [first.status, second.status].sort((left, right) => left - right)
  assert.deepEqual(statuses, [201, 409])
  const rejected = first.status === 409 ? first : second
  assert.equal(record(rejected)['error'], 'registration-full', '输的那一个要说明是名额，不是邮箱重复')
  assert.equal(h.db.countUsers(), 1, '事务里数 + 插入：不许两个都写进去')
})

test('closed × full 交叉：两种状态各自的状态码与文案', async () => {
  // 关闭 + 没满：closed 优先（不许注册），full 仍是假。
  const closed = harness({ mode: 'closed', maxAccounts: 5 })
  assert.equal((await configOf(closed))['full'], false)
  const closedCode = await closed.call('POST', '/api/auth/email-code', { email: 'a@qq.com', purpose: 'register' })
  assert.equal(closedCode.status, 403)
  assert.equal(record(closedCode)['error'], 'registration-closed')
  const closedRegister = await register(closed, 'a@qq.com')
  assert.equal(closedRegister.status, 403)
  assert.equal(record(closedRegister)['error'], 'registration-closed')

  // 关闭 + 满：仍是 closed（先判的那一档），不是 registration-full。
  const both = harness({ mode: 'closed', maxAccounts: 1 })
  assert.equal((await register(both, 'a@qq.com')).status, 403, 'closed 下第一条也注册不了')
  // 直接建一个账号把名额占满，再看两个入口。
  both.db.createUser({
    email: 'taken@qq.com', passwordHash: 'x', displayName: 'x', role: 'user',
    emailVerifiedAt: null, maxConnectors: null, quotaBytes: null,
  })
  assert.equal((await configOf(both))['full'], true)
  const bothCode = await both.call('POST', '/api/auth/email-code', { email: 'b@qq.com', purpose: 'register' })
  assert.equal(bothCode.status, 403)
  assert.equal(record(bothCode)['error'], 'registration-closed', 'closed 与 full 同时成立时说 closed')
  const bothRegister = await register(both, 'b@qq.com')
  assert.equal(bothRegister.status, 403)
  assert.equal(record(bothRegister)['error'], 'registration-closed')

  // 开放 + 满：full。
  const full = harness({ mode: 'open', maxAccounts: 1 })
  full.db.createUser({
    email: 'taken@qq.com', passwordHash: 'x', displayName: 'x', role: 'user',
    emailVerifiedAt: null, maxConnectors: null, quotaBytes: null,
  })
  const fullCode = await full.call('POST', '/api/auth/email-code', { email: 'c@qq.com', purpose: 'register' })
  assert.equal(fullCode.status, 403)
  assert.equal(record(fullCode)['error'], 'registration-full')
})

test('重置密码不受名额影响；已登录用户也不受影响', async () => {
  const h = harness({ maxAccounts: 1, requireEmailVerification: true }, true)
  assert.equal((await h.call('POST', '/api/auth/email-code', { email: 'a@qq.com', purpose: 'register' })).status, 202)
  assert.equal(
    (await h.call('POST', '/api/auth/register', { email: 'a@qq.com', code: '246810', password: '1234567890' })).status,
    201,
  )
  assert.equal((await configOf(h))['full'], true)

  // 已登录：/api/auth/me 与控制台照常。
  assert.equal((await h.call('GET', '/api/auth/me')).status, 200)
  assert.equal((await h.call('GET', '/api/console/state')).status, 200)

  // 重置：发码仍 202（purpose=reset 不判名额），用码能改密码，改完能登录。
  const resetCode = await h.call('POST', '/api/auth/email-code', { email: 'a@qq.com', purpose: 'reset' })
  assert.equal(resetCode.status, 202)
  const reset = await h.call('POST', '/api/auth/password/reset', {
    email: 'a@qq.com', code: '246810', password: 'new-password-1',
  })
  assert.equal(reset.status, 200)
  const login = await h.call('POST', '/api/auth/login', { email: 'a@qq.com', password: 'new-password-1' })
  assert.equal(login.status, 200)
})

test('配置解析：maxAccounts 只收正整数与 null；缺省 = null（不限）', () => {
  const base = { mode: 'accounts', smtp: { host: 'smtp.test', from: 'a@b.co' } }
  const parse = (value: unknown) => parseAuthConfig({
    ...base,
    registration: value === undefined ? {} : { maxAccounts: value },
  }, { configDir: '.' })

  assert.equal(parse(undefined).registration.maxAccounts, null)
  assert.equal(parse(null).registration.maxAccounts, null)
  assert.equal(parse(3).registration.maxAccounts, 3)
  for (const bad of [0, -1, 1.5, '3', true]) {
    assert.throws(() => parse(bad), /maxAccounts/, `坏值 ${String(bad)} 要启动失败`)
  }
})
