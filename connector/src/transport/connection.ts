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
 * 4. **握手阶段只有一条出帧路径**（`sendHandshakeFrame`）。握手帧必须能在 `serving` 之前发出去，
 *    而 `send()` 在 `serving` 之前恒为 `false` —— 所以给驱动器单独开一条**只放握手帧**的路径，
 *    而不是把 `send()` 的门禁放宽（那等于给"握手期发业务帧"开口子）。
 *    另外握手帧**不盖 `fc`**：它们的线上形状里没有这个字段（§3）。
 * 5. **封箱是出帧路径上的一个收口**（`write`）。`fc` 在这里分配、又正是 nonce 的来源，
 *    所以"分配 `fc`"与"用这个 `fc` 封箱"必须紧挨着 —— 分开写迟早出现"封的时候用了另一个 `fc`"
 *    或"同一个 `fc` 封两次"（后者直接破 AEAD）。**配了 `secure` 却拿不出密码器时宁可不发**：
 *    明文上线是唯一不可接受的选项。不配 `secure` 的连接则是**明文通道模式**（测试与 fixtures
 *    词汇层用它，那里的 `box` 本来就是可逆占位），`box` 原样透传。
 *
 * 时间、随机数、定时器全部注入，所以测试能用真实的短周期跑完整条链路。
 *
 * 握手如何接上 `markHandshakeDone` 见 `.agents/notes/implemented/2026-10-01-handshake-on-connection.md`，
 * 封箱与重放窗口的顺序见 `.agents/notes/implemented/2026-10-01-business-frame-sealing.md`
 */
import { ProtocolError } from '../protocol/errors.js'
import { createSendCounter, type SendCounter, type SessionKeys } from '../protocol/crypto.js'
import {
  aadFieldsOf,
  hasBox,
  isHandshakeFrameType,
  isPreKeysPlaintextFrame,
  needsBox,
  newFrameId,
  type FrameType,
  type WireFrame,
} from '../protocol/frame.js'
import { pausable } from '../protocol/flow.js'
import {
  createSendWindow,
  decodeCredit,
  elicitsCredit,
  encodeCredit,
  type SendWindow,
} from '../protocol/flow.js'
import type { BoxCodec } from '../protocol/box.js'
import type {
  HandshakeDriver,
  HandshakeEstablishment,
  HandshakeSession,
} from '../protocol/handshake-driver.js'
import { createBackoff, type Backoff } from './backoff.js'
import { createBatcher, type Batcher } from './batch.js'
import {
  assertHandshakePhase,
  createLineSplitter,
  decodeFrame,
  encodeFrame,
  isHandshakeFrame,
} from './codec.js'
import { createKeepalive, type Keepalive } from './keepalive.js'
import { createConnectionMachine, type ConnectionState } from './state.js'

/** 参与攒批的帧类型 —— **就是"可暂停"的那几类**，判据只有 `flow.ts` 的 `pausable` 一处。 */
const isBatched = (type: FrameType): boolean => pausable(type)
/** 能把联合的每个成员各自 `Omit`（内置 `Omit` 会把联合塌成一个）。 */
type DistributiveOmit<T, K extends PropertyKey> = T extends unknown ? Omit<T, K> : never

/** 认证标签字节数（与 `protocol/box.ts` 的 `TAG_BYTES` 同一个值）。 */
const TAG_BYTES = 16

/**
 * 封箱之后 `box` 会有多大（字节，含 JSON 引号）。
 *
 * 箱是 `base64url(密文 ‖ tag)`，所以体积是 `4*ceil((n+16)/3)`。攒批的 4 KiB 阈值虽然
 * 是个**软触发**，但 base64 会把载荷放大 1/3 —— 拿明文长度去估会让"攒够 4 KiB"实际
 * 发出去 5.4 KiB。这一点误差比 `fc` 的位数差更能改变行为，所以这里算上。
 */
function sealedBoxBytes(plaintextBytes: number): number {
  const raw = plaintextBytes + TAG_BYTES
  return Math.ceil(raw / 3) * 4 + 2
}

/**
 * 估算一个待发帧的线上字节数。
 *
 * 用占位 `fc` 替代真实值 —— 真实 `fc` 要到发送时才分配（见 `OutboundFrame`），
 * 在这里消耗一个计数值只为估算不值得。`fc` 的十进制位数最多差 2 字节，
 * 而它服务的 4 KiB 阈值是个**软触发**，这点误差不改变行为。
 */
