/**
 * 限流（契约 §12 的滥用对策里有"按设备限流与审计"；§3.1 的错误表里有 `rate-limited`）。
 *
 * 用**令牌桶**而不是"每分钟最多 N 次"：后者在窗口边界上允许 2N 次突发
 * （Windows 的固定窗口限流就是这么被绕过的）。令牌桶的两个参数各自有意义：
 *
 * - `capacity`：允许的**突发**上限（桶多大）；
 * - `refillPerSecond`：长期**平均**速率。
 *
 * 两件事必须想清楚，否则限流会变成"随机拒绝正常用户"：
 *
 * 1. **按谁限**：认证过的调用方按**身份**（设备 id / 连接器 id），不是按 IP ——
 *    中转在代理之后时 IP 会把所有人归成一个（那是最糟的形态：一个人把大家限住）。
 *    唯一的例外是**还没配对的那一跳**（`pairing:anonymous:<来源地址>`）：那里没有任何身份，
 *    来源地址是唯一能区分的维度；取不到地址或部署在代理之后时它退化成一个全局桶，
 *    与"完全不分来源"等价（不更坏）。
 * 2. **时钟**：注入 `now()`。真实时间会让测试变成"睡一会儿再看"，那类测试又慢又脆；
 *    注入之后限流的语义（补充、封顶、拒绝）可以被精确断言。
 *
 * 内存形态：进程内一张表。多实例部署时限流会变成"每个实例各限一份"
 * （§12 的完整形态要求共享存储或边缘限流）—— 如实记在笔记里，现在不引依赖。
 */
import type { ChannelLogger } from './logger.ts'

export interface RateLimitOptions {
  /** 桶容量（突发上限）。 */
  capacity: number
  /** 每秒补充多少令牌（长期平均速率）。 */
  refillPerSecond: number
  now?: () => number
  log?: ChannelLogger
}

export interface RateLimitDecision {
  allowed: boolean
  /**
   * 被拒时告知客户端"多少毫秒后可以再试"（HTTP 上对应 `Retry-After`）。
   *
   * **`null` 表示"不会自行恢复"**：`refillPerSecond: 0` 是合法配置（硬配额），
   * 此时桶永不补充。注意不能返回 `Infinity` —— `JSON.stringify` 会把它写成 `null`，
   * 而客户端分不清"无限久"与"字段缺失"（这正是本条类型存在的理由）。
   */
  retryAfterMs: number | null
}

export interface RateLimiter {
  /** 取一个令牌。`key` 是身份（设备 id / 连接器 id）。 */
  take(key: string): RateLimitDecision
  /** 观测：当前有多少个桶（空闲清理用）。 */
  readonly size: number
  /** 清掉已经完全补满的桶（它们与"从没出现过"等价）。返回清掉几个。 */
  sweep(): number
}

/**
 * 隔多少次取用做一次自清。
 *
 * 为什么要自清：`take` 会为**每个见过的身份**建桶，而"见过的身份"没有上界
 * （扫端口的人可以编出无数个）；桶本身很小，但表会长。自清而不是定时器，
 * 与"惰性补充"同一个理由：**不引入后台任务**。
 *
 * 取 64：一次自清扫全表，所以这个值决定"摊销到每次取用的扫描成本"。
 * 64 时每次取用摊到 1/64 次扫描 —— 在限流这种每秒几十次的路径上可以忽略。
 */
const SWEEP_EVERY = 64

export function createRateLimiter(options: RateLimitOptions): RateLimiter {
  const now = options.now ?? (() => Date.now())
  const capacity = options.capacity
  const refillPerMs = options.refillPerSecond / 1000

  /** `key → { tokens, at }`：`at` 是上次结算时刻（惰性补充，不靠定时器）。 */
  const buckets = new Map<string, { tokens: number; at: number }>()
  /** 取用计数：每 `SWEEP_EVERY` 次做一次自清（见该常量的说明）。 */
  let takes = 0

  const sweep = (): number => {
    const at = now()
    let removed = 0
    for (const [key, bucket] of buckets) {
      const refilled = Math.min(capacity, bucket.tokens + (at - bucket.at) * refillPerMs)
      if (refilled >= capacity) {
        buckets.delete(key)
        removed += 1
      }
    }
    return removed
  }

  return {
    get size() {
      return buckets.size
    },

    take(key) {
      // 自清：`take` 会为每个见过的身份建桶，而"见过的身份"没有上界（扫描者能编出无数个）。
      // 每 SWEEP_EVERY 次做一次全表扫描 —— 摊销到单次取用上可以忽略（见常量说明）。
      takes += 1
      if (takes % SWEEP_EVERY === 0) sweep()

      const at = now()
      const bucket = buckets.get(key) ?? { tokens: capacity, at }
      // 惰性补充：从上次结算到现在按速率加点，**封顶在容量**（否则闲置越久越能突发）。
      const refilled = Math.min(capacity, bucket.tokens + (at - bucket.at) * refillPerMs)
      if (refilled < 1) {
        // 被拒时**也要写回**（把补充量结算掉），否则下次判断会重复补同一段时间。
        buckets.set(key, { tokens: refilled, at })
        // 零补充（硬配额）时**如实回 `null`**（"不会自行恢复"），而不是 `Infinity`：
        // 后者过 JSON 会变成 `null` 或 `undefined`，与"字段缺失"混淆（见类型的说明）。
        const retryAfterMs = refillPerMs === 0 ? null : Math.ceil((1 - refilled) / refillPerMs)
        options.log?.debug(
          `限流：${key} 被拒${retryAfterMs === null ? '（该身份不会自行恢复，需要加容量或换配置）' : `，约 ${retryAfterMs}ms 后可再试`}`,
        )
        return { allowed: false, retryAfterMs }
      }
      buckets.set(key, { tokens: refilled - 1, at })
      return { allowed: true, retryAfterMs: 0 }
    },

    sweep,
  }
}
