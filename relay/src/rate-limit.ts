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
 * 1. **按谁限**：这里按调用方身份（设备 id / 连接器 id），不是按 IP ——
 *    中转在代理之后时 IP 会把所有人归成一个（那是最糟的形态：一个人把大家限住）。
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

export function createRateLimiter(options: RateLimitOptions): RateLimiter {
  const now = options.now ?? (() => Date.now())
  const capacity = options.capacity
  const refillPerMs = options.refillPerSecond / 1000

  /** `key → { tokens, at }`：`at` 是上次结算时刻（惰性补充，不靠定时器）。 */
  const buckets = new Map<string, { tokens: number; at: number }>()

  return {
    get size() {
      return buckets.size
    },

    take(key) {
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

    sweep() {
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
    },
  }
}
