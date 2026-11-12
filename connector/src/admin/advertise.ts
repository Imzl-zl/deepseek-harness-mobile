/**
 * 「上报哪些地址」的管理面。
 *
 * ## 它解决什么
 *
 * 直连监听面**按设计枚举全部非内部网卡**（`transport/listener.ts:143-167`：
 * "过滤虚拟网卡靠名字匹配，又脆又漏"），这是**候选池**，不是上报集合。
 * 默认上报的只有默认路由那张网卡的 IPv4（`endpoints.ts` 的 `defaultDirectUrls`）；
 * 一台装了 VMware 的机器因此不会再把两条拨不通的 `192.168.x.1` 摆到手机上。
 * 其余候选走「更多地址（N）」折叠区，用户点名 `extra` 才上报；`hide` 可藏默认那条。
 *
 * 反向的需求同样存在：想额外上报一个**不在网卡枚举里**的地址
 * （典型：Tailscale 的 `100.x`，`isNonPublicHost` 认它属于 CGNAT）。
 *
 * ## 为什么存在存储里而不是配置文件
 *
 * 这是操作者随时会改的运行期偏好。放进 `cordis.patch.yml` 等于让
 * "藏掉一条垃圾地址"变成一次"改配置 + 重启"的部署动作。
 *
 * ## 校验只在写入处
 *
 * 监听面本身**不终结 TLS**（`transport/listener.ts`），所以地址分两档，判据与
 * 手机侧手填同一套（`app/lib/core/endpoint.dart` 的 `isPrivateOrLoopback`）：
 *
 * - `ws://` 只收非公网：明文直连只在局域网 / 回环 / CGNAT 里有意义；把明文
 *   指到公网等于把元数据摊开，而那一档要用户在**手机上**逐次确认，面板不替他拍板。
 * - `wss://` 收任意主机：TLS 由外部终结（反向代理 / frp / `tailscale serve`），
 *   于是"公网地址也能直连"成立，且这里是**唯一**能被手机自动发现的入口
 *   （手填那条在手机上一次一条，换地址就得再填）。
 *
 * 为什么"公网只能走中转"被撤掉：见
 * `.agents/notes/implemented/2026-11-10-direct-endpoint-accepts-wss.md`。
 */
import { isNonPublicHost } from '../transport/relay-url.js'

/** 上报地址的显式表态（key = url）。 */
export type AdvertiseKind = 'hide' | 'extra'

export interface AdvertiseTablePort {
  get(key: string): { kind: AdvertiseKind } | undefined
  keys(): Iterable<string>
  put(key: string, value: { kind: AdvertiseKind }): Promise<void>
  delete(key: string): Promise<boolean>
}

/** 一条可拨地址（网卡枚举的结果，或用户追加的）。 */
export interface AdvertiseCandidate {
  url: string
  label?: string
}

/** 管理面读到的形状。 */
export interface AdvertiseView {
  /** 当前**会**上报的地址，带来源。 */
  advertised: { url: string; label?: string; source: 'auto' | 'extra' }[]
  /** 被藏掉的地址（仍在网卡上，只是不报）。 */
  hidden: string[]
  /**
   * 网卡上有、但**默认不上报**的地址（「更多地址 N」折叠区）。
   *
   * 默认集合只含主地址（`endpoints.ts` 的 `defaultDirectUrls`）：VMware 虚拟网卡、
   * 轮换出来的 IPv6 GUA 都在这里。它们仍然可拨（用户点名上报），只是不该一上来
   * 就占手机上的端点列表。
   */
  folded: AdvertiseCandidate[]
  /** 网卡枚举出来的全部地址（含被藏掉的），供界面画开关。 */
  candidates: AdvertiseCandidate[]
}

export function advertiseMapOf(
  table: AdvertiseTablePort | null,
): Map<string, AdvertiseKind> {
  const out = new Map<string, AdvertiseKind>()
  if (table === null) return out
  for (const url of table.keys()) {
    const row = table.get(url)
    if (row !== undefined) out.set(url, row.kind)
  }
  return out
}

