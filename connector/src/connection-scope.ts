/** 每连接的订阅、方法面与认证状态。候选配对不能进入普通业务。
 * 决策：.agents/notes/implemented/2026-10-08-pairing-v2-and-device-connections.md。
 */
import type { JobControlPort } from './dsh/jobs.js'
import { resolveSessionAddress, type SessionsPort } from './dsh/sessions.js'
import { createHandlers, type HandlerDeps } from './handlers.js'
import type { PairingEndpoint } from './pairing-endpoint.js'
import type { PairingCandidate } from './pairing.js'
import { createJobSubscriptions } from './job-subscriptions.js'
import { createMethodFace } from './method-face.js'
import { createSessionPager } from './session-page.js'
import { createSessionSubscriptions } from './session-subscriptions.js'
import { METRIC, type ChannelLogger, type ChannelMetrics } from './observability.js'
import type { Idempotency } from './idempotency.js'
import type { SessionBuffer } from './session-buffer.js'
import type { DeviceAppState } from './presence.js'
import type { WireFrame } from './protocol/frame.js'
import { ProtocolError } from './protocol/errors.js'
import type { ConnectionPort } from './transport/connection.js'

/**
 * 设备瞬时状态的上报面（契约 §6.2 仲裁判定的输入）。
 *
 * 实现是挂载级的 `presence.ts`；这里只持有窄接口，于是"每连接装配"不认识挂载级的状态表。
 */
export interface DevicePresenceSink {
  /** 设备完成鉴权、连接进入服务态。 */
  online(devId: string): void
  /** 连接离开服务态。 */
  offline(devId: string): void
  /** 手机声明前后台态（`sync.hello`）。 */
  app(devId: string, state: DeviceAppState): void
  /** 订阅集整体覆盖。 */
  subscriptions(devId: string, sids: readonly string[]): void
  /** 手机在这个会话上答了一次话。 */
  interacted(devId: string, sid: string, at: number): void
}

/**
 * **每连接**才能回答的问题："这条连接是哪台设备"。
 *
 * 由本文件自己构造（`deviceId` 本来就是它的状态），方法面与 `sync.hello` /
 * `interaction.respond` 通过它拿到设备身份与 presence 上报面。
 */
export interface ConnectionIdentity {
  /** 这条连接当前服务的设备；未完成鉴权（或已结束服务）时是 `null`。 */
  deviceId(): string | null
  presence: DevicePresenceSink
}

export interface ConnectionScopeDeps {
  logger: ChannelLogger
  metrics: ChannelMetrics
  handlers: Omit<HandlerDeps, 'jobSubscriptions' | 'sessionSubscriptions' | 'sessionPager'>
  sessions: SessionsPort
  buffer: SessionBuffer
  jobControl: JobControlPort | null
  idempotency: Idempotency | null
  /**
   * 本连接的 presence 上报面（实现是挂载级的 `presence.ts`）。**可缺**：只为
   * "不需要 presence 的装配"留的口子（例如只测方法面的用例）。缺了 `sync.hello`
   * 仍然能答，只是不上报前后台态。
   */
  presence?: DevicePresenceSink
  /**
   * 该会话上仍在途的 ask 事件（重连重投，见 `session-subscriptions.ts` 的 `pendingOf`）。
   * **可缺**：只测方法面 / 订阅骨架的用例不需要它；缺了就是"没有要重投的"。
   */
  pendingAsks?: (sid: string) => readonly { seq: number; body: string }[]
}
export interface PairingScope {
  candidate: PairingCandidate
  endpoint: PairingEndpoint
}
export interface ConnectionScope {
  deviceEstablished(devId: string): void
  pairingEstablished(): void
  servingEnded(): void
  handleFrame(frame: WireFrame): void
}

