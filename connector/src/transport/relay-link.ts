/** 控制连接只接收路由通知；每次设备连接建立独立的 Connection。
 * 决策：.agents/notes/implemented/2026-10-08-pairing-v2-and-device-connections.md。
 */
import { WebSocket } from 'ws'
import { parseRelayControl, MAX_PENDING_BYTES, MAX_PAIRING_CANDIDATES, type DeviceBinding } from '../../../protocol/relay-control.mjs'
import { createBackoff } from './backoff.js'
import { relayUrlOf } from './relay-url.js'
import type { Connection, DialSocket } from './connection.js'
import type { ChannelLogger } from '../observability.js'

export interface RelayLinkOptions {
  url: string
  token: string
  allowInsecureLocal?: boolean
  /** 公网明文（自部署中转）：与手机侧 checkedRelayUri 的第二档同一判据。 */
  allowInsecurePublic?: boolean
  allows(binding: DeviceBinding): boolean
  createData(binding: DeviceBinding): Connection
  onConnected(): Promise<void>
  log: ChannelLogger
}
export interface RelayLink {
  start(): void
  stop(): void
  readonly connections: number
}
interface DataConnection { socket: WebSocket; connection: Connection | null; binding: DeviceBinding }

function asDialSocket(ws: WebSocket): DialSocket {
  const port: DialSocket = {
    send: (raw) => ws.send(raw), close: (code, reason) => ws.close(code, reason),
    onopen: null, onmessage: null, onclose: null, onerror: null,
  }
  ws.on('message', (raw, binary) => {
    if (binary) { ws.close(1003, 'text frames required'); return }
    port.onmessage?.({ data: raw.toString() })
  })
  ws.on('close', (code, reason) => port.onclose?.({ code, reason: reason.toString() }))
  ws.on('error', (error) => port.onerror?.(error))
  return port
}

export function createRelayLink(options: RelayLinkOptions): RelayLink {
  const base = relayUrlOf(options.url, options.allowInsecureLocal, options.allowInsecurePublic)
  base.pathname = '/ws/connector'
  const backoff = createBackoff()
  const data = new Map<string, DataConnection>()
  let control: WebSocket | null = null
  let retry: ReturnType<typeof setTimeout> | null = null
  let watchdog: ReturnType<typeof setTimeout> | null = null
  let stopped = false

  const closeData = (channelId: string): void => {
    const entry = data.get(channelId)
    if (entry === undefined) return
    data.delete(channelId)
    entry.connection?.stop()
    // CONNECTING 上调用 close 会产生 error，由统一监听记录。
    entry.socket.close(1000, 'channel ended')
  }
  const allDataClosed = (): void => {
    for (const channelId of [...data.keys()]) closeData(channelId)
  }
  const armWatchdog = (socket: WebSocket): void => {
    if (watchdog !== null) clearTimeout(watchdog)
    watchdog = setTimeout(() => {
      if (control === socket) socket.terminate()
    }, 2 * 60_000)
    watchdog.unref()
  }
  const openData = (channelId: string, binding: DeviceBinding): void => {
    if (data.has(channelId)) return
    if (!options.allows(binding)) {
      options.log.warn('拒绝中转通知中未获准的设备或过期候选')
      return
    }
    for (const [oldId, entry] of data) {
      if (entry.binding.deviceId === binding.deviceId) closeData(oldId)
    }
    if (binding.purpose === 'pairing'
      && [...data.values()].filter((entry) => entry.binding.purpose === 'pairing').length >= MAX_PAIRING_CANDIDATES) {
      options.log.warn('待配对数据连接已达上限')
      return
    }
    const url = new URL(base)
    url.searchParams.set('dev', binding.deviceId)
    url.searchParams.set('channel', channelId)
    const socket = new WebSocket(url, { headers: { authorization: `Bearer ${options.token}` }, handshakeTimeout: 10_000 })
    const entry: DataConnection = { socket, connection: null, binding }
    data.set(channelId, entry)
    socket.on('error', (error) => options.log.warn('设备数据连接失败', error))
    socket.on('open', () => {
      if (stopped || data.get(channelId) !== entry) { socket.close(); return }
      try {
        entry.connection = options.createData(binding)
        entry.connection.attach(asDialSocket(socket))
      } catch (error) {
        options.log.warn('设备连接装配失败', error)
        closeData(channelId)
      }
    })
    socket.on('close', () => {
      if (data.get(channelId) !== entry) return
      data.delete(channelId)
      entry.connection?.stop()
    })
  }
  const connect = (): void => {
    if (stopped || control !== null) return
    const socket = new WebSocket(base, { headers: { authorization: `Bearer ${options.token}` }, handshakeTimeout: 10_000 })
    control = socket
    socket.on('open', () => {
      if (stopped || control !== socket) return
      armWatchdog(socket)
      // 名册失败不能静默维持一条看似在线的控制连接；重连后重放。
      void options.onConnected().then(() => {
        if (control === socket) backoff.reset()
      }).catch((error: unknown) => {
        options.log.warn('控制面初始化失败，关闭后重试', error)
        if (control === socket) socket.close(1011, 'initialization failed')
      })
    })
    socket.on('ping', () => { if (control === socket) armWatchdog(socket) })
    socket.on('message', (raw, binary) => {
      if (control !== socket || stopped) return
      if (binary || raw.toString().length > MAX_PENDING_BYTES) { socket.close(1008, 'invalid control message'); return }
      const message = parseRelayControl(raw.toString())
      if (message === undefined) { socket.close(1008, 'invalid control message'); return }
      if (message.t === 'relay.close') closeData(message.channelId)
      else openData(message.channelId, message.binding)
    })
    socket.on('error', (error) => options.log.warn('中转控制连接失败', error))
    socket.on('close', () => {
      if (control !== socket) return
      control = null
      if (watchdog !== null) clearTimeout(watchdog)
      watchdog = null
      allDataClosed()
      if (stopped) return
      retry = setTimeout(() => { retry = null; connect() }, backoff.next())
    })
  }
  return {
    start() { stopped = false; connect() },
    stop() {
      stopped = true
      if (retry !== null) clearTimeout(retry)
      if (watchdog !== null) clearTimeout(watchdog)
      retry = watchdog = null
      const socket = control
      control = null
      allDataClosed()
      socket?.close(1000, 'connector stopped')
    },
    get connections() { return data.size },
  }
}
