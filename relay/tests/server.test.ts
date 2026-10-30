/**
 * 中转服务的冒烟用例（契约 §2 / §12.1；`docs/subsystems/connector-and-relay.md` §1.6）：
 * **真 HTTP + 真 WS + 真路由**。
 *
 * 前面的用例测的是判定（零依赖、几十毫秒）；这一组测的是"接起来之后真的能转发" ——
 * 它是唯一能覆盖"凭据从哪来、升级怎么认证、控制面怎么通知、投递写回哪条 socket"的证据。
 *
 * v2 的连接拓扑是**三条 socket**：连接器控制面（只收 `relay.open` / `relay.close` 通知）、
 * 手机（一条连接一个 `channelId`）、连接器为该通道另拨的数据面。
 */
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { WebSocket } from 'ws'

import { startRelay } from '../src/server.ts'
import type { Authenticated } from '../src/http-face.ts'

const TOKENS: Record<string, Authenticated> = {
  'connector-token-1': { kind: 'connector', id: 'conn-1' },
}

/** 设备令牌由**名册**认：它不在摘要表里，中转只知道它的摘要。 */
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

/**
 * 建连**并从头收帧**：监听要在 `open` 之前挂上 ——
 * 数据面升级那一刻就会补投暂存的首批帧，它比客户端的 `open` 事件还早。
 */
function connect(url: string, headers: Record<string, string> = {}): Promise<{ ws: WebSocket; lines: string[] }> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, { headers })
    const lines = collect(ws)
    ws.once('open', () => resolve({ ws, lines }))
    ws.once('error', reject)
  })
}

const postJson = (base: string, path: string, token: string, body: unknown) =>
  fetch(`${base}${path}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })

test('端到端：名册 → 换票 → 控制面 relay.open → 数据面双向转发 → 断开一起消失（真 socket）', async (t) => {
  const relay = await startRelay({ port: 0, authenticate: (token) => TOKENS[token] })
  t.after(() => relay.close())
  const base = `http://127.0.0.1:${relay.port}`
  const wsBase = `ws://127.0.0.1:${relay.port}`

  // 1. 连接器先连上控制面（准入、登记与数据面都要求它在线）
  const connector = await connect(`${wsBase}/ws/connector`, {
    authorization: 'Bearer connector-token-1',
  })
  t.after(() => connector.ws.close())
  const notices = connector.lines

  // 2. 电脑侧重放名册（只交摘要）：dev-1 归属 conn-1
  const published = await postJson(base, '/devices', 'connector-token-1', { devices: ROSTER })
  assert.equal(published.status, 201)

  // 3. 手机凭**设备令牌**换票（已配对设备的重连路径）
  const ticketed = await postJson(base, '/ws-ticket', DEVICE_TOKEN, {})
  assert.equal(ticketed.status, 201)
  const { ticket } = (await ticketed.json()) as { ticket: string }

  // 4. 手机带票升级：中转为这次连接生成 channelId，并通过控制面通知电脑侧拨数据连接
  const device = await connect(`${wsBase}/ws/device?ticket=${encodeURIComponent(ticket)}`)
  t.after(() => device.ws.close())
  const deviceLines = device.lines
  const notice = JSON.parse(await waitFor('控制面收到 relay.open', () => notices[0])) as {
    v: number
    t: string
    channelId: string
    binding: { connectorId: string; deviceId: string; purpose: string }
  }
  assert.equal(notice.v, 1)
  assert.equal(notice.t, 'relay.open')
  assert.deepEqual(notice.binding, { connectorId: 'conn-1', deviceId: 'dev-1', purpose: 'paired' })
  assert.equal(relay.core.channel(notice.channelId)?.connected, false, '通道已建立，数据连接还没到')

  // 5. 手机在电脑侧拨号**之前**先说一句：首批帧不许丢、不许乱序
  //    （要么挂在有界缓冲里由 `attachData` 交还，要么直投 —— 两条路都合法，丢帧不合法）。
  device.ws.send(ev('sid_1', 1))

  // 6. 电脑侧按通知拨数据面（控制面只是通知面，不承载业务帧）
  const data = await connect(
    `${wsBase}/ws/connector?dev=dev-1&channel=${encodeURIComponent(notice.channelId)}`,
    { authorization: 'Bearer connector-token-1' },
  )
  t.after(() => data.ws.close())
  assert.equal(
    await waitFor('电脑侧收到手机那一句', () => data.lines[0]),
    ev('sid_1', 1),
    '原样转发（中转不解载荷；这一句说在数据面存在之前，靠通道的暂存缓冲交还）',
  )
  assert.equal(relay.core.channel(notice.channelId)?.connected, true)

  // 7. 反过来：电脑侧推一行，设备收到
  data.ws.send(ev('sid_1', 2))
  assert.equal(await waitFor('设备收到电脑侧那一行', () => deviceLines[0]), ev('sid_1', 2))

  // 8. 票是一次性的：同一张票再升级一次被拒，且不进入协议层
  await assert.rejects(() => open(`${wsBase}/ws/device?ticket=${encodeURIComponent(ticket)}`), /401/)

  // 9. 数据端断开 → 中转关掉配对的另一端，并让控制面知道那条通道结束了
  data.ws.close()
  assert.equal(
    JSON.parse(await waitFor('控制面收到 relay.close', () => notices[1])).t,
    'relay.close',
  )
  await waitFor('设备那端也被关掉', () => (device.ws.readyState === WebSocket.CLOSED ? true : undefined))
  assert.equal(relay.core.channel(notice.channelId), undefined, '通道随数据面的断开一起消失')
})

