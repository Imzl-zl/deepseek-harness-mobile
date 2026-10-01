/**
 * 中转 ⇄ 连接器 的传输缝（契约 §2.2 升级鉴权）。
 *
 * **中转是一个独立进程**（`node relay/src/main.ts --config …`），这条用例也这么跑它 ——
 * 与生产同一个形态，于是它同时验证了：
 *
 * - 入口能读配置、能把摘要表建起来、能监听（第 41 轮的东西在这里第一次被真跑）；
 * - 连接器带令牌**走升级头**拨号能被接受（第 38 轮实测 undici 扩展才敢用的写法）；
 * - 令牌不对时升级被拒，而连接层进入自己的重连退避（不是停在一个假的"已连接"状态）。
 *
 * 早期版本把中转当**库**导入（跨工程 import + 一个额外的 `tsconfig.e2e.json`）。
 * 那是过渡：进程形态更接近生产，而且连接器不必为了测试去解析中转的源码。已改过来。
 */
import assert from 'node:assert/strict'
import { spawn, type ChildProcess } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { test } from 'node:test'

import { createConnection } from '../src/transport/connection.js'

const TOKEN = 'connector-token-1'
const RELAY_DIR = resolve(import.meta.dirname, '../../relay')

const waitFor = async (what: string, check: () => boolean, timeoutMs = 5_000): Promise<void> => {
  const started = Date.now()
  while (!check()) {
    if (Date.now() - started > timeoutMs) throw new Error(`等待超时：${what}`)
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
}

/** 起一个真的中转子进程，返回它的端口（从它打印的启动行里读出来）。 */
async function startRelayProcess(
  t: { after(fn: () => void | Promise<void>): void },
  tokens: { kind: 'device' | 'connector'; id: string; token: string }[],
) {
  const dir = await mkdtemp(join(tmpdir(), 'dsh-relay-'))
  const configPath = join(dir, 'relay.config.json')
  await writeFile(
    configPath,
    JSON.stringify({
      port: 0,
      host: '127.0.0.1',
      // 配置里**只放摘要**（§12.2）：明文令牌只存在于测试自己这一侧。
      tokens: tokens.map((entry) => ({
        kind: entry.kind,
        id: entry.id,
        hash: createHash('sha256').update(entry.token, 'utf8').digest('hex'),
      })),
    }),
    'utf8',
  )

  const child: ChildProcess = spawn(
    process.execPath,
    [join(RELAY_DIR, 'src', 'main.ts'), '--config', configPath],
    { cwd: RELAY_DIR, stdio: ['ignore', 'pipe', 'pipe'] },
  )
  let output = ''
  child.stdout?.on('data', (chunk: Buffer) => {
    output += chunk.toString('utf8')
  })
  child.stderr?.on('data', (chunk: Buffer) => {
    output += chunk.toString('utf8')
  })

  t.after(async () => {
    child.kill('SIGTERM')
    await new Promise<void>((resolve) => {
      if (child.exitCode !== null) {
        resolve()
        return
      }
      child.once('exit', () => resolve())
    })
    await rm(dir, { recursive: true, force: true })
  })

  await waitFor('中转打印监听地址', () => /ws:\/\/127\.0\.0\.1:(\d+)/.test(output))
  const port = Number(/ws:\/\/127\.0\.0\.1:(\d+)/.exec(output)?.[1])
  assert.equal(Number.isFinite(port) && port > 0, true, `没读端口：${output}`)
  return { port, output: () => output }
}

test('连接器带令牌拨号到**独立进程中转**：升级成功、连接层进入握手态', async (t) => {
  const relay = await startRelayProcess(t, [{ kind: 'connector', id: 'conn-1', token: TOKEN }])

  const connection = createConnection({
    url: `ws://127.0.0.1:${relay.port}/ws/connector`,
    // 与产品同一个写法：令牌走升级头。
    dial: (url) =>
      new WebSocket(url, {
        headers: { authorization: `Bearer ${TOKEN}` },
      } as never) as never,
    onFrame: () => {},
  })
  t.after(() => connection.stop())
  connection.start()

  await waitFor('连接层进入握手态', () => connection.state === 'handshake')
})

test('令牌不对：升级被拒，连接层进入退避重连而不是停在假的"已连接"状态', async (t) => {
  const relay = await startRelayProcess(t, [{ kind: 'connector', id: 'conn-1', token: TOKEN }])

  const connection = createConnection({
    url: `ws://127.0.0.1:${relay.port}/ws/connector`,
    dial: (url) =>
      new WebSocket(url, { headers: { authorization: 'Bearer wrong' } } as never) as never,
    onFrame: () => {},
  })
  t.after(() => connection.stop())
  connection.start()

  await waitFor('进入退避重连', () => connection.state === 'backoff')
})

test(
  '设备经中转抵达连接器：换票 → 升级 → 设备那一行出现在连接器的 onFrame 里',
  async (t) => {
  const deviceToken = 'device-token-1'
  const relay = await startRelayProcess(t, [
    { kind: 'connector', id: 'conn-1', token: TOKEN },
    { kind: 'device', id: 'dev-1', token: deviceToken },
  ])
  const httpBase = `http://127.0.0.1:${relay.port}`
  const wsBase = `ws://127.0.0.1:${relay.port}`

  // 连接器先上线（中转的"出码登记 → 认领"要求它在线），并进服务态。
  const frames: { t?: string; id?: string }[] = []
  // 观测：包一层 `send`，记录**真正写到 socket 上**的字节。
  // 这一层能一次分开两种可能：帧没出连接器（send/batcher 吞了）vs 出了但中转没收（中转侧的事）。
  const sent: string[] = []
  const connection = createConnection({
    url: `${wsBase}/ws/connector`,
    dial: (url) => {
      const ws = new WebSocket(url, { headers: { authorization: `Bearer ${TOKEN}` } } as never) as never as {
        send(data: string): void
      }
      const original = ws.send.bind(ws)
      ws.send = (data: string) => {
        sent.push(String(data))
        original(data)
      }
      return ws as never
    },
    onFrame: (frame) => frames.push(frame as { t?: string; id?: string }),
  })
  t.after(() => connection.stop())
  connection.start()
  await waitFor('连接器进入握手态', () => connection.state === 'handshake')
  // 明文通道模式：手动宣告握手完成，于是 `send` 可用（本用例不测密码学，只测转发）。
  connection.markHandshakeDone()
  await waitFor('连接器进入服务态', () => connection.state === 'serving')

  // 出码登记（连接器令牌）→ 换票（设备令牌 + codeHash）
  const codeHash = 'hash-a'
  const registered = await fetch(`${httpBase}/pairing/register`, {
    method: 'POST',
    headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify({ codeHash }),
  })
  assert.equal(registered.status, 201)
  const ticketed = await fetch(`${httpBase}/ws-ticket`, {
    method: 'POST',
    headers: { authorization: `Bearer ${deviceToken}`, 'content-type': 'application/json' },
    body: JSON.stringify({ codeHash }),
  })
  assert.equal(ticketed.status, 201)
  const { ticket } = (await ticketed.json()) as { ticket: string }

  // 连接器先说一句：中转据此学到这个 sid 归它。
  // **用 `res` 而不是 `ev`**：`ev` 是"可攒批/可暂停"的帧（§4.3），会先在连接层的 batcher 里等
  // 一次 flush；本用例只想验证**转发**，不想让时序掺进攒批器 —— 那属于连接层自己的测试。
  assert.equal(connection.send({ v: 1, t: 'res', id: 'r0', sid: 'sid_1', ok: true, box: 'x' }), true)

  // 设备带票升级，然后发一行 —— 它应当出现在**连接器的 onFrame** 里。
  const device = new WebSocket(`${wsBase}/ws/device?ticket=${encodeURIComponent(ticket)}`)
  t.after(() => device.close())
  await new Promise<void>((resolve, reject) => {
    device.onopen = () => resolve()
    device.onerror = () => reject(new Error('设备带票升级失败（中转应当接受它）'))
  })
  // **必须补换行**：协议是行级分帧（§3），连接器侧的分帧器只在遇到 `\n` 时才交出一帧。
  // 不补的话那一行会永远攒在分帧器里 —— 表现正是"对端什么都没收到"，而两边看起来都正常。
  device.send(`${JSON.stringify({ v: 1, t: 'req', id: 'r1', sid: 'sid_1', fc: 0, box: '{}' })}\n`)

  try {
    await waitFor('连接器收到设备那一行', () => frames.some((frame) => frame.t === 'req'))
  } catch (error) {
    // 超时时把中转的输出带出来：它只转发与记账，线索都在那儿。
    throw new Error(`${String(error)}\n中转输出：\n${relay.output()}`)
  }
  assert.equal(frames.find((frame) => frame.t === 'req')?.id, 'r1', '原样转发（中转不解载荷、不改帧头）')
})

test('入口配错就在**启动时**失败：没有 tokens 直接退出（不留下"起来了但都 401"的中转）', async (t) => {
  const dir = await mkdtemp(join(tmpdir(), 'dsh-relay-bad-'))
  const configPath = join(dir, 'relay.config.json')
  await writeFile(configPath, JSON.stringify({ port: 0 }), 'utf8')
  t.after(() => rm(dir, { recursive: true, force: true }))

  const child = spawn(process.execPath, [join(RELAY_DIR, 'src', 'main.ts'), '--config', configPath], {
    cwd: RELAY_DIR,
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  const code = await new Promise<number | null>((resolve) => child.once('exit', (value) => resolve(value)))
  assert.equal(code, 2, '配置错误要以非零码退出')
})
