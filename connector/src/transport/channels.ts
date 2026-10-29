/**
 * 传输面的**通道注册表**：每个"连接方式"一个通道，各自独立启停。
 *
 * ## 它解决什么
 *
 * 传输面原来是一把开关：`startTransport` / `stopTransport` 同时起停**拨号连接
 * （中转）与直连监听面**，`transportRunning` 一个布尔。2026-10-17 用户原话：
 * 「不是有两中方式为啥就一个开关？……后面我要是再加新的方式也就一个开关吗？」
 *
 * 所以传输面按**方式**建模：每个通道有 id / 标签 / start / stop / running，
 * 管理面与 UI 都按注册表枚举渲染。**加第三种方式（Tailscale、服务器中转……）
 * 只是往注册表加一个端口** —— 管理面路由与 UI 开关的形状不变，这条由
 * `tests/admin-face.test.ts`（路由按通道生成）与 `tests/client-panel.test.ts`
 * （UI 按通道枚举）两道断言钉住。
 *
 * ## 两条通道的语义差异（停一条不碰另一条）
 *
 * - `relay`（中转拨号）：`relay-link.ts` 的控制连接 + 每设备一条数据连接，
 *   断开自愈（退避重连）。停它 = 关控制面与所有数据连接，**不碰**直连。
 * - `direct`（直连监听）：`listener.ts` 的 WS 服务端 + 已接受的连接。
 *   停它 = 停止接受并关掉已接受的连接（`tests/listener.test.ts` 有覆盖），
 *   **不碰**中转。
 *
 * 两条路各自持独立的 Connection 对象（`listener.ts` 文件头"为什么不复用拨号
 * 那条连接"），所以"停一条"在代码路径上就是可能的，不需要加锁或仲裁。
 *
 * ## 失败必须带到界面上
 *
 * 启动单条通道失败（端口被占）时错误**原样抛出**，由管理面归一成 400 + 原因
 * （照 `routes.ts` 的 `badRequest` 模式），通道保持"未运行"。静默失败会让
 * 操作者以为开关生效了。
 */

/** 一个通道的当前状态（管理面与 UI 的唯一数据源）。 */
export interface ChannelState {
  /** 稳定 id（`relay` / `direct`）。URL 与 UI 都用它，不改名。 */
  readonly id: string
  /** 给人看的标签（界面词，与协议字段无关）。 */
  readonly label: string
  /** 此刻在跑吗。 */
  readonly running: boolean
  /**
   * 跑着的这条**真的连上了吗**。只有"拨出去"的通道有这件事实（中转控制面）；
   * 直连是监听面，没有"连上"这个状态，所以缺省不报。
   *
   * 面板的「连接」卡要答"手机那头通没通"，`running` 答不了
   * （`start()` 之后到 `open` 之前也是 running）。
   */
  readonly connected?: boolean
  /** 一行事实：拨向哪 / 监听在哪 / 为什么没配。 */
  readonly detail: string
}

/** 一个通道的端口。装配层（`index.ts`）提供，本模块不认识连接细节。 */
export interface ChannelPort {
  readonly id: string
  readonly label: string
  running(): boolean
  /** 「真的连上了吗」。只有拨出去的通道给得出，直连不给。 */
  connected?(): boolean
  /** 启动。失败（端口被占等）**抛出**，由调用方把原因带回界面。 */
  start(): Promise<void>
  /** 停止。幂等。 */
  stop(): Promise<void>
  /** 当前事实的一行描述（拨向地址 / 监听地址 / 未配置原因）。 */
  detail(): string
}

export interface TransportChannels {
  /** 全部通道的当前状态。顺序即注册顺序（常用在前）。 */
  channels(): readonly ChannelState[]
  /** 起（`running: true`）或停（`running: false`）一条通道。 */
  setChannel(id: string, running: boolean): Promise<void>
}

/**
 * 建通道注册表。
 *
 * @param ports - 通道端口。**加一种方式就是往这个数组加一项** —— 管理面路由
 *   （`routes.ts` 按 `channels()` 生成）与 UI（`client.js` 按同一个列表渲染）
 *   自动跟上，这是"形状不变"的机械保证。
 */
export function createTransportChannels(ports: readonly ChannelPort[]): TransportChannels {
  return {
    channels: () => ports.map((port) => ({
      id: port.id,
      label: port.label,
      running: port.running(),
      // 只在端口给得出时带上：不给就是"这个通道没有这个事实"，
      // 而不是"连上了/没连上"。
      ...(port.connected === undefined ? {} : { connected: port.connected() }),
      detail: port.detail(),
    })),
    async setChannel(id, running) {
      const port = ports.find((candidate) => candidate.id === id)
      // 不认识的 id **不当成功**：那会让界面显示"已启动"而实际上什么都没发生。
      if (port === undefined) throw new Error(`未知传输通道：${id}`)
      if (running) {
        await port.start()
      } else {
        await port.stop()
      }
    },
  }
}

/** 直连通道未配置（`listenPort: 0`）时的一行事实。 */
export const DIRECT_UNCONFIGURED = '未配置监听端口（listenPort: 0）'

/** 把通道列表压成一行日志（`中转拨号:运行中 直连监听:未运行`）。 */
export function describeChannels(states: readonly ChannelState[]): string {
  return states.map((state) => `${state.label}:${state.running ? '运行中' : '未运行'}`).join(' ')
}
