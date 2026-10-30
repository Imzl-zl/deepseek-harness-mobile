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
import { createAdminAuthenticator, type AdminDigest } from './admin/auth.ts'
import { rateKeyOf } from './digest-auth.ts'
import { createRateLimiter } from './rate-limit.ts'
import { createMetering, type Metering, type QuotaConfig, type MeteringState } from './metering.ts'
import { createMeteringStateWriter, FLUSH_EVERY_MS } from './metering-state.ts'
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
  /** 管理面凭据（只放摘要）。不配 = 这张面不存在（`/admin*` 一律 404）。 */
  admin?: AdminDigest
  /** 按人的流量额度。不配 = 只转发、不记账。 */
  quota?: QuotaConfig
  /**
   * `connectorId → owner`（来自配置里的令牌条目，**不是**运行时状态）。
   *
   * 额度主体由它决定：配了 owner 就是 `user:<owner>`，没配退回 `connector:<id>`。
   */
  ownerOf?: (connectorId: string) => string | undefined
  /** `persist: true` 时启动读回的状态（由装配方读文件后传进来）。 */
  quotaState?: MeteringState
  log?: ChannelLogger
}
export interface RelayServer {
  port: number
  core: RelayCore
  devices: DeviceRegistry
  /** 额度面（没配 `quota` 时是 `undefined`）：面板与自检读它。 */
  readonly metering: Metering | undefined
  close(): Promise<void>
}
interface Link {
  binding: DeviceBinding
  device: WebSocket
  data: WebSocket | null
  setupTimer: ReturnType<typeof setTimeout> | null
  pairingTimer: ReturnType<typeof setTimeout> | null
  /** 通道建立时刻（面板的"起止时间"；不参与任何判定）。 */
  startedAt: number
  /** 本通道累计转发的字节（面板用；额度按**人**记在 `metering` 里）。 */
  forwardedBytes: number
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
  /**
   * 额度：**只记账，不参与路由**。`check` 已经按 `enforce` 判过 —— `off` 时恒不超。
   *
   * 配额被拒时返回的是既有错误码 `rate-limited`（契约 §3.1 不动）：手机两侧都已经
   * 认识它（429 → `rateLimited` → 退避重试），新加一个码只会多四处要改的东西。
   */
  const metering = options.quota === undefined
    ? undefined
    : createMetering({
      quota: options.quota,
      ownerOf: options.ownerOf ?? (() => undefined),
      ...(options.quotaState === undefined ? {} : { state: options.quotaState }),
      ...(log === undefined ? {} : { log }),
    })
  const quotaDenied = metering === undefined
    ? undefined
    : (connectorId: string): { retryAfterMs: number | null } | undefined => {
      const verdict = metering.check(connectorId)
      return verdict.exceeded ? { retryAfterMs: verdict.retryAfterMs } : undefined
    }
  const quotaWriter = options.quota?.persist === true && options.quota.statePath !== undefined
    ? createMeteringStateWriter({
      path: options.quota.statePath, ...(log === undefined ? {} : { log }),
    })
    : undefined
  const face = createHttpFace({
    core, tickets, devices, authenticate: options.authenticate,
    rateLimit: (key) => limiter.take(key), ...(log === undefined ? {} : { log }),
    ...(quotaDenied === undefined ? {} : { quotaDenied }),
  })
  const controls = new Map<string, { socket: WebSocket; alive: boolean }>()
  const links = new Map<string, Link>()
  /** 管理面认证。`undefined` = 没配凭据 ⇒ 这张面**不存在**（不是"开着但没人能进"）。 */
  const adminAuth = options.admin === undefined ? undefined : createAdminAuthenticator(options.admin)

