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
import { randomBytes } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'

import type { TokenDigest } from './digest-auth.ts'
import {
  appendTokenToConfig, issueToken, removeTokenFromConfig, restoreTokenInConfig,
  revokeTokenInConfig, setAdminInConfig, setQuotaOwnerInConfig,
} from './issue-token.ts'
import { createTokenTable } from './token-table.ts'
import { createJsonLogger } from './json-logger.ts'
import { readMeteringState } from './metering-state.ts'
import { startRelay, type ConnectorEnroll } from './server.ts'

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
  /**
   * 管理面（`/admin`）的凭据，只放 `sha256(令牌)`。
   *
   * **不配就没有这张面**：`server.ts` 对 `/admin*` 一律 404。这是"绝不裸奔"的
   * 结构性保证 —— 不靠端口绑在哪、也不靠反代配置对不对。
   */
  admin?: { id: string; hash: string }
  /**
   * 按人的流量额度。**整段不配 = 只转发、不记账**。
   *
   * `period` 用 UTC 结算；`owners` 按人覆盖 `defaultBytes`；`persist: true` 才落盘
   * （默认内存态，重启清零 —— 与名册/票同一条纪律）。
   */
  quota?: {
    period?: 'month' | 'day' | 'none'
    enforce?: 'cut' | 'block' | 'off'
    defaultBytes?: number
    owners?: Record<string, number>
    persist?: boolean
    statePath?: string
  }
  /**
   * 连接器认证模式。
   *
   * - `open`（**默认**）：连接器不带令牌也能连 —— 中转在 `POST /connector/enroll`
   *   当场给它签一张普通令牌（同一张摘要表、同一个吊销按钮）。
   * - `required`：只认管理员签发的令牌（`--issue-token` 或管理面板）。
   */
  connectorAuth?: 'open' | 'required'
  /**
   * 自动签发总数上限（只数 `source: "auto"` 且未吊销的条目）。
   *
   * **`null` 或不写 = 无上限**，不预设人为限制；owner 想收紧就写个正整数。
   */
  autoEnrollLimit?: number | null
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

/**
 * 管理面段先校验：摘要不是 64 位十六进制就**启动失败**。
 *
 * 与"没有 tokens 直接退出"同一条纪律 —— 一个"面板开了但永远 401"的中转，
 * 比一开始就说"你的 admin.hash 写错了"难查得多。
 */
if (config.admin !== undefined) {
  const { id, hash } = config.admin
  if (typeof id !== 'string' || id === '' || typeof hash !== 'string' || !/^[0-9a-fA-F]{64}$/.test(hash)) {
    console.error('配置里的 admin 段不合法：需要 { "id": "<非空>", "hash": "<sha256 十六进制，64 位>" }')
    process.exit(2)
  }
}

/**
 * 连接器认证段校验。同样是"启动时就大声失败"：
 * 一个模式拼错（`opne`）就会**静默退回默认值**，而默认值是开放的 —— 那是最不该猜的一格。
 */
if (
  config.connectorAuth !== undefined
  && config.connectorAuth !== 'open'
  && config.connectorAuth !== 'required'
) {
  console.error(`配置里的 connectorAuth 不合法：「${String(config.connectorAuth)}」（只能是 open / required）`)
  process.exit(2)
}
if (
  config.autoEnrollLimit !== undefined
  && config.autoEnrollLimit !== null
  && (!Number.isInteger(config.autoEnrollLimit) || config.autoEnrollLimit < 1)
) {
  console.error('配置里的 autoEnrollLimit 不合法：正整数，或 null / 不写（= 无上限）')
  process.exit(2)
}

/**
 * 额度段校验。配错就**启动失败**（与"没有 tokens 直接退出"同一条纪律）：
 * 一个"额度永远算 0"或"永远超"的中转，比一开始就说清哪里写错难查得多。
 */
