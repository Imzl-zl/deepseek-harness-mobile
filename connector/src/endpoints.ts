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
  // **监听面没起 ⇒ 一条直连地址都不报**（含用户 `extra` 点名的那几条）。
  //
  // `extra` 的语义是"额外上报哪几条地址"，不是"凭空造一条能拨的路"：
  // 监听面停着的时候，任何直连地址都拨不通，报出去就是撒谎。
  // 2026-11-14 真机验收踩到 —— 直连停了，二维码还宣称局域网可用
  // （`lanAvailable` 为真），手机拿到一张配不上的码。
  const listening = input.listener !== null && input.listener !== undefined
  const direct = listening
    ? listenerUrls
      .filter((entry) => defaults.has(entry.url) && !hidden.has(entry.url))
      .sort((a, b) => hintRank(a.url, input.lanHint) - hintRank(b.url, input.lanHint))
    : []
  for (const entry of direct) {
    endpoints.push({ kind: 'direct', url: entry.url, ...(entry.label === '' ? {} : { label: entry.label }) })
  }
  // 用户额外加的地址按字面原样上报 —— 它可能不在网卡枚举里，所以没有网卡名可带。
  // **仍然以监听面在跑为前提**（见上）。
  if (listening) {
    for (const url of extra) {
      if (hidden.has(url)) continue
      if (endpoints.some((endpoint) => endpoint.url === url)) continue
      endpoints.push({ kind: 'direct', url })
    }
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
 * 默认上报的直连地址集合。**最多一条**。
 *
 * 判据按顺序：
 * 1. `lanHint`（默认路由那张网卡的 IPv4）命中一条**非虚拟**候选 ⇒ 就报它。
 *    普通机器（默认路由 = 局域网）走的正是这一条，与旧判据逐字一致。
 * 2. hint 拿不到 / 已过期 / 指向虚拟网卡 ⇒ 在**真实局域网 IPv4** 里选一条：
 *    只认 RFC1918 三段（`192.168/16` → `172.16/12` → `10/8` 偏好序），
 *    同段取枚举顺序第一条。
 * 3. 以上都没有 ⇒ **只有唯一一条非虚拟候选**才报（显式绑定 `listenHost` / 单网卡机器）。
 *
 * **虚拟网卡（TUN / VMware / Hyper-V / Docker，按 MAC OUI 认定）一律不进默认集合**，
 * 即使它是唯一候选 —— 那种机器确实没有手机拨得通的局域网地址，该走中转。
 * 不猜一条：一条拨不通的地址上码只会让手机白等超时。
 *
 * 其余候选（VMware 虚拟网卡、轮换出来的 IPv6 GUA、Tailscale 的 CGNAT）进「更多地址」
 * 折叠区，用户点名 `extra` 才上报；`extra` 是显式表态，不受上面的判据约束。
 *
 * ## 为什么不再以 `lanHint` 为准（2026-11-20）
 *
 * 旧判据是"只报 `lanHint` 命中的那条"，它默认**默认路由所在的网卡就是局域网网卡**。
 * 开代理 / VPN（TUN 模式）时这个前提不成立：内核选路会落到 TUN 虚拟网卡上
 * （实测 `198.18.0.1`），于是
 *
 * - TUN 在候选池里 ⇒ 上报拨不通的 TUN 地址；
 * - `lanHint` 刷新后匹配不上 ⇒ 多候选下**一条都不报** ⇒ 出码报"没有可上报的地址"。
 *
 * 两种坏法同一天在同一个用户身上出现过。而"哪条地址是局域网"是**地址自己**的
 * 事实（RFC1918 段），不需要问内核 —— 内核只回答"先拨哪条"，那是排序问题。
 *
 * 判据与 `transport/relay-url.ts` 的 `isNonPublicHost` 同源：那个函数回答的是
 * "要不要放行明文"，粒度更宽（含 CGNAT / link-local / ULA）；这里只认
 * **家用/公司局域网 IPv4** 三个段 —— TUN 的 `198.18/15`、CGNAT 的 `100.64/10`
 * 属于"手机拨不通"，不该进默认集合。
 *
 * 返回的是**完整 URL 集合**（端口也在内），因为上报/隐藏都按 URL 键控。
 *
 * Note: 为什么是"地址是不是局域网"而不是"默认路由是谁" —— 见
 * `.agents/notes/implemented/2026-11-20-advertise-by-address-not-by-default-route.md`；
 * 旧判据的来历与被取代的代价 —— 见
 * `.agents/notes/implemented/2026-11-06-default-advertise-main-ip.md`。
 */
export function defaultDirectUrls(
  urls: readonly { url: string; virtual?: boolean }[],
  lanHint: string | null | undefined,
): ReadonlySet<string> {
  // **虚拟网卡先排除**：TUN 的 `198.18.0.1`（FlClash）与 VMware 的 `192.168.x.1`
  // 都落在可拨网段里，单看地址分不出来 —— 而它们手机都拨不通。
  // 判据来自监听面带出的 MAC 事实（`transport/listener.ts` 的 `isVirtualMac`）。
  const real = urls.filter((entry) => entry.virtual !== true)

  // 1. `lanHint`（默认路由那张网卡的 IPv4）命中一条**真实**网卡 ⇒ 就报它。
  //    TUN 抢走默认路由时 hint 指向的是虚拟网卡，这一步自然落空，
  //    于是走到第 2 条 —— 这正是 2026-11-20 要修的那个洞。
  const hint = lanHint ?? ''
  if (hint !== '') {
    const matched = real.filter((entry) => hostOf(entry.url) === hint)
    if (matched.length > 0) return new Set(matched.map((entry) => entry.url))
  }

  // 2. hint 拿不到 / 已过期 / 指向虚拟网卡：**在真实局域网 IPv4 里选**。
  //    仍然只报一条（手机端点列表不该被多条地址占满 —— 2026-11-06 用户的
  //    原话是"能用的就是主机的 IP 地址吧？这不是多余？"）。
  //    选哪条：`192.168/16` 先于 `172.16/12` 先于 `10/8`
  //    （家用/公司最常见的网段排前面），同段取枚举顺序第一条。
  const lan = real.filter((entry) => isLanIpv4(hostOf(entry.url)))
  if (lan.length > 0) {
    const best = [...lan].sort(
      (a, b) => lanRank(hostOf(a.url)) - lanRank(hostOf(b.url)),
    )[0]!
    return new Set([best.url])
  }

  // 3. 没有真实局域网地址：唯一一条候选（显式绑定 `listenHost` / 单网卡机器）才报。
  //    **虚拟标过的不算** —— 那是"知道拨不通"的地址。
  if (real.length === 1) return new Set([real[0]!.url])
  return new Set()
}

/**
 * 局域网网段的偏好序：`192.168/16` → `172.16/12` → `10/8`。
 *
 * 这只是**顺序**，不是"报不报"：三段都是 RFC1918 私有网段，都合法。
 * 家用路由器出厂默认几乎都是 `192.168.0/24` 或 `192.168.1/24`，
 * 所以它排前面命中率最高。
 */
function lanRank(host: string): number {
  if (host.startsWith('192.168.')) return 0
  if (host.startsWith('172.')) return 1
  return 2 // 10/8
}

/**
 * 这是不是一个**手机在同一局域网里拨得通**的 IPv4（`ws://` / `wss://` URL 也行）。
 *
 * 只认 RFC1918 的三段：`10/8`、`172.16/12`、`192.168/16`。
 * **不认** CGNAT（`100.64/10`，Tailscale 等组网用它 —— 那是另一条路，
 * 用户点名 `extra` 才该上码）、**不认** TUN 的 `198.18/15`、**不认**回环。
 *
 * 导出是给"报错文案要按同一判据分档"用的（`index.ts` 的 `listenerNoAddressReason`）——
 * 文案与判据说两套话，就会在用户最需要准确的时刻给出一句错话。
 */
export function isLanAddress(url: string): boolean {
  return isLanIpv4(hostOf(url))
}

function isLanIpv4(host: string): boolean {
  const parts = host.split('.')
  if (parts.length !== 4) return false
  const octets: number[] = []
  for (const part of parts) {
    if (part === '' || part.length > 3) return false
    const value = Number(part)
    if (!Number.isInteger(value) || value < 0 || value > 255) return false
    octets.push(value)
  }
  if (octets.length !== 4) return false
  const [a, b] = octets as [number, number, number, number]
  if (a === 10) return true
  if (a === 172 && b >= 16 && b <= 31) return true
  if (a === 192 && b === 168) return true
  return false
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
