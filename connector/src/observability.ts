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
  /** 握手成功次数（§4.1 的两道校验都过了）。 */
  handshakesEstablished: 'connector.handshake.established',
  /** 收到的帧总数。 */
  inboundFrames: 'connector.frames.inbound',
  /** 发出的帧总数。 */
  outboundFrames: 'connector.frames.outbound',
  /**
   * 已发出的**字节数**（线上 `encodeFrame` 之后的 UTF-8 长度，累计）。
   *
   * 为什么需要一个字节数（纯观测，不参与任何判据）：中转按人流量额度计费，
   * 而"一次标题变更到底推了多少字节"此前只能靠猜。它与 `outboundFrames`
   * 回答的是不同问题 —— 帧数看不出"`session.list` 整包（本机 302 行）占了多大一份"。
   * 有了它，才谈得上"要不要窄口只取一行"这种不可逆的协议决定
   * （`.agents/notes/implemented/2026-11-01-refetch-scope-by-trigger.md` 文末）。
   */
  bytesOutbound: 'connector.bytes.outbound',
  /** 攒批发出的批次数。 */
  batches: 'connector.batches.sent',
  /** 当前已配对的未吊销设备数。 */
  pairedDevices: 'connector.devices.paired',
  /** 当前待处理的审批 / 提问数。 */
  pendingInteractions: 'connector.interactions.pending',
  /**
   * 已发出的**宿主状态变更提示**（`host` 帧，契约 §5.9）条数。
   *
   * 为什么值得一个计数：这条通道的失败形态是**安静**的 —— 一个触发点没接上，
   * 手机就"显示旧值"，而两端都不报错。有这个数，`GET /api/dsh-mobile/status`
   * 就能回答"电脑侧到底推没推"（真机验收时用它区分"没推"与"推了但客户端没刷新"）。
   */
  hostStateNotices: 'connector.host.notices',
} as const

export type MetricName = (typeof METRIC)[keyof typeof METRIC]

/**
 * 按**帧类型**的出站字节（纯观测）—— 动态指标名。
 *
 * 为什么不放进 `METRIC`：那张表的判据是"全是字面量"（`tests/observability.test.ts` 逐条比），
 * 塞进函数就会破坏它；而这两个名字的键是**运行时才知道的**（帧类型 / 方法名）。
 *
 * 为什么在总数之外还要拆：`connector.bytes.outbound` 只能回答"一共多少"，
 * 而"一次回前台 230 KB 到底是谁"必须逐类回答 —— 快照（`res`）、会话事件重放（`ev`）、
 * 通知（`host`）三者的对策完全不同（缓存 / 恢复策略 / 不该压）。
 *
 * **口径是线上字节**（`encodeFrame` 之后），与 `connector.bytes.outbound` 同一个来源、
 * 同一次 `emit`，所以可核对的恒等式是 `Σ out_frame.* === outbound`。
 * 早先 `ev` / `live` 记在会话订阅的发送点上、口径是明文箱长度 —— 那里看不见
 * `credit` / `ping` / 握手帧，于是"一次回前台"有 30% 无主（2026-11-01 实测）。
 * 拆到唯一出帧点之后没有残余，"谁都没算"这一档不再存在。
 */
export const outFrameBytesMetric = (frameType: string): string =>
  `connector.bytes.out_frame.${frameType}`

/**
 * 按 **RPC 方法**的应答字节（纯观测）—— 只拆 `res`，所以它是 `out_frame.res`
 * 的**内部分解**，口径是**明文 `box` 的 UTF-8 长度**（方法名只有方法面知道，
 * 那里拿不到封箱后的字节）。两份口径不同是有意的：帧类型那本账要能对总量，
 * 方法那本账要回答"这一包里正文有多大"。
 */
export const outMethodBytesMetric = (method: string): string =>
  `connector.bytes.out_method.${method}`

/**
 * 出站字节的两个账本（总账 + 按帧类型），**在同一个回调里记两笔**。
 *
 * 为什么是一个函数而不是两处 `increment`：两个账本必须来自同一串字节 ——
 * 分开记的那一版把 `ev` / `live` 记在会话订阅的发送点上，于是
 * `Σ out_frame.* < outbound` 且差额（`credit` / `ping` / `握手帧`）无人认领。
 * 现在差额恒为 0，**可以由 `tests/out-frame-bytes.test.ts` 直接断言**。
 *
 * 连接层不认识指标名，只回一个 `(字节数, 帧类型)`；怎么记是这里的事。
 */
export function createOutboundByteMeter(
  metrics: ChannelMetrics,
): (bytes: number, frameType: string) => void {
  return (bytes, frameType) => {
    metrics.increment(METRIC.bytesOutbound, bytes)
    metrics.increment(outFrameBytesMetric(frameType), bytes)
  }
}
