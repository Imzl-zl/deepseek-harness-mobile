/**
 * 跨工程 e2e 的共用夹具：**起一个真的中转子进程**，并把端口读回来。
 *
 * 抽出来的理由：两处用例（传输缝、带密钥的三方链路）都要它，而"起进程 + 读端口 + 收尾"
 * 的细节（临时目录、SIGTERM、解析启动行）写两遍必然会分叉 —— 那类分叉的症状是
 * "一条用例偶发失败"，最难查。
 *
 * 形态上它刻意**不是**导入中转源码：中转是独立进程（第 42 轮从"跨工程 import"改过来的），
 * 连它的入口都一起被这条夹具验证（读配置、建摘要表、打印监听地址、配错以码 2 退出）。
 */
import { spawn, type ChildProcess } from 'node:child_process'
import { createHash } from 'node:crypto'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

/** 中转工程根（相对本文件：`connector/tests/support` → 仓库根 → `relay`）。 */
const RELAY_DIR = resolve(import.meta.dirname, '../../../relay')

export interface TokenSpec {
  kind: 'device' | 'connector'
  id: string
  /** **明文令牌**：只存在于测试这一侧，写进配置的是它的摘要。 */
  token: string
}

export interface RelayProcess {
  port: number
  /** 子进程到目前为止的输出（排查超时时把它带进错误里）。 */
  output: () => string
  /**
   * **清空重启**：杀掉这个中转进程，在**同一个端口**上起一个全新的。
   *
   * 它是 I7（"删掉中转全部业务状态后重启，已配对设备仅凭电脑侧数据收敛"）
   * 唯一诚实的验法：新进程里没有任何内存状态 —— 登记表、票、设备投影、归属全空。
   * 在同一个进程里"手动清一清"测不到这条：真正会漏的正是**那些没被清掉的东西**。
   */
  restart(): Promise<void>
}

/** 轮询等待（失败要快、要清楚，不要挂住整个套件）。 */
export async function waitFor(what: string, check: () => boolean, timeoutMs = 5_000): Promise<void> {
  const started = Date.now()
  while (!check()) {
    if (Date.now() - started > timeoutMs) throw new Error(`等待超时：${what}`)
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
}

/** 找一个空闲端口（起一个临时 server 让它分配，再关掉）。 */
async function freePort(): Promise<number> {
  const { createServer } = await import('node:net')
  return new Promise<number>((resolve, reject) => {
    const probe = createServer()
    probe.once('error', reject)
    probe.listen(0, '127.0.0.1', () => {
      const address = probe.address()
      const port = typeof address === 'object' && address !== null ? address.port : 0
      probe.close(() => resolve(port))
    })
  })
}

export async function startRelayProcess(
  t: { after(fn: () => void | Promise<void>): void },
  tokens: TokenSpec[],
): Promise<RelayProcess> {
  const dir = await mkdtemp(join(tmpdir(), 'dsh-relay-'))
  const configPath = join(dir, 'relay.config.json')
  // **固定端口**（不是 0）：重启要回到同一个端口，否则连接器的 `relayUrl` 就指向别处了。
  const port = await freePort()
  await writeFile(
    configPath,
    JSON.stringify({
      port,
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

  let child: ChildProcess | null = null
  let output = ''

  const spawnRelay = async (): Promise<void> => {
    // 每次都从零累积输出：重启后上一轮的日志只会干扰排查。
    output = ''
    const started: ChildProcess = spawn(
      process.execPath,
      [join(RELAY_DIR, 'src', 'main.ts'), '--config', configPath],
      { cwd: RELAY_DIR, stdio: ['ignore', 'pipe', 'pipe'] },
    )
    child = started
    started.stdout?.on('data', (chunk: Buffer) => {
      output += chunk.toString('utf8')
    })
    started.stderr?.on('data', (chunk: Buffer) => {
      output += chunk.toString('utf8')
    })
    await waitFor('中转打印监听地址', () => /ws:\/\/127\.0\.0\.1:(\d+)/.test(output))
  }

  const stop = async (): Promise<void> => {
    const running = child
    child = null
    if (running === null) return
    running.kill('SIGTERM')
    await new Promise<void>((resolve) => {
      if (running.exitCode !== null) {
        resolve()
        return
      }
      running.once('exit', () => resolve())
    })
  }

  await spawnRelay()

  t.after(async () => {
    await stop()
    await rm(dir, { recursive: true, force: true })
  })

  const reported = Number(/ws:\/\/127\.0\.0\.1:(\d+)/.exec(output)?.[1])
  if (!Number.isFinite(reported) || reported <= 0) throw new Error(`没读端口：${output}`)

  return {
    port: reported,
    output: () => output,
    restart: async () => {
      await stop()
      await spawnRelay()
    },
  }
}
