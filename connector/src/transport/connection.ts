/**
 * 出站 WSS 拨号接线（契约 §2.2）。
 *
 * 把已经各自测过的零件接到一个 socket 上：状态机（`state.ts`）、退避（`backoff.ts`）、
 * 保活与半开（`keepalive.ts`）、攒批（`batch.ts`）、编解码与握手门禁（`codec.ts`）。
 *
 * 三处接线决定值得写下来：
 *
 * 1. **只有 `ev` / `live` 攒批**。控制帧（`credit` / `pong` / `persisted` / `ping`）必须立刻走 ——
 *    把它们也压进 50 ms 窗口，会让对端的流控与保活判据凭空多出延迟，
 *    那正是「两层序号分离」要避免的互相拖累。帧集合与 `flow.ts` 的 `pausable` 一致
 *    （都是「可补」的那两类），所以复用同一个判据。
 * 2. **`onclose` 是唯一的收口**。半开、错误、对端断开全部先关 socket，再由 `onclose`
 *    统一驱动 `serving → closed → backoff`。否则"重连计时器起了两个"这类 bug 会到处冒。
 * 3. **`stop()` 之后绝不重连**。`onclose` 在主动停止时同样会触发，靠 `stopped` 标志区分 ——
 *    漏了这一条的表现是插件卸载后还在后台反复拨号。
 *
 * 时间、随机数、定时器全部注入，所以测试能用真实的短周期跑完整条链路。
 */
import { ProtocolError } from '../protocol/errors.js'
import { createSendCounter, type SendCounter } from '../protocol/crypto.js'
import type { WireFrame } from '../protocol/frame.js'
import { createBackoff, type Backoff } from './backoff.js'
import { createBatcher, type Batcher } from './batch.js'
import { assertHandshakePhase, createLineSplitter, decodeFrame, encodeFrame } from './codec.js'
import { createKeepalive, type Keepalive } from './keepalive.js'
import { createConnectionMachine, type ConnectionState } from './state.js'

/** 参与攒批的帧类型 —— 即可补的那两类（与 `flow.ts` 的 `pausable` 同一集合）。 */
const BATCHED_FRAME_TYPES: ReadonlySet<string> = new Set(['ev', 'live'])

/** 能把联合的每个成员各自 `Omit`（内置 `Omit` 会把联合塌成一个）。 */
type DistributiveOmit<T, K extends PropertyKey> = T extends unknown ? Omit<T, K> : never

/**
 * 估算一个待发帧的线上字节数。
 *
 * 用占位 `fc` 替代真实值 —— 真实 `fc` 要到发送时才分配（见 `OutboundFrame`），
 * 在这里消耗一个计数值只为估算不值得。`fc` 的十进制位数最多差 2 字节，
 * 而它服务的 4 KiB 阈值是个**软触发**，这点误差不改变行为。
 */
function estimateBytes(frame: OutboundFrame): number {
  return Buffer.byteLength(JSON.stringify({ ...frame, fc: 0 }), 'utf8')
}

/**
 * 待发帧：**`fc` 由连接层分配**，调用方传什么都会被覆盖。
 *
 * 理由：`fc` 是每连接的帧计数器，也是 nonce 的来源（契约 §4.2）。让上层决定它，
 * 就等于让上层有机会重用 nonce；而重用 nonce 会直接破掉 AEAD。
 */
export type OutboundFrame = DistributiveOmit<WireFrame, 'fc'> & { fc?: number }

/** 拨号用的最小 socket 形状。DOM `WebSocket`（Node 22+ 自带）结构上满足它。 */
export interface DialSocket {
  send(data: string): void
  close(code?: number, reason?: string): void
  onopen: ((event: unknown) => void) | null
  onmessage: ((event: { data: unknown }) => void) | null
  onclose: ((event: unknown) => void) | null
  onerror: ((event: unknown) => void) | null
}

export interface ConnectionLogger {
  info(message: string): void
  warn(message: string, detail?: unknown): void
}

