/** 公网中转的 HTTP/WS 装配；每设备数据连接与控制连接分离。
 * 决策：.agents/notes/implemented/2026-10-08-pairing-v2-and-device-connections.md。
 */
import { randomBytes } from 'node:crypto'
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import { WebSocketServer, WebSocket } from 'ws'
import {
  MAX_WIRE_BYTES, CHANNEL_CONNECT_TIMEOUT_MS, type DeviceBinding,
} from '../../protocol/relay-control.mjs'
import { createRelayCore, type RelayCore, type Delivery } from './core.ts'
import { createDeviceRegistry, type DeviceRegistry } from './device-registry.ts'
import { createHttpFace, type Authenticated } from './http-face.ts'
import { createRateLimiter } from './rate-limit.ts'
import { createTicketStore } from './tickets.ts'
import { PAIRING_REGISTRATION_TTL_MS } from './pairing-registry.ts'
import type { ChannelLogger } from './logger.ts'

const MAX_BODY_BYTES = 1024 * 1024
const CONTROL_HEARTBEAT_MS = 60_000
const MAX_SEND_BUFFER_BYTES = 2 * MAX_WIRE_BYTES

export interface RelayServerOptions {
  port: number
  host?: string
  authenticate: (token: string) => Authenticated | undefined
  rateLimit?: { capacity: number; refillPerSecond: number }
  log?: ChannelLogger
}
export interface RelayServer {
  port: number
  core: RelayCore
  devices: DeviceRegistry
  close(): Promise<void>
}
interface Link {
  binding: DeviceBinding
  device: WebSocket
  data: WebSocket | null
  setupTimer: ReturnType<typeof setTimeout> | null
  pairingTimer: ReturnType<typeof setTimeout> | null
}

function bearerOf(header: string | string[] | undefined): string | undefined {
  const value = Array.isArray(header) ? header[0] : header
  return value === undefined ? undefined : /^Bearer\s+(.+)$/i.exec(value.trim())?.[1]
}
async function readBody(request: IncomingMessage): Promise<unknown> {
  let size = 0
  const chunks: Buffer[] = []
  for await (const chunk of request) {
    const buffer = Buffer.from(chunk as Buffer)
    size += buffer.length
    if (size > MAX_BODY_BYTES) throw new Error('请求体过大')
    chunks.push(buffer)
  }
  return size === 0 ? undefined : JSON.parse(Buffer.concat(chunks).toString('utf8')) as unknown
}
function reply(response: ServerResponse, status: number, body: unknown): void {
  response.writeHead(status, { 'content-type': 'application/json' })
  response.end(JSON.stringify(body))
}

