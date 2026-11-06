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
 * ## 默认只报"主机的 IP"
 *
 * 监听面枚举全部非内部网卡是**候选池**（`transport/listener.ts:134-138` 刻意不按
 * 网卡名过滤：猜名字又脆又漏）。但**自报给手机**的默认集合不是整个候选池 ——
 * 一台装了 VMware 的机器会多出两条永远拨不通的 `192.168.x.1`，三条 IPv6 GUA，
 * 手机上每一条都占一行（2026-11-06 真机原话："能用的就是主机的 IP 地址吧？"）。
 *
 * 所以默认集合是 {@link defaultDirectUrls}：**默认路由那张网卡的 IPv4**
 * （`lan-address.ts:40` 的内核选路，不发包），拿不到 hint 时只敢报唯一一条候选。
 * 其余地址要用户显式 `extra` 才上报；`hide` 仍然对默认那条生效。
 *
 * 顺序：direct 先于 relay；direct 内部默认路由的地址排第一（现在默认集合通常
 * 只有它一条，排序是为"用户追加了 extra"时的稳定顺序）。
 */
export function describeEndpoints(input: {
  relayUrl?: string | undefined
  lanHint?: string | null
  listener?: Listener | null
  /**
   * 用户对**上报哪些地址**的显式表态（`url → 'hide' | 'extra'`）。
   *
   * 为什么需要它：默认集合只含主地址，但一台机器可能有第二条真的可拨的网
   * （Tailscale / 第二张网卡）。`extra` 让用户点名上报；`hide` 让用户把默认那条
   * 也藏掉（例如默认路由是 WAN，手机其实在同网段的另一张网卡上）。
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
  const listenerUrls = input.listener?.urls ?? []
  const defaults = defaultDirectUrls(listenerUrls, input.lanHint)
  const direct = listenerUrls
    .filter((entry) => defaults.has(entry.url) && !hidden.has(entry.url))
    .sort((a, b) => hintRank(a.url, input.lanHint) - hintRank(b.url, input.lanHint))
  for (const entry of direct) {
    endpoints.push({ kind: 'direct', url: entry.url, ...(entry.label === '' ? {} : { label: entry.label }) })
  }
  // 用户额外加的地址按字面原样上报 —— 它可能不在网卡枚举里，所以没有网卡名可带。
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

/**
 * 默认上报的直连地址集合。
 *
 * 判据只有两条，按优先级：
 * 1. **默认路由那张网卡**（`lanHint`）：内核选路得来的 IPv4 就是手机同一局域网时
 *    最可能拨通的那条；同 IP 出现在多张网卡上也只报它。
 * 2. 拿不到 hint 时**只有唯一一条候选**才默认报：那可能是显式绑定到某个地址
 *    （`listenHost` 不是 `0.0.0.0`），也可能是单网卡机器。多候选且没有 hint
 *    就不猜 —— 让用户从「更多地址」里点名上报，比替他选一条可靠的。
 *
 * 返回的是**完整 URL 集合**（端口也在内），因为上报/隐藏都按 URL 键控。
 *
 * Note: 为什么默认只报主地址、为什么多候选不猜 —— 见
 * `.agents/notes/implemented/2026-11-06-default-advertise-main-ip.md`
 */
export function defaultDirectUrls(
  urls: readonly { url: string }[],
  lanHint: string | null | undefined,
): ReadonlySet<string> {
  const hint = lanHint
  if (hint !== null && hint !== undefined && hint !== '') {
    const matched = urls.filter((entry) => hostOf(entry.url) === hint)
    if (matched.length > 0) return new Set(matched.map((entry) => entry.url))
  }
  return urls.length === 1 ? new Set([urls[0]!.url]) : new Set()
}

/** 取 URL 的主机部分（IPv6 去掉方括号）；解析失败回空串，不猜。 */
function hostOf(url: string): string {
  try {
    return new URL(url).hostname.replace(/^\[|\]$/g, '')
  } catch {
    return ''
  }
}

/** 默认路由地址排最前（0），其余排后（1）。 */
function hintRank(url: string, hint: string | null | undefined): number {
  if (hint === null || hint === undefined || hint === '') return 1
  return hostOf(url) === hint ? 0 : 1
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
