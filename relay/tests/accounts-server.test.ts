/**
 * 账号模式接进真 server 的回归：
 * 登录 → 控制台建令牌 → 控制面首连绑定 `?id=` → 管理员停用 → 连接被收掉。
 */
import assert from 'node:assert/strict'
import { mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { WebSocket } from 'ws'

import { createAccountsLimiters } from '../src/accounts/face.ts'
import type { AuthConfig } from '../src/accounts/config.ts'
import { createAccountsDb } from '../src/accounts/db.ts'
import { hashPassword } from '../src/accounts/password.ts'
import {
  appendTokenToConfig, bindConnectorInConfig, clearConnectorBindingInConfig, issueToken,
  patchTokenInConfig, removeTokenFromConfig, restoreTokenInConfig, revokeTokenInConfig,
} from '../src/issue-token.ts'
import { startRelay, type AccountsRuntime } from '../src/server.ts'
import { createTokenTable } from '../src/token-table.ts'

const CONFIG: AuthConfig = {
  mode: 'accounts',
  dbPath: ':memory:',
  serverName: '测试中转',
  registration: { mode: 'open', requireEmailVerification: false, emailDomains: ['qq.com'], maxAccounts: null },
  limits: { defaultMaxConnectors: 2, defaultQuotaBytes: 1024 },
  adminEmails: ['admin@qq.com'],
  trustProxy: false,
  sessionDays: 30,
}

interface Session {
  cookie: string
  csrf: string
}

async function login(base: string, email: string, password: string): Promise<Session> {
  const response = await fetch(`${base}/api/auth/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email, password }),
  })
  assert.equal(response.status, 200, `登录失败：${await response.clone().text()}`)
  const cookies = response.headers.getSetCookie()
  const pairs = cookies.map((item) => item.split(';')[0] ?? '')
  const csrf = pairs.find((item) => item.startsWith('dsh_relay_csrf='))?.split('=')[1] ?? ''
  return { cookie: pairs.join('; '), csrf }
}

async function postJson(base: string, path: string, session: Session, body: unknown): Promise<Response> {
  return fetch(`${base}${path}`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      cookie: session.cookie,
      'x-csrf-token': session.csrf,
    },
    body: JSON.stringify(body),
  })
}

test('账号模式：控制台建令牌 → 首连绑定 → 管理员停用收线', async (t) => {
  const dir = await mkdtemp(join(tmpdir(), 'dsh-relay-accounts-'))
  const configPath = join(dir, 'relay.config.json')
  await writeFile(configPath, `${JSON.stringify({ tokens: [] }, null, 2)}\n`, 'utf8')
  const db = createAccountsDb(':memory:')
  const table = createTokenTable([])

  const user = db.createUser({
    email: 'a@qq.com',
    passwordHash: await hashPassword('1234567890'),
    displayName: 'A',
    role: 'user',
    emailVerifiedAt: Date.now(),
    maxConnectors: null,
    quotaBytes: 1024,
  })
  db.createUser({
    email: 'admin@qq.com',
    passwordHash: await hashPassword('1234567890'),
    displayName: 'Admin',
    role: 'admin',
    emailVerifiedAt: Date.now(),
    maxConnectors: null,
    quotaBytes: null,
  })

  const runtime: AccountsRuntime = {
    db,
    config: CONFIG,
    tokens: table,
    secureCookies: false,
    limiters: createAccountsLimiters(),
    statusOf(userId) {
      const row = db.findById(userId)
      return row === undefined ? 'missing' : row.status
    },
    async createToken(owner, name) {
      const limit = owner.maxConnectors ?? CONFIG.limits.defaultMaxConnectors
      if (table.countForUser(owner.id) >= limit) throw new Error('connector-limit')
      const id = `tk_${Math.random().toString(36).slice(2, 10)}`
      const issued = issueToken({ kind: 'connector', id })
      const createdAt = Date.now()
      await appendTokenToConfig(configPath, { kind: 'connector', id, hash: issued.hash, userId: owner.id, name, createdAt })
      table.add({ kind: 'connector', id, hash: issued.hash, userId: owner.id, name, createdAt })
      return { token: issued.token, id }
    },
    async renameToken(id, name) {
      if (!(await patchTokenInConfig(configPath, { kind: 'connector', id }, { name }))) return false
      return table.setName(id, name)
    },
    async setTokenEnabled(id, enabled) {
      if (enabled) {
        if (!table.restore(id)) return false
        await restoreTokenInConfig(configPath, { kind: 'connector', id })
        return true
      }
      if (!table.revoke(id)) return false
      await revokeTokenInConfig(configPath, { kind: 'connector', id })
      return true
    },
    async removeToken(id) {
      if (!table.remove(id)) return false
      await removeTokenFromConfig(configPath, { kind: 'connector', id })
      return true
    },
    async resetBinding(id) {
      if (!(await clearConnectorBindingInConfig(configPath, { kind: 'connector', id }))) return false
      return table.clearConnectorBinding(id)
    },
    async bindToken(id, connectorId) {
      const bound = await bindConnectorInConfig(configPath, { kind: 'connector', id }, connectorId)
      if (bound) table.bindConnector(id, connectorId)
      return bound
    },
  }

  const relay = await startRelay({
    port: 0,
    host: '127.0.0.1',
    authenticate: (token) => table.authenticate(token),
    ownerOf: (connectorId) => table.ownerOf(connectorId),
    accounts: runtime,
  })
  t.after(async () => {
    await relay.close()
    db.close()
  })
  const base = `http://127.0.0.1:${relay.port}`
  const wsBase = `ws://127.0.0.1:${relay.port}`

  const session = await login(base, 'a@qq.com', '1234567890')

  // 两台电脑；第三台被账号上限挡住。
  const first = await postJson(base, '/api/console/connectors', session, { name: '家里' })
  assert.equal(first.status, 201)
  const firstBody = await first.json() as { token: string; id: string }
  const second = await postJson(base, '/api/console/connectors', session, { name: '公司' })
  assert.equal(second.status, 201)
  const third = await postJson(base, '/api/console/connectors', session, { name: '第三台' })
  assert.equal(third.status, 409)
  assert.equal((await third.json() as { error: string }).error, 'connector-limit')

  // 管理员把上限改成 3：库里的值是唯一真相，控制台下一次就能建第三台。
  const admin = await login(base, 'admin@qq.com', '1234567890')
  const raised = await postJson(base, '/admin/api/users/limits', admin, { id: user.id, maxConnectors: 3 })
  assert.equal(raised.status, 200)
  const thirdOk = await postJson(base, '/api/console/connectors', session, { name: '第三台' })
  assert.equal(thirdOk.status, 201)

  // 第一次连上来：令牌是随机的，`?id=` 是电脑自报的 pcId —— 绑定发生在这里。
  const ws = new WebSocket(`${wsBase}/ws/connector?id=pc-home`, {
    headers: { authorization: `Bearer ${firstBody.token}` },
  })
  await new Promise<void>((resolve, reject) => {
    ws.once('open', resolve)
    ws.once('error', reject)
    setTimeout(() => reject(new Error('控制面没有连上')), 3_000)
  })
  assert.equal(table.list().find((row) => row.id === firstBody.id)?.connectorId, 'pc-home')
  assert.equal(table.ownerOf('pc-home'), user.id)

  // 同一枚令牌换一个 ?id= 再连：403（绑定之后必须一致）。
  const mismatch = await new Promise<number>((resolve, reject) => {
    const other = new WebSocket(`${wsBase}/ws/connector?id=pc-other`, {
      headers: { authorization: `Bearer ${firstBody.token}` },
    })
    other.on('error', () => { /* terminate 在握手期会再发一个 error；这里吃掉 */ })
    other.on('unexpected-response', (_request, response) => {
      resolve(response.statusCode ?? 0)
      other.terminate()
    })
    other.on('open', () => reject(new Error('不一致的 ?id= 也连上了')))
    setTimeout(() => reject(new Error('没有拿到 403')), 3_000)
  })
  assert.equal(mismatch, 403)

  // 管理员账号会话可以直接进管理面（不需要 break-glass 令牌）。
  const stateResponse = await fetch(`${base}/admin/api/state`, { headers: { cookie: admin.cookie } })
  assert.equal(stateResponse.status, 200)
  const state = await stateResponse.json() as { users: { email: string }[] }
  assert.equal(state.users.length, 2)
  assert.equal(state.users.some((row) => row.email === 'a@qq.com'), true)

  // 停用：控制面立刻被收掉（4000）。
  const closed = new Promise<{ code: number; reason: string }>((resolve) => {
    ws.once('close', (code, reason) => resolve({ code, reason: reason.toString() }))
  })
  const suspended = await postJson(base, '/admin/api/users/status', admin, { id: user.id, status: 'suspended' })
  assert.equal(suspended.status, 200)
  const closedInfo = await closed
  assert.equal(closedInfo.code, 4000)
  assert.match(closedInfo.reason, /account suspended/)

  // 停用同时作废浏览器会话，不只是收连接。
  const meAfter = await fetch(`${base}/api/auth/me`, { headers: { cookie: session.cookie } })
  assert.equal(meAfter.status, 401, '被停用账号的会话应立即失效')

  // 配置里落的是连接器 id，不是明文令牌。
  const raw = await readFile(configPath, 'utf8')
  assert.match(raw, /pc-home/)
  assert.equal(raw.includes(firstBody.token), false)
})
