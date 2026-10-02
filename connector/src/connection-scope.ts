/**
 * 每连接装配（契约 §5.5、§12.1）：把"一条连接上的活物"从 `index.ts` 的 `start-transport` 里搬出来。
 *
 * ## 为什么它能被搬出来（先量再下）
 *
 * 这些构造物（方法面 / 会话订阅 / 翻页器 / 配对端点）**只通过 4 个成员碰连接** ——
 * `send` / `sendPairingFrame` / `whenWritable` / `state`，也就是 `ConnectionPort`。
 * 实测 9 处调用、去重后 4 个成员，见
 * `.agents/notes/implemented/2026-10-01-per-connection-scope-is-an-extraction.md`。
 * 所以这是一次**搬家**而不是重构：`createConnectionScope(port, deps)` 的 `port`
 * 就是"每条 socket 各一份"的入口 —— 监听面 accept 一条 socket 就调一次，多设备自然成立。
 *
 * ## 什么留在这里，什么留在挂载级（这条缝是量出来的，不是猜的）
 *
 * | 构造物 | 归属 | 判据 |
 * |---|---|---|
 * | 方法面 / 处理器表 | **每连接** | 它的 deps 里就有下面两个订阅注册表 |
 * | 会话订阅 / 任务输出订阅 | **每连接** | 它是"这台设备要看哪几个会话"：断连即全部终止（宿主流不为断了的连接白跑） |
 * | 翻页器 | **每连接** | 水位来自**本条连接**订阅面的开启帧缓存（§5.3：`throughSeq` 必须出自开启帧） |
 * | 配对端点 | **每连接** | 回执要往这条连接里发 |
 * | **增量缓冲** | **挂载级** | 见下 |
 * | 幂等表 / 配对核心 / 出码命令 / 会话与任务适配器 | **挂载级** | 与哪条连接无关；命令更不能按连接重复注册 |
 *
 * ### 增量缓冲为什么**不**跟着连接走
 *
 * 它存在的理由就是"手机断线重连后按 `since` 接着收"（§5.5）。挂在连接上的话：
 *
 * - 新连接一建，缓冲是**空的** —— 重订时 `tailFrom` 覆盖不到水位，
 *   恢复语义**静默退化成每次灌一份完整快照**（症状是"每次重连都从头刷一遍"，不报错、不告警）；
 * - 翻页器同理：水位表也是空的了，`session.page` 会拿不到 `throughSeq`，
 *   于是回 `session/window-missed`；而水位**恰好**能从缓冲里恢复
 *   （`tailFrom` 找得到 `since + 1` 时，基线就是 `since`）——缓冲留在挂载级时这条路是通的；
 * - 它的裁剪点本来就是**跨设备**的量（"全部配对设备水位的最小值"，§5.5），
 *   而设备是横跨连接的。
 *
 * 代价说清楚：连接层的 `onStateChange` 现在只终止订阅流，**不**清缓冲 ——
 * 未确认的区间会一直留着，直到该设备重新连上并 `persisted`（或超限转为"只走快照"）。
 * 缓冲自己带着 10000 条 / 16 MiB 的上界，所以它不会无界增长。
 *
 * 取舍与被否方案：`.agents/notes/implemented/2026-10-01-per-connection-scope-is-an-extraction.md`
 */
import type { JobControlPort } from './dsh/jobs.js'
import type { SessionsPort } from './dsh/sessions.js'
import { createHandlers, type HandlerDeps } from './handlers.js'
import { createPairingEndpoint, type PairedDeviceRow } from './pairing-endpoint.js'
import { createJobSubscriptions } from './job-subscriptions.js'
import { createMethodFace } from './method-face.js'
import { createSessionPager } from './session-page.js'
import { createSessionSubscriptions } from './session-subscriptions.js'
import { METRIC, type ChannelLogger, type ChannelMetrics } from './observability.js'
import type { Idempotency } from './idempotency.js'
import type { Pairing } from './pairing.js'
import type { SessionBuffer } from './session-buffer.js'
import type { WireFrame } from './protocol/frame.js'
import type { ConnectionPort } from './transport/connection.js'

/**
 * 每连接的装配需要的一切。**除 `port` 外全部是挂载级的**：全是无状态适配器，
 * 或本来就该跨连接共享的东西（缓冲、幂等、配对核心、设备行写入）。
 *
 * 这里刻意 **不** 收 `ctx`：一个连宿主长什么样的都不知道的模块，才可能被两侧
 * （产品装配与将来监听面的多设备）复用而不各自分叉。
 */