export async function startRelay(options: RelayServerOptions): Promise<RelayServer> {
  const log = options.log
  const devices = createDeviceRegistry(log === undefined ? {} : { log })
  const core = createRelayCore(log === undefined ? {} : { log })
  const tickets = createTicketStore(log === undefined ? {} : { log })
  const limits = options.rateLimit ?? { capacity: 60, refillPerSecond: 6 }
  const limiter = createRateLimiter({ ...limits, ...(log === undefined ? {} : { log }) })
  const face = createHttpFace({
    core, tickets, devices, authenticate: options.authenticate,
    rateLimit: (key) => limiter.take(key), ...(log === undefined ? {} : { log }),
  })
  const controls = new Map<string, { socket: WebSocket; alive: boolean }>()
  const links = new Map<string, Link>()

  const http = createServer((request, response) => {
    void (async () => {
      const url = new URL(request.url ?? '/', 'http://relay.invalid')
      if (url.pathname === '/healthz' && request.method === 'GET') {
        reply(response, 200, { status: 'ok' })
        return
      }
      let body: unknown
      try { body = await readBody(request) } catch {
        reply(response, 400, { error: 'bad-request' })
        return
      }
      const token = bearerOf(request.headers.authorization)
      const remoteAddress = request.socket.remoteAddress
      const result = face.handle({
        method: request.method ?? 'GET', path: url.pathname,
        // 未认证那一跳（首配）按来源地址取桶 —— 它是那一跳唯一能区分的维度。
        ...(remoteAddress === undefined ? {} : { remoteAddress }),
        ...(token === undefined ? {} : { token }), ...(body === undefined ? {} : { body }),
      })
      reply(response, result.status, result.body ?? {})
    })().catch((error: unknown) => {
      log?.warn('HTTP 请求处理失败', error)
      if (!response.headersSent) reply(response, 500, { error: 'internal' })
      else response.destroy()
    })
  })
  http.requestTimeout = CHANNEL_CONNECT_TIMEOUT_MS
  http.headersTimeout = CHANNEL_CONNECT_TIMEOUT_MS
  const wss = new WebSocketServer({ noServer: true, maxPayload: MAX_WIRE_BYTES })

  function closeLink(channelId: string, code = 4000, reason = 'channel closed'): void {
    const link = links.get(channelId)
    if (link === undefined) return
    links.delete(channelId)
    core.closeChannel(channelId)
    if (link.setupTimer !== null) clearTimeout(link.setupTimer)
    if (link.pairingTimer !== null) clearTimeout(link.pairingTimer)
    link.device.close(code, reason)
    link.data?.close(code, reason)
    const control = controls.get(link.binding.connectorId)?.socket
    if (control?.readyState === WebSocket.OPEN) {
      control.send(JSON.stringify({ v: 1, t: 'relay.close', channelId }))
    }
  }
  function detachControl(connectorId: string): void {
    controls.delete(connectorId)
    for (const [channelId, link] of links) {
      if (link.binding.connectorId === connectorId) closeLink(channelId, 4000, 'connector offline')
    }
    core.detachConnector(connectorId)
    devices.detachConnector(connectorId)
  }
  function deliver(deliveries: readonly Delivery[]): void {
    for (const delivery of deliveries) {
      const link = links.get(delivery.channelId)
      if (link === undefined) continue
      const target = delivery.to === 'data' ? link.data : link.device
      if (target === null || target.readyState !== WebSocket.OPEN) {
        closeLink(delivery.channelId, 4000, 'peer unavailable')
        continue
      }
      if (target.bufferedAmount + Buffer.byteLength(delivery.raw, 'utf8') > MAX_SEND_BUFFER_BYTES) {
        closeLink(delivery.channelId, 4008, 'slow consumer')
        continue
      }
      target.send(delivery.raw, (error) => {
        if (error == null) return
        log?.warn('数据帧投递失败', error)
        closeLink(delivery.channelId, 4000, 'delivery failed')
      })
    }
  }
  function observeData(ws: WebSocket, channelId: string, kind: 'device' | 'data'): void {
    ws.on('message', (data, binary) => {
      const link = links.get(channelId)
      if (link === undefined || link[kind] !== ws) return
      if (binary) { closeLink(channelId, 1003, 'text frames required'); return }
      try { deliver(core.onLine({ kind, channelId }, data.toString())) } catch (error) {
        log?.warn('数据连接帧被拒绝', error)
        closeLink(channelId, 4008, 'channel limit exceeded')
      }
    })
    ws.on('close', () => {
      if (links.get(channelId)?.[kind] === ws) closeLink(channelId)
    })
    ws.on('error', (error) => {
      log?.warn('数据连接出错', error)
      if (links.get(channelId)?.[kind] === ws) closeLink(channelId)
    })
  }
  function acceptControl(ws: WebSocket, connectorId: string): void {
    const previous = controls.get(connectorId)
    if (previous !== undefined) {
      detachControl(connectorId)
      previous.socket.close(4000, 'replaced')
    }
    const state = { socket: ws, alive: true }
    controls.set(connectorId, state)
    core.attachConnector(connectorId)
    ws.on('pong', () => { if (controls.get(connectorId) === state) state.alive = true })
    ws.on('message', () => ws.close(1008, 'control channel is notification only'))
    ws.on('close', () => { if (controls.get(connectorId) === state) detachControl(connectorId) })
    ws.on('error', (error) => { log?.warn('控制连接出错', error); ws.close() })
    log?.info(`连接器 ${connectorId} 控制面已连接`)
  }
  function acceptDevice(ws: WebSocket, binding: DeviceBinding): void {
    const previous = core.channelOf(binding.connectorId, binding.deviceId)
    if (previous !== undefined) closeLink(previous, 4000, 'replaced')
    const channelId = randomBytes(16).toString('base64url')
    try { core.openDevice(channelId, binding) } catch (error) {
      log?.warn('设备连接准入失败', error)
      ws.close(4008, 'admission rejected')
      return
    }
    const link: Link = { binding, device: ws, data: null, setupTimer: null, pairingTimer: null }
    links.set(channelId, link)
    observeData(ws, channelId, 'device')
    link.setupTimer = setTimeout(() => closeLink(channelId, 4000, 'data connection timeout'), CHANNEL_CONNECT_TIMEOUT_MS)
    if (binding.purpose === 'pairing') {
      link.pairingTimer = setTimeout(() => closeLink(channelId, 4000, 'pairing expired'), PAIRING_REGISTRATION_TTL_MS)
    }
    const control = controls.get(binding.connectorId)?.socket
    if (control?.readyState !== WebSocket.OPEN) { closeLink(channelId, 4000, 'connector offline'); return }
    control.send(JSON.stringify({ v: 1, t: 'relay.open', channelId, binding }))
  }

  const refuse = (socket: import('node:stream').Duplex, status: number, reason: string): void => {
    socket.end(`HTTP/1.1 ${status} ${reason}\r\nconnection: close\r\n\r\n`)
  }
  http.on('upgrade', (request, socket, head) => {
    const url = new URL(request.url ?? '/', 'http://relay.invalid')
    if (url.pathname === '/ws/connector') {
      const caller = options.authenticate(bearerOf(request.headers.authorization) ?? '')
      if (caller?.kind !== 'connector') { refuse(socket, 401, 'Unauthorized'); return }
      if (!limiter.take(`connector:${caller.id}`).allowed) { refuse(socket, 429, 'Too Many Requests'); return }
      const deviceId = url.searchParams.get('dev')
      const channelId = url.searchParams.get('channel')
      if (deviceId === null && channelId === null) {
        wss.handleUpgrade(request, socket, head, (ws) => acceptControl(ws, caller.id))
        return
      }
      const channel = channelId === null ? undefined : core.channel(channelId)
      if (channel === undefined || channel.connected || channel.binding.connectorId !== caller.id
        || channel.binding.deviceId !== deviceId || !controls.has(caller.id)) {
        refuse(socket, 403, 'Forbidden')
        return
      }
      wss.handleUpgrade(request, socket, head, (ws) => {
        const link = links.get(channel.channelId)
        if (link === undefined || link.data !== null) { ws.close(4000, 'stale channel'); return }
        link.data = ws
        observeData(ws, channel.channelId, 'data')
        if (link.setupTimer !== null) clearTimeout(link.setupTimer)
        link.setupTimer = null
        deliver(core.attachData(caller.id, channel.binding.deviceId, channel.channelId))
      })
      return
    }
    if (url.pathname === '/ws/device') {
      const binding = tickets.consume(url.searchParams.get('ticket') ?? '')
      if (binding === undefined) { refuse(socket, 401, 'Unauthorized'); return }
      if (!core.isConnectorOnline(binding.connectorId)) { refuse(socket, 503, 'Service Unavailable'); return }
      if (!limiter.take(`device:${binding.deviceId}`).allowed) { refuse(socket, 429, 'Too Many Requests'); return }
      wss.handleUpgrade(request, socket, head, (ws) => acceptDevice(ws, binding))
      return
    }
    refuse(socket, 404, 'Not Found')
  })

  const heartbeat = setInterval(() => {
    for (const [connectorId, state] of controls) {
      if (!state.alive) {
        detachControl(connectorId)
        state.socket.terminate()
      } else {
        state.alive = false
        state.socket.ping()
      }
    }
  }, CONTROL_HEARTBEAT_MS)
  heartbeat.unref()
  await new Promise<void>((resolve, reject) => {
    http.once('error', reject)
    http.listen(options.port, options.host ?? '127.0.0.1', () => { http.off('error', reject); resolve() })
  })
  const address = http.address()
  return {
    port: typeof address === 'object' && address !== null ? address.port : options.port,
    core, devices,
    async close() {
      clearInterval(heartbeat)
      for (const channelId of [...links.keys()]) closeLink(channelId, 1001, 'server shutting down')
      controls.clear()
      for (const ws of wss.clients) ws.terminate()
      await new Promise<void>((resolve) => wss.close(() => resolve()))
      await new Promise<void>((resolve) => http.close(() => resolve()))
    },
  }
}