function quotaProblem(quota: NonNullable<RelayConfig['quota']>): string | undefined {
  if (quota.period !== undefined && !['month', 'day', 'none'].includes(quota.period)) {
    return `period 只能是 month / day / none（收到 ${String(quota.period)}）`
  }
  if (quota.enforce !== undefined && !['cut', 'block', 'off'].includes(quota.enforce)) {
    return `enforce 只能是 cut / block / off（收到 ${String(quota.enforce)}）`
  }
  // `defaultBytes` 不写 = 不限制（默认）。写了就必须是正整数。
  if (quota.defaultBytes !== undefined && (!Number.isInteger(quota.defaultBytes) || quota.defaultBytes <= 0)) {
    return 'defaultBytes 必须是正整数（不限制就别写这一格）'
  }
  for (const [owner, bytes] of Object.entries(quota.owners ?? {})) {
    if (!Number.isInteger(bytes) || bytes <= 0) return `owners.${owner} 必须是正整数（取消某人的上限请删掉那一格）`
  }
  if (quota.persist === true && quota.statePath !== undefined && quota.statePath === '') {
    return 'persist: true 时 statePath 不能是空串'
  }
  return undefined
}
if (config.quota !== undefined) {
  const problem = quotaProblem(config.quota)
  if (problem !== undefined) {
    console.error(`配置里的 quota 段不合法：${problem}`)
    process.exit(2)
  }
  // 默认落盘位置与配置同目录 —— 那个目录在容器里已经可写（compose 的挂载）。
  config.quota = {
    ...config.quota,
    ...(config.quota.persist === true && config.quota.statePath === undefined
      ? { statePath: join(dirname(configPath), 'relay.state.json') }
      : {}),
  }
}

// 签发模式：`--issue-token connector <id>` —— 生成令牌、把**摘要**写进配置、把令牌打印一次。
// 它**必须能在 `tokens` 为空时运行**（否则没有办法引导第一台连接器）。
//
// **只签连接器**：设备令牌由电脑侧签发、摘要经 `POST /devices` 进名册（§8.2）。
// 中转签设备令牌等于转发器凭空造出"我是某台设备"的凭据，正是 v2 否掉的形状。
const issueArgs = process.argv.includes('--issue-token')
  ? process.argv.slice(process.argv.indexOf('--issue-token') + 1, process.argv.indexOf('--issue-token') + 3)
  : []
if (issueArgs.length === 2) {
  const [kind, id] = issueArgs as [string, string]
  if (kind !== 'connector') {
    console.error(`签发类型只支持 connector（收到 ${kind}）。`)
    console.error('设备令牌不由中转签发：它由电脑侧生成、摘要经 POST /devices 进名册，')
    console.error('于是中转即使被读走配置也造不出"我是某台设备"的凭据。给设备发令牌请走配对流程。')
    process.exit(2)
  }
  if (id === undefined || id === '') {
    console.error('用法: --issue-token connector <连接器 id> [--owner <用户>]')
    process.exit(2)
  }
  // `--owner <名字>`（可选）：同一人的多台电脑写同一个 owner，限流按**人**分桶。
  // 不配就按连接器分桶 —— 那是旧行为，也是"每人一台电脑"时的等价形状。
  const owner = argValue('--owner')
  const issued = issueToken({ kind, id })
  const tokens = await appendTokenToConfig(configPath, {
    kind, id, hash: issued.hash,
    ...(owner === undefined || owner === '' ? {} : { owner }),
  })
  console.log(
    `已签发 ${kind} 令牌（id=${id}${owner === undefined ? '' : `，owner=${owner}`}）。`
    + `摘要已写进 ${configPath}（现在 ${tokens.length} 条）。`,
  )
  console.log('令牌**只显示这一次**，请立刻交给对端：')
  console.log(issued.token)
  process.exit(0)
}

// 管理面令牌：`--issue-admin <id>` —— 与连接器令牌同规格（128 位随机）、
// 同样只把**摘要**写进配置、明文只打印这一次。
//
// 它**不写进 `tokens` 表**：连接器令牌的权力是"替一台电脑报名册、拨数据面"，
// 不该交给浏览器。管理面只看与管，权限小一个量级（`admin/auth.ts` 的文件头）。
if (process.argv.includes('--issue-admin')) {
  const index = process.argv.indexOf('--issue-admin')
  const id = process.argv[index + 1]
  if (id === undefined || id === '') {
    console.error('用法: --issue-admin <管理身份 id>')
    process.exit(2)
  }
  const issued = issueToken({ kind: 'connector', id })
  await setAdminInConfig(configPath, { id, hash: issued.hash })
  console.log(`已签发管理令牌（id=${id}）。摘要已写进 ${configPath}（admin 段）。`)
  console.log('令牌**只显示这一次**，请立刻存进密码管理器：')
  console.log(issued.token)
  process.exit(0)
}