function estimateBytes(frame: OutboundFrame): number {
  if (!needsBox(frame.t)) return Buffer.byteLength(JSON.stringify({ ...frame, fc: 0 }), 'utf8')
  const plaintext = 'box' in frame ? Buffer.byteLength(frame.box, 'utf8') : 0
  // 头按 `box: ''` 估，再加上封箱后的字节数 —— 箱的体积只跟明文长度有关。
  const header = Buffer.byteLength(JSON.stringify({ ...frame, fc: 0, box: '' }), 'utf8')
  return header + sealedBoxBytes(plaintext)
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
  /** 收到一帧（已过解码、握手门禁与**解箱**；`box` 里是明文载荷）。 */
  onFrame: (frame: WireFrame, now: number) => void
  /**
   * 安全会话：握手 + 封箱（契约 §4.1 / §4.2）。**两者绑在一个对象里**，
   * 因为"握手谈出密钥"与"用密钥封箱"是同一条链路的上下半段 —— 允许只配一半，
   * 等于允许一个"握手过了但帧是明文"的连接。
   *
   * 不配时连接停在 `handshake`（由上层手动 `markHandshakeDone()`），`box` **原样透传** ——
   * 那是**明文通道模式**：测试与 `protocol/fixtures` 的词汇层用它（那里的 `box` 是可逆占位，
   * 不是密文，见 `protocol/frame.ts` 的说明）。产品装配必须配 `secure`。
   */
  secure?: {
    /** **每次建连调一次工厂**，拿到该连接的握手会话。 */
    handshake: HandshakeDriver
    /** 握手成功后用它建该连接的箱密码器。每次建连都会重新调用。 */
    createCipher(keys: SessionKeys): BoxCodec
  }
  /** 握手成功：会话密钥交给上层（方法面要用它对 `box` 做 AEAD）。 */
  onEstablished?: (result: HandshakeEstablishment) => void
  onStateChange?: (from: ConnectionState, to: ConnectionState) => void
  log?: ConnectionLogger
  now?: () => number
  random?: () => number
  /** `setTimeout` 语义，返回取消函数。 */
  schedule?: (fn: () => void, ms: number) => () => void
  heartbeatMs?: number
  batchMs?: number
}

/**
 * 与"每连接状态"之间的**窄端口**：只有这 4 个成员。
 *
 * 它把一条**实测结论**固化成类型：`index.ts` 的 `start-transport` 里所有每连接的构造物
 * （处理器表 / 订阅 / 增量缓冲 / 分页器 / 配对端点）合计只通过这 4 个成员碰连接
 * （实测 9 处调用，见 `.agents/notes/implemented/2026-10-01-per-connection-scope-is-an-extraction.md`）。
 * 因此"按连接装配"是一次**搬家**而不是重构：那段构造现在就在
 * `connection-scope.ts` 的 `createConnectionScope(port, deps)` 里，`port` 即本类型。
 *
 * 这个类型的两个用处：
 * - 成员名写错或将来从 `Connection` 里删掉任何一个，`tsc` 会**在这里**报错；
 * - 加第 5 个成员时，`tests/connection-surface.test.ts`（读源码的运行时门禁）会先红。
 */
export type ConnectionPort = Pick<
  Connection,
  'send' | 'whenWritable' | 'state'
>

