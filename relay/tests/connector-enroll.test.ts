/**
 * 连接器自助兑换（`POST /connector/enroll`）。
 *
 * 守四条：
 *
 * 1. **不传装配面 = 关闭**（403）：没接线的中转绝不放行；
 * 2. `required` 也是 403 —— "要不要认证"只由模式决定，认证路径没有第二条；
 * 3. `open` 签出来的令牌**就是一张普通令牌**：立刻能用同一张表认证，行上带 `source: auto`；
 * 4. 名额只由 `limit` 决定：`null` 不拦，给了数字就用完即 `429 auto-enroll-full`。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { issueToken } from '../src/issue-token.ts'
import { startRelay, type ConnectorEnroll } from '../src/server.ts'
import { createTokenTable } from '../src/token-table.ts'

interface EnrollOptions {
  mode?: 'open' | 'required'
  limit?: number | null
}

/** 起一台只带兑换面的中转，返回它的端口与那张摘要表。 */
async function withRelay(
  options: EnrollOptions | null,
  run: (ctx: { port: number; table: ReturnType<typeof createTokenTable> }) => Promise<void>,
): Promise<void> {
  const table = createTokenTable([])
  let issued = 0
  const enroll: ConnectorEnroll = {
    mode: options?.mode ?? 'open',
    limit: options?.limit ?? null,
    count: () => table.list().filter((row) => row.source === 'auto' && row.revokedAt === undefined).length,
    async issue({ pcId }) {
      issued += 1
      const id = `auto-${pcId === '' ? 'x' : pcId}-${issued}`
      const token = issueToken({ kind: 'connector', id })
      table.add({ kind: 'connector', id, hash: token.hash, source: 'auto' })
      return { token: token.token, connectorId: id }
    },
  }
  const relay = await startRelay({
    port: 0,
    host: '127.0.0.1',
    authenticate: (token) => table.authenticate(token),
    ...(options === null ? {} : { connectorEnroll: enroll }),
  })
  try {
    await run({ port: relay.port, table })
  } finally {
    await relay.close()
  }
}

const enroll = (port: number, body: unknown): Promise<Response> =>
  fetch(`http://127.0.0.1:${port}/connector/enroll`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })

test('没接兑换面：一律 403（关闭是默认，不接就是没有）', async () => {
  await withRelay(null, async ({ port }) => {
    const response = await enroll(port, { pcId: 'pc-1' })
    assert.equal(response.status, 403)
    assert.deepEqual(await response.json(), { error: 'connector-auth-required' })
  })
})

test('required 模式：403（只认管理员签发的令牌）', async () => {
  await withRelay({ mode: 'required' }, async ({ port }) => {
    const response = await enroll(port, { pcId: 'pc-1' })
    assert.equal(response.status, 403)
    assert.deepEqual(await response.json(), { error: 'connector-auth-required' })
  })
})

test('open 模式：签出来的就是一张普通令牌，立刻能用同一张表认证', async () => {
  await withRelay({ mode: 'open' }, async ({ port, table }) => {
    const response = await enroll(port, { pcId: 'pc-1', name: '我的台式机' })
    assert.equal(response.status, 201)
    const body = await response.json() as { token: string; connectorId: string }
    assert.equal(typeof body.token, 'string')
    assert.match(body.connectorId, /^auto-/)

    // **同一个认证入口**：不需要"自动令牌"专用的第二条路径。
    assert.equal(table.authenticate(body.token)?.id, body.connectorId)
    // 行上带 `source: auto`：面板据此标"来源：自动"，可批量清理。
    const row = table.list().find((item) => item.id === body.connectorId)
    assert.equal(row?.source, 'auto')
    assert.equal(row?.revokedAt, undefined)
  })
})

test('缺 pcId：400（不留匿名身份）', async () => {
  await withRelay({ mode: 'open' }, async ({ port }) => {
    const response = await enroll(port, { name: '没有 pcId' })
    assert.equal(response.status, 400)
    assert.deepEqual(await response.json(), { error: 'pcId-required' })
  })
})

test('名额：limit=1 时第二次 429；limit=null 时不拦', async () => {
  await withRelay({ mode: 'open', limit: 1 }, async ({ port }) => {
    assert.equal((await enroll(port, { pcId: 'pc-1' })).status, 201)
    const second = await enroll(port, { pcId: 'pc-2' })
    assert.equal(second.status, 429)
    assert.deepEqual(await second.json(), { error: 'auto-enroll-full' })
  })
  await withRelay({ mode: 'open', limit: null }, async ({ port }) => {
    for (const pcId of ['pc-1', 'pc-2', 'pc-3']) {
      assert.equal((await enroll(port, { pcId })).status, 201)
    }
  })
})

test('吊销后就腾出名额（名额只数"还在用"的自动条目）', async () => {
  await withRelay({ mode: 'open', limit: 1 }, async ({ port, table }) => {
    const first = await enroll(port, { pcId: 'pc-1' })
    const created = await first.json() as { connectorId: string }
    assert.equal((await enroll(port, { pcId: 'pc-2' })).status, 429)

    table.revoke(created.connectorId)
    assert.equal((await enroll(port, { pcId: 'pc-3' })).status, 201)
  })
})
