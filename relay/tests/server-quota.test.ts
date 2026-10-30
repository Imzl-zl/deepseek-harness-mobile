/**
 * 额度在**真服务器**上的行为（契约 §2.4；`docs/subsystems/connector-and-relay.md` §2.4）。
 *
 * 四条要钉住：
 * 1. `cut`：用满那一刻，已有通道以 **4003 + `rate-limited quota`** 收口（手机认这个码）；
 * 2. 之后换票 **429**（票是一次性的，绕不过去）；
 * 3. `block`：已有连接不踢，只挡新建；
 * 4. **按人合账**：同一个 owner 的两台电脑共用一个额度。
 *
 * 另加两条落盘用例：`persist: true` 重启接着算、默认重启清零（那是写进代价里的选择）。
 */
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { WebSocket } from 'ws'

import { startRelay } from '../src/server.ts'
import type { Authenticated } from '../src/http-face.ts'
import { readMeteringState } from '../src/metering-state.ts'

const hashOf = (token: string): string => createHash('sha256').update(token, 'utf8').digest('hex')
const line = (frame: Record<string, unknown>): string => JSON.stringify({ v: 1, ...frame })
const ev = (sid: string, seq: number): string => line({ t: 'ev', sid, seq, fc: seq, box: 'x' })

const roster = (id: string, deviceToken: string): unknown[] => [
  {
    id,
    pairingId: `pair-${id}`,
    devPubEd: 'a'.repeat(64),
    devPubDh: 'b'.repeat(64),
    name: id,
    tokenHash: hashOf(deviceToken),
  },
]

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

function connect(url: string, headers: Record<string, string> = {}): Promise<{ ws: WebSocket; lines: string[] }> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, { headers })
    const lines: string[] = []
    ws.on('message', (data) => { lines.push(typeof data === 'string' ? data : Buffer.from(data as Buffer).toString('utf8')) })
    ws.once('open', () => resolve({ ws, lines }))
    ws.once('error', reject)
  })
}

const post = (base: string, path: string, token: string, body: unknown) =>
  fetch(`${base}${path}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })

const ticketOf = async (base: string, deviceToken: string): Promise<Response> =>
  post(base, '/ws-ticket', deviceToken, {})

test('cut：用满就断，已建立的通道收到 4003 + rate-limited quota；之后换票 429', async (t) => {
  const tokens: Record<string, Authenticated> = { 't-conn': { kind: 'connector', id: 'conn-1' } }
  const relay = await startRelay({
    port: 0,
    authenticate: (token) => tokens[token],
    // 1 字节额度：第一帧必然用满（用例只验"用满之后发生什么"，不验字节统计本身）。
    quota: { period: 'month', enforce: 'cut', defaultBytes: 1 },
  })
  t.after(() => relay.close())
  const base = `http://127.0.0.1:${relay.port}`
  const wsBase = `ws://127.0.0.1:${relay.port}`

  const connector = await connect(`${wsBase}/ws/connector?id=conn-1`, { authorization: 'Bearer t-conn' })
  t.after(() => connector.ws.close())
  assert.equal((await post(base, '/devices', 't-conn', { devices: roster('dev-1', 'dev-token') })).status, 201)

  const ticketed = await ticketOf(base, 'dev-token')
  assert.equal(ticketed.status, 201, '还没用量：换票照常')
  const { ticket } = (await ticketed.json()) as { ticket: string }

  const device = await connect(`${wsBase}/ws/device?ticket=${encodeURIComponent(ticket)}`)
  t.after(() => device.ws.close())
  let closed: { code: number; reason: string } | null = null
  device.ws.on('close', (code, reason) => { closed = { code, reason: reason.toString() } })

  const notice = JSON.parse(await waitFor('控制面收到 relay.open', () => connector.lines[0])) as { channelId: string }
  const data = await connect(
    `${wsBase}/ws/connector?dev=dev-1&channel=${encodeURIComponent(notice.channelId)}`,
    { authorization: 'Bearer t-conn' },
  )
  t.after(() => data.ws.close())

  device.ws.send(ev('sid_1', 1))
  const seen = await waitFor('设备收到关闭', () => closed ?? undefined)
  assert.equal(seen.code, 4003, '用手机认得的关闭码，而不是 4008/4000')
  assert.equal(seen.reason, 'rate-limited quota', '理由首词是封闭表里的协议码')

  const denied = await ticketOf(base, 'dev-token')
  assert.equal(denied.status, 429)
  const body = (await denied.json()) as { error: string; retryAfterMs: number | null }
  assert.equal(body.error, 'rate-limited')
  assert.equal(typeof body.retryAfterMs, 'number', '月额度会说"下个月几号恢复"，不是 null')
  assert.ok((body.retryAfterMs ?? 0) > 0)
})