export interface Connection {
  start(): void
  stop(): void
  /**
   * 发一帧**业务帧**。
   *
   * @returns `false` 表示当前不在 `serving`，**这一帧没发出去** ——
   *   调用方据此排队或丢弃，而不是以为发出去了。
   *
   * 握手帧不走这里（它们在 `serving` 之前发，由握手驱动器经内部路径写），
   * 所以这个入口在握手阶段恒返回 `false`，正是它该有的语义。
   */
  send(frame: OutboundFrame): boolean
  /**
   * 等一次"窗口又有空位"（§4.3 的暂停-恢复）。
   *
   * 为什么需要它：`send` 满窗时**不接受**那一帧（如实回 `false`），于是发送方必须把它**压住**
   * —— 而"什么时候可以再发"只有本层知道（`credit` 到达、且 `window` 释放）。没有这个信号，
   * 由调用方驱动的可补流（任务输出是第一个）就只能靠轮询或者干脆丢帧，两条都不对：
   * 轮询白烧定时器，丢帧则违背"暂停不是丢弃"。
   *
   * **一定会被兑现**：窗口释放时兑现；连接离开服务态时也兑现
   * （否则等在这里的发送方会永远挂着）—— 兑现后重试 `send` 会得到 `false`，
   * 调用方据此收工。
   *
   * 为什么要它（任务输出是第一个由调用方驱动的可补流）：
   * `.agents/notes/implemented/2026-10-01-job-output-transport-shape.md`
   */
  whenWritable(type: FrameType): Promise<void>
  /**
   * 接管一个已经打开的 socket（监听面 accept 之后交给它）。
   *
   * 与拨号路径的两处不同都是必需的：**已经 OPEN**（onopen 不再触发，要直接走一次打开处理）
   * 与**不自愈**（接受来的连接没有拨号目标）。详见 ttach 的注释。
   */
  attach(socket: DialSocket): void
  /**
   * 手动宣告握手完成。**只在不配 `secure` 的装配里可用**（测试与手工调试）——
   * 配了 `secure` 时握手结论只能来自驱动器：手动调用等于绕过两道校验。
   */
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

  /** 等在"窗口有空位"上的发送方（`whenWritable`）。连接离开服务态时一并兑现。 */
  const writableWaiters: Array<() => void> = []

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
  /** 本次连接的握手会话（每次建连换一个）。 */
  let session: HandshakeSession | null = null
  /** 本次连接的箱密码器。**每连接换一把密钥**，所以建连时必须清空（§4.2）。 */
  let cipher: BoxCodec | null = null
  /** 本次连接的发送窗口（契约 §4.3）。**每连接归零**：`fc` 重数，额度也随之重来。 */
  let window: SendWindow = createSendWindow()

  const log = options.log

  const transition = (to: ConnectionState): void => {
    if (machine.state === to) return
    const from = machine.state
    machine.to(to)
    // 离开服务态时**兑现**所有等在"窗口有空位"上的发送方：否则它们会永远挂着。
    // 兑现后它们重试 `send`，会拿到 `false`（不在服务态）并据此收工。
    if (from === 'serving' && to !== 'serving') notifyWritable()
    options.onStateChange?.(from, to)
  }

  /** 窗口又空出来了：唤醒等在 `whenWritable` 上的发送方（§4.3 的暂停-恢复）。 */
  const notifyWritable = (): void => {
    const waiters = writableWaiters.splice(0)
    for (const resolve of waiters) resolve()
  }

  // ---- 定时器 ----

  /**
   * 起两个周期任务：攒批 flush 与保活判定。
   *
   * **拨号与接受两条路都要起**（`start()` 与 `attach()` 都调它）—— 只在 `start()` 里起的版本
   * 让接受来的连接永远发不出可攒批的帧（`ev` / `live` / `job` 会一直留在 batcher 里，
   * 而 `send()` 照样回 `true`），也永远判不出半开。症状是"连上了、握手也过了，
   * 但事件一条都收不到"，两边看起来都正常。
   *
   * 幂等：`attach()` 可以在一条连接上被调多次（每次换一条 socket），重复起定时器会漏掉旧的。
   *
   * 为什么"只在 `start()` 里起"是个**静默 bug**（以及怎么被抓到的），见
   * `.agents/notes/implemented/2026-10-02-listener-face.md`。
   */
  const startTimers = (): void => {
    cancelTick?.()
    cancelFlush?.()
    cancelTick = null
    cancelFlush = null
    scheduleTick()
    scheduleFlush()
  }

