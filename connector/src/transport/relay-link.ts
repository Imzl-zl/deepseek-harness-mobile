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
  /**
   * 本连接器的通道 id（`connectorId`），随控制面升级 URL 的 `?id=` 一起自报。
   *
   * **中转据此核对"你是不是你以为的那台"**：令牌的 id 与自报的 id 不一致会被拒
   * （`relay/src/server.ts` 的控制面分支）。没有这一格时两者不一致**没有任何一处会报**
   * —— 症状是二维码里的 `pcId` 与中转眼里的 id 不是同一个值，而两端都"看起来正常"。
   *
   * 老连接器不带这个参数，中转照旧放行（兼容分支在中转侧，到期即删）。
   */
  connectorId: string
  allowInsecureLocal?: boolean
  /** 公网明文（自部署中转）：与手机侧 checkedRelayUri 的第二档同一判据。 */
  allowInsecurePublic?: boolean
  /**
   * 控制面这次**为什么没连上**（一句人话）；连上时给 `null`。
   *
   * 没有这一格时，面板只能显示「重连中」—— 而 401（令牌不被承认）、404（地址少了
   * `/ws/connector`）、网络不通在界面上长得一模一样，操作者只能去翻日志。
   * 2026-11-03 真机：令牌是旧中转签的，升级回 401，面板一直「重连中」。
   */
  onFailure?(reason: string | null): void
  allows(binding: DeviceBinding): boolean
  createData(binding: DeviceBinding): Connection
  onConnected(): Promise<void>
  log: ChannelLogger
}
export interface RelayLink {
  start(): void
  stop(): void
  readonly connections: number
  /**
   * 控制面此刻**真的连上了吗**。
   *
   * 与"link 对象存在"是两件事：`start()` 之后到 `open` 之前、以及每次断开到退避
   * 重连成功之间，对象都在、连接不在。面板要答"我的手机连上了吗"，只能看这个 ——
   * 看 `connections`（数据通道条数）也不对：没有手机在线时它恒为 0，
   * 但中转控制面明明是通的。
   */
  readonly connected: boolean
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

/**
 * 升级被拒时那句人话。
 *
 * `ws` 的 `error` 事件只有一句 "Received network error or non-101 status code"，
 * 分不出 401 与 404 —— 而这两种的下一步动作完全不同（换令牌 / 改地址）。
 * 所以状态码从 `unexpected-response` 拿，翻译放在这里（纯函数，可单测）。
 */
export function describeUpgradeFailure(status: number): string {
  if (status === 401) return '中转不认这张令牌（HTTP 401）：去控制台「添加电脑」重签一张，贴到「连接」卡'
  if (status === 403) {
    // 中转对这一档有四种原因（`relay/src/server.ts` 的控制面准入）：账号被停用、
    // 没带 `?id=`、自报的电脑 id 与令牌绑定不符、以及通道抢占。文案必须把它们
    // 都覆盖 —— 2026-11-03 那次真因是"账号"这一支，旧文案只提 id 不一致，
    // 把排查带偏了一整轮。
    return '中转拒绝了这台电脑（HTTP 403）：账号可能被停用，或令牌与自报的电脑 id 对不上'
      + ' —— 去控制台看这个账号与这台电脑的状态'
  }
  if (status === 404) return '中转没有这个地址（HTTP 404）：地址要以 /ws/connector 结尾'
  return `中转拒绝升级（HTTP ${status}）`
}

export function createRelayLink(options: RelayLinkOptions): RelayLink {
  const base = relayUrlOf(options.url, options.allowInsecureLocal, options.allowInsecurePublic)
  base.pathname = '/ws/connector'
  /**
   * 控制面 URL（带 `?id=`）。**数据面不带**：数据通道靠 `dev` + `channel` 认领，
   * 而 `id` 只在"连接器自报身份"这一处有意义。
   */
  const controlUrl = (): URL => {
    const url = new URL(base)
    url.searchParams.set('id', options.connectorId)
    return url
  }
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
    const socket = new WebSocket(controlUrl(), { headers: { authorization: `Bearer ${options.token}` }, handshakeTimeout: 10_000 })
    control = socket
    socket.on('open', () => {
      if (stopped || control !== socket) return
      options.onFailure?.(null)
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
    socket.on('error', (error) => {
      options.onFailure?.(`连不上中转：${error instanceof Error ? error.message : String(error)}`)
      options.log.warn('中转控制连接失败', error)
    })
    // 非 101 的应答：`ws` 只在**没有**监听这条事件时才发 `error`（那句 message 不含状态码）。
    // 接管它必须自己 `destroy()`，否则请求半挂、`close` 不来，退避重连也就不会发生。
    socket.on('unexpected-response', (request, response) => {
      options.onFailure?.(describeUpgradeFailure(response.statusCode ?? 0))
      request.destroy()
    })
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
    get connected() { return control !== null && control.readyState === WebSocket.OPEN },
  }
}
