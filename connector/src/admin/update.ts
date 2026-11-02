/**
 * 「有没有新版本」—— 面板上的**一个只读查询**，不是自动更新。
 *
 * ## 为什么装在电脑侧而不是浏览器直连 npm
 *
 * 浏览器直连 `registry.npmjs.org` 会被 CORS / 内网代理 / 公司网关三件事分叉，
 * 而"这台电脑够不够得着 npm"本来就是电脑侧的事实（插件就是它装的）。
 * 所以查询放在宿主进程里，面板只问 `/api/dsh-mobile/update`。
 *
 * ## 真值只有一个：npm 上的 `latest`
 *
 * 插件是通过 `dsh plugin add dsh-mobile-connector` 装的，那条路径读的就是 npm 的
 * `latest`。GitHub Release 上的 tgz 是同一份构建、但版本号属于**另一个**发布节奏
 * （App 和插件共用 `v*` 标签），拿它当判据会给出错误结论 —— 这里不猜。
 *
 * ## 失败不假装"已是最新"
 *
 * 查不到（离线 / npm 挂了 / 包还没发过）时 `latest` 是 `null`，界面显示
 * "查不到最新版本"并给出错误原话。把失败画成"已是最新"是最坏的一种谎言。
 */

/** 一次查询的结论。`latest === null` = 没查到（不是"没有新版"）。 */
export interface UpdateInfo {
  /** 本机装的版本（`connector/package.json` 的 `version`）。 */
  current: string
  /** npm 上的 `latest`；查不到就是 `null`。 */
  latest: string | null
  /** `latest` 是否比 `current` 新（查不到时恒 `false`）。 */
  hasUpdate: boolean
  /** 给人看的落地页（npm 包页）。 */
  url: string | null
  /** 这次结论是什么时候取的（epoch ms）。 */
  checkedAt: number
  /** 查询失败时的原话（**不吞**）。 */
  error?: string
}

export interface UpdateChecker {
  /** 查一次（带内存缓存，[ttlMs] 内重复调用直接回上一次的结论）。 */
  check(): Promise<UpdateInfo>
}

const REGISTRY = 'https://registry.npmjs.org/dsh-mobile-connector/latest'
/** 缓存时长：`check` 是用户点出来的，一分钟内连点不该打两次网络。 */
const TTL_MS = 60_000

/**
 * 比版本号：**只按数字段比**，不认识的前缀当 0。
 *
 * 不用 semver 是为了不引依赖 —— 我们的版本只有 `x.y.z`，预发布串（`-rc.1`）
 * 一律按"不比正式版新"处理（`0.1.8-rc.1` 与 `0.1.8` 比 → 不新）。
 */
export function isNewerVersion(current: string, latest: string): boolean {
  const parse = (value: string): number[] =>
    (value.split('-')[0] ?? '')
      .split('.')
      .map((part) => Number.parseInt(part, 10))
      .map((n) => (Number.isFinite(n) ? n : 0))
  const a = parse(current)
  const b = parse(latest)
  const length = Math.max(a.length, b.length)
  for (let i = 0; i < length; i += 1) {
    const left = a[i] ?? 0
    const right = b[i] ?? 0
    if (right > left) return true
    if (right < left) return false
  }
  return false
}

export function createUpdateChecker(options: {
  current: string
  /** 查询实现（测试注入；缺省用全局 `fetch`）。 */
  fetchImpl?: typeof fetch
  now?: () => number
  ttlMs?: number
}): UpdateChecker {
  const now = options.now ?? (() => Date.now())
  const ttl = options.ttlMs ?? TTL_MS
  let cached: UpdateInfo | null = null

  const fetchImpl = (): typeof fetch => options.fetchImpl ?? fetch

  return {
    async check() {
      if (cached !== null && now() - cached.checkedAt < ttl) return cached
      const base = { current: options.current, checkedAt: now() }
      try {
        const response = await fetchImpl()(REGISTRY, {
          headers: { accept: 'application/json' },
        })
        if (!response.ok) {
          throw new Error(`npm registry 回了 HTTP ${response.status}`)
        }
        const body = (await response.json()) as { version?: unknown }
        const latest = typeof body.version === 'string' ? body.version : ''
        if (latest === '') throw new Error('npm registry 的应答里没有 version')
        cached = {
          ...base,
          latest,
          hasUpdate: isNewerVersion(options.current, latest),
          url: `https://www.npmjs.com/package/dsh-mobile-connector/v/${latest}`,
        }
        return cached
      } catch (error) {
        // **失败不缓存**：下一次点还能再试（npm 抖一下不该锁死一分钟）。
        return {
          ...base,
          latest: null,
          hasUpdate: false,
          url: null,
          error: error instanceof Error ? error.message : String(error),
        }
      }
    },
  }
}