  const scheduleTick = (): void => {
    // 判定周期取心跳的 1/4：够密，又不必为每次判定设一个精确到毫秒的闹钟。
    const period = Math.max(10, Math.round((heartbeatMs ?? 60_000) / 4))
    const run = (): void => {
      if (stopped) return
      const at = now()
      // **半开判据只在 `serving` 期间成立**（契约 §2.2 的原话："`serving` 期间
      // 任一方向连续 2 个心跳周期无任何帧 → 视为断开"）。
      //
      // 少了这道门，会踩一个症状极具误导性的坑：**应答方（电脑侧）在 `serving`
      // 之前本来就收不到任何帧** —— 它等对端发 `hello`。于是"连上中转 → 进 `handshake`
      // → 一个帧都没有 → 两个周期后判自己半开 → 关掉一条完全健康的连接"
      // （关闭码 4000 `half-open`）。中转侧看到的是"连接器反复断开"（每 30 秒一轮，
      // 那是退避上界），而**每次断开都会清掉未认领的配对登记** —— 于是扫码换票
      // 永远 409，两端日志各自看起来都正常。真机联调实测：每 30 秒一次，持续数小时。
      //
      // 空闲计时照旧推进（`onFrame` 在收发时都会重置它），所以进 `serving` 那一刻
      // 的计时是正确的：那一刻之前没有帧，但那时也**不该**判半开。
      //
      // Note: 为什么这道门是必需的 —— 见
      // `.agents/notes/implemented/2026-10-07-connector-self-disconnect-two-causes.md`
      if (machine.state !== 'serving') {
        cancelTick = schedule(run, period)
        return
      }
      const action = keepalive.tick(at)
      // `id` 是必需的（§2.2）：`pong` 没有 `sid`，中继只能靠它把应答送回这一侧。
      // 生成器与握手帧同源（`protocol/frame.ts` 的 `newFrameId`）—— 两处各造一套
      // 就会出现"某些帧的 id 中继认不出"这种只在真机上才发作的偏差。
      if (action.kind === 'ping') write({ v: 1, t: 'ping', id: newFrameId(), box: '' })
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

  /**
   * 把攒的批发出去。
   *
   * 满窗时**不丢**：发不出去的可补帧重新入队，等 `credit` 到达再放（契约 §4.3 说的是"暂停"
   * 而不是"丢弃"）。队列因此有界 —— `send()` 满窗时根本不再接收新的可补帧，
   * 能积压的只有"入队时窗口还开着、真正要发时窗口已满"的那一批。
   */
  const drainBatch = (): void => {
    const batch = batcher.take()
    if (batch === null || socket === null) return
    for (const frame of batch.items) {
      if (!write(frame)) batcher.push(frame, estimateBytes(frame), now())
    }
  }

  // ---- 收发 ----

  /**
   * 直接写出一帧，**由本层分配 `fc`，并在同一个地方封箱**。
   *
   * 不做状态判断 —— 调用方负责。两个"只在这里做"的理由：
   *
   * - **`fc` 在这里统一盖上**，所以调用方传什么都不影响正确性；握手帧不盖（§3）。
   * - **封箱紧挨着 `fc` 分配**：`fc` 正是 nonce 的来源，"分配"与"封箱"分开写迟早
   *   出现封的时候用了另一个 `fc`，或者同一个 `fc` 封两次 —— 后者直接破 AEAD。
   *   调用方（上层）看到的 `box` 永远是**明文载荷**，密封是这一层的事。
   *
   * **没有密码器就绝不发**需要封箱的帧：丢掉并留声，而不是明文发出去（§3 只有
   * 握手三帧与 `presence` 是明文）。这条只在配了 `secure` 时生效 —— 不配 `secure` 的
   * 连接**本来就是明文通道**（测试与 fixtures 的词汇层用它），那种模式下 `box` 原样透传。
   * 两种模式的区分是"配不配 `secure`"，不是某个分支里的隐式判断。
   *
   * 写出去也算「有动静」（§2.2 的半开判据是**任一方向**），所以这里重置空闲计时 ——
   * **除了 `ping`**：它是探针本身，`keepalive.tick()` 已经为它重置过，再重置一次会把
   * 「一个空闲期只探一次」这条抹掉，于是每个周期都发 ping、空闲计时永远攒不满两个周期，
   * **半开就永远判不出来**。
   *
   * @returns `false` 表示**这一帧没发出去**（满窗的可补帧，或没有密码器）。
   */
  const write = (frame: OutboundFrame): boolean => {
    if (socket === null) return false
    // 窗口检查在**分配 `fc` 之前**：没发出去的帧不该消耗序号，否则窗口算术会把没上线的帧也算进去。
    if (!window.canSend(frame.t)) return false
    try {
      const handshakeFrame = isPreKeysPlaintextFrame(frame.t)
      const wire = handshakeFrame
        ? (frame as WireFrame)
        : ({ ...frame, fc: counter.next() } as WireFrame)

      if (!handshakeFrame) {
        // 只有真的发出去才记账：窗口算的是"已发未确认"，不是"打算发"。
        if ('fc' in wire && wire.fc !== undefined) window.onSent(wire.fc, wire.t)
      }

      if (!handshakeFrame && needsBox(wire.t)) {
        if (!hasBox(wire)) {
          // `needsBox` 说该封箱，联合里却没有这个字段 —— 契约与类型漂移了。
          // 静默发出去就是明文上线，所以这里吵。
          throw new ProtocolError('internal', `${wire.t} 需要封箱，但帧里没有 box 字段`)
        }
        if (cipher === null) {
          if (options.secure !== undefined) {
            // 配了 `secure` 却拿不出密码器：只可能是"握手已过但密码器没装上"这类装配错误。
            // 宁可不发，也不明文上线。
            log?.warn(`还没有会话密钥，${wire.t} 帧不发（配了 secure 的连接不允许明文帧）`)
            return false
          }
          // 明文通道模式（未配 `secure`）：`box` 原样透传。
          socket.send(encodeFrame(wire))
          if (frame.t !== 'ping') keepalive.onFrame(now())
          return true
        }
        socket.send(encodeFrame({ ...wire, box: cipher.sealFrame(wire, wire.box) }))
        if (frame.t !== 'ping') keepalive.onFrame(now())
        return true
      }

      socket.send(encodeFrame(wire))
      if (frame.t !== 'ping') keepalive.onFrame(now())
      return true
    } catch (error) {
      log?.warn('发帧失败', error)
      return false
    }
  }

  /**
   * 握手阶段唯一的出帧路径。只放握手帧过去 ——
   * 驱动器拿到的 `send` 是它，而不是 `send()`：后者在 `serving` 之前恒为 `false`，
   * 而把 `serving` 的门禁放宽给握手帧，等于给"握手期发业务帧"开了口子。
   */
  const sendHandshakeFrame = (frame: WireFrame): void => {
    if (!isHandshakeFrame(frame)) {
      log?.warn(`握手中试图发送非握手帧 ${frame.t}，已拒绝`)
      return
    }
    write(frame)
  }

  /**
   * 收帧后的流控记账（契约 §4.3）。**必须在解箱之后**：`ack` 与 `fc` 都要先被认证，
   * 否则一帧伪造的 credit 就能替对端松开窗口。
   *
   * 两个 `if` 刻意**不写成 if/else、也不提前 return**：`credit` 走记账、其余帧走回执，
   * 而"`credit` 不回 `credit`"这条规则**只由 `elicitsCredit` 表达一次**。
   * （变异校验里踩过：写成"早返回 + 谓词"两处各表一遍时，谓词成了死逻辑 ——
   * 把它改成恒真都没有任何测试会红。）
   */
  const accountFlow = (frame: WireFrame): void => {
    if (!('fc' in frame) || frame.fc === undefined) return

    if (frame.t === 'credit') {
      const ack = decodeCredit(hasBox(frame) ? frame.box : '')
      const before = window.unacked
      window.onCredit(ack)
      if (window.unacked < before) {
        // 窗口刚松开：被压住的可补帧立刻放出去，不等下一个攒批窗口。
        drainBatch()
        // 并唤醒等在 `whenWritable` 上的发送方 —— 由调用方驱动的可补流（任务输出）
        // 靠这个信号继续，而不是靠轮询。
        notifyWritable()
      }
    }

    // 收到的每一帧都立刻回 credit。`credit` 自己除外 —— 否则两端互刷 ack 停不下来。
    if (elicitsCredit(frame.t)) {
      const sent = write({ v: 1, t: 'credit', box: encodeCredit(frame.fc) })
      if (!sent) log?.warn(`回 credit(${frame.fc}) 没发出去`)
    }
  }

  const handleFrame = (frame: WireFrame): void => {
    // 任何一帧都算「有动静」：收与发都重置空闲计时（§2.2 的半开判据是"任一方向"）。
    keepalive.onFrame(now())
    // 门禁先于解箱：握手期根本没有密钥，业务帧要在**碰密码学之前**就被拦掉。
    assertHandshakePhase(frame, handshakeDone)

    if (!handshakeDone) {
      // 没有驱动器时不拦：那种装配（测试）自己掌握握手进度，`onFrame` 是它唯一的入口。
      if (session !== null && isHandshakeFrame(frame)) session.onFrame(frame)
      else options.onFrame(frame, now())
      return
    }
    if (isHandshakeFrame(frame)) {
      // 握手已完成还来握手帧：重复投递或重放。**忽略并留声**，不回错误帧 ——
      // 回了就等于告诉对端"我这条连接还处在握手期"。
      log?.warn(`握手已完成，忽略握手帧 ${frame.t}`)
      return
    }
    if (cipher !== null && needsBox(frame.t)) {
      if (!hasBox(frame)) {
        // 对端发来一个"该封箱却没有 box"的帧。绝不能放它过去：跳过解箱就等于
        // 跳过认证与重放守卫，伪造的 `credit` 会直接改状态。
        throw new ProtocolError('protocol/bad-frame', `${frame.t} 帧缺少 box`)
      }
      // 解箱失败会抛（认证失败 → bad-frame；fc 不单调 → replay），由调用方关连接。
      // 上层的 `box` 一律是**明文载荷**：加密只存在于这一层。
      const opened = { ...frame, box: cipher.openFrame(frame, frame.box) }
      accountFlow(opened)
      options.onFrame(opened, now())
      return
    }
    accountFlow(frame)
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
        // **把原始行也带出来**：`bad-frame` 有十来个来源（超限 / 不是 JSON / 缺 t /
        // 字符集不对 / 握手门禁 / 解箱失败…），只说"被拒"等于没说 ——
        // 排查时只能靠猜（实测踩过：真机上连接器每 30 秒因 `bad-frame` 断开，
        // 而日志里只有这一句，看不出是哪一种）。
        // 截断到 500 字符：它是**别人的输入**，不该让日志被它撑爆。
        const detail = {
          raw: line.length > 500 ? `${line.slice(0, 500)}…` : line,
          // **`message` 必须显式取**：`JSON.stringify(new Error('x'))` 是 `{}`
          // （Error 的自有属性不可枚举），只打 error 等于什么都没打（实测踩过：
          // 真机上连接器每 30 秒因 `bad-frame` 断开，而日志里的 error 是空的，
          // 白白多花了一轮排查）。
          message: error instanceof Error ? error.message : String(error),
          // 握手到哪一步了 —— `bad-frame` 的两大来源（握手门禁 vs 解箱）靠它区分。
          handshakeDone,
        }
        log?.warn(`收帧被拒（${code}），关闭连接`, detail)
        socket?.close(4002, code)
        return
      }
    }
  }

