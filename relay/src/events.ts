/**
 * 最近事件的环形缓冲（面板"动态"分区用）。
 *
 * ## 它和日志的关系
 *
 * 日志是**留声**（一行一个 JSON，给 `docker logs`/排障）；这里是**回显**（最近 100 条，
 * 给面板看"刚刚发生了什么"）。两者同一批事件、同一份字段，不另立一套口径 ——
 * 实现方式是给 `ChannelLogger` 套一层镜像：写日志的同时往环里丢一条。
 *
 * ## 三条纪律
 *
 * 1. **只留元数据**：帧载荷、令牌、配对秘密不进日志，同样不进环形缓冲（契约 §12.2）。
 * 2. **有界**：固定容量，满了覆盖最旧的。单实例、单人运维，100 条够看。
 * 3. **不阻塞**：`push` 是一次数组写入 + 一次长度裁剪，没有 I/O、没有 await。
 */
import type { ChannelLogger } from './logger.ts'

export interface RelayEvent {
  /** 毫秒时间戳。 */
  at: number
  level: 'info' | 'warn' | 'error'
  /** 事件名（与日志的 `evt` 同一批）。 */
  evt: string
  /** 元数据（只放 id/码/字节数这类，不放内容）。 */
  detail: Record<string, unknown>
}

export interface EventRing {
  push(event: RelayEvent): void
  /** 最新的在前。 */
  list(): readonly RelayEvent[]
  readonly size: number
}

const isPlainObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value)
  // `Error` / `Date` 这类也有原型链：只收**字面量对象**，其余折成字符串。
  && Object.getPrototypeOf(value) === Object.prototype

export function createEventRing(options: { capacity?: number } = {}): EventRing {
  const capacity = options.capacity ?? 100
  const events: RelayEvent[] = []

  return {
    push(event) {
      events.push(event)
      if (events.length > capacity) events.splice(0, events.length - capacity)
    },
    list() {
      return [...events].reverse()
    },
    get size() { return events.length },
  }
}

/**
 * 给日志套一层"顺便记进环里"的镜像。
 *
 * `debug` 不记（那是排障细节，帧级噪声不该占掉"最近发生了什么"的位置）；
 * `detail` 不是普通对象时收成 `{ detail: String(...) }`，免得环里出现奇怪的值。
 */
export function mirrorToRing(
  base: ChannelLogger | undefined,
  ring: EventRing,
  clock: () => number = () => Date.now(),
): ChannelLogger {
  const record = (level: 'info' | 'warn' | 'error', evt: string, detail?: unknown): void => {
    ring.push({
      at: clock(),
      level,
      evt,
      detail: isPlainObject(detail)
        ? { ...detail }
        : detail === undefined ? {} : { detail: String(detail) },
    })
  }
  return {
    info(evt, detail) { base?.info(evt, detail); record('info', evt, detail) },
    warn(evt, detail) { base?.warn(evt, detail); record('warn', evt, detail) },
    error(evt, detail) { base?.error(evt, detail); record('error', evt, detail) },
    debug(evt, detail) { base?.debug(evt, detail) },
  }
}