export interface ConnectionScopeDeps {
  logger: ChannelLogger
  metrics: ChannelMetrics
  /**
   * 方法面的挂载级依赖（能力位、别名、设备清单、宿主服务端口）。
   *
   * 类型上用 `Omit` **摘掉**每连接的那三个：它们由本层填进去，从外面传进来只会制造
   * "两个连接共用一个订阅表"这种不会报错、只会串台的状态。
   */
  handlers: Omit<HandlerDeps, 'jobSubscriptions' | 'sessionSubscriptions' | 'sessionPager'>
  /** 会话面。订阅流与翻页共用同一个适配器（它是纯闭包，无状态）。 */
  sessions: SessionsPort
  /** 增量缓冲（§5.5）。**挂载级** —— 理由见文件头。 */
  buffer: SessionBuffer
  /** 任务控制（可选服务 `jobController`）：缺了就不挂任何 `job.*` 订阅。 */
  jobControl: JobControlPort | null
  /** 配对核心（§12.1）：由本机身份派生，与哪条连接无关。 */
  pairing: Pairing
  /** 落设备行（`devices` 表）—— 新增设备的**唯一**路径。 */
  putDevice: (devId: string, row: PairedDeviceRow) => Promise<void>
  /** 幂等执行（§5.6）。挂载级：它的行在库里，连接换了不影响。 */
  idempotency: Idempotency | null
}

/** 一条连接上的活物。除了这三个入口，外面不需要知道里面有什么。 */
export interface ConnectionScope {
  /**
   * 握手完成：记下这条连接**认证出来**的设备。
   *
   * 缓冲的水位按设备记（§5.5），而入站 `persisted` 必须知道它来自哪台设备 ——
   * 身份只能来自握手，不能来自帧内容（帧里的字段是手机自己报的，可以撒谎）。
   */
  deviceEstablished(devId: string): void
  /**
   * 连接不再服务：终止全部订阅流，并忘掉设备身份（不留下一个可能张冠李戴的水位）。
   *
   * **不动增量缓冲** —— 见文件头"增量缓冲为什么不跟着连接走"。
   */
  servingEnded(): void
  /**
   * 处理一帧入站业务帧。
   *
   * 本方法**不阻塞**：要等 DSH 服务的部分（方法面、配对）自己异步收尾，
   * 因为同一条 socket 上还有 `credit` 与保活要走。
   */
  handleFrame(frame: WireFrame): void
}

