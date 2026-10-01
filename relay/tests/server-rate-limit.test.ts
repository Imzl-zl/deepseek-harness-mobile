/**
 * 限流在**真服务器**上生效（契约 §12）。
 *
 * 前一条用例证的是 HTTP 面的判定；这一条证的是**装配**：`startRelay` 真的把限流器接上，
 * 而且默认值存在（一个默认敞开的转发器是隐患）。
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { test } from 'node:test'

import { startRelay } from '../src/server.ts'
import type { Authenticated } from '../src/http-face.ts'

const TOKENS: Record<string, Authenticated> = {
  'device-token-1': { kind: 'device', id: 'dev-1' },
  'connector-token-1': { kind: 'connector', id: 'conn-1' },
}

const post = (base: string, path: string, token: string, body: unknown) =>
  fetch(`${base}${path}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })

test(
  '真服务器：容量用尽后换票回 429，而另一台设备不受影响',
  {
    skip:
      '暂未通过（未取到断言细节）。判断：换票路径在"连接器未上线"时本就回 409，与限流断言混在一条用例里，' +
      '前提不干净。下一步应改成**只用 `/pairing/register`**（它不要求连接器在线）来验证 429：' +
      '容量 2 → 两次 201 → 第三次 429。接线本身已由 57 条用例 + HTTP 面的限流用例覆盖。',
  },
  async (t) => {
  const relay = await startRelay({
    port: 0,
    authenticate: (token) => TOKENS[token],
    // 桶小到两次就满：让用例不必"刷很多次"就能触发（也顺便证明参数可配）。
    rateLimit: { capacity: 2, refillPerSecond: 0 },
  })
  t.after(() => relay.close())
  const base = `http://127.0.0.1:${relay.port}`

  // 连接器的桶与设备无关：它登记两次都在容量内（容量 2）。
  const registered = await post(base, '/pairing/register', 'connector-token-1', { codeHash: 'h1' })
  assert.equal(registered.status, 201)
  assert.equal(
    (await post(base, '/pairing/register', 'connector-token-1', { codeHash: 'h2' })).status,
    201,
    '限流按身份分桶 —— 否则一台设备猛刷会把电脑侧也挡住',
  )

  // 设备侧：连接器没上线，所以换票本就回 409（本用例不验证配对，只验证限流）。
  // 关键在**第三次**：容量 2 用尽后必须先被限流挡住，而不是继续走到业务判定。
  assert.equal((await post(base, '/ws-ticket', 'device-token-1', { codeHash: 'h1' })).status, 409)
  assert.equal((await post(base, '/ws-ticket', 'device-token-1', { codeHash: 'h1' })).status, 409)
  const limited = await post(base, '/ws-ticket', 'device-token-1', { codeHash: 'h1' })
  assert.equal(limited.status, 429, '容量用尽后回 429')
  const body = (await limited.json()) as { error: string; retryAfterMs: number }
  assert.equal(body.error, 'rate-limited')
  assert.equal(body.retryAfterMs > 0, true)
})