  // ---- 连接生命周期 ----

  /**
   * 进 `serving`。**两个调用者语义不同**：
   * 驱动器在两道校验都过了之后调（`established`），或没有配 `secure` 时上层手动调。
   * 两处都经这里，是为了让"进 serving 要重置退避"这条只写一遍。
   */
  const enterServing = (): void => {
    handshakeDone = true
    // 握手成功要重置退避：否则下次掉线会从上次积累的大间隔开始等。
    backoff.reset()
    transition('serving')
  }

  const connect = (): void => {
    if (stopped) return
    transition('connecting')
    // 每次建连都换分帧器**、计数器与密码器** —— 新连接新密钥，`fc` 从 0 重数（§4.2）。
    splitter = createLineSplitter()
    counter = createSendCounter()
    cipher = null
    // 新连接新账本：`fc` 从 0 重数，额度也随之归零（§4.3）。
    window = createSendWindow()
    handshakeDone = false
    session = null

    // 拨号连接**自愈**：对端走了就退避重连（`url` 是它的目标）。
    wireSocket(options.dial(options.url), { alreadyOpen: false, heals: true })
  }

  /**
   * 接管一个**已经打开的** socket（对端连进来的，比如监听面 accept 之后）。
   *
   * 与拨号路径的两处不同都是**必需的**，不是风格差异：
   *
   * - **已经 OPEN**：`onopen` 不会再触发，所以"打开之后做什么"要直接走一次
   *   （否则连接永远停在 `connecting`，症状是"连上了但什么都不发生"）。
   * - **不自愈**：接受来的连接没有拨号目标。让它按拨号那套在断开时去 `dial(options.url)`，
   *   症状是"监听模式下桥接莫名其妙连去中转" —— 而重新接受一条连接是**监听面的职责**。
   */
  const attach = (socket: DialSocket): void => {
    if (stopped) return
    transition('connecting')
    splitter = createLineSplitter()
    counter = createSendCounter()
    cipher = null
    window = createSendWindow()
    handshakeDone = false
    session = null
    // **定时器要跟着起**：接受路径不走 `start()`，少了这一步就永远发不出可攒批的帧、
    // 也判不出半开（见 `startTimers` 的说明）。
    startTimers()
    wireSocket(socket, { alreadyOpen: true, heals: false })
  }