test('block：已有连接不踢，只挡新建', async (t) => {
  const tokens: Record<string, Authenticated> = { 't-conn': { kind: 'connector', id: 'conn-1' } }
  const relay = await startRelay({
    port: 0,
    authenticate: (token) => tokens[token],
    quota: { period: 'month', enforce: 'block', defaultBytes: 1 },
  })
  t.after(() => relay.close())
  const base = `http://127.0.0.1:${relay.port}`
  const wsBase = `ws://127.0.0.1:${relay.port}`

  const connector = await connect(`${wsBase}/ws/connector?id=conn-1`, { authorization: 'Bearer t-conn' })
  t.after(() => connector.ws.close())
  assert.equal((await post(base, '/devices', 't-conn', { devices: roster('dev-1', 'dev-token') })).status, 201)
  const { ticket } = (await (await ticketOf(base, 'dev-token')).json()) as { ticket: string }
  const device = await connect(`${wsBase}/ws/device?ticket=${encodeURIComponent(ticket)}`)
  t.after(() => device.ws.close())

  const notice = JSON.parse(await waitFor('控制面收到 relay.open', () => connector.lines[0])) as { channelId: string }
  const data = await connect(
    `${wsBase}/ws/connector?dev=dev-1&channel=${encodeURIComponent(notice.channelId)}`,
    { authorization: 'Bearer t-conn' },
  )
  t.after(() => data.ws.close())

  device.ws.send(ev('sid_1', 1))
  assert.equal(await waitFor('电脑侧收到那一帧', () => data.lines[0]), ev('sid_1', 1), '超了也把这帧送完')
  assert.equal(device.ws.readyState, WebSocket.OPEN, 'block 不踢已有连接')

  assert.equal((await ticketOf(base, 'dev-token')).status, 429, '但新连接在换票这一步就被拒')
})

