/**
 * 限流在**真服务器**上生效（契约 §12）。
 *
 * 前一条用例证的是 HTTP 面的判定；这一条证的是**装配**：`startRelay` 真的把限流器接上，
 * 而且默认值存在（一个默认敞开的转发器是隐患）。
 *
 * v2 的一处新事实：**控制连接的升级也从连接器自己的桶里取令牌**
 * （`limiter.take('connector:<id>')`）—— 所以"连接器桶里有 3 个令牌"要算上它。
 * 这也正是"一台设备刷不垮电脑侧"的另一半：两套身份各有各的上界。
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { test } from 'node:test'

import { WebSocket } from 'ws'

import { startRelay } from '../src/server.ts'
import type { Authenticated } from '../src/http-face.ts'

const TOKENS: Record<string, Authenticated> = {
  'connector-token-1': { kind: 'connector', id: 'conn-1' },
}

/** 设备令牌由**名册**认（v2：中转只存摘要）。 */
const DEVICE_TOKEN = 'device-token-1'
const ROSTER = [
  {
    id: 'dev-1',
    pairingId: 'pair-1',
    devPubEd: 'a'.repeat(64),
    devPubDh: 'b'.repeat(64),
    name: '我的手机',
    tokenHash: createHash('sha256').update(DEVICE_TOKEN, 'utf8').digest('hex'),
  },
]
const OFFER_ID = 'A'.repeat(22)

const post = (base: string, path: string, token: string, body: unknown) =>
  fetch(`${base}${path}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })

const open = (url: string, headers: Record<string, string> = {}): Promise<WebSocket> =>
  new Promise((resolve, reject) => {
    const ws = new WebSocket(url, { headers })
    ws.once('open', () => resolve(ws))
    ws.once('error', reject)
  })

test('真服务器：容量用尽后回 429，且按身份分桶（一台设备刷不垮电脑侧）', async (t) => {
  const relay = await startRelay({
    port: 0,
    authenticate: (token) => TOKENS[token],
    // 桶小到几次就满：让用例不必"刷很多次"就能触发（也顺便证明参数可配）。
    rateLimit: { capacity: 3, refillPerSecond: 0 },
  })
  t.after(() => relay.close())
  const base = `http://127.0.0.1:${relay.port}`
  const wsBase = `ws://127.0.0.1:${relay.port}`

  // 连接器的桶（容量 3）：控制面升级(1) → 名册上报(2) → 出码登记(3)
  const connector = await open(`${wsBase}/ws/connector`, {
    authorization: 'Bearer connector-token-1',
  })
  t.after(() => connector.close())
  assert.equal(
    (await post(base, '/devices', 'connector-token-1', { devices: ROSTER })).status,
    201,
    '名册上报（只交摘要）',
  )
  assert.equal(
    (await post(base, '/pairing/register', 'connector-token-1', { v: 2, offerId: OFFER_ID })).status,
    201,
    '出码登记（公开邀请，不含秘密）',
  )

  const limited = await post(base, '/pairing/register', 'connector-token-1', { v: 2, offerId: OFFER_ID })
  assert.equal(limited.status, 429, '容量用尽后回 429')
  const body = (await limited.json()) as { error: string; retryAfterMs: number | null }
  assert.equal(body.error, 'rate-limited')
  // `refillPerSecond: 0` = 硬配额：如实回 `null`（"不会自行恢复"）。
  // 这里原本断言 `> 0`，而实现返回 `Infinity` —— 过 JSON 会变成 `null`，
  // 正是这条用例把那个问题逼出来的（见笔记）。
  assert.equal(body.retryAfterMs, null)

  // 设备有自己的桶：连接器被限住不该牵连它（否则一台设备猛刷会把电脑侧也挡住）。
  // 设备桶也是 3：前三次换票照常，第四次才是它自己的上界。
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    assert.equal(
      (await post(base, '/ws-ticket', DEVICE_TOKEN, {})).status,
      201,
      `设备第 ${attempt} 次换票应当放行（它自己的桶是满的）`,
    )
  }
  assert.equal(
    (await post(base, '/ws-ticket', DEVICE_TOKEN, {})).status,
    429,
    '设备也有自己的上界 —— 否则一台设备就能把中转刷成自己的专属转发器',
  )
})
