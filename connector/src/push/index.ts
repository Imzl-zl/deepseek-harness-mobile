/**
 * 推送摘要与合并（契约 §9）。
 *
 * **推送只负责敲门，不参与正确性**（不变量 I6 的推论）：推送丢失、重复、乱序都不影响
 * 状态收敛，兜底是「App 每次回到前台无条件发一次 `sync.hello`」。这条定位决定了本文件的
 * 两个设计取向 —— 宁可少推、也绝不把正文塞进推送。
 *
 * ## 一、摘要是白名单拼出来的，不是截取出来的
 *
 * 契约只允许两档：`rich`（默认，带最小摘要）/ `doorbell`（只带「有新事件」），
 * 并明确要求如实记录：**`rich` 档下摘要对推送通道可见，正文与工具输出始终不可见**。
 *
 * 所以摘要是从**固定词表 + 计数 + 工具名**拼出来的，**不允许**从会话内容里截一段 ——
 * 截取方案在第一次遇到"审批理由是命令全文"时就会把命令推进推送通道，而推送通道
 * （厂商推送服务）不在端到端加密范围内。`doorbell` 档连工具名都不带。
 *
 * ## 二、「60 s 内折叠为一条」按**限流**读，不按延迟读
 *
 * 契约原文只说了「同会话同类型 60 s 内折叠为一条」，两种读法都通：延迟 60 s 再推，
 * 或立刻推第一条、其后 60 s 内的同类折进它。这里选**后者**，理由：
 *
 * - 推送的作用是敲门，审批晚 60 s 才响会让「手机接管」这个场景失去意义；
 * - 「折叠」的语义是用户看到的通知条数，而不是服务端的发送时机；
 * - 前者需要为每个待推项持有定时器与持久队列，而推送不参与正确性 —— 为它引入
 *   跨重启的持久队列，成本与收益完全不匹配。
 */

/** 四类触发，**全部由电脑侧判定**（契约 §9）。 */
export const PUSH_TRIGGERS = [
  'approval-pending',
  'question-pending',
  'job-settled',
  'turn-failed',
] as const

export type PushTrigger = (typeof PUSH_TRIGGERS)[number]

/** 同会话同类型在这个窗口内折叠为一条。 */
export const PUSH_COALESCE_MS = 60_000

/** 两档隐私开关（契约 §1.1 的 `pushDigest` 配置项）。 */
export type PushDigestLevel = 'rich' | 'doorbell'

/** 推给中转的一条通知。**字段是白名单**，没有可以塞正文的位置。 */
export interface PushNotice {
  trigger: PushTrigger
  /** 通道别名；中转据此路由，它看不到 DSH 会话 id。 */
  sid: string
  /** 折叠了多少次同类触发（≥1）。 */
  count: number
  /**
   * 工具名。`doorbell` 档下被剥掉，`job-settled` / `turn-failed` 也没有它 ——
   * 它是**元数据**不是正文，所以 `rich` 档可以带。
   */
  toolName?: string
}

/**
 * 生成摘要用的上下文。刻意只有这三个字段：想加一个新字段就得先回答
 * 「它会不会把正文带出去」。
 */
export interface PushContext {
  toolName?: string
}

export interface PushMerger {
  /**
   * 记一次触发。
   *
   * @returns 该现在推的通知；落在折叠窗口内时返回 `null`（计数已累加）。
   */
  note(trigger: PushTrigger, sid: string, context: PushContext, now: number): PushNotice | null
  /** 切换隐私档位。切换只影响**之后**生成的通知。 */
  setLevel(level: PushDigestLevel): void
  readonly level: PushDigestLevel
  /** 当前活跃的折叠桶数量（诊断用）。 */
  readonly activeBuckets: number
}

interface Bucket {
  firstAt: number
  count: number
  toolName?: string
}

/** 折叠键：**同会话 + 同类型**，两个都相同才算同类。 */
const keyOf = (trigger: PushTrigger, sid: string): string => `${sid}\u0000${trigger}`

export function createPushMerger(level: PushDigestLevel = 'rich'): PushMerger {
  const buckets = new Map<string, Bucket>()
  let current = level

  return {
    note(trigger, sid, context, now) {
      const key = keyOf(trigger, sid)
      const existing = buckets.get(key)

      if (existing !== undefined && now - existing.firstAt < PUSH_COALESCE_MS) {
        // 折叠：只累加计数。通知条数不增 —— 这正是「折叠为一条」要的效果。
        existing.count += 1
        return null
      }

      const bucket: Bucket = {
        firstAt: now,
        count: 1,
        ...(context.toolName === undefined ? {} : { toolName: context.toolName }),
      }
      buckets.set(key, bucket)

      const notice: PushNotice = { trigger, sid, count: 1 }
      // `doorbell` 档连工具名都不带 —— 它的全部信息量就是「有新事件」。
      if (current === 'rich' && bucket.toolName !== undefined) notice.toolName = bucket.toolName
      return notice
    },

    setLevel(next) {
      current = next
    },

    get level() {
      return current
    },

    get activeBuckets() {
      return buckets.size
    },
  }
}
