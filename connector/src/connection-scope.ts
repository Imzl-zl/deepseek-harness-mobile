/** 每连接的订阅、方法面与认证状态。候选配对不能进入普通业务。
 * 决策：.agents/notes/implemented/2026-10-08-pairing-v2-and-device-connections.md。
 */
import type { JobControlPort } from './dsh/jobs.js'
import type { SessionsPort } from './dsh/sessions.js'
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
import type { WireFrame } from './protocol/frame.js'
import { ProtocolError } from './protocol/errors.js'
import type { ConnectionPort } from './transport/connection.js'

export interface ConnectionScopeDeps {
  logger: ChannelLogger
  metrics: ChannelMetrics
  handlers: Omit<HandlerDeps, 'jobSubscriptions' | 'sessionSubscriptions' | 'sessionPager'>
  sessions: SessionsPort
  buffer: SessionBuffer
  jobControl: JobControlPort | null
  idempotency: Idempotency | null
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
    send: (out) => {
      if (port.state !== 'serving') return 'closed'
      const frame = out.t === 'ev'
        ? { v: 1 as const, t: 'ev' as const, sid: out.sid, seq: out.seq, box: out.body }
        : { v: 1 as const, t: 'live' as const, sid: out.sid, stream: out.stream, rev: out.rev, box: out.body }
      return port.send(frame) ? 'sent' : 'paused'
    },
    waitWritable: () => port.whenWritable('ev'), log: logger,
  })
  const sessionPager = createSessionPager({ sessions: deps.sessions, cursorOf: (sid) => sessionSubscriptions.cursorOf(sid), log: logger })
  const methodFace = createMethodFace({
    handlers: createHandlers({
      ...deps.handlers, sessionSubscriptions, sessionPager,
      ...(jobSubscriptions === null ? {} : { jobSubscriptions }),
    }),
    ...(deps.idempotency === null ? {} : { idempotency: deps.idempotency }),
    onError: (message, detail) => logger.warn(message, detail),
  })

  return {
    deviceEstablished(devId) {
      if (pairing !== undefined) throw new Error('配对候选不能激活普通业务身份')
      deviceId = devId
    },
    pairingEstablished() {
      if (pairing === undefined) throw new Error('普通设备连接不能激活配对通道')
      pairingReady = true
    },
    servingEnded() {
      generation += 1
      pairingReady = false
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
