/**
 * 管理面的凭据与"没配就不存在"（`relay/src/admin/auth.ts`、`server.ts` 的 `/admin` 分支）。
 *
 * 三条要钉住：
 * 1. 没配 `admin` ⇒ `/admin*` 一律 404（与未知路径同形，不泄露"有没有配置"）；
 * 2. 配了 ⇒ 没令牌/错令牌 401 且 `cache-control: no-store`，对的给计数快照；
 * 3. 升级回调里**再验一次**：认证与回调之间被吊销的连接，建立后立刻被关。
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { test } from 'node:test'

import { WebSocket } from 'ws'

import { startRelay } from '../src/server.ts'
import type { Authenticated } from '../src/http-face.ts'

const ADMIN_TOKEN = 'admin-token-for-tests'
const ADMIN = { id: 'ops', hash: createHash('sha256').update(ADMIN_TOKEN, 'utf8').digest('hex') }

const baseOf = (port: number): string => `http://127.0.0.1:${port}`
const wsBaseOf = (port: number): string => `ws://127.0.0.1:${port}`

test('没配 admin：这张面不存在（404），带上令牌也一样', async (t) => {
  const relay = await startRelay({ port: 0, authenticate: () => undefined })
  t.after(() => relay.close())
  const base = baseOf(relay.port)

  const anonymous = await fetch(`${base}/admin/api/state`)
  assert.equal(anonymous.status, 404)
  const withToken = await fetch(`${base}/admin/api/state`, {
    headers: { authorization: `Bearer ${ADMIN_TOKEN}` },
  })
  assert.equal(withToken.status, 404, '没配置就没有"猜对了就开"这回事')
})

test('配了 admin：没令牌/错令牌 401 且 no-store；对的给计数快照', async (t) => {
  const relay = await startRelay({ port: 0, authenticate: () => undefined, admin: ADMIN })
  t.after(() => relay.close())
  const base = baseOf(relay.port)

  const anonymous = await fetch(`${base}/admin/api/state`)
  assert.equal(anonymous.status, 401)
  assert.equal(anonymous.headers.get('cache-control'), 'no-store', '凭据走头，响应不许被缓存')
  assert.deepEqual(await anonymous.json(), { error: 'unauthorized' })

  const wrong = await fetch(`${base}/admin/api/state`, { headers: { authorization: 'Bearer nope' } })
  assert.equal(wrong.status, 401)

  const digestAsToken = await fetch(`${base}/admin/api/state`, {
    headers: { authorization: `Bearer ${ADMIN.hash}` },
  })
  assert.equal(digestAsToken.status, 401, '摘要本身不是凭据（否则读走配置就等于拿到钥匙）')

  const ok = await fetch(`${base}/admin/api/state`, {
    headers: { authorization: `Bearer ${ADMIN_TOKEN}` },
  })
  assert.equal(ok.status, 200)
  const body = (await ok.json()) as { v: number; counters: Record<string, number> }
  assert.equal(body.v, 1)
  for (const key of ['connectors', 'channels', 'tickets', 'devices', 'bound']) {
    assert.equal(typeof body.counters[key], 'number', `计数快照缺少 ${key}`)
  }
})

test('管理面本期只读：POST 被拒（还没有任何写路径）', async (t) => {
  const relay = await startRelay({ port: 0, authenticate: () => undefined, admin: ADMIN })
  t.after(() => relay.close())

  const posted = await fetch(`${baseOf(relay.port)}/admin/api/state`, {
    method: 'POST',
    headers: { authorization: `Bearer ${ADMIN_TOKEN}`, 'content-type': 'application/json' },
    body: '{}',
  })
  assert.equal(posted.status, 405)
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
