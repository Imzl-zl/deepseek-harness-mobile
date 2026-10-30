/**
 * 中转的日志面：一行一个 JSON 事件（容器里 `docker logs` 直接可读、可 grep、可入库）。
 *
 * ## 为什么不是文本
 *
 * 原来的实现是一条中文句子 + 可选 detail（`main.ts` 的 `console.*` 注入）：人能读，
 * 但**检索不了** —— "这个人这个月被限流几次"要拿正则去猜句子。事件化之后每个字段都
 * 有名字，面板与排障读的是同一份东西。
 *
 * ## 三条纪律（契约 §12.2）
 *
 * 1. **不记内容**：帧载荷、令牌明文、`tokenHash`、配对秘密一律不进日志。调用方负责
 *    只传元数据；这里再兜一层 —— 长字符串会被截断，避免"整帧被塞进 detail"把日志爆炸。
 * 2. **一处一个事件**：`evt` 是固定的短名（`channel.open` / `quota.rejected` …），
 *    不拼句子（拼句子等于每次改文案都断一段日志查询）。
 * 3. **不做后台缓冲**：同步写一行。中转是低事件量（连接与帧都不记），不需要批量。
 *
 * 与 `logger.ts` 的关系：那个接口是"我需要什么形状"，这里是它的一个实现；
 * 测试与嵌入方仍可传自己的替身。
 */
import type { ChannelLogger } from './logger.ts'

/** 单个字符串字段的上限（字节）。超了截断 —— 防止误把整帧/整份名册塞进一行。 */
export const MAX_FIELD_BYTES = 512
/** 保留字段：`detail` 里出现同名键时**不覆盖**（否则事件名本身会被改写）。 */
const RESERVED = new Set(['ts', 'level', 'evt'])

const isPlainObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value) && Object.getPrototypeOf(value) === Object.prototype

const clamp = (value: string): string => {
  if (Buffer.byteLength(value, 'utf8') <= MAX_FIELD_BYTES) return value
  let used = 0
  let out = ''
  for (const char of value) {
    const size = Buffer.byteLength(char, 'utf8')
    if (used + size > MAX_FIELD_BYTES) break
    out += char
    used += size
  }
  return `${out}…`
}

/** 值归一化：字符串截断、`Error` 只留消息、函数/符号丢掉（JSON 里没有它们的位置）。 */
export function normalizeLogValue(value: unknown): unknown {
  if (typeof value === 'string') return clamp(value)
  if (value instanceof Error) return clamp(value.message)
  if (Array.isArray(value)) return value.map((item) => normalizeLogValue(item))
  if (isPlainObject(value)) {
    const out: Record<string, unknown> = {}
    for (const [key, item] of Object.entries(value)) {
      if (item === undefined || typeof item === 'function' || typeof item === 'symbol') continue
      out[key] = normalizeLogValue(item)
    }
    return out
  }
  if (typeof value === 'bigint') return value.toString()
  return value
}

export interface JsonLoggerOptions {
  /** 写一行。默认 info/debug → stdout，warn/error → stderr。 */
  write?: (line: string, level: 'debug' | 'info' | 'warn' | 'error') => void
  now?: () => number
  /** `debug` 级是否输出（生产默认关，用 `DSH_RELAY_DEBUG=1` 打开）。 */
  debug?: boolean
  /** 注入时钟时用的固定时区无关格式；默认 ISO 8601。 */
  formatTime?: (at: number) => string
}

export function createJsonLogger(options: JsonLoggerOptions = {}): ChannelLogger {
  const now = options.now ?? (() => Date.now())
  const formatTime = options.formatTime ?? ((at: number) => new Date(at).toISOString())
  const write = options.write ?? ((line: string, level: 'debug' | 'info' | 'warn' | 'error') => {
    if (level === 'warn' || level === 'error') console.error(line)
    else console.log(line)
  })
  const debugEnabled = options.debug ?? false

  const emit = (level: 'debug' | 'info' | 'warn' | 'error', evt: string, detail?: unknown): void => {
    if (level === 'debug' && !debugEnabled) return
    const line: Record<string, unknown> = { ts: formatTime(now()), level, evt }
    if (detail !== undefined) {
      if (isPlainObject(detail)) {
        for (const [key, value] of Object.entries(detail)) {
          if (RESERVED.has(key) || value === undefined) continue
          line[key] = normalizeLogValue(value)
        }
      } else {
        line['detail'] = normalizeLogValue(detail)
      }
    }
    write(JSON.stringify(line), level)
  }

  return {
    info: (evt, detail) => emit('info', evt, detail),
    warn: (evt, detail) => emit('warn', evt, detail),
    error: (evt, detail) => emit('error', evt, detail),
    debug: (evt, detail) => emit('debug', evt, detail),
  }
}
