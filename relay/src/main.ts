/**
 * 中转的可运行入口（`node relay/src/main.ts --config relay.config.json`）。
 *
 * 这里只做"读配置 → 起服务 → 优雅退出"，判定与接线都在别的文件里
 * （`http-face.ts` / `core.ts` / `server.ts` / `digest-auth.ts`）。
 *
 * ## 配置文件（JSON）
 *
 * ```json
 * { "port": 8787, "host": "127.0.0.1",
 *   "tokens": [{ "kind": "connector", "id": "conn-1", "hash": "<sha256(token) 十六进制>" }] }
 * ```
 *
 * **只放摘要**（§12.2：中转只存 `token_hash`）——明文令牌不该出现在中转的任何配置或库里。
 *
 * ## 为什么启动时就把摘要表读进来
 *
 * 配错了（缺 `tokens`、摘要不是十六进制、重复条目）应当在**启动时**大声失败：
 * 一个"起来了但所有连接都 401"的中转比没起来更难排查。`createDigestAuthenticator`
 * 对重复条目直接抛，这里把它连同 JSON 解析错误一起当启动失败。
 *
 * 优雅退出：SIGINT/SIGTERM → `close()`（关所有 socket、停止监听），然后退出。
 * 不做"接住所有异常继续跑"：那是把故障藏起来。
 */
import { readFile } from 'node:fs/promises'

import { createDigestAuthenticator, type TokenDigest } from './digest-auth.ts'
import { appendTokenToConfig, issueToken, revokeTokenInConfig } from './issue-token.ts'
import { startRelay } from './server.ts'

interface RelayConfig {
  port?: number
  host?: string
  tokens?: TokenDigest[]
  /**
   * 限流参数（§12 的"按设备限流与审计"）。
   *
   * 不配就用 `server.ts` 的默认值（容量 60 / 每秒补 6）——**默认生效**，
   * 因为一个默认敞开的转发器是隐患；配了就按配置来，启动时会打印生效值。
   */
  rateLimit?: { capacity: number; refillPerSecond: number }
}

function argValue(name: string): string | undefined {
  const index = process.argv.indexOf(name)
  return index === -1 ? undefined : process.argv[index + 1]
}

const configPath = argValue('--config')
if (configPath === undefined) {
  // 用法写清楚再退出：这是人启动服务时唯一的指引。
  console.error('用法: node relay/src/main.ts --config <relay.config.json>')
  process.exit(2)
}

const raw = await readFile(configPath, 'utf8')
const config = JSON.parse(raw) as RelayConfig

// 签发模式：`--issue-token <device|connector> <id>` —— 生成令牌、把**摘要**写进配置、
// 把令牌打印一次。它**必须能在 `tokens` 为空时运行**（否则没有办法引导第一台设备）。
const issueArgs = process.argv.includes('--issue-token')
  ? process.argv.slice(process.argv.indexOf('--issue-token') + 1, process.argv.indexOf('--issue-token') + 3)
  : []
if (issueArgs.length === 2) {
  const [kind, id] = issueArgs as [string, string]
  if (kind !== 'device' && kind !== 'connector') {
    console.error('签发类型的取值是 device 或 connector')
    process.exit(2)
  }
  const issued = issueToken({ kind, id })
  const tokens = await appendTokenToConfig(configPath, { kind, id, hash: issued.hash })
  console.log(`已签发 ${kind} 令牌（id=${id}）。摘要已写进 ${configPath}（现在 ${tokens.length} 条）。`)
  console.log('令牌**只显示这一次**，请立刻交给对端：')
  console.log(issued.token)
  process.exit(0)
}

const entries = config.tokens ?? []

// 吊销模式：`--revoke-token <device|connector> <id>`（软吊销：行留着、标 `revokedAt`）。
if (process.argv.includes('--revoke-token')) {
  const index = process.argv.indexOf('--revoke-token')
  const [kind, id] = process.argv.slice(index + 1, index + 3) as [string, string]
  if ((kind !== 'device' && kind !== 'connector') || id === undefined) {
    console.error('用法: --revoke-token <device|connector> <id>')
    process.exit(2)
  }
  const { tokens, revoked } = await revokeTokenInConfig(configPath, { kind, id })
  if (!revoked) {
    // "我吊销的那个到底在不在"要能被脚本分辨出来 —— 静默成功会让拼错的 id 看起来没事。
    console.error(`配置里没有 ${kind} ${id} 的摘要：什么都没改`)
    process.exit(2)
  }
  console.log(`已吊销 ${kind} 令牌（id=${id}）。行留在配置里（软吊销），现在 ${tokens.length} 条。`)
  process.exit(0)
}

if (entries.length === 0) {
  console.error('配置里没有 tokens：中转起来也无人能连上（只放摘要，不放明文令牌）')
  process.exit(2)
}

const authenticate = createDigestAuthenticator(entries)
const relay = await startRelay({
  port: config.port ?? 8787,
  host: config.host ?? '127.0.0.1',
  authenticate,
  // 配置里给了就用它，没给就用 `server.ts` 的默认值（默认生效，见那里的说明）。
  ...(config.rateLimit === undefined ? {} : { rateLimit: config.rateLimit }),
  // 中转必须**留声**：它只转发与记账，出问题时（投递目标不在、丢弃、认证被拒）
  // 日志是唯一的线索。级别用 debug 之外的 info/warn，默认就能看见。
  log: {
    info: (message, detail) => console.log(`[relay] ${message}`, detail ?? ''),
    warn: (message, detail) => console.warn(`[relay] ${message}`, detail ?? ''),
    error: (message, detail) => console.error(`[relay] ${message}`, detail ?? ''),
    debug: (message, detail) => {
      if (process.env['DSH_RELAY_DEBUG'] === '1') console.log(`[relay:debug] ${message}`, detail ?? '')
    },
  },
})

console.log(`中转已监听 ws://${config.host ?? '127.0.0.1'}:${relay.port}（摘要表 ${authenticate.size} 条）`)

let closing = false
const shutdown = (signal: string): void => {
  if (closing) return
  closing = true
  console.log(`收到 ${signal}：正在关闭`)
  void relay.close().then(() => {
    process.exit(0)
  })
}
process.on('SIGINT', () => shutdown('SIGINT'))
process.on('SIGTERM', () => shutdown('SIGTERM'))