  /** 接线：**拨号与接受共用这一处**（差别只由两个开关表达，见 `attach` 的说明）。 */
  const wireSocket = (
    next: DialSocket,
    mode: { alreadyOpen: boolean; heals: boolean },
  ): void => {
    socket = next

    /** 由 `onopen` 或"已打开的 socket"直接调用（两种触发时机，同一段处理）。 */
    const onOpen = (): void => {
      if (stopped) return
      // 鉴权在 WSS 建立时已完成（ticket / 连接器令牌，§2.2），下一步就是 §4.1 的握手。
      transition('handshake')
      const secure = options.secure
      session =
        secure?.handshake({
          send: sendHandshakeFrame,
          established: (result) => {
            // 到这里说明 `verifySignature` 与 `verifyConfirm` 都过了。
            // **先把密码器装上再进 serving**：顺序反了就会有一小段"已经在服务但发不出帧"的窗口，
            // 而那一小段里的每一帧都会被 `write` 丢掉（宁丢不发明文）。
            cipher = secure.createCipher(result.keys)
            enterServing()
            options.onEstablished?.(result)
          },
          failed: (reason, error) => {
            // 握手失败：关掉这条连接，剩下的交给 `onclose` 统一收口（退避重连）。
            // **不发任何协议帧** —— 对端要么已经死了，要么在等我们，两种情况都只有关闭有意义。
            log?.warn(`握手失败（${reason}），关闭连接`, error)
            socket?.close(4003, reason)
          },
          schedule,
        }) ?? null
    }

    next.onopen = onOpen
    // 接受来的 socket 已经 OPEN：`onopen` 不会再触发，所以这里直接走一次。
    // （少了这一步的症状是"连上了但什么都不发生"——连接永远停在 `connecting`。）
    if (mode.alreadyOpen) onOpen()

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
      session?.dispose()
      session = null
      // 密钥属于这条连接：断开即作废，避免下一条连接误用上一把（§4.2）。
      cipher = null
      if (stopped) return
      transition('closed')
      // **只有拨号连接自愈**：接受来的连接没有拨号目标，重新接受一条是监听面的职责。
      // 让它按拨号那套去 `dial(url)` 的症状是"监听模式下桥接莫名其妙连去中转"。
      if (!mode.heals) return
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
      startTimers()
      connect()
    },

