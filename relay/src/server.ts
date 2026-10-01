/**
 * 中转的入口：把 HTTP 面与 WS 入口接到 `core` 上（契约 §2 的连接建立）。
 *
 * 分工：**判定在 `http-face.ts` / `core.ts`**（零依赖、几十毫秒可测），
 * 这里只做三件"必须碰 socket"的事：
 *
 * 1. 读 HTTP 请求（方法、路径、Bearer 令牌、JSON 体）交给判定；
 * 2. 升级 WS 并**认证这一次升级**：
 *    - 连接器：`Authorization: Bearer <连接器令牌>`（长连凭据不进 URL）；
 *    - 设备：`?ticket=<一次性票>`（票就是为进 URL 而生的，见 `tickets.ts` 的说明）。
 * 3. 把一行交给 `core.onLine`，并把投递写回目标连接；断开时 `detach*`。
 *
 * 两处刻意的选择：
 * - **每个身份只留一条连接**：同一 `id` 再连上来会把旧的关掉（否则 `core` 里的"在线集合"
 *   与真实连接脱节，投递会打到一条僵尸 socket 上）。
 * - 升级失败**只回状态码再断开**，不进入协议层：这时还没有任何帧交换，发协议帧没有意义。
 */
import { createServer, type IncomingMessage, type Server, type ServerResponse } from 'node:http'

import { WebSocketServer, type WebSocket } from 'ws'

import { createRelayCore, type RelayCore } from './core.ts'
import { createHttpFace, type Authenticated } from './http-face.ts'
import { createRateLimiter } from './rate-limit.ts'
import { createTicketStore } from './tickets.ts'
import type { ChannelLogger } from './logger.ts'

/** HTTP 体上限：两个端点都只收一个小 JSON（`codeHash`），64 KiB 已经非常宽。 */
const MAX_BODY_BYTES = 64 * 1024

export interface RelayServerOptions {
  port: number
  host?: string
  /** 校验令牌（实现方去查摘要表，§12.2）。 */
  authenticate: (token: string) => Authenticated | undefined
  /**
   * 限流参数（按身份，§12 的"按设备限流与审计"）。
   *
   * **有默认值**：一个默认敞开的转发器是隐患（一台设备可以把票刷满）。
   * 默认值取"宽松但封顶"：`capacity 60` / `refillPerSecond 6` —— 手机正常重连与
   * 翻历史远达不到，而脚本猛刷会在几秒内被挡住。启动时会把生效值打进日志，
   * 免得操作者事后问"为什么我被 429 了"。
   */
  rateLimit?: { capacity: number; refillPerSecond: number }
  log?: ChannelLogger
}

export interface RelayServer {
  port: number
  core: RelayCore
  close(): Promise<void>
}

const bearerOf = (header: string | string[] | undefined): string | undefined => {
  const value = Array.isArray(header) ? header[0] : header
  if (value === undefined) return undefined
  const match = /^Bearer\s+(.+)$/i.exec(value.trim())
  return match?.[1]
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
  if (size === 0) return undefined
  return JSON.parse(Buffer.concat(chunks).toString('utf8')) as unknown
}