export function createConnectionScope(
  port: ConnectionPort,
  deps: ConnectionScopeDeps,
  pairing?: PairingScope,
): ConnectionScope {
  const { logger, metrics } = deps
  let deviceId: string | null = null
  let pairingReady = false
  let generation = 0
  const jobSubscriptions = deps.jobControl === null ? null : createJobSubscriptions({
    source: deps.jobControl,
    send: (sid, output) => {
      if (port.state !== 'serving') return 'closed'
      return port.send({ v: 1, t: 'job', sid, box: JSON.stringify(output) }) ? 'sent' : 'paused'
    },
    waitWritable: () => port.whenWritable('job'), log: logger,
  })
  const sessionSubscriptions = createSessionSubscriptions({
    source: deps.sessions, buffer: deps.buffer,
    // **子会话的地址要带父会话 id**（判据在清单行里，见 `resolveSessionAddress`）——
    // 少了它，宿主对子会话的 `follow` 直接拒绝，手机进去是一片空白。
    addressOf: (dshSessionId) => resolveSessionAddress(deps.sessions, dshSessionId),
    ...(deps.pendingAsks === undefined ? {} : { pendingOf: deps.pendingAsks }),
    send: (out) => {
      if (port.state !== 'serving') return 'closed'
      const frame = out.t === 'ev'
        ? { v: 1 as const, t: 'ev' as const, sid: out.sid, seq: out.seq, box: out.body }
        : { v: 1 as const, t: 'live' as const, sid: out.sid, stream: out.stream, rev: out.rev, box: out.body }
      return port.send(frame) ? 'sent' : 'paused'
    },
    waitWritable: () => port.whenWritable('ev'), log: logger,
    // **订阅变化就上报 presence**：`foreground` 档的 claim 判据是"前台且已订阅该 sid"，
    // 而订阅集只有这一处是权威（`sessionSubscriptions` 自己的 entries）。
    onChange: (sids) => {
      const devId = deviceId
      if (devId !== null) deps.presence?.subscriptions(devId, sids)
    },
  })
  const sessionPager = createSessionPager({ sessions: deps.sessions, cursorOf: (sid) => sessionSubscriptions.cursorOf(sid), log: logger })
  /**
   * 本连接的设备身份窗口。**由这里构造而不是外面传进来**：`deviceId` 本来就是本作用域的
   * 状态（`deviceEstablished` 写、`servingEnded` 清），让外面持有一个 getter 只会多一处
   * 可能与真实状态不一致的副本。
   */
  const identity: ConnectionIdentity | undefined =
    deps.presence === undefined ? undefined : { deviceId: () => deviceId, presence: deps.presence }
  const methodFace = createMethodFace({
    handlers: createHandlers({
      ...deps.handlers, sessionSubscriptions, sessionPager,
      ...(jobSubscriptions === null ? {} : { jobSubscriptions }),
      // 两个**每连接**才答得了的方法面（`sync.hello` 要上报前后台态、
      // `interaction.respond` 要记 lastInteractedAt 并可能收束在途 claim）：
      // 它们需要"这条连接是哪台设备"，而那只有本作用域知道。
      ...(identity === undefined ? {} : { connection: identity }),
    }),
    ...(deps.idempotency === null ? {} : { idempotency: deps.idempotency }),
    onError: (message, detail) => logger.warn(message, detail),
  })

  return {
    deviceEstablished(devId) {
      if (pairing !== undefined) throw new Error('配对候选不能激活普通业务身份')
      deviceId = devId
      // 鉴权完成 = 这台设备在线了。**前台态此时仍为 false**（还没收到 `sync.hello`），
      // 于是一个刚连上的设备不会被 `foreground` 档误判成"用户正看着手机"。
      deps.presence?.online(devId)
    },
    pairingEstablished() {
      if (pairing === undefined) throw new Error('普通设备连接不能激活配对通道')
      pairingReady = true
    },
    servingEnded() {
      generation += 1
      pairingReady = false
      // 断开 = 这台设备下线。**整条记录作废**（订阅集属于这条连接）——
      // 见 `presence.ts` 的 `offline`。
      if (deviceId !== null) deps.presence?.offline(deviceId)
      deviceId = null
      jobSubscriptions?.stopAll()
      sessionSubscriptions.stopAll()
    },
    handleFrame(frame) {
      if (frame.t === 'ping') {
        port.send({ v: 1, t: 'pong', id: frame.id, box: '' })
        return
      }
      if (frame.t === 'pong' || frame.t === 'credit' || frame.t === 'presence') return
      if (pairing !== undefined) {
        if (!pairingReady || frame.t !== 'pair-commit') {
          throw new ProtocolError('protocol/not-paired', '待配对连接只允许加密授权提交')
        }
        const activeGeneration = generation
        void pairing.endpoint.handle(frame.box, pairing.candidate).then((result) => {
          if (generation !== activeGeneration || !pairingReady) return
          if (!port.send({ v: 1, t: 'pair-result', id: frame.id, box: JSON.stringify(result) })) {
            logger.warn('配对结果未送达，设备应核对授权状态后重试')
          }
        })
        return
      }
      if (deviceId === null) throw new ProtocolError('protocol/not-paired', '设备尚未完成认证')
      if (frame.t === 'persisted') {
        deps.buffer.ack(frame.sid, deviceId, frame.seq)
        return
      }
      if (frame.t === 'req') {
        const activeGeneration = generation
        void methodFace.handle(frame).then((response) => {
          if (response === null || activeGeneration !== generation) return
          if (!port.send(response)) {
            metrics.increment(METRIC.rejectedFrames)
            logger.warn(`应答 ${frame.id} 未送达`)
          }
        })
        return
      }
      metrics.increment(METRIC.rejectedFrames)
      throw new ProtocolError('protocol/bad-frame', `设备不能在本连接发送 ${frame.t}`)
    },
  }
}
