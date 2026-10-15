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
 * 顺序：direct 先于 relay。理由与手机侧 `mergeEndpoints` 的插入规则一致：
 * 第一次发现直连时它自动成为首选，与"同一局域网延迟低"的意图一致。
 * 而用户一旦在手机上手动重排，后续合并只更新字段、不再挪位。
 */
export function describeEndpoints(input: {
  relayUrl?: string | undefined
  listener?: Listener | null
}): { endpoints: EndpointView[] } {
  const endpoints: EndpointView[] = []
  for (const entry of input.listener?.urls ?? []) {
    endpoints.push({ kind: 'direct', url: entry.url, ...(entry.label === '' ? {} : { label: entry.label }) })
  }
  if (input.relayUrl !== undefined && input.relayUrl !== '') {
    endpoints.push({ kind: 'relay', url: input.relayUrl, label: '中转' })
  }
  return { endpoints }
}

/**
 * 建端点面。
 *
 * `listener` 是**现取**的（传 getter 而不是值）：监听面在挂载过程中才起，
 * 而 `endpoint.describe` 可能在之后的任何时刻被调。
 */
export function createEndpointsPort(deps: {
  relayUrl: string | undefined
  listenerOf: () => Listener | null
}): EndpointsPort {
  return {
    describe() {
      return describeEndpoints({
        relayUrl: deps.relayUrl,
        listener: deps.listenerOf(),
      })
    },
  }
}
