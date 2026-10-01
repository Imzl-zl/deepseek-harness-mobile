/**
 * 中转服务的冒烟用例（契约 §2）：**真 HTTP + 真 WS + 真路由**。
 *
 * 前面 33 条用例测的是判定（零依赖、几十毫秒）；这一条测的是"接起来之后真的能转发" ——
 * 它是唯一能覆盖"凭据从哪来、升级怎么认证、投递写回哪条 socket"的证据。
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { WebSocket } from 'ws'

import { startRelay } from '../src/server.ts'
import type { Authenticated } from '../src/http-face.ts'

const TOKENS: Record<string, Authenticated> = {
  'device-token-1': { kind: 'device', id: 'dev-1' },
  'connector-token-1': { kind: 'connector', id: 'conn-1' },
}

const line = (frame: Record<string, unknown>): string => JSON.stringify({ v: 1, ...frame })
const ev = (sid: string, seq: number): string => line({ t: 'ev', sid, seq, fc: seq, box: 'x' })

/** 等到某个 Promise 解开（带超时：失败要快、要清楚，不要挂住整个套件）。 */
function waitFor<T>(what: string, check: () => T | undefined, timeoutMs = 2_000): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const started = Date.now()
    const timer = setInterval(() => {
      const value = check()
      if (value !== undefined) {
        clearInterval(timer)
        resolve(value)
        return
      }
      if (Date.now() - started > timeoutMs) {
        clearInterval(timer)
        reject(new Error(`等待超时：${what}`))
      }
    }, 5)
  })
}

/** 收集一条 socket 收到的所有原始行。 */
function collect(ws: WebSocket): string[] {
  const lines: string[] = []
  ws.on('message', (data) => {
    lines.push(typeof data === 'string' ? data : Buffer.from(data as Buffer).toString('utf8'))
  })
  return lines
}

const open = (url: string, headers: Record<string, string> = {}): Promise<WebSocket> =>
  new Promise((resolve, reject) => {
    const ws = new WebSocket(url, { headers })
    ws.once('open', () => resolve(ws))
    ws.once('error', reject)
  })

test('端到端：换票 → 两条 WS 升级 → 设备发一行 → 连接器收到（真 socket）', async (t) => {
  const relay = await startRelay({ port: 0, authenticate: (token) => TOKENS[token] })
  t.after(() => relay.close())
  const base = `http://127.0.0.1:${relay.port}`
  const wsBase = `ws://127.0.0.1:${relay.port}`

  // 1. 连接器先连上（登记与认领都要求它在线）
  const connector = await open(`${wsBase}/ws/connector`, {
    authorization: 'Bearer connector-token-1',
  })
  t.after(() => connector.close())
  const connectorLines = collect(connector)

  // 2. 电脑侧出码登记（HTTP，连接器令牌）
  const registered = await fetch(`${base}/pairing/register`, {
    method: 'POST',
    headers: { authorization: 'Bearer connector-token-1', 'content-type': 'application/json' },
    body: JSON.stringify({ codeHash: 'hash-a' }),
  })
  assert.equal(registered.status, 201)

  // 3. 手机换票（HTTP，设备令牌 + codeHash）
  const ticketed = await fetch(`${base}/ws-ticket`, {
    method: 'POST',
    headers: { authorization: 'Bearer device-token-1', 'content-type': 'application/json' },
    body: JSON.stringify({ codeHash: 'hash-a' }),
  })
  assert.equal(ticketed.status, 201)
  const { ticket } = (await ticketed.json()) as { ticket: string }

  // 4. 连接器先说一句（中转据此学到 sid 归属）
  connector.send(ev('sid_1', 0))
  await waitFor('中转学到归属', () => (relay.core.stats.sessions === 1 ? true : undefined))

  // 5. 设备带票升级，发一行 —— 它必须出现在连接器那条 socket 上
  const device = await open(`${wsBase}/ws/device?ticket=${encodeURIComponent(ticket)}`)
  t.after(() => device.close())
  device.send(ev('sid_1', 1))
  const got = await waitFor('连接器收到设备的那一行', () => connectorLines[0])
  assert.equal(got, ev('sid_1', 1), '原样转发（中转不解载荷）')

  // 6. 反过来：连接器推一行，设备收到
  const deviceLines = collect(device)
  connector.send(ev('sid_1', 2))
  const back = await waitFor('设备收到连接器的那一行', () => deviceLines[0])
  assert.equal(back, ev('sid_1', 2))
})

test('升级认证：票不对 / 令牌不对 / 路径不对都拒掉，且不进入协议层', async (t) => {
  const relay = await startRelay({ port: 0, authenticate: (token) => TOKENS[token] })
  t.after(() => relay.close())
  const wsBase = `ws://127.0.0.1:${relay.port}`

  // 没票的设备：401
  await assert.rejects(() => open(`${wsBase}/ws/device?ticket=nope`), /401/)
  // 没有令牌的连接器：401
  await assert.rejects(() => open(`${wsBase}/ws/connector`), /401/)
  // 设备令牌拿来当连接器令牌：401（凭据类型不对，不是"有令牌就行"）
  await assert.rejects(
    () => open(`${wsBase}/ws/connector`, { authorization: 'Bearer device-token-1' }),
    /401/,
  )
  // 未知路径：404
  await assert.rejects(() => open(`${wsBase}/ws/nope`), /404/)
})

test('同一个身份再连上来：旧的被替换掉（投递不会打到僵尸 socket）', async (t) => {
  const relay = await startRelay({ port: 0, authenticate: (token) => TOKENS[token] })
  t.after(() => relay.close())
  const wsBase = `ws://127.0.0.1:${relay.port}`

  const first = await open(`${wsBase}/ws/connector`, { authorization: 'Bearer connector-token-1' })
  const second = await open(`${wsBase}/ws/connector`, { authorization: 'Bearer connector-token-1' })
  t.after(() => second.close())

  await waitFor('旧连接被关掉', () => (first.readyState === WebSocket.CLOSED ? true : undefined))
  assert.equal(second.readyState, WebSocket.OPEN, '新的那条继续服务')
  assert.equal(relay.core.stats.connectors, 1, '在线集合里只有一条')
})