    stop() {
      stopped = true
      cancelTick?.()
      cancelFlush?.()
      cancelRetry?.()
      cancelTick = cancelFlush = cancelRetry = null
      // 握手在途也要收干净：否则超时定时器会活过 `stop()`，然后对着一条已停止的连接报失败。
      session?.dispose()
      session = null
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
      // 满窗时对可补帧如实回 `false`：这一帧**没有被接受**，调用方据此暂停（§4.3）。
      // 其余帧不受窗口限制（压住 `res` 会死锁），所以这一条只可能拦下 `ev` / `live` / `job`。
      if (!window.canSend(frame.t)) return false
      if (isBatched(frame.t)) {
        batcher.push(frame, estimateBytes(frame), now())
        return true
      }
      return write(frame)
    },

    attach,

    whenWritable(type) {
      if (machine.acceptsBusinessFrames && window.canSend(type)) return Promise.resolve()
      return new Promise<void>((resolve) => {
        writableWaiters.push(resolve)
      })
    },

    markHandshakeDone() {
      if (options.secure !== undefined) {
        // 配了 `secure` 时握手结论只能来自驱动器（两道校验都过）。手动调用等于绕过它们，
        // 而绕过之后 `cipher` 仍然是 null —— 那样连一帧都发不出去，所以这里直接吵。
        throw new Error(
          '配了 secure 的连接不接受手动 markHandshakeDone：serving 只能由握手驱动器推进',
        )
      }
      enterServing()
    },

    get state() {
      return machine.state
    },
  }
}
