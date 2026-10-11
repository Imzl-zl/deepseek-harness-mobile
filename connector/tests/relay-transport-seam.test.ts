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
 *
 * ## 为什么这里不再有"设备那一行抵达连接器"那两条
 *
 * 它们验的是 v1 的两种回程机制 —— **按 `sid` 广播**与**按帧头 `id` 猜回程** ——
 * 而配对 v2 把两者都删了（`pairing-v2.md` §2：数据路径逐条双向转发，不按 `sid` 广播、
 * 不按请求 `id` 猜回程，改为按 `channelId` 成对绑定）。
 *
 * 更根本的是连接粒度变了（`connector-and-relay.md` §1.6）：**每台在线设备一条数据连接**，
 * 而数据连接由连接器收到 `relay.open` 之后自己拨。所以"一个裸 `createConnection`
 * 从 `/ws/connector` 同时承载设备帧"这条路在 v2 里**不存在** —— 保留那两条用例
 * 等于要求实现保留一个已删除的机制。
 *
 * 同一批不变量（且是 v2 的形状）在别处：
 * - 设备帧经中转抵达连接器、反向投递、断开一起消失 → `relay/tests/server.test.ts`
 *   （三条真 socket：控制面 / `/ws/device?ticket=` / `/ws/connector?dev=&channel=`）；
 * - 握手与业务帧 AEAD 经中转双向成立 → `tests/pairing-e2e.test.ts`
 *   （真中转 + `createRelayLink` + `createDeviceConnection`，含多设备与 I7 重启）。
 *
 * 决策笔记：`.agents/notes/implemented/2026-10-09-pairing-v2-test-migration.md`。
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