test('升级认证：票不对 / 令牌不对 / 凭据类型不对 / 数据面对不上通道 / 路径不对，都进不了协议层', async (t) => {
  const relay = await startRelay({ port: 0, authenticate: (token) => TOKENS[token] })
  t.after(() => relay.close())
  const wsBase = `ws://127.0.0.1:${relay.port}`

  // 没票 / 票不对的设备：401
  await assert.rejects(() => open(`${wsBase}/ws/device?ticket=nope`), /401/)
  await assert.rejects(() => open(`${wsBase}/ws/device`), /401/)
  // 没有令牌的连接器：401
  await assert.rejects(() => open(`${wsBase}/ws/connector`), /401/)
  // 不认识的令牌（比如 v1 时代签的设备令牌）：401 —— 中转不认识它，
  // 而它也不该被认识：设备凭据面在名册（由电脑侧写入）。
  await assert.rejects(
    () => open(`${wsBase}/ws/connector`, { authorization: 'Bearer v1-device-token' }),
    /401/,
  )
  // 数据面：路径对了但那条通道不存在（或不属于它）→ 403，而不是"先连上再说"
  await assert.rejects(
    () => open(`${wsBase}/ws/connector?dev=dev-1&channel=nope`, { authorization: 'Bearer connector-token-1' }),
    /403/,
  )
  // 未知路径：404
  await assert.rejects(() => open(`${wsBase}/ws/nope`), /404/)
})

test('控制面自报 id：与令牌一致才放行，不一致 403，不带（老连接器）放行', async (t) => {
  const relay = await startRelay({ port: 0, authenticate: (token) => TOKENS[token] })
  t.after(() => relay.close())
  const wsBase = `ws://127.0.0.1:${relay.port}`
  const auth = { authorization: 'Bearer connector-token-1' }

  // 一致：放行（正常连接器的路径）。
  const matched = await open(`${wsBase}/ws/connector?id=conn-1`, auth)
  t.after(() => matched.close())
  assert.equal(matched.readyState, WebSocket.OPEN)

  // 不一致：403 —— 这正是"二维码里的 pcId 与中转眼里的 id 不是同一个"那一刻，
  // 多机之后它会让路由把通知发给错的一台，所以在准入处就拒。
  await assert.rejects(
    () => open(`${wsBase}/ws/connector?id=conn-2`, auth),
    /403/,
    '自报 id 与令牌 id 不一致必须拒',
  )

  // **兼容分支**：不带 `?id=` 的是老连接器 —— 放行（下个 minor 删）。
  const legacy = await open(`${wsBase}/ws/connector`, auth)
  t.after(() => legacy.close())
  assert.equal(legacy.readyState, WebSocket.OPEN, '老连接器不带 id 时必须照旧能连')
})

test('摘要表里带 device 条目：**启动即失败**（不留下"起来了但谁都连不上"的中转）', async (t) => {
  // 这是上面那条 401 的完整路径版：v1 的配置里常有 device 摘要条目，而 v2 的中转
  // 认不出它（设备凭据在名册）。若照常启动，操作者看到的是"手机 403、电脑侧一切正常"，
  // 而真因在配置里 —— 所以在这里就退出，并把原因与修法一起打印。
  const dir = await mkdtemp(join(tmpdir(), 'dsh-relay-devkind-'))
  const configPath = join(dir, 'relay.config.json')
  await writeFile(
    configPath,
    JSON.stringify({
      port: 0,
      tokens: [
        { kind: 'connector', id: 'conn-1', hash: 'a'.repeat(64) },
        { kind: 'device', id: 'dev-1', hash: 'b'.repeat(64) },
      ],
    }),
    'utf8',
  )
  t.after(() => rm(dir, { recursive: true, force: true }))

  const child = spawn(
    process.execPath,
    [join(import.meta.dirname, '..', 'src', 'main.ts'), '--config', configPath],
    { cwd: join(import.meta.dirname, '..'), stdio: ['ignore', 'pipe', 'pipe'] },
  )
  let output = ''
  child.stdout?.on('data', (chunk: Buffer) => {
    output += chunk.toString('utf8')
  })
  child.stderr?.on('data', (chunk: Buffer) => {
    output += chunk.toString('utf8')
  })
  const code = await new Promise<number | null>((resolve) => child.once('exit', (value) => resolve(value)))
  assert.equal(code, 2, '配置里有 device 摘要条目时要以非零码退出')
  assert.match(output, /device 条目/, '退出信息要说清是哪一条、为什么')
  assert.match(output, /POST \/devices/, '并告诉修法：设备令牌走名册')
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
