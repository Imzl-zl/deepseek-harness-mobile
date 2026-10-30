/**
 * 管理面：凭据、页面、读快照与四个写动作（`relay/src/admin/*`、`server.ts` 的 `/admin` 分支）。
 *
 * 要钉住的六条：
 * 1. 没配 `admin` ⇒ `/admin*` 一律 404（与未知路径同形）；
 * 2. 配了 ⇒ 缺/错令牌 401 且 `cache-control: no-store`，对的才给页面与快照；
 * 3. 页面是**单文件内联**（没有任何外链），未认证连页面都拿不到；
 * 4. 写操作**全部**要求同一个 Bearer（没有 cookie，就没有 CSRF 可打）；
 * 5. 改额度 / 重置 / 断开 / 吊销各自打到真正的状态上，并留一条 `admin.action` 审计；
 * 6. 升级回调里再验一次令牌：认证与回调之间被吊销的连接，建立后立刻被关。
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { test } from 'node:test'

import { WebSocket } from 'ws'

import { startRelay } from '../src/server.ts'
import type { Authenticated } from '../src/http-face.ts'
import type { AdminOps, AdminStateView } from '../src/admin/routes.ts'

const ADMIN_TOKEN = 'admin-token-for-tests'
const ADMIN = { id: 'ops', hash: createHash('sha256').update(ADMIN_TOKEN, 'utf8').digest('hex') }
const AUTH = { authorization: `Bearer ${ADMIN_TOKEN}` }

const baseOf = (port: number): string => `http://127.0.0.1:${port}`
const wsBaseOf = (port: number): string => `ws://127.0.0.1:${port}`

const get = (base: string, path: string, headers: Record<string, string> = {}) =>
  fetch(`${base}${path}`, { headers })
const post = (base: string, path: string, headers: Record<string, string>, body: unknown) =>
  fetch(`${base}${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: JSON.stringify(body),
  })

/**
 * 等一条 socket 关闭，**带超时**。
 *
 * 少了超时，用例在"应当被关掉却没有"时会挂住整个套件 —— 变异校验时这会把
 * "1 条红"变成"一直转"，看起来像环境问题而不是断言失败。
 */
const closedWithin = (ws: WebSocket, ms = 2_000): Promise<{ code: number; reason: string }> =>
  new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('等待关闭超时（连接没有被收掉）')), ms)
    ws.once('close', (code, reason) => {
      clearTimeout(timer)
      resolve({ code, reason: reason.toString() })
    })
  })

/** 收集审计日志（只关心 `admin.action`）。 */
function recorder(): { log: { info(m: string, d?: unknown): void; warn(m: string, d?: unknown): void; error(m: string, d?: unknown): void; debug(m: string, d?: unknown): void }; actions: Record<string, unknown>[] } {
  const actions: Record<string, unknown>[] = []
  const noop = (): void => { /* 其余级别不关心 */ }
  return {
    actions,
    log: {
      info: (message, detail) => { if (message === 'admin.action') actions.push(detail as Record<string, unknown>) },
      warn: noop, error: noop, debug: noop,
    },
  }
}

const opsOf = (calls: string[]): AdminOps => ({
  tokens: () => [
    { id: 'conn-1', owner: 'alice' },
    { id: 'old-pc', revokedAt: 1_700_000_000_000 },
  ],
  async setTokenEnabled(id, enabled) {
    calls.push(`token:${id}:${enabled}`)
    return { ok: true }
  },
  async persistQuota(owner, bytes) {
    calls.push(`quota:${owner}:${bytes}`)
    return { ok: true }
  },
})

const TOKENS: Record<string, Authenticated> = {
  't-conn': { kind: 'connector', id: 'conn-1', owner: 'alice' },
}

test('没配 admin：这张面不存在（404），带上令牌也一样', async (t) => {
  const relay = await startRelay({ port: 0, authenticate: () => undefined })
  t.after(() => relay.close())
  const base = baseOf(relay.port)

  assert.equal((await get(base, '/admin/api/state')).status, 404)
  assert.equal((await get(base, '/admin/api/state', AUTH)).status, 404, '没配置就没有"猜对了就开"这回事')
  assert.equal((await get(base, '/admin')).status, 404)
})