/** 写入口的校验失败（归一成 400 带回界面）。 */
export class AdvertiseError extends Error {}

/**
 * 校验一条 `extra` 地址：`ws://` 限非公网，`wss://` 不限 —— 理由见文件头。
 *
 * `hide` 不需要校验：它只会让某个已有地址不上报，不引入新拨号面。
 */
export function assertExtraAddress(url: string): void {
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    throw new AdvertiseError(`地址解析失败：${url}`)
  }
  if (parsed.protocol !== 'ws:' && parsed.protocol !== 'wss:') {
    throw new AdvertiseError('直连地址必须是 ws://（局域网）或 wss://（外部终结 TLS）')
  }
  if (parsed.username !== '' || parsed.password !== '' || parsed.hash !== '' || parsed.search !== '') {
    throw new AdvertiseError('地址不能带凭据、查询参数或片段')
  }
  // `wss://` 到此为止：主机是不是公网不影响可行性（TLS 已由外部终结）。
  if (parsed.protocol === 'wss:') return
  const host = parsed.hostname.replace(/^\[|\]$/g, '')
  if (!isNonPublicHost(host)) {
    throw new AdvertiseError('公网直连要用 wss://（ws:// 明文仅限局域网 / 回环 / CGNAT）')
  }
}

export interface AdvertiseAdmin {
  view(): AdvertiseView
  /**
   * 设定一条表态。
   *
   * - `hide`：把这条自报地址藏掉（仍在网卡上）。
   * - `extra`：额外上报一条地址（校验见 `assertExtraAddress`）。
   * - `clear`：清掉这条的表态（回到默认：自报的报、追加的不报）。
   */
  set(url: string, kind: AdvertiseKind | 'clear'): Promise<void>
}

export function createAdvertiseAdmin(deps: {
  tableOf: () => AdvertiseTablePort | null
  candidatesOf: () => readonly AdvertiseCandidate[]
  /**
   * 默认会上报的候选（`endpoints.ts` 的 `defaultDirectUrls` 算出来的那一组）。
   *
   * **必须由调用方给**，不在这里重新判"哪张网卡是主网卡"：默认路由是内核选路
   * 的事实，只有 `lan-address.ts` 那一处知道；这里再猜一份就是第二套判据。
   */
  defaultUrlsOf: () => ReadonlySet<string>
}): AdvertiseAdmin {
  return {
    view() {
      const table = deps.tableOf()
      const settings = advertiseMapOf(table)
      const candidates = [...deps.candidatesOf()]
      const defaults = deps.defaultUrlsOf()
      const hidden: string[] = []
      const folded: AdvertiseCandidate[] = []
      const advertised: AdvertiseView['advertised'] = []
      for (const candidate of candidates) {
        const setting = settings.get(candidate.url)
        if (setting === 'hide') {
          hidden.push(candidate.url)
          continue
        }
        if (setting === 'extra' || defaults.has(candidate.url)) {
          advertised.push({
            url: candidate.url,
            ...(candidate.label === undefined ? {} : { label: candidate.label }),
            source: setting === 'extra' ? 'extra' : 'auto',
          })
          continue
        }
        // 网卡上确实有，但默认集合没选它：进折叠区，等用户点名上报。
        folded.push({
          url: candidate.url,
          ...(candidate.label === undefined ? {} : { label: candidate.label }),
        })
      }
      for (const [url, kind] of settings) {
        if (kind !== 'extra') continue
        if (advertised.some((entry) => entry.url === url)) continue
        advertised.push({ url, source: 'extra' })
      }
      return { advertised, hidden, folded, candidates }
    },

    async set(url, kind) {
      const table = deps.tableOf()
      if (table === null) throw new AdvertiseError('存储还没就绪')
      if (kind === 'clear') {
        await table.delete(url)
        return
      }
      if (kind === 'extra') assertExtraAddress(url)
      await table.put(url, { kind })
    },
  }
}