  const http = createServer((request, response) => {
    void (async () => {
      const url = new URL(request.url ?? '/', 'http://relay.invalid')
      if (url.pathname === '/healthz' && request.method === 'GET') {
        reply(response, 200, { status: 'ok' })
        return
      }
      if (url.pathname === '/admin' || url.pathname.startsWith('/admin/')) {
        // 未配置凭据：连"有没有这张面"都不回答 —— 404 与未知路径同形。
        // Note: 为什么管理凭据独立于连接器令牌、为什么没配就不存在 —— 见
        // `.agents/notes/implemented/2026-10-30-relay-mutable-token-table-and-admin-credential.md`
        if (adminAuth === undefined) { reply(response, 404, { error: 'not-found' }); return }
        if (request.method !== 'GET') { reply(response, 405, { error: 'method-not-allowed' }); return }
        response.setHeader('cache-control', 'no-store')
        const who = adminAuth(bearerOf(request.headers.authorization) ?? '')
        if (who === undefined) {
          // 认证不过的请求按来源地址取桶：它没有任何身份可用，与首配那一跳同一个理由。
          const refused = limiter.take(`admin-anonymous:${request.socket.remoteAddress ?? 'unknown'}`)
          if (!refused.allowed) {
            reply(response, 429, { error: 'rate-limited', retryAfterMs: refused.retryAfterMs })
            return
          }
          reply(response, 401, { error: 'unauthorized' })
          return
        }
        if (!limiter.take(`admin:${who.id}`).allowed) {
          reply(response, 429, { error: 'rate-limited', retryAfterMs: 1_000 })
          return
        }
        // 本期只有计数快照（面板的页面与写操作在下一批）。**没有任何写路径**。
        if (url.pathname === '/admin/api/state') {
          reply(response, 200, {
            v: 1,
            counters: {
              connectors: core.stats.connectors,
              channels: core.stats.channels,
              tickets: tickets.stats.tickets,
              devices: devices.stats.devices,
              bound: devices.stats.bound,
            },
          })
          return
        }
        reply(response, 404, { error: 'not-found' })
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

  /**
   * 把一端的关闭码/理由转给**另一端**（关闭码只能是 3000–4999 的应用/私有区间）。
   *
   * 为什么必须有它：电脑侧在握手层拒绝时用 **4003 + 协议码/说明**（契约 §4.1），
   * 手机要靠这串东西区分"被另一台设备占用"（`device/busy`，停机等用户）
   * 与"网络断了"（退避重连）。中转若只送默认的 `4000 channel closed`，
   * 手机就只会退避重试 —— **撞门而没有结论**。
   *
   * 只转发 3000–4999：`1005` / `1006` / `1015` 是本地判定值，按 RFC 6455 §7.4.1
   * 不得出现在线上（`ws` 也会拒绝发送）。
   */
  function forwardableClose(code: number): boolean {
    return code >= 3000 && code <= 4999
  }

  /** 理由按 UTF-8 截到 ≤120 字节（WS 硬上限 123），不切断多字节字符。 */
  function closeReason(reason: string): string {
    if (Buffer.byteLength(reason, 'utf8') <= 120) return reason
    let used = 0
    let out = ''
    for (const char of reason) {
      const size = Buffer.byteLength(char, 'utf8')
      if (used + size > 120) break
      out += char
      used += size
    }
    return out
  }

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
  /**
   * 这个人用满了：把它名下**所有**通道按 4003 收掉。
   *
   * 为什么不是只关这一条：同一个人可能有两台电脑同时在线（两条通道、一个额度），
   * 只关一条会让"超额"看起来像偶发断线。`closeLink` 已经先删表再关 socket，
   * 之后到达的帧会被 `links.get(...) !== ws` 丢弃（同一轮同步代码里，不会重入）。
   */
  function cutSubject(subject: string, reason: string): void {
    if (metering === undefined) return
    for (const channelId of [...links.keys()]) {
      const link = links.get(channelId)
      if (link === undefined) continue
      if (metering.subjectOf(link.binding.connectorId) !== subject) continue
      closeLink(channelId, 4003, reason)
    }
  }
  function observeData(ws: WebSocket, channelId: string, kind: 'device' | 'data'): void {
    ws.on('message', (data, binary) => {
      const link = links.get(channelId)
      if (link === undefined || link[kind] !== ws) return
      if (binary) { closeLink(channelId, 1003, 'text frames required'); return }
      const raw = data.toString()
      let result: ReturnType<RelayCore['onLine']>
      try { result = core.onLine({ kind, channelId }, raw) } catch (error) {
        log?.warn('数据连接帧被拒绝', error)
        closeLink(channelId, 4008, 'channel limit exceeded')
        return
      }
      /**
       * 记账、转发、超限收口在**同一个同步块**里（中间没有 `await`）：一帧只有一次
       * 计数机会，也不存在"判完额度、还没转发就被别的事件插进来"的窗口。
       *
       * 只算子业务通道（`purpose === 'paired'`）：配对是恢复路径，额度用完的人
       * 仍然要能重新扫码。
       */
      // 热路径只做一次 Map 查询 + 一次整数加法；**不在这里序列化、不写盘**（见下面的节流器）。
      const charged = metering !== undefined && link.binding.purpose === 'paired'
        ? metering.charge(link.binding.connectorId, result.bytes)
        : undefined
      if (metering !== undefined && link.binding.purpose === 'paired') {
        link.forwardedBytes += result.bytes
      }
      deliver(result.deliveries)
      // 这一帧已经交出去了再断：允许超出一帧（帧是原子的，不能在中间切）。
      if (charged?.over === true && metering?.enforce === 'cut') {
        cutSubject(metering.subjectOf(link.binding.connectorId), 'rate-limited quota')
      }
    })
    ws.on('close', (code, reason) => {
      if (links.get(channelId)?.[kind] !== ws) return
      // **一端的关闭码/理由要转给另一端**（见 `forwardableClose` 的说明）。
      // 电脑侧拒绝（4003 + `device/busy …`）只有经过这一跳才能到手机。
      closeLink(
        channelId,
        forwardableClose(code) ? code : 4000,
        forwardableClose(code) && reason.length > 0 ? closeReason(reason.toString()) : 'channel closed',
      )
    })
    ws.on('error', (error) => {
      log?.warn('数据连接出错', error)
      if (links.get(channelId)?.[kind] === ws) closeLink(channelId)
    })
  }
  function acceptControl(ws: WebSocket, connectorId: string, owner?: string): void {
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
    log?.info(`连接器 ${connectorId} 控制面已连接${owner === undefined ? '' : `（owner=${owner}）`}`)
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
    const link: Link = {
      binding, device: ws, data: null, setupTimer: null, pairingTimer: null,
      startedAt: Date.now(), forwardedBytes: 0,
    }
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
      const presented = bearerOf(request.headers.authorization) ?? ''
      const caller = options.authenticate(presented)
      if (caller?.kind !== 'connector') { refuse(socket, 401, 'Unauthorized'); return }
      /**
       * **接受前重验一次**（这是本批的并发口子）。
       *
       * `wss.handleUpgrade` 的回调是**异步**的：从上面那次认证到回调执行之间，
       * 管理员可能刚好吊销了这台连接器（面板/CLI），或者它被重新签发给了别的 id。
       * 只认一次会放过"已吊销却连上"的连接 —— 那与"停用一台在线设备却不收连接"
       * 是同一类错误（`device-admin` 的 `disconnect` 就是为那条加的）。
       */
      const stillValid = (): boolean => options.authenticate(presented)?.id === caller.id
      // 配了 `owner` 的连接器按**人**分桶：多开几台电脑不该等于多领几个预算。
      if (!limiter.take(rateKeyOf(caller)).allowed) { refuse(socket, 429, 'Too Many Requests'); return }
      const deviceId = url.searchParams.get('dev')
      const channelId = url.searchParams.get('channel')
      if (deviceId === null && channelId === null) {
        // **连接器自报身份**（`?id=`）：**必带**且必须与令牌的 id 一致。
        // 两者不一致时，二维码里的 `pcId` 与中转眼里的 id 是两个值，而此前
        // **没有任何一处会报**（见 `connector/src/transport/relay-link.ts` 的 `connectorId`）。
        // 不带 `?id=` 一律拒 —— 没有"老连接器"这回事：这套协议还没发版。
        const declared = url.searchParams.get('id')
        if (declared === null || declared !== caller.id) {
          log?.warn(
            `连接器自报的 id(${declared ?? '缺'}) 与令牌 id(${caller.id}) 不一致，拒绝控制面`,
          )
          refuse(socket, 403, 'Forbidden')
          return
        }
        wss.handleUpgrade(request, socket, head, (ws) => {
          if (!stillValid()) { ws.close(4000, 'credential revoked'); return }
          acceptControl(ws, caller.id, caller.owner)
        })
        return
      }
      const channel = channelId === null ? undefined : core.channel(channelId)
      if (channel === undefined || channel.connected || channel.binding.connectorId !== caller.id
        || channel.binding.deviceId !== deviceId || !controls.has(caller.id)) {
        refuse(socket, 403, 'Forbidden')
        return
      }
      // 额度用满：连数据面也不给拨（配对通道不在此列 —— 它是恢复路径）。
      if (channel.binding.purpose === 'paired' && quotaDenied?.(caller.id) !== undefined) {
        refuse(socket, 429, 'Too Many Requests')
        return
      }
      wss.handleUpgrade(request, socket, head, (ws) => {
        // 同一条重验：吊销可能落在"查到通道"与"接受数据面"之间。
        if (!stillValid()) { ws.close(4000, 'credential revoked'); return }
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
      // 额度用满：新连接在建连这一步就被拒（票是一次性的，绕不过去）。
      if (binding.purpose === 'paired' && quotaDenied?.(binding.connectorId) !== undefined) {
        refuse(socket, 429, 'Too Many Requests')
        return
      }
      wss.handleUpgrade(request, socket, head, (ws) => acceptDevice(ws, binding))
      return
    }
    refuse(socket, 404, 'Not Found')
  })

  /**
   * 额度落盘节流：每 5 s 看一次脏标记。
   *
   * 热路径**不序列化、不写盘**（每帧一次 `JSON.stringify` 会把转发成本翻倍）；
   * 这里读多写少，代价最多是"重启丢掉最后 5 秒的用量"。
   */
  const quotaFlushTimer = quotaWriter === undefined || metering === undefined
    ? null
    : setInterval(() => {
      if (!metering.dirty) return
      quotaWriter.save(metering.serialize())
      metering.markClean()
    }, FLUSH_EVERY_MS)
  quotaFlushTimer?.unref()

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
    core, devices, metering,
    async close() {
      clearInterval(heartbeat)
      if (quotaFlushTimer !== null) clearInterval(quotaFlushTimer)
      // 先冲最后一份用量再收连接：晚到的 socket 事件不再改计数。
      if (quotaWriter !== undefined && metering !== undefined && metering.dirty) {
        quotaWriter.save(metering.serialize())
        metering.markClean()
        await quotaWriter.flush()
      }
      for (const channelId of [...links.keys()]) closeLink(channelId, 1001, 'server shutting down')
      controls.clear()
      for (const ws of wss.clients) ws.terminate()
      await new Promise<void>((resolve) => wss.close(() => resolve()))
      await new Promise<void>((resolve) => http.close(() => resolve()))
    },
  }
}