test('配了 admin：缺/错令牌 401 且 no-store；对的给页面与快照（摘要本身不算凭据）', async (t) => {
  const calls: string[] = []
  const relay = await startRelay({ port: 0, authenticate: () => undefined, admin: ADMIN, adminOps: opsOf(calls) })
  t.after(() => relay.close())
  const base = baseOf(relay.port)

  const anonymous = await get(base, '/admin/api/state')
  assert.equal(anonymous.status, 401)
  assert.equal(anonymous.headers.get('cache-control'), 'no-store')
  assert.deepEqual(await anonymous.json(), { error: 'unauthorized' })

  assert.equal((await get(base, '/admin/api/state', { authorization: 'Bearer nope' })).status, 401)
  assert.equal((await get(base, '/admin/api/state', { authorization: `Bearer ${ADMIN.hash}` })).status, 401)

  // **页面本身不要令牌**：它只有输入框与渲染逻辑（`/admin/api/*` 与写操作才要 Bearer）。
  // 要令牌的话浏览器打开 URL 不会带它，用户永远没地方填 —— 自我锁死。
  const page = await get(base, '/admin')
  assert.equal(page.status, 200)
  assert.match(page.headers.get('content-type') ?? '', /text\/html/)
  assert.match(page.headers.get('content-security-policy') ?? '', /default-src 'none'/)
  const html = await page.text()
  assert.match(html, /管理令牌/, '页面上有令牌输入框')
  assert.equal(/<script[^>]+src=/.test(html), false, '单文件：没有任何外链脚本')
  assert.equal(/<link[^>]+href=/.test(html), false, '单文件：没有任何外链样式表')

  const state = (await (await get(base, '/admin/api/state', AUTH)).json()) as AdminStateView
  assert.equal(state.v, 1)
  assert.deepEqual(state.connectors, [])
  assert.deepEqual(state.channels, [])
  assert.deepEqual(state.roster, { devices: 0, bound: 0, published: {} })
  assert.equal(state.quota, null, '没配额度就是 null（面板据此显示"未配置"）')
  assert.deepEqual(state.tokens.map((row) => row.id), ['conn-1', 'old-pc'], '令牌清单来自落盘点，且不含摘要')
})

test('写操作都要同一个 Bearer；GET 路径不接受 POST', async (t) => {
  const calls: string[] = []
  const relay = await startRelay({ port: 0, authenticate: () => undefined, admin: ADMIN, adminOps: opsOf(calls) })
  t.after(() => relay.close())
  const base = baseOf(relay.port)

  assert.equal((await post(base, '/admin/api/quota', {}, { subject: 'user:alice', bytes: 1 })).status, 401)
  assert.equal((await post(base, '/admin/api/disconnect', {}, { connectorId: 'conn-1' })).status, 401)
  assert.deepEqual(calls, [], '未认证的写请求不该落到落盘点')

  assert.equal((await post(base, '/admin/api/state', AUTH, {})).status, 404, '读路径不接受写')
  assert.equal((await post(base, '/admin/api/quota', AUTH, { subject: 'nobody', bytes: 1 })).status, 400)
  assert.equal((await post(base, '/admin/api/quota', AUTH, { subject: 'user:alice', bytes: -1 })).status, 400)
})

