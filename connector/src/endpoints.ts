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
 * ## 默认集合 = 此刻的**全部局域网 IPv4**
 *
 * 监听面枚举全部非内部网卡是**候选池**（`transport/listener.ts` 刻意不按网卡名
 * 或 MAC 过滤）。但上报给手机的默认集合只取**地址本身是局域网段**的那些
 * （{@link autoAdvertisedUrls} 的判据 `isLanAddress`：`10/8`、`172.16/12`、
 * `192.168/16`）。
 *
 * 这条判据只回答"这个地址是不是局域网"，**不猜哪一条手机拨得通**：
 * 那是手机自己拨一次才知道的事（码里全给，手机先通先用）。所以这里不再按
 * 默认路由/网卡挑唯一一条 —— 那种猜法在开代理 TUN、有线 + WiFi 双网卡的机器上
 * 会把真实地址筛掉或把拨不通的地址报出去（2026-11-20、2026-11-24 两次都是它）。
 *
 * 其余候选（IPv6 GUA、CGNAT、TUN 的 `198.18/15`）进「更多地址」折叠区，
 * 用户点名 `extra` 才上报；`hide` 仍对默认集合生效。
 *
 * 顺序：direct 先于 relay；direct 内部**默认路由那条排第一**（`lanHint` 只当排序，
 * 不当判据），其余按 `192.168 → 172.16 → 10` 段序。
 */
export function describeEndpoints(input: {
  relayUrl?: string | undefined
  lanHint?: string | null
  listener?: Listener | null
  /**
   * 用户对**上报哪些地址**的显式表态（`url → 'hide' | 'extra'`）。
   *
   * 为什么需要它：默认集合只含局域网 IPv4，但一台机器可能有另一条真的可拨的网
   * （Tailscale / 第二张网卡 / 外部终结 TLS 的 wss）。`extra` 让用户点名上报；
   * `hide` 让用户把某条局域网地址也藏掉（例如那条其实是虚拟网卡的 host-only 网段）。
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
  const defaults = autoAdvertisedUrls(listenerUrls, settings)
  // **监听面没起 ⇒ 一条直连地址都不报**（含用户 `extra` 点名的那几条）。
  //
  // `extra` 的语义是"额外上报哪几条地址"，不是"凭空造一条能拨的路"：
  // 监听面停着的时候，任何直连地址都拨不通，报出去就是撒谎。
  // 2026-11-14 真机验收踩到 —— 直连停了，二维码还宣称局域网可用
  // （`lanAvailable` 为真），手机拿到一张配不上的码。
  const listening = input.listener !== null && input.listener !== undefined
  const direct = listening
    ? listenerUrls
      .filter((entry) => defaults.has(entry.url))
      .sort((a, b) => hintRank(a.url, input.lanHint) - hintRank(b.url, input.lanHint)
        || lanRank(hostOf(a.url)) - lanRank(hostOf(b.url)))
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
 * 默认会上报的地址集合：**此刻枚举到的全部局域网 IPv4**（{@link isLanAddress}），
 * 减去用户 `hide` 的。
 *
 * 判据只看**地址本身**，不看网卡名、不看 MAC、不看默认路由 —— 一台机器的
 * 默认路由可能被代理 TUN 抢走（`198.18.0.1`），而真实局域网地址一直在候选池里。
 * "这个地址是不是局域网段"是地址自己的事实，不需要问内核，也不需要猜。
 *
 * 为什么不再只报一条：只报一条就必须猜"哪条对"，而**哪条拨得通只有手机知道**。
 * 猜错的表现是"码里写着死地址"或"明明有局域网却说没有"（2026-11-20 / 2026-11-24）。
 * 现在全给，手机并行拨；配对成功后端点表只留拨通的那条（手机侧收敛）。
 *
 * Note: 取代"默认路由那张网卡 + 虚拟网卡 MAC 判据" —— 见
 * `.agents/notes/implemented/2026-11-24-offer-carries-current-lan-addresses.md`
 * 与被它取代的 `.agents/notes/implemented/2026-11-20-advertise-by-address-not-by-default-route.md`。
 */
export function autoAdvertisedUrls(
  urls: readonly { url: string }[],
  settings: ReadonlyMap<string, 'hide' | 'extra'> = new Map(),
): ReadonlySet<string> {
  const out = new Set<string>()
  for (const entry of urls) {
    if (settings.get(entry.url) === 'hide') continue
    if (!isLanAddress(entry.url)) continue
    out.add(entry.url)
  }
  return out
}

/**
 * 「直连开着，但没有一条局域网地址可上报」时的**如实原因**。
 *
 * 调用前提：{@link autoAdvertisedUrls} 算出来是空的（出码那一侧正是这么用的）。
 * 三档，每档都对应一个可验证的事实：
 *
 * 1. 一条地址都没枚举到；
 * 2. 有地址，但没有一条是局域网 IPv4（只剩组网 / IPv6 / TUN 段）；
 * 3. 有局域网 IPv4，那就只可能是被用户 `hide` 掉了。
 *
 * 为什么单独一个函数：**文案与判据必须同源**。以前文案在 `index.ts` 里自己分档，
 * 判据改动一次文案就撒一次谎（2026-11-20 与 2026-11-24 各一次）。
 */
export function noLanAddressReason(candidates: readonly { url: string }[]): string {
  if (candidates.length === 0) {
    return '直连监听已启动，但没有枚举到任何网卡地址'
  }
  if (!candidates.some((entry) => isLanAddress(entry.url))) {
    return '直连监听已启动，但没有局域网 IPv4 地址'
      + '（现有的是组网或 IPv6）。可在「上报给手机的地址」里手动添加一条'
  }
  return '直连监听已启动，但局域网地址都被「上报给手机的地址」里删掉了'
    + '（展开「更多地址」可恢复，或点「恢复」把删掉的加回来）'
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
