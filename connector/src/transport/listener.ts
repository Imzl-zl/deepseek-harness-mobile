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
import { networkInterfaces } from 'node:os'

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

/** 一个可拨地址（带给人看的名字）。 */
export interface DialableUrl {
  readonly url: string
  readonly label: string
}

export interface Listener {
  /** 实际监听的端口（`port: 0` 时由系统分配）。 */
  readonly port: number
  /** 当前活着的被接受连接数。 */
  readonly active: number
  /**
   * **实际可拨**的地址（`ws://<ip>:<port>`），已滤掉内部地址、已去重。
   *
   * 为什么不直接用配置里的 `host`：配 `0.0.0.0` 时它不是一个可拨地址，
   * 而手机要的是"往哪拨"。所以这里按 `host` 是不是通配地址分两支：
   * 通配 → 枚举非内部网卡；具体地址 → 就用它。
   */
  readonly urls: readonly DialableUrl[]
  close(): Promise<void>
}

/// 通配地址：配了它就意味着"所有网卡"，可拨地址要另行枚举。
const WILDCARD_HOSTS = new Set(['', '0.0.0.0', '::', '[::]'])

/**
 * 算出这个监听面的可拨地址。
 *
 * 每条带上网卡名 —— 手机上显示"同一网络(Wi-Fi)"比显示一个 IP 有用，
 * 而切网卡时列表自己变（这正是"发现"的意义）。
 */
function dialableUrls(host: string, port: number): { url: string; label: string }[] {
  const base = WILDCARD_HOSTS.has(host) ? null : normalizeHost(host)
  const out: { url: string; label: string }[] = []
  const seen = new Set<string>()

  const push = (address: string, label: string): void => {
    // IPv6 要括起来：`ws://[fe80::1]:8788`，否则端口会被当成地址的一部分。
    const wrapped = address.includes(':') && !address.startsWith('[')
      ? `[${address}]`
      : address
    const url = `ws://${wrapped}:${port}`
    if (seen.has(url)) return
    seen.add(url)
    out.push({ url, label })
  }

  if (base !== null) {
    push(base, host)
    return out
  }

  for (const [name, entries] of Object.entries(networkInterfaces())) {
    // `Object.entries` 的值类型是 `T | undefined`（TS 的索引签名语义）——
    // 运行时不会缺，但类型上要收窄，否则就是在骗编译器。
    if (entries === undefined) continue
    for (const entry of entries) {
      // **内部地址不过线**：`127.0.0.1` 拨不进来（手机不在本机），
      // 而把它报出去会让手机上多一条永远拨不通的端点。
      if (entry.internal) continue
      // 只要 IPv4 与 IPv6 的全球/本地地址；link-local 的 IPv6 需要作用域 id
      // （`fe80::1%eth0`），URL 里带 `%` 会被当成转义，所以跳过。
      if (entry.family === 'IPv6' && entry.address.toLowerCase().startsWith('fe80')) continue
      // **全部上报，不按网卡名过滤**：哪些地址手机拨得通，电脑侧无从得知
      // （这台机器同时有以太网与 WiFi，还有 VMware 虚拟网卡）。过滤虚拟网卡
      // 靠名字匹配，又脆又漏；真正的答案在**顺序**——默认路由的地址排第一
      // （`dialableUrls` 的调用方给 `hint`），手机先拨先通，其余留作回落。
      push(entry.address, name)
    }
  }
  // **IPv4 排在前**：手机的常见情形是同局域网 IPv4 直连，而拨号是**顺序**的 ——
  // 2026-10-17 真机实测：这台电脑的 WiFi 网卡有三个拨不通的 IPv6 GUA
  // （隐私扩展轮换出来的），枚举顺序把它们排在最前，手机每个等满 10s 超时，
  // 冷启动 30 秒才连上（用户原话"退出软件怎么就连不上了"）。IPv4 先拨，
  // 毫秒级就通；IPv6 留作回落（原生 IPv6 局域网仍然可用）。
  out.sort((a, b) => familyRank(a.url) - familyRank(b.url))
  return out
}

/// IPv4 在前、IPv6 在后（URL 里含 `:` 且带方括号的是 IPv6 字面量）。
function familyRank(url: string): number {
  return url.includes('[') ? 1 : 0
}

/// 去掉 IPv6 字面量的方括号（`[::]` → `::`），其余原样。
function normalizeHost(host: string): string {
  return host.startsWith('[') && host.endsWith(']') ? host.slice(1, -1) : host
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
  const urls = dialableUrls(options.host ?? '127.0.0.1', bound)
  log?.info(
    `直连监听面已就绪：${urls.map((u) => u.url).join(' / ') || 'ws://' + (options.host ?? '127.0.0.1') + ':' + bound}`
    + '（TLS 由外部终结）',
  )

  return {
    port: bound,
    get active() {
      return connections.size
    },
    get urls() {
      return urls
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
