/**
 * 结构化日志与指标（契约 §1.2）。
 *
 * 两件事，都为「出问题时能在电脑上查」服务：
 *
 * 1. **把 cordis 的 printf 风格 logger 收成两参数形状**（`(message, detail?)`）。
 *    cordis 的 `LoggerMethod` 是 `(format, ...params)`，而本插件内部一律用
 *    「一句人能读的话 + 一个结构化对象」。在这里收口，就不用让每个调用点都去记
 *    `%s` / `%O` 的区别，也不会出现「detail 忘了格式化于是被吞掉」。
 * 2. **计数与仪表**：通道的状态机迁移、拒绝的帧、重连次数都要能一眼看到。
 *    指标只在内存里，`snapshot()` 供健康上报读。
 *
 * 刻意**不**做日志分级过滤与采样：那是宿主的 exporter 的职责
 * （cordis 的 `Exporter.levels` 已经管了），插件再管一层只会让两边判断不一致。
 */

/** cordis logger facade 的最小结构（`ctx.logger(name)` 的返回值）。 */
export interface PrintfLogger {
  error(format: unknown, ...params: unknown[]): void
  info(format: unknown, ...params: unknown[]): void
  warn(format: unknown, ...params: unknown[]): void
  debug(format: unknown, ...params: unknown[]): void
}

/** 本插件内部统一的日志形状。 */
export interface ChannelLogger {
  info(message: string): void
  warn(message: string, detail?: unknown): void
  error(message: string, detail?: unknown): void
  /** 详细到只在排查时想看的东西。 */
  debug(message: string, detail?: unknown): void
}

/**
 * 把 printf 风格 logger 收成两参数形状。
 *
 * `%O` 是 cordis 自带的「对象格式化」占位符；detail 为空时不追加参数，
 * 免得日志里多出一个 `undefined`。
 */
export function createChannelLogger(logger: PrintfLogger): ChannelLogger {
  const emit =
    (method: keyof PrintfLogger) =>
    (message: string, detail?: unknown): void => {
      if (detail === undefined) logger[method]('%s', message)
      else logger[method]('%s %O', message, detail)
    }
  return {
    info: (message) => logger.info('%s', message),
    warn: emit('warn'),
    error: emit('error'),
    debug: emit('debug'),
  }
}

/** 不落任何日志的实现，给测试与「宿主没给 logger」时用。 */
export const silentLogger: ChannelLogger = {
  info: () => {},
  warn: () => {},
  error: () => {},
  debug: () => {},
}

export interface ChannelMetrics {
  increment(name: string, by?: number): void
  gauge(name: string, value: number): void
  snapshot(): Readonly<Record<string, number>>
}

/**
 * 内存指标。名字用**扁平的常量字符串**（调用方自己定义常量），不做层级前缀拼接 ——
 * 层级在 `snapshot()` 的消费端（健康上报）里没有用，只会让键名变长。
 */
export function createMetrics(): ChannelMetrics {
  const values = new Map<string, number>()
  return {
    increment(name, by = 1) {
      values.set(name, (values.get(name) ?? 0) + by)
    },
    gauge(name, value) {
      values.set(name, value)
    },
    snapshot() {
      return Object.fromEntries(values)
    },
  }
}

/**
 * 本插件用到的指标名。集中定义，避免同一个含义在两个地方拼出两个键。
 */
export const METRIC = {
  /** 连接状态迁移次数。 */
  stateTransitions: 'connector.state.transitions',
  /** 已建连次数（含重连）。 */
  connects: 'connector.connect.count',
  /** 因协议原因被拒的帧数。 */
  rejectedFrames: 'connector.frames.rejected',
  /** 收到的帧总数。 */
  inboundFrames: 'connector.frames.inbound',
  /** 发出的帧总数。 */
  outboundFrames: 'connector.frames.outbound',
  /** 攒批发出的批次数。 */
  batches: 'connector.batches.sent',
  /** 当前已配对的未吊销设备数。 */
  pairedDevices: 'connector.devices.paired',
  /** 当前待处理的审批 / 提问数。 */
  pendingInteractions: 'connector.interactions.pending',
  /** 转给手机但没等到回答、按 fail-closed 收束的次数。 */
  failClosed: 'connector.interactions.fail_closed',
} as const

export type MetricName = (typeof METRIC)[keyof typeof METRIC]