export function createConnectionScope(
  port: ConnectionPort,
  deps: ConnectionScopeDeps,
): ConnectionScope {
  const { logger, metrics } = deps

  /** 这条连接认证出的设备。`null` = 握手还没完成（那时 `persisted` 无处可记）。 */
  let deviceId: string | null = null

  // 任务控制是**另一个**可选服务（`dsh-web-app` 提供，base 没有）：缺了就只列不停。
  // 输出订阅要"往这条连接里出帧"，出帧三态在这里归一：
  // 不在服务态 → `'closed'`（别发了）；满窗 → `'paused'`（等窗口，暂停不是丢弃）。
  const jobSubscriptions =
    deps.jobControl === null
      ? null
      : createJobSubscriptions({
          source: deps.jobControl,
          send: (sid, output) => {
            if (port.state !== 'serving') return 'closed'
            return port.send({ v: 1, t: 'job', sid, box: JSON.stringify(output) })
              ? 'sent'
              : 'paused'
          },
          waitWritable: () => port.whenWritable('job'),
          log: logger,
        })

  // 会话订阅：与任务输出**同一套骨架**（背压、承诺兑现、跟连接活），
  // 两处只在"键怎么取、开启帧怎么展开、有没有终止帧"上不同。
  const sessionSubscriptions = createSessionSubscriptions({
    source: deps.sessions,
    buffer: deps.buffer,
    send: (out) => {
      if (port.state !== 'serving') return 'closed'
      const body = out.body
      const frame =
        out.t === 'ev'
          ? { v: 1 as const, t: 'ev' as const, sid: out.sid, seq: out.seq, box: body }
          : {
              v: 1 as const,
              t: 'live' as const,
              sid: out.sid,
              stream: out.stream,
              rev: out.rev,
              box: body,
            }
      return port.send(frame) ? 'sent' : 'paused'
    },
    waitWritable: () => port.whenWritable('ev'),
    log: logger,
  })

  // 翻页的水位来自**本条连接**订阅面的开启帧缓存（§5.3：`throughSeq` 必须出自开启帧）；
  // 覆盖不到时水位由缓冲补回来（见文件头）。
  const sessionPager = createSessionPager({
    sessions: deps.sessions,
    cursorOf: (sid) => sessionSubscriptions.cursorOf(sid),
    log: logger,
  })

  // 配对端点（§12.1 第 3 步）：校验 → 落设备行 → 明文回执，产品与 fixture 共用这一处。
  // 它**不是**方法面方法（没有 `sid`、不经 `req`），所以不走 `methodFace`。
  const pairingEndpoint = createPairingEndpoint({
    pairing: deps.pairing,
    putDevice: deps.putDevice,
    reply: ({ id, payload }) => {
      port.sendPairingFrame({ v: 1, t: 'pair-ack', id, box: JSON.stringify(payload) })
    },
    log: logger,
  })

  const methodFace = createMethodFace({
    handlers: createHandlers({
      ...deps.handlers,
      sessionSubscriptions,
      sessionPager,
      ...(jobSubscriptions === null ? {} : { jobSubscriptions }),
    }),
    ...(deps.idempotency === null ? {} : { idempotency: deps.idempotency }),
    onError: (message, detail) => logger.warn(message, detail),
  })
  logger.debug(`方法面已就绪：${methodFace.implemented.length} 个方法`, {
    methods: [...methodFace.implemented],
  })

  return {
    deviceEstablished(devId) {
      deviceId = devId
    },

    servingEnded() {
      // 连接一离开服务态，任务输出与会话订阅全部终止：手机这一侧收不到任何东西，
      // 让它重连后自己按 `from` / `since` 重订（宿主流不会为断了的连接白跑）。
      jobSubscriptions?.stopAll()
      sessionSubscriptions.stopAll()
      // 连接没了，"这台设备"的身份也就不再成立：不留下一个可能张冠李戴的水位。
      deviceId = null
    },

    handleFrame(frame) {
      switch (frame.t) {
        case 'ping':
          // 连接层保活。回 pong 让对端不必等超时。空载荷也要封箱（§3）。
          port.send({ v: 1, t: 'pong', box: '' })
          return
        case 'pong':
        case 'credit':
        case 'presence':
          // 保活与流控记账已在 connection 内部处理；这里无需再动作。
          return
        case 'persisted': {
          // 手机说"这条 seq 之前的我都写进本地库了"（§5.3 / §5.5）。
          // 据此推进**这台设备**的落盘水位；等全部配对设备都覆盖过才允许裁掉缓冲头部 ——
          // 快的那台确认了不代表慢的那台也收到了。
          if (deviceId !== null) {
            const removed = deps.buffer.ack(frame.sid, deviceId, frame.seq)
            if (removed > 0) {
              logger.debug(
                `增量缓冲裁剪：${frame.sid} 裁掉 ${removed} 条（设备 ${deviceId} 确认到 ${frame.seq}）`,
              )
            }
          }
          return
        }
        case 'pair':
          // 配对帧**在密钥建立之前**到达，所以连接层把它直接交到这里。
          void pairingEndpoint.handle({ id: frame.id, box: frame.box })
          return
        case 'req':
          // 方法面。**异步**：handler 可能要等 DSH 服务，而收帧路径不能阻塞
          //（同一条 socket 上还有 `credit` / 保活要走）。
          void methodFace.handle(frame).then((response) => {
            if (response === null) return
            // 发不出去就留声：手机在等这个 `res`，静默丢弃会变成"永远转圈"。
            if (!port.send(response)) {
              metrics.increment(METRIC.rejectedFrames)
              logger.warn(`应答 ${frame.id} 没发出去（连接不在服务态或窗口拒绝）`)
            }
          })
          return
        default:
          // **不静默丢弃**：手机端会看到"发出去但没回应"，而电脑侧一片安静 ——
          // 那是最难查的一类故障。`res` / `ev` / `live` / `persisted` 都是电脑侧发出的方向，
          // 从手机收到它们说明对端跑错了协议。
          metrics.increment(METRIC.rejectedFrames)
          logger.warn(`收到电脑侧方向的帧：${frame.t}（手机不该发这个）`)
      }
    },
  }
}