test('按人合账：同一个 owner 的两台电脑共用一个额度（第一台用满，第二台也连不上）', async (t) => {
  const tokens: Record<string, Authenticated> = {
    't-home': { kind: 'connector', id: 'home-pc', owner: 'alice' },
    't-work': { kind: 'connector', id: 'work-pc', owner: 'alice' },
  }
  const relay = await startRelay({
    port: 0,
    authenticate: (token) => tokens[token],
    quota: { period: 'month', enforce: 'cut', defaultBytes: 1 },
    ownerOf: (id) => tokens[id === 'home-pc' ? 't-home' : 't-work']?.owner,
  })
  t.after(() => relay.close())
  const base = `http://127.0.0.1:${relay.port}`
  const wsBase = `ws://127.0.0.1:${relay.port}`

  // 两台电脑各自上线、各自报名册（设备 id 由公钥派生，正常不会撞）。
  const home = await connect(`${wsBase}/ws/connector?id=home-pc`, { authorization: 'Bearer t-home' })
  const work = await connect(`${wsBase}/ws/connector?id=work-pc`, { authorization: 'Bearer t-work' })
  t.after(() => home.ws.close())
  t.after(() => work.ws.close())
  assert.equal((await post(base, '/devices', 't-home', { devices: roster('dev-home', 'dev-token-home') })).status, 201)
  assert.equal((await post(base, '/devices', 't-work', { devices: roster('dev-work', 'dev-token-work') })).status, 201)
  assert.equal(relay.metering?.subjectOf('work-pc'), relay.metering?.subjectOf('home-pc'), '两台电脑是同一个主体')

  // 家里那台用掉额度。
  const { ticket } = (await (await ticketOf(base, 'dev-token-home')).json()) as { ticket: string }
  const device = await connect(`${wsBase}/ws/device?ticket=${encodeURIComponent(ticket)}`)
  t.after(() => device.ws.close())
  const notice = JSON.parse(await waitFor('控制面收到 relay.open', () => home.lines[0])) as { channelId: string }
  const data = await connect(
    `${wsBase}/ws/connector?dev=dev-home&channel=${encodeURIComponent(notice.channelId)}`,
    { authorization: 'Bearer t-home' },
  )
  t.after(() => data.ws.close())
  const subject = relay.metering?.subjectOf('home-pc') ?? ''
  device.ws.send(ev('sid_1', 1))
  // 等**记账**落下来（不等关闭）：这条用例验的是"共用一个桶"，断不断是上一条的事。
  await waitFor('家里那台的用量记到 alice 名下', () => (relay.metering?.usedOf(subject) ?? 0) > 0 ? true : undefined)

  // 公司那台一次都没用过，但**同一个人的额度已经空了**。
  const workTicket = await ticketOf(base, 'dev-token-work')
  assert.equal(workTicket.status, 429, '不共用的话它会拿到 201（那正是"多开一台电脑多领一份"）')
})

test('落盘：persist 时重启接着算；不 persist 时重启清零（如实写进代价）', async (t) => {
  const dir = await mkdtemp(join(tmpdir(), 'dsh-relay-quota-'))
  t.after(() => rm(dir, { recursive: true, force: true }))
  const statePath = join(dir, 'relay.state.json')
  const tokens: Record<string, Authenticated> = { 't-conn': { kind: 'connector', id: 'conn-1' } }

  const first = await startRelay({
    port: 0,
    authenticate: (token) => tokens[token],
    quota: { period: 'month', enforce: 'cut', defaultBytes: 100, persist: true, statePath },
  })
  first.metering?.charge('conn-1', 42)
  await first.close()

  const restored = await readMeteringState(statePath)
  const persisted = await startRelay({
    port: 0,
    authenticate: (token) => tokens[token],
    quota: { period: 'month', enforce: 'cut', defaultBytes: 100, persist: true, statePath },
    ...(restored === undefined ? {} : { quotaState: restored }),
  })
  t.after(() => persisted.close())
  assert.equal(persisted.metering?.usedOf('connector:conn-1'), 42, '重启后接着算')

  const fresh = await startRelay({
    port: 0,
    authenticate: (token) => tokens[token],
    quota: { period: 'month', enforce: 'cut', defaultBytes: 100 },
  })
  t.after(() => fresh.close())
  fresh.metering?.charge('conn-1', 42)
  assert.equal(fresh.metering?.usedOf('connector:conn-1'), 42)
})

test('默认不限制：没配 quota 也在记账，但谁都不会被挡住', async (t) => {
  // "默认不限制、管理员可配置"是常态：计量一直在跑（面板看得到用量），
  // 上限只有管理员给某个人设了才会有。
  const relay = await startRelay({ port: 0, authenticate: () => undefined })
  t.after(() => relay.close())
  assert.equal(relay.metering.limitOf('connector:conn-1'), null, '没设上限 = null，不是 0')
  relay.metering.charge('conn-1', 10 * 1024 * 1024)
  assert.equal(relay.metering.usedOf('connector:conn-1'), 10 * 1024 * 1024, '照样记账')
  assert.equal(relay.metering.check('conn-1').exceeded, false, '不限制就不会超')
})
