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
}

export async function waitFor(what: string, check: () => boolean, timeoutMs = 5_000): Promise<void> {
  const started = Date.now()
  while (!check()) {
    if (Date.now() - started > timeoutMs) throw new Error(`等待超时：${what}`)
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
}

export async function startRelayProcess(
  t: { after(fn: () => void | Promise<void>): void },
  tokens: TokenSpec[],
): Promise<RelayProcess> {
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
  if (!Number.isFinite(port) || port <= 0) throw new Error(`没读端口：${output}`)
  return { port, output: () => output }
}