test('面板能管：改额度写回配置、重置用量、断开连接器、吊销令牌（各留一条审计）', async (t) => {
  const calls: string[] = []
  const { log, actions } = recorder()
  const relay = await startRelay({
    port: 0,
    authenticate: (token) => TOKENS[token],
    admin: ADMIN,
    adminOps: opsOf(calls),
    ownerOf: (id) => (id === 'conn-1' ? 'alice' : undefined),
    quota: { period: 'month', enforce: 'cut', defaultBytes: 100, owners: { alice: 500 } },
    log,
  })
  t.after(() => relay.close())
  const base = baseOf(relay.port)
  const wsBase = wsBaseOf(relay.port)

  const connector = await new Promise<WebSocket>((resolve, reject) => {
    const ws = new WebSocket(`${wsBase}/ws/connector?id=conn-1`, { headers: { authorization: 'Bearer t-conn' } })
    ws.once('open', () => resolve(ws))
    ws.once('error', reject)
  })
  t.after(() => connector.close())

  const before = (await (await get(base, '/admin/api/state', AUTH)).json()) as AdminStateView
  assert.deepEqual(before.connectors.map((row) => row.connectorId), ['conn-1'])
  assert.equal(before.connectors[0]?.owner, 'alice')
  assert.deepEqual(before.quota?.rows.map((row) => row.subject), ['user:alice'], '没流量的人也在面板上')
  assert.equal(before.quota?.rows[0]?.used, 0)

  // 改额度：内存立刻生效 + 写回配置（按人）
  assert.equal((await post(base, '/admin/api/quota', AUTH, { subject: 'user:alice', bytes: 2_048 })).status, 200)
  assert.equal(relay.metering?.limitOf('user:alice'), 2_048)
  assert.deepEqual(calls, ['quota:alice:2048'])

  // 重置用量
  relay.metering?.charge('conn-1', 10)
  assert.equal(relay.metering?.usedOf('user:alice'), 10)
  assert.equal((await post(base, '/admin/api/quota/reset', AUTH, { subject: 'user:alice' })).status, 200)
  assert.equal(relay.metering?.usedOf('user:alice'), 0)

  // 吊销令牌：落盘点被调用，且已在线的那条控制面立刻被收掉
  const closed = closedWithin(connector)
  assert.equal((await post(base, '/admin/api/tokens/revoke', AUTH, { id: 'conn-1' })).status, 200)
  assert.equal((await closed).code, 4000)
  assert.deepEqual(calls.at(-1), 'token:conn-1:false')
  assert.equal(relay.core.stats.connectors, 0, '吊销等于下线，不是"配置文件里的一个字段"')

  assert.deepEqual(
    actions.map((action) => action['action']),
    ['quota.set', 'quota.reset', 'token.revoke'],
  )
  assert.equal(actions[0]?.['actor'], 'ops')
})

test('断开：按连接器整条收掉；按设备只收那一条通道', async (t) => {
  const { log } = recorder()
  const relay = await startRelay({
    port: 0, authenticate: (token) => TOKENS[token], admin: ADMIN, adminOps: opsOf([]), log,
  })
  t.after(() => relay.close())
  const base = baseOf(relay.port)
  const wsBase = wsBaseOf(relay.port)

  const open = (): Promise<WebSocket> => new Promise((resolve, reject) => {
    const ws = new WebSocket(`${wsBase}/ws/connector?id=conn-1`, { headers: { authorization: 'Bearer t-conn' } })
    ws.once('open', () => resolve(ws))
    ws.once('error', reject)
  })

  const first = await open()
  const firstClosed = closedWithin(first)
  assert.equal((await post(base, '/admin/api/disconnect', AUTH, { connectorId: 'conn-1' })).status, 200)
  assert.equal((await firstClosed).code, 4000)
  assert.equal(relay.core.stats.connectors, 0)

  // 已经不在线：同样的请求回 404（不假装成功）
  assert.equal((await post(base, '/admin/api/disconnect', AUTH, { connectorId: 'conn-1' })).status, 404)

  // 按设备：没有那条通道 → 404（面板点的是它自己列出来的行，不该出现"点了没反应"）
  const second = await open()
  t.after(() => second.close())
  assert.equal(
    (await post(base, '/admin/api/disconnect', AUTH, { connectorId: 'conn-1', deviceId: 'dev-1' })).status,
    404,
  )
})

test('升级回调里再验一次：认证与回调之间被吊销 ⇒ 建立后立刻以 4000 关闭', async (t) => {
  // 真实吊销发生在外面的 `await` 之间；这里用"第二次认证就认不出"的替身精确复现那一刻。
  let calls = 0
  const once: Authenticated = { kind: 'connector', id: 'conn-1' }
  const relay = await startRelay({
    port: 0,
    authenticate: () => {
      calls += 1
      return calls === 1 ? once : undefined
    },
  })
  t.after(() => relay.close())

  const closed = await new Promise<{ code: number; reason: string }>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('等待关闭超时')), 2_000)
    const ws = new WebSocket(`${wsBaseOf(relay.port)}/ws/connector?id=conn-1`, {
      headers: { authorization: 'Bearer any' },
    })
    ws.on('close', (code, reason) => {
      clearTimeout(timer)
      resolve({ code, reason: reason.toString() })
    })
    ws.on('error', () => { /* 关闭可能先表现为 error；断言只认 close 事件 */ })
  })

  assert.equal(closed.code, 4000, '不是 4003：控制面拒绝不在握手层')
  assert.equal(closed.reason, 'credential revoked')
  assert.equal(relay.core.stats.connectors, 0, '被吊销的控制面不得留在在线集合里')
})