export interface ConnectionOptions {
  url: string
  /** 拨号器。生产传 `(url) => new WebSocket(url)`,测试传自己的桩。 */
  dial: (url: string) => DialSocket
  /** 收到一帧（已过解码与握手门禁）。 */
  onFrame: (frame: WireFrame, now: number) => void
  onStateChange?: (from: ConnectionState, to: ConnectionState) => void
  log?: ConnectionLogger
  now?: () => number
  random?: () => number
  /** `setTimeout` 语义，返回取消函数。 */
  schedule?: (fn: () => void, ms: number) => () => void
  heartbeatMs?: number
  batchMs?: number
}

export interface Connection {
  start(): void
  stop(): void
  /**
   * 发一帧。
   *
   * @returns `false` 表示当前不在 `serving`（或握手未完成），**这一帧没发出去** ——
   *   调用方据此排队或丢弃，而不是以为发出去了。
   */
  send(frame: OutboundFrame): boolean
  /** 上层完成 §4.1 的三条消息后调用，进入 `serving`。 */
  markHandshakeDone(): void
  readonly state: ConnectionState
}

export function createConnection(options: ConnectionOptions): Connection {
  const now = options.now ?? (() => Date.now())
  const schedule =
    options.schedule ??
    ((fn, ms) => {
      const handle = setTimeout(fn, ms)
      return () => clearTimeout(handle)
    })
  const heartbeatMs = options.heartbeatMs

  const machine = createConnectionMachine()
  const backoff: Backoff = createBackoff(options.random)
  const keepalive: Keepalive = createKeepalive(
    heartbeatMs === undefined ? {} : { heartbeatMs },
  )
  const batcher: Batcher<OutboundFrame> = createBatcher(
    options.batchMs === undefined ? {} : { flushMs: options.batchMs },
  )

  /**
   * 发送计数器。**每次建连都换一个新的** —— 契约 §4.2：每连接换密钥，`fc` 从 0 重数。
   * 跨连接复用计数器的唯一后果就是 nonce 重用，而那会直接破掉 AEAD。
   */
  let counter: SendCounter = createSendCounter()

  let socket: DialSocket | null = null
  let splitter = createLineSplitter()
  let cancelTick: (() => void) | null = null
  let cancelFlush: (() => void) | null = null
  let cancelRetry: (() => void) | null = null
  let stopped = false
  let handshakeDone = false

  const log = options.log

  const transition = (to: ConnectionState): void => {
    if (machine.state === to) return
    const from = machine.state
    machine.to(to)
    options.onStateChange?.(from, to)
  }

  // ---- 定时器 ----

  const scheduleTick = (): void => {
    // 判定周期取心跳的 1/4：够密，又不必为每次判定设一个精确到毫秒的闹钟。
    const period = Math.max(10, Math.round((heartbeatMs ?? 60_000) / 4))
    const run = (): void => {
      if (stopped) return
      const action = keepalive.tick(now())
      if (action.kind === 'ping') write({ v: 1, t: 'ping' })
      else if (action.kind === 'half-open') {
        // 半开：TCP 不会报错，只能自己判。关掉 socket，剩下的交给 onclose 统一收口。
        log?.warn('判定为半开连接，关闭并重连', { silentMs: action.silentMs })
        socket?.close(4000, 'half-open')
      }
      cancelTick = schedule(run, period)
    }
    cancelTick = schedule(run, period)
  }

  const scheduleFlush = (): void => {
    const period = Math.max(5, Math.round((options.batchMs ?? 50) / 2))
    const run = (): void => {
      if (stopped) return
      if (batcher.due(now())) drainBatch()
      cancelFlush = schedule(run, period)
    }
    cancelFlush = schedule(run, period)
  }

  const drainBatch = (): void => {
    const batch = batcher.take()
    if (batch === null || socket === null) return
    for (const frame of batch.items) write(frame)
  }

  // ---- 收发 ----

  /**
   * 直接写出一帧，**由本层分配 `fc`**。
   *
   * 不做状态判断 —— 调用方负责。`fc` 在这里统一盖上，所以调用方传什么都不影响正确性。
   */
  const write = (frame: OutboundFrame): void => {
    if (socket === null) return
    try {
      socket.send(encodeFrame({ ...frame, fc: counter.next() } as WireFrame))
    } catch (error) {
      log?.warn('发帧失败', error)
    }
  }

  const handleFrame = (frame: WireFrame): void => {
    // 任何一帧都算「有动静」：收与发都重置空闲计时（§2.2 的半开判据是"任一方向"）。
    keepalive.onFrame(now())
    assertHandshakePhase(frame, handshakeDone)
    options.onFrame(frame, now())
  }

  const handleMessage = (data: unknown): void => {
    if (typeof data !== 'string') {
      log?.warn('收到非文本帧，按协议不支持关闭')
      socket?.close(4002, 'binary-frame')
      return
    }
    let lines: string[]
    try {
      lines = splitter(data)
    } catch (error) {
      log?.warn('分帧失败', error)
      socket?.close(4002, 'bad-frame')
      return
    }
    for (const line of lines) {
      try {
        const decoded = decodeFrame(line)
        if (decoded.kind === 'ignored') continue
        if (decoded.kind === 'unsupported') {
          // 对端在等一个应答 —— 沉默会让它永远挂着（§3）。
          write({
            v: 1,
            t: 'res',
            id: decoded.id,
            ok: false,
            box: JSON.stringify({ code: 'protocol/unsupported-version' }),
          })
          continue
        }
        handleFrame(decoded.frame)
      } catch (error) {
        const code = error instanceof ProtocolError ? error.code : 'protocol/bad-frame'
        log?.warn(`收帧被拒（${code}），关闭连接`, error)
        socket?.close(4002, code)
        return
      }
    }
  }

  // ---- 连接生命周期 ----

  const connect = (): void => {
    if (stopped) return
    transition('connecting')
    // 每次建连都换分帧器**与计数器** —— 新连接新密钥，`fc` 从 0 重数（§4.2）。
    splitter = createLineSplitter()
    counter = createSendCounter()
    handshakeDone = false

    const next = options.dial(options.url)
    socket = next

    next.onopen = () => {
      if (stopped) return
      // 鉴权在 WSS 建立时已完成（ticket / 连接器令牌，§2.2），下一步就是 §4.1 的握手。
      transition('handshake')
    }

    next.onmessage = (event) => {
      if (stopped) return
      handleMessage(event.data)
    }

    next.onerror = (event) => {
      log?.warn('socket 出错', event)
    }

    next.onclose = () => {
      // **唯一的收口**：半开、错误、对端断开全部走这里。
      socket = null
      if (stopped) return
      transition('closed')
      const delay = backoff.next()
      transition('backoff')
      cancelRetry = schedule(() => {
        cancelRetry = null
        connect()
      }, delay)
    }
  }

  return {
    start() {
      if (stopped) return
      cancelTick = null
      scheduleTick()
      scheduleFlush()
      connect()
    },

    stop() {
      stopped = true
      cancelTick?.()
      cancelFlush?.()
      cancelRetry?.()
      cancelTick = cancelFlush = cancelRetry = null
      const current = socket
      socket = null
      // 关掉在途 socket；它的 onclose 会因为 `stopped` 直接返回，不再重连。
      current?.close(1000, 'stopped')
      // 只有「进行中」的三个态能去 `closed`（迁移表是白名单，`idle → closed` 非法）。
      if (machine.is('connecting', 'handshake', 'serving')) transition('closed')
      // `closed` 与 `backoff` 都能回 `idle`；`idle` 自己不用动。
      if (machine.is('closed', 'backoff')) transition('idle')
    },

    send(frame) {
      if (!machine.acceptsBusinessFrames) return false
      if (BATCHED_FRAME_TYPES.has(frame.t)) {
        batcher.push(frame, estimateBytes(frame), now())
        return true
      }
      write(frame)
      return true
    },

    markHandshakeDone() {
      handshakeDone = true
      // 握手成功要重置退避：否则下次掉线会从上次积累的大间隔开始等。
      backoff.reset()
      transition('serving')
    },

    get state() {
      return machine.state
    },
  }
}