const entries = config.tokens ?? []

// 吊销模式：`--revoke-token connector <id>`（软吊销：行留着、标 `revokedAt`）。
// 同样只认连接器：设备吊销走电脑侧（`devices.revoke` / 从名册里摘掉），
// 因为名册的写入方本来就是电脑侧。
if (process.argv.includes('--revoke-token')) {
  const index = process.argv.indexOf('--revoke-token')
  const [kind, id] = process.argv.slice(index + 1, index + 3) as [string, string]
  if (kind !== 'connector' || id === undefined) {
    console.error('用法: --revoke-token connector <连接器 id>')
    console.error('设备吊销不走中转：名册由电脑侧写入（POST /devices），请从电脑侧摘掉那台设备。')
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

// **开放模式下空表是合法起点**：谁都没来兑换过，表本来就是空的。此时拒绝启动等于
// 把"零管理"这件事做死 —— 而它正是 `connectorAuth: "open"` 的全部意义。
if (entries.length === 0 && (config.connectorAuth ?? 'open') !== 'open') {
  console.error(
    '配置里没有 tokens，且 connectorAuth 是 required：中转起来也无人能连上'
    + '（只放摘要，不放明文令牌）。要免维护就把 connectorAuth 设成 "open"',
  )
  process.exit(2)
}

/**
 * 摘要表在 `main` 里持有（而不是只交出一个 authenticate 函数）：面板的吊销/恢复
 * 要能在运行中改它，而"改哪里"必须只有一处。
 */
let table: ReturnType<typeof createTokenTable>
try {
  table = createTokenTable(entries)
} catch (error) {
  // 配置错就**明确失败**：带着 device 条目的中转"起来了但谁都连不上"（设备 403、
  // 连接器可能还正常），那种半死状态比起不来难查得多。与下面"没有 tokens 直接退出"
  // 是同一条纪律。
  console.error(`配置里的令牌摘要表不可用：${error instanceof Error ? error.message : String(error)}`)
  process.exit(2)
}
const authenticate = (token: string) => table.authenticate(token)

/**
 * 面板的写动作落到配置文件（**与 CLI 共用同一套写法**：整份重写、保留其他键）。
 *
 * 失败一律回 `{ ok: false, error }`，由面板回 500 —— 绝不"界面说改好了、文件没变"。
 */
const adminOps = config.admin === undefined ? undefined : {
  tokens: () => table.list(),
  async setTokenEnabled(id: string, enabled: boolean): Promise<{ ok: boolean; error?: string }> {
    try {
      if (enabled) {
        if (!table.restore(id)) return { ok: false, error: `配置里没有 id 为 ${id} 的令牌` }
        await restoreTokenInConfig(configPath, { kind: 'connector', id })
        return { ok: true }
      }
      if (!table.revoke(id)) return { ok: false, error: `配置里没有 id 为 ${id} 的令牌` }
      await revokeTokenInConfig(configPath, { kind: 'connector', id })
      return { ok: true }
    } catch (error) {
      return { ok: false, error: error instanceof Error ? error.message : String(error) }
    }
  },
  async removeToken(id: string): Promise<{ ok: boolean; error?: string }> {
    try {
      if (!table.remove(id)) return { ok: false, error: `配置里没有 id 为 ${id} 的令牌` }
      await removeTokenFromConfig(configPath, { kind: 'connector', id })
      return { ok: true }
    } catch (error) {
      return { ok: false, error: error instanceof Error ? error.message : String(error) }
    }
  },
  async persistQuota(owner: string, bytes: number | null): Promise<{ ok: boolean; error?: string }> {
    try {
      await setQuotaOwnerInConfig(configPath, owner, bytes)
      return { ok: true }
    } catch (error) {
      return { ok: false, error: error instanceof Error ? error.message : String(error) }
    }
  },
}
// 额度主体来自**配置**（令牌条目里的 `owner`），不是运行时状态：连接器掉线不该让
// "算在谁名下"跟着变。吊销的条目不参与（它连不上，也不该占着额度）。
const owners = new Map<string, string>()
for (const entry of entries) {
  if (entry.owner !== undefined && entry.revokedAt === undefined) owners.set(entry.id, entry.owner)
}
const quotaState = config.quota?.persist === true && config.quota.statePath !== undefined
  ? await readMeteringState(config.quota.statePath, {
    error: (message, detail) => console.error(`[relay] ${message}`, detail ?? ''),
    warn: () => { /* 读状态只用 error */ },
    info: () => { /* 同上 */ },
    debug: () => { /* 同上 */ },
  })
  : undefined

/**
 * 连接器自助兑换（`POST /connector/enroll`）。
 *
 * 签出来的是**一张普通令牌**：进同一张摘要表、同一个吊销按钮、同一条限流 ——
 * "要不要认证"只由这里的 `mode` 决定，认证路径没有第二条。
 * **先落盘再进内存表**：写不进配置文件，就不该存在"能连、重启就丢"的令牌。
 */
const connectorAuth = config.connectorAuth ?? 'open'
const autoEnrollLimit = config.autoEnrollLimit ?? null
const autoEnrolledCount = (): number =>
  table.list().filter((row) => row.source === 'auto' && row.revokedAt === undefined).length
const connectorEnroll: ConnectorEnroll = {
  mode: connectorAuth,
  limit: autoEnrollLimit,
  count: autoEnrolledCount,
  async issue({ pcId, name }) {
    const connectorId = `auto-${randomBytes(4).toString('hex')}`
    const issued = issueToken({ kind: 'connector', id: connectorId })
    await appendTokenToConfig(configPath, {
      kind: 'connector',
      id: connectorId,
      hash: issued.hash,
      source: 'auto',
    })
    table.add({ kind: 'connector', id: connectorId, hash: issued.hash, source: 'auto' })
    console.log(
      `已自动签发连接器令牌（id=${connectorId}，pcId=${pcId}`
      + `${name === undefined ? '' : `，${name}`}）：自动条目现在 ${autoEnrolledCount()} 条`,
    )
    return { token: issued.token, connectorId }
  },
}

const relay = await startRelay({
  port: config.port ?? 8787,
  host: config.host ?? '127.0.0.1',
  authenticate,
  // 配置里给了就用它，没给就用 `server.ts` 的默认值（默认生效，见那里的说明）。
  ...(config.rateLimit === undefined ? {} : { rateLimit: config.rateLimit }),
  // 没配 `admin` 就不传：那张面不存在（`/admin*` 一律 404）。
  ...(config.admin === undefined ? {} : { admin: config.admin }),
  // 没配 `quota` 就不传：只转发、不记账。
  ...(config.quota === undefined ? {} : { quota: config.quota }),
  ownerOf: (connectorId: string) => owners.get(connectorId),
  ...(quotaState === undefined ? {} : { quotaState }),
  // 面板的写动作（没配 admin 就没有这张面，也就不传）。
  ...(adminOps === undefined ? {} : { adminOps }),
  connectorEnroll,
  // 中转必须**留声**：它只转发与记账，出问题时（投递目标不在、丢弃、认证被拒）
  // 日志是唯一的线索。一行一个 JSON 事件（`json-logger.ts`）：容器里能 grep 字段，
  // 面板与排障读同一份东西。`debug` 级默认关（`DSH_RELAY_DEBUG=1` 打开）。
  log: createJsonLogger({ debug: process.env['DSH_RELAY_DEBUG'] === '1' }),
})

console.log(
  `中转已监听 ws://${config.host ?? '127.0.0.1'}:${relay.port}（摘要表 ${table.size} 条`
  + `，连接器认证 ${connectorAuth === 'open' ? '开放（可自助兑换）' : '必需'}`
  + `，自动签发上限 ${autoEnrollLimit === null ? '无' : `${autoEnrollLimit} 条`}`
  + `${config.admin === undefined ? '' : `，管理面 /admin 已启用（${config.admin.id}）`}）`,
)

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