export async function startRelay(options: RelayServerOptions): Promise<RelayServer> {
  const log = options.log
  const core = createRelayCore({ ...(log === undefined ? {} : { log }) })
  const tickets = createTicketStore({ ...(log === undefined ? {} : { log }) })
  const limits = options.rateLimit ?? { capacity: 60, refillPerSecond: 6 }
  const limiter = createRateLimiter({
    capacity: limits.capacity,
    refillPerSecond: limits.refillPerSecond,
    ...(log === undefined ? {} : { log }),
  })
  log?.info(`限流生效：每身份容量 ${limits.capacity}，补充 ${limits.refillPerSecond}/秒`)

  const face = createHttpFace({
    core,
    tickets,
    authenticate: options.authenticate,
    rateLimit: (key) => limiter.take(key),
    ...(log === undefined ? {} : { log }),
  })

  /** 身份 → 当前那条 socket（每个身份只留一条）。 */
  const sockets = new Map<string, WebSocket>()

  const http: Server = createServer((request: IncomingMessage, response: ServerResponse) => {
    void (async () => {
      const url = new URL(request.url ?? '/', 'http://relay.invalid')
      let body: unknown
      try {
        body = await readBody(request)
      } catch (error) {
        response.writeHead(400, { 'content-type': 'application/json' })
        response.end(JSON.stringify({ error: 'bad-request' }))
        log?.debug('HTTP 体读失败', error)
        return
      }
      // `token` 先取一次再判空：分两次调用 `bearerOf` 会让 TS 收窄不了（也真的会算两遍）。
      const token = bearerOf(request.headers.authorization)
      const result = face.handle({
        method: request.method ?? 'GET',
        path: url.pathname,
        ...(token === undefined ? {} : { token }),
        ...(body === undefined ? {} : { body }),
      })
      response.writeHead(result.status, { 'content-type': 'application/json' })
      response.end(JSON.stringify(result.body ?? {}))
    })()
  })

  const wss = new WebSocketServer({ noServer: true })

  const refuse = (socket: import('node:stream').Duplex, status: number, reason: string): void => {
    log?.debug(`拒绝升级：${reason}`)
    socket.write(`HTTP/1.1 ${status} ${reason}\r\nconnection: close\r\n\r\n`)
    socket.destroy()
  }

  http.on('upgrade', (request, socket, head) => {
    const url = new URL(request.url ?? '/', 'http://relay.invalid')
    if (url.pathname === '/ws/connector') {
      const token = bearerOf(request.headers.authorization)
      const caller = token === undefined ? undefined : options.authenticate(token)
      if (caller === undefined || caller.kind !== 'connector') {
        refuse(socket, 401, 'Unauthorized')
        return
      }
      wss.handleUpgrade(request, socket, head, (ws) => {
        accept(ws, 'connector', caller.id)
      })
      return
    }
    if (url.pathname === '/ws/device') {
      const ticket = url.searchParams.get('ticket') ?? ''
      const deviceId = tickets.consume(ticket)
      if (deviceId === undefined) {
        // 票不对/过期/用过：这时还什么都没有交换，回状态码然后断开即可。
        refuse(socket, 401, 'Unauthorized')
        return
      }
      wss.handleUpgrade(request, socket, head, (ws) => {
        accept(ws, 'device', deviceId)
      })
      return
    }
    refuse(socket, 404, 'Not Found')
  })

  function accept(ws: WebSocket, kind: 'connector' | 'device', id: string): void {
    // 每个身份只留一条：旧的先关掉（否则投递会打到僵尸 socket 上）。
    const previous = sockets.get(id)
    if (previous !== undefined && previous !== ws) {
      log?.debug(`${id} 重复连接：关掉旧的那条`)
      previous.close(4000, 'replaced')
    }
    sockets.set(id, ws)
    if (kind === 'connector') core.attachConnector(id)
    else core.attachDevice(id)

    ws.on('message', (data) => {
      const raw = typeof data === 'string' ? data : Buffer.from(data as Buffer).toString('utf8')
      for (const delivery of core.onLine({ kind, id }, raw)) {
        const target = sockets.get(delivery.to)
        if (target === undefined) {
          // `core` 已按在线集合过滤过，能走到这里只可能是并发断开；留声即可。
          log?.debug(`投递目标已断开：${delivery.to}`)
          continue
        }
        target.send(delivery.raw)
      }
    })

    ws.on('close', () => {
      if (sockets.get(id) !== ws) return // 已被新连接替换：不要把它从表里删掉
      sockets.delete(id)
      if (kind === 'connector') core.detachConnector(id)
      else core.detachDevice(id)
    })

    // **`error` 必须监听**：写失败（对端已消失、socket 半开）在 `ws` 里是 `error` 事件，
    // 不监听就是**静默丢失** —— 而"对端没收到"与"我们没写成功"在日志上将无从区分。
    ws.on('error', (error) => {
      log?.warn(`${kind} ${id} 的 socket 出错（这一条连接上后续的投递可能都没发出去）`, error)
    })
  }

  await new Promise<void>((resolve) => {
    http.listen(options.port, options.host ?? '127.0.0.1', () => {
      resolve()
    })
  })
  const address = http.address()
  const port = typeof address === 'object' && address !== null ? address.port : options.port

  return {
    port,
    core,
    async close() {
      for (const ws of sockets.values()) ws.close(1001, 'server shutting down')
      sockets.clear()
      await new Promise<void>((resolve) => wss.close(() => resolve()))
      await new Promise<void>((resolve) => http.close(() => resolve()))
    },
  }
}
