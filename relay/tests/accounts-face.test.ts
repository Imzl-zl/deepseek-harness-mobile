/** 账号 HTTP 面：注册 → 登录 → 控制台 → 退出；域名白名单、验证码、CSRF。 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createAccountsFace, createAccountsLimiters, type AccountsReply, type ConsoleBridge } from '../src/accounts/face.ts'
import type { AuthConfig } from '../src/accounts/config.ts'
import { createAccountsDb, publicUserOf } from '../src/accounts/db.ts'
import { createCodeStore, type MailMessage } from '../src/accounts/email.ts'
import { createRateLimiter } from '../src/rate-limit.ts'

const CONFIG: AuthConfig = {
  mode: 'accounts',
  baseUrl: 'https://relay.test',
  dbPath: ':memory:',
  serverName: '测试中转',
  registration: { mode: 'open', requireEmailVerification: true, emailDomains: ['qq.com'], maxAccounts: null },
  limits: { defaultMaxConnectors: 2, defaultQuotaBytes: 1024 },
  adminEmails: ['admin@qq.com'],
  trustProxy: false,
  sessionDays: 30,
  smtp: { host: 'smtp.test', port: 587, secure: false, starttls: true, from: 'noreply@relay.test' },
}

interface Harness {
  face: ReturnType<typeof createAccountsFace>
  db: ReturnType<typeof createAccountsDb>
  sent: MailMessage[]
  jar: { cookie: string; csrf: string }
}

function harness(options: { limiters?: ReturnType<typeof createAccountsLimiters>; config?: AuthConfig } = {}): Harness {
  const config = options.config ?? CONFIG
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
    mailer: { async send(message) { sent.push(message) } },
    console: bridge,
    limiters: options.limiters ?? createAccountsLimiters(),
    secureCookies: false,
    codes: createCodeStore({ generate: () => '246810', cooldownMs: 0, ttlMs: 60_000 }),
  })
  return { face, db, sent, jar: { cookie: '', csrf: '' } }
}

function absorb(setCookie: string | string[] | undefined, jar: Harness['jar']): void {
  const list = Array.isArray(setCookie) ? setCookie : setCookie === undefined ? [] : [setCookie]
  const pairs: string[] = []
  for (const item of list) {
    const [pair] = item.split(';')
    if (pair === undefined) continue
    const index = pair.indexOf('=')
    if (index <= 0) continue
    const name = pair.slice(0, index)
    const value = pair.slice(index + 1)
    if (name === 'dsh_relay_session' && value !== '') {
      pairs.push(pair)
      jar.cookie = pairs.join('; ')
    }
    if (name === 'dsh_relay_csrf') {
      jar.csrf = value
      if (value !== '') {
        pairs.push(pair)
        jar.cookie = pairs.join('; ')
      }
    }
  }
}

async function call(
  h: Harness,
  method: string,
  path: string,
  body?: Record<string, unknown>,
  sendCsrf = true,
): Promise<AccountsReply> {
  const reply = await h.face.handle({
    method,
    path,
    search: new URLSearchParams(),
    headers: {
      ...(h.jar.cookie === '' ? {} : { cookie: h.jar.cookie }),
      ...(sendCsrf && h.jar.csrf !== '' ? { 'x-csrf-token': h.jar.csrf } : {}),
      'user-agent': 'test',
    },
    ...(body === undefined ? {} : { body }),
    remoteAddress: '203.0.113.9',
  })
  assert.ok(reply !== undefined)
  absorb(reply.headers?.['set-cookie'], h.jar)
  return reply
}

const record = (reply: AccountsReply): Record<string, unknown> =>
  reply.body !== null && typeof reply.body === 'object' ? reply.body as Record<string, unknown> : {}

test('注册 → 会话 → 建电脑 → 退出 → 登录', async () => {
  const h = harness()
  const code = await call(h, 'POST', '/api/auth/email-code', { email: 'a@qq.com', purpose: 'register' })
  assert.equal(code.status, 202)
  assert.equal(h.sent.length, 1)
  assert.match(h.sent[0]?.text ?? '', /246810/)

  const registered = await call(h, 'POST', '/api/auth/register', {
    email: 'a@qq.com', code: '246810', password: '1234567890', displayName: 'A',
  })
  assert.equal(registered.status, 201)
  assert.equal((record(registered)['user'] as Record<string, unknown>)['email'], 'a@qq.com')
  assert.notEqual(h.jar.cookie, '', '注册即登录')

  const me = await call(h, 'GET', '/api/auth/me')
  assert.equal(me.status, 200)
  assert.equal((record(me)['user'] as Record<string, unknown>)['displayName'], 'A')

  const noCsrf = await call(h, 'POST', '/api/console/connectors', { name: '家里' }, false)
  assert.equal(noCsrf.status, 403)
  assert.equal(record(noCsrf)['error'], 'csrf')

  const made = await call(h, 'POST', '/api/console/connectors', { name: '家里' })
  assert.equal(made.status, 201)
  assert.equal(record(made)['token'], 'tok-1')

  const state = await call(h, 'GET', '/api/console/state')
  assert.equal(state.status, 200)
  assert.equal((record(state)['user'] as Record<string, unknown>)['email'], 'a@qq.com')

  const out = await call(h, 'POST', '/api/auth/logout')
  assert.equal(out.status, 200)
  assert.equal((await call(h, 'GET', '/api/auth/me')).status, 401)

  const wrong = await call(h, 'POST', '/api/auth/login', { email: 'a@qq.com', password: 'nope-nope-nope' })
  assert.equal(wrong.status, 401)
  assert.equal(record(wrong)['error'], 'bad-credentials')

  const ok = await call(h, 'POST', '/api/auth/login', { email: 'a@qq.com', password: '1234567890' })
  assert.equal(ok.status, 200)
  assert.equal((await call(h, 'GET', '/api/auth/me')).status, 200)
})

test('域名白名单、验证码错误、重复邮箱', async () => {
  const h = harness()
  const badDomain = await call(h, 'POST', '/api/auth/email-code', { email: 'a@example.com', purpose: 'register' })
  assert.equal(badDomain.status, 400)
  assert.equal(record(badDomain)['error'], 'email-domain')

  const badCode = await call(h, 'POST', '/api/auth/register', {
    email: 'b@qq.com', code: '000000', password: '1234567890',
  })
  assert.equal(badCode.status, 400)
  assert.equal(record(badCode)['error'], 'code-invalid')

  await call(h, 'POST', '/api/auth/email-code', { email: 'admin@qq.com', purpose: 'register' })
  const registered = await call(h, 'POST', '/api/auth/register', {
    email: 'admin@qq.com', code: '246810', password: '1234567890',
  })
  assert.equal(registered.status, 201)
  assert.equal((record(registered)['user'] as Record<string, unknown>)['role'], 'admin', 'adminEmails 注册即管理员')

  const again = await call(h, 'POST', '/api/auth/email-code', { email: 'admin@qq.com', purpose: 'register' })
  assert.equal(again.status, 409)
  assert.equal(record(again)['error'], 'email-taken')
})

test('发码按邮箱限流：桶用完回 429', async () => {
  const h = harness({
    limiters: {
      ...createAccountsLimiters(),
      codeEmail: createRateLimiter({ capacity: 1, refillPerSecond: 0 }),
    },
  })
  assert.equal((await call(h, 'POST', '/api/auth/email-code', { email: 'a@qq.com', purpose: 'register' })).status, 202)
  const limited = await call(h, 'POST', '/api/auth/email-code', { email: 'a@qq.com', purpose: 'register' })
  assert.equal(limited.status, 429)
  assert.equal(record(limited)['error'], 'rate-limited')
})

test('关闭邮箱验证：注册不需要验证码，也不会发信', async () => {
  const h = harness({
    config: {
      ...CONFIG,
      registration: { ...CONFIG.registration, requireEmailVerification: false },
    },
  })
  const registered = await call(h, 'POST', '/api/auth/register', {
    email: 'c@qq.com', password: '1234567890',
  })
  assert.equal(registered.status, 201)
  assert.equal(h.sent.length, 0)
})

test('注册页有"名额已满"这一档（与 closed 分开；置灰复用同一条分支）', async () => {
  const h = harness()
  const page = await call(h, 'GET', '/register')
  assert.equal(page.status, 200)
  const html = page.html ?? ''
  // 文案分开：closed 是"关闭注册"，full 是"名额已满"。
  assert.match(html, /id="closed-hint"[^>]*>这台中转已关闭注册。</)
  assert.match(html, /id="full-hint"[^>]*>注册名额已满。</)
  // 判据来自服务端现算的 `/api/auth/config`，不是页面里的常量。
  assert.match(html, /data\.registration\.full === true/)
})
