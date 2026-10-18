/**
 * 「上报哪些地址」的管理面。
 *
 * ## 它解决什么
 *
 * 直连监听面**按设计枚举全部非内部网卡**（`transport/listener.ts:134-138`：
 * "过滤虚拟网卡靠名字匹配，又脆又漏"）。一台装了 VMware 的机器因此会多报
 * 两条手机永远拨不通的 `192.168.x.1`。手机侧的同网段排序让它们不占时间
 * （`core/endpoint.dart` 的 `dialOrder`），但它们仍然占列表位置 ——
 * **由用户点名藏掉，比猜网卡名可靠**。
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
 * 直连地址是**明文 `ws://` + 非公网**（电脑侧监听面刻意不终结 TLS，
 * `transport/listener.ts` 的"不终结 TLS"）。公网地址要走中转，不在这里 ——
 * 所以 `extra` 只收 `ws://` + 非公网，**与手机侧的手填校验同一个判据**
 * （`app/lib/core/endpoint.dart` 的 `isPrivateOrLoopback`；两侧的对齐由
 * `tests/relay-url-nonpublic.test.ts` 用同一批地址钉住）。
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
  /** 被藏掉的自报地址（仍在网卡上，只是不报）。 */
  hidden: string[]
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
 * 校验一条 `extra` 地址。**只收 `ws://` + 非公网** —— 理由见文件头。
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
  if (parsed.protocol !== 'ws:') {
    throw new AdvertiseError('直连地址必须是 ws://（电脑侧监听面不终结 TLS）')
  }
  if (parsed.username !== '' || parsed.password !== '' || parsed.hash !== '' || parsed.search !== '') {
    throw new AdvertiseError('地址不能带凭据、查询参数或片段')
  }
  const host = parsed.hostname.replace(/^\[|\]$/g, '')
  if (!isNonPublicHost(host)) {
    throw new AdvertiseError('直连地址必须是局域网 / 回环 / CGNAT 地址（公网请走中转）')
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
}): AdvertiseAdmin {
  return {
    view() {
      const table = deps.tableOf()
      const settings = advertiseMapOf(table)
      const candidates = [...deps.candidatesOf()]
      const hidden: string[] = []
      const advertised: AdvertiseView['advertised'] = []
      for (const candidate of candidates) {
        if (settings.get(candidate.url) === 'hide') {
          hidden.push(candidate.url)
          continue
        }
        advertised.push({
          url: candidate.url,
          ...(candidate.label === undefined ? {} : { label: candidate.label }),
          source: 'auto',
        })
      }
      for (const [url, kind] of settings) {
        if (kind !== 'extra') continue
        if (advertised.some((entry) => entry.url === url)) continue
        advertised.push({ url, source: 'extra' })
      }
      return { advertised, hidden, candidates }
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
