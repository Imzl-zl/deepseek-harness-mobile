/**
 * 直连监听面（契约 §14.6 的第一跳；落地设计见 `docs/subsystems/connector-and-relay.md` §1.7）。
 *
 * 桥接原本只**拨号**（主动连中转）。直连拓扑下手机直接连电脑，所以桥接还要能**接受**连接。
 * 本文件只做三件"必须碰 socket"的事，其余全在既有零件里：
 *
 * 1. 起一个 `ws` 服务端（Node 22 的全局 `WebSocket` 只有客户端，没有服务端实现）；
 * 2. 每 accept 一条，就**装配一次**（`createConnectionScope(port, deps)` 那条缝），
 *    然后把 socket 交给连接层的 `attach()`；
 * 3. 卸载时停止接受并关掉已接受的连接。
 *
 * ## 三条刻意的选择
 *
 * - **默认不监听**：`port` 为 `0` 时直接不建服务端。不配置就等于这个功能不存在，
 *   而不是"监听了但没人用"—— 后者会在真机上表现为"莫名其妙多开了一个端口"。
 * - **不终结 TLS**：插件只监听明文 WS，TLS 由外部终结（Tailscale `tailscale serve` 或反向代理）。
 *   于是插件里**没有一条"跳过 TLS"的分支**可被误开，也不必持有证书私钥。
 *   手机侧始终拨 `wss://`，契约 §2 的两跳都成立。
 * - **不做应用层鉴权**：鉴权就是 §4.1 的握手本身 —— 未配对的设备在 `hello` 处被
 *   `protocol/not-paired` 拒掉。在监听面上再加一层令牌会得到两套"谁能连"的判据，
 *   而它们迟早不一致，且第二套没有契约依据。
 *
 * ## 为什么不复用拨号那条连接
 *
 * 拨号连接的 `onclose` **自愈**（按退避重连 `relayUrl`）。接受来的连接没有拨号目标：
 * 让它按拨号那套去 `dial(url)` 的症状是"监听模式下桥接莫名其妙连去中转"。
 * 所以监听面用**独立的连接对象**（每条 socket 一个），由 `attach()` 的 `heals: false` 收口。
 *
 * 取舍与被否方案：`.agents/notes/implemented/2026-10-02-listener-face.md`
 */
import { WebSocketServer, type WebSocket } from 'ws'

import type { ConnectionPort } from './connection.js'
import type { ChannelLogger } from '../observability.js'

/**
 * 一条被接受的连接。**刻意只有两个成员** —— 监听面不需要知道连接里有什么，
 * 与 `ConnectionPort` 的 4 个成员是同一套纪律（窄端口）。
 */
export interface AcceptedConnection {
  /** 把这条已经打开的 socket 交给连接层。 */
  attach(socket: unknown): void
  /** 连接层那 4 个成员（`createConnectionScope` 的输入）。 */
  readonly port: ConnectionPort
  /** 停止这条连接（卸载时收口）。 */
  stop(): void
}

export interface ListenerOptions {
  /**
   * 监听端口。**`0` = 由系统分配一个空闲端口**（测试与"随便给个口"用）。
   *
   * "要不要监听"**不在这里判断** —— 那是装配层的决定（配置里 `listenPort: 0` 表示关，
   * 于是装配层根本不会调本函数）。把两者混成一个 `0`，测试就没法要一个临时端口了。
   */
  port: number
  /** 监听地址。默认 `127.0.0.1` —— 要走 tailnet 时显式写那个地址。 */
  host?: string
  /**
   * 为**一条新接受的 socket** 装配一次。
   *
   * 由装配层提供（它持有挂载级的 `scopeDeps`）。监听面不认识 DSH、不认识 `ctx` ——
   * 与 `connection-scope.ts` 同一条纪律。
   */
  accept(): AcceptedConnection
  log?: ChannelLogger
}

export interface Listener {
  /** 实际监听的端口（`port: 0` 时由系统分配）。 */
  readonly port: number
  /** 当前活着的被接受连接数。 */
  readonly active: number
  close(): Promise<void>
}

/**
 * 起监听面。
 *
 * @throws 端口被占等绑定失败 —— 由调用方决定是拒绝挂载还是只留声。
 */
export async function startListener(options: ListenerOptions): Promise<Listener> {
  const log = options.log

  const server = new WebSocketServer({ port: options.port, host: options.host ?? '127.0.0.1' })
  /** 活着的连接（卸载时逐个停）。 */
  const connections = new Set<AcceptedConnection>()

  server.on('connection', (socket: WebSocket) => {
    // **每 accept 一条就装配一次**：方法面 / 订阅 / 翻页器 / 配对端点都是每连接的
    //（`connection-scope.ts` 的文件头写了为什么）。两条连接共用一份会串台 ——
    // 表现为"第二台手机连上了、也握手成功了，但收不到任何事件"。
    const accepted = options.accept()
    connections.add(accepted)

    socket.on('close', () => {
      connections.delete(accepted)
      // **不重连**：接受来的连接没有拨号目标，重新接受一条是监听面自己的职责
      //（`attach()` 的 `heals: false` 已经把这条表达在连接层）。
      log?.debug(`直连设备断开（当前 ${connections.size} 条）`)
    })
    // 与中转侧同一条纪律：写失败在 `ws` 里是 `error` 事件，不监听就是**静默丢失**。
    socket.on('error', (error) => {
      log?.warn('直连 socket 出错（这一条上后续的帧可能都没发出去）', error)
    })

    // **已经 OPEN**：`onopen` 不会再触发，所以 `attach()` 内部会直接走一次"打开"处理。
    accepted.attach(socket)
    log?.debug(`接受一条直连（当前 ${connections.size} 条）`)
  })

  server.on('error', (error) => {
    // 监听面出错（端口被占等）要吵：静默的话操作者会以为在监听。
    log?.error('直连监听面出错', error)
  })

  await new Promise<void>((resolve, reject) => {
    const onError = (error: unknown): void => reject(error)
    server.once('error', onError)
    server.once('listening', () => {
      server.off('error', onError)
      resolve()
    })
  })

  const address = server.address()
  const bound = typeof address === 'object' && address !== null ? address.port : options.port
  log?.info(`直连监听面已就绪：ws://${options.host ?? '127.0.0.1'}:${bound}（TLS 由外部终结）`)

  return {
    port: bound,
    get active() {
      return connections.size
    },
    async close() {
      for (const accepted of connections) {
        accepted.stop()
        connections.delete(accepted)
      }
      await new Promise<void>((resolve) => server.close(() => resolve()))
    },
  }
}
