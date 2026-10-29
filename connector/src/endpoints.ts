/**
 * 端点自报面：`endpoint.describe`（契约 §5.7、§14.6 的直连拓扑）。
 *
 * ## 它解决什么
 *
 * 手机上原来只有一个端点（配对时给的那条中转）。要让"同一局域网直连"可用，
 * 手机必须知道**往哪拨** —— 而那个地址是会变的（DHCP、切 WiFi、插网线）。
 *
 * 所以由连接器自报：它报的是**实际绑定到的**地址（`listener.urls`，
 * 来自 `os.networkInterfaces()` 枚举，不是配置里写的那个字符串），
 * 外加它知道的那条中转。手机连上后拉一次，覆盖本地缓存。
 *
 * ## 为什么不是一个新令牌 / 不是二维码字段
 *
 * - 令牌：直连面的鉴权就是握手本身（未配对设备在 `hello` 处被
 *   `protocol/not-paired` 拒）。再加一层令牌会得到两套"谁能连"的判据，
 *   而它们迟早不一致。
 * - 二维码字段：二维码是**一次性**的，而 IP 会变。用户的核心场景是
 *   "电脑不在身边"——那时没法重新出码。更根本的：那把**临时路由提示**
 *   塞进了**永久凭据包**，两种生命周期混在一起。
 *
 * 取舍与被否方案：`.agents/notes/implemented/2026-10-14-endpoint-switching-lan-direct.md`
 */
import type { Listener } from './transport/listener.js'
import { relayHintFor } from './pairing.js'
/** 一个可拨端点。**与手机侧 `core/endpoint.dart` 的 `endpointToJson` 逐字对应。** */
export interface EndpointView {
  /** `relay` 经中转（换票 + `/ws/device?ticket=`）；`direct` 局域网直连（裸 WS）。 */
  readonly kind: 'relay' | 'direct'
  /** 拨号地址。 */
  readonly url: string
  /** 给人看的名字（网卡名 / "中转"）。可缺。 */
  readonly label?: string
}

export interface EndpointsPort {
  /** 当前可拨的端点表。**顺序即偏好**：direct 先于 relay。 */
  describe(): { endpoints: EndpointView[] }
}

/**
 * 算端点表。**纯函数** —— 单测不需要真监听面。
 *
 * 顺序：direct 先于 relay；direct 内部**默认路由的地址排第一**（手机和电脑
 * 同一局域网时它就是对的，先拨先通；顺序拨号下把一个拨不通的地址排在前面
 * 等于每个超时 10 秒）。理由与手机侧 `mergeEndpoints` 的插入规则一致：
 * 第一次发现直连时它自动成为首选，与"同一局域网延迟低"的意图一致。
 * 而用户一旦在手机上手动重排，后续合并只更新字段、不再挪位。
 *
 * **relay 条目用实时提示**（[relayHintFor]）：配置里的 `relayUrl` 是拨号地址
 * （本机中转是环回），原样报给手机会多一条永远拨不通的端点；而电脑换 WiFi 后
 * 配置里的旧 IP 同样拨不通。出码与自报走同一个函数，"二维码里的地址"与
 * "端点表里的地址"因此不会是两个答案。
 */
export function describeEndpoints(input: {
  relayUrl?: string | undefined
  lanHint?: string | null
  listener?: Listener | null
  /**
   * 用户对**上报哪些地址**的显式表态（`url → 'hide' | 'extra'`）。
   *
   * 为什么需要它：监听面**按设计枚举全部非内部网卡**（`transport/listener.ts:134-138`
   * 明确不做按网卡名过滤 —— 那"又脆又漏"）。但一台装了 VMware 的机器会因此多报
   * 两条手机永远拨不通的 `192.168.x.1`。手机侧的同网段排序让它们不占时间，
   * 但它们仍然占列表位置 —— 由用户点名藏掉比猜网卡名可靠。
   *
   * `extra` 是反向的：用户想额外上报一个地址（如 Tailscale 的 `100.x`），
   * 它不在网卡枚举里，但确实是这台机器的一个可拨地址。
   */
  advertise?: ReadonlyMap<string, 'hide' | 'extra'> | undefined
}): { endpoints: EndpointView[] } {
  const settings = input.advertise ?? new Map<string, 'hide' | 'extra'>()
  const hidden = new Set<string>()
  const extra: string[] = []
  for (const [url, kind] of settings) {
    if (kind === 'hide') hidden.add(url)
    else extra.push(url)
  }

  const endpoints: EndpointView[] = []
  const direct = [...(input.listener?.urls ?? [])]
    .filter((entry) => !hidden.has(entry.url))
    .sort((a, b) => hintRank(a.url, input.lanHint) - hintRank(b.url, input.lanHint))
  for (const entry of direct) {
    endpoints.push({ kind: 'direct', url: entry.url, ...(entry.label === '' ? {} : { label: entry.label }) })
  }
  // 用户额外加的地址按字面原样上报 —— 它不在网卡枚举里，所以没有网卡名可带。
  for (const url of extra) {
    if (hidden.has(url)) continue
    if (endpoints.some((endpoint) => endpoint.url === url)) continue
    endpoints.push({ kind: 'direct', url })
  }
  if (input.relayUrl !== undefined && input.relayUrl !== '') {
    endpoints.push({
      kind: 'relay',
      url: relayHintFor(input.relayUrl, input.lanHint ?? null),
      label: '中转',
    })
  }
  return { endpoints }
}

/** 默认路由地址排最前（0），其余排后（1）。 */
function hintRank(url: string, hint: string | null | undefined): number {
  if (hint === null || hint === undefined || hint === '') return 1
  return url.includes(hint) ? 0 : 1
}

/**
 * 建端点面。
 *
 * `relayUrl` / `listener` / `lanHint` 全是**现取**（传 getter 而不是值）：
 * 监听面在挂载过程中才起、局域网地址在换 WiFi 后会变、而 `relayUrl` 还能被面板
 * 热改（`loader/volatile-update`）—— `endpoint.describe` 可能在之后的任何时刻被调，
 * 取到的必须是当时的真值。
 */
export function createEndpointsPort(deps: {
  relayUrlOf: () => string | undefined
  lanHintOf: () => string | null
  listenerOf: () => Listener | null
  /** 用户显式藏掉 / 额外加的上报地址（现取：管理面随时可改）。 */
  advertiseOf?: () => ReadonlyMap<string, 'hide' | 'extra'>
}): EndpointsPort {
  return {
    describe() {
      return describeEndpoints({
        relayUrl: deps.relayUrlOf(),
        lanHint: deps.lanHintOf(),
        listener: deps.listenerOf(),
        advertise: deps.advertiseOf?.(),
      })
    },
  }
}
