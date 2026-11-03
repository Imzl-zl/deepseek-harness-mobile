/**
 * 按来源地址的**连续失败锁定**（管理面与登录页共用一份计数）。
 *
 * ## 为什么不是"限流"
 *
 * 限流（`rate-limit.ts`）管的是**速率**：桶里还有令牌就放行，猜错一百次也只是变慢。
 * 爆破要的是"猜错就停"——所以这里数的是**连续失败次数**，不是请求数：
 * 成功一次清零，连错 `failures` 次就把这个地址锁 `cooldownMs`。
 *
 * ## 三个决定
 *
 * 1. **锁定不是永久的**：到期自动放行。永久封禁会把"自己在外面输错五次"变成
 *    "回家改配置"，而这份配置在服务器上，等于把自己关在门外。
 * 2. **锁定期内连正确密码也不放行**：否则爆破方只要持续尝试，锁定就形同虚设
 *    （每 N 次能试一次）。这条与限流的分桶是两回事，两边都要有。
 * 3. **计数键是来源地址**：没有别的可用身份（失败的那一方本来就没有身份）。
 *    反代后面要拿真实地址，得先配好 `X-Forwarded-For` 的信任边界 —— 那是部署的事，
 *    这里只认 `remoteAddress`。
 *
 * ## 关掉它
 *
 * `failures <= 0` 即整体关闭（配置里写 `"lockout": { "failures": 0 }`）。
 * 关掉是显式动作：默认值 5 次 / 15 分钟。
 *
 * Note: 为什么是"连续失败 + 冷却"而不是永久封禁 —— 见
 * `.agents/notes/implemented/2026-11-03-admin-lockout-and-token-issue.md`
 */

export interface LockoutOptions {
  /** 连续失败几次开始锁。`<= 0` = 关闭。 */
  failures: number
  /** 锁多久（毫秒）。 */
  cooldownMs: number
  /** 注入时钟（测试用）。 */
  now?: () => number
  /** 表的上限：超过就清掉最早到期的条目（防内存被随机地址撑爆）。 */
  maxKeys?: number
}

export interface LockoutState {
  blocked: boolean
  /** 还要等多久（毫秒）；没锁就是 0。 */
  retryAfterMs: number
  /** 当前连续失败次数（锁定期内保持锁定时的值）。 */
  failures: number
}

export interface FailureLockout {
  /** 现在这个地址被锁着吗。 */
  stateOf(key: string): LockoutState
  /** 记一次失败，返回记完之后的判定（调用方据此决定回 401 还是 429）。 */
  fail(key: string): LockoutState
  /** 成功一次：清零（锁定也一起解除 —— 能成功就说明不是爆破方）。 */
  clear(key: string): void
}

const FREE: LockoutState = { blocked: false, retryAfterMs: 0, failures: 0 }

interface Entry {
  failures: number
  blockedUntil: number
  at: number
}

export function createFailureLockout(options: LockoutOptions): FailureLockout {
  const now = options.now ?? Date.now
  const maxKeys = options.maxKeys ?? 10_000
  const entries = new Map<string, Entry>()
  const disabled = options.failures <= 0 || options.cooldownMs <= 0

  const stateOf = (key: string): LockoutState => {
    if (disabled) return FREE
    const entry = entries.get(key)
    if (entry === undefined) return FREE
    const at = now()
    if (entry.blockedUntil > at) {
      return { blocked: true, retryAfterMs: entry.blockedUntil - at, failures: entry.failures }
    }
    // 冷却结束：不再挡人，计数也从零开始 —— 让人等过一次之后还有完整的重试额度

    // （否则一次手误就永远"错一次锁一次"，把自己锁死在门外）。
    return { blocked: false, retryAfterMs: 0, failures: entry.failures }
  }

  /** 超容量时先清"冷却已结束"的，再清最久没动的 —— 正在锁的条目不动。 */
  const prune = (): void => {
    if (entries.size <= maxKeys) return
    const at = now()
    for (const [key, entry] of entries) {
      if (entry.blockedUntil <= at) entries.delete(key)
      if (entries.size <= maxKeys) return
    }
    while (entries.size > maxKeys) {
      const first = entries.keys().next()
      if (first.done === true) return
      entries.delete(first.value)
    }
  }

  return {
    stateOf,
    fail(key) {
      if (disabled) return FREE
      const at = now()
      const previous = entries.get(key)
      // 冷却已过：从 1 重新数（"上一次锁之前"的失败不该继续累计）。
      const base = previous !== undefined && previous.blockedUntil > 0 && previous.blockedUntil <= at
        ? 0
        : previous?.failures ?? 0
      const failures = base + 1
      const blockedUntil = failures >= options.failures ? at + options.cooldownMs : 0
      entries.set(key, { failures, blockedUntil, at })
      prune()
      return stateOf(key)
    },
    clear(key) {
      entries.delete(key)
    },
  }
}
