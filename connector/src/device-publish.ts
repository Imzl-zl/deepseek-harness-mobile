/**
 * 设备名册的上报（契约 §8.2 的 `devices` 投影、I7）。
 *
 * ## 为什么要有这一步
 *
 * 中转要能把"设备 → 连接器"路由对（配对帧与握手帧都没有 `sid`），而这层归属
 * **只活在中转内存里是不行的**：中转被清空/重启之后，已配对设备必须能自己回来
 * （I7 的原话："删掉中转全部业务状态后重启，已配对设备仅凭电脑侧数据收敛"）。
 *
 * 所以电脑侧在**每次连上中转时**把整份名册重放一遍，中转据此重建归属与凭据面。
 * 名册只带**摘要**（§12.2）—— 明文令牌从不离开电脑侧。
 *
 * ## 与 `pairing-register.ts` 的三处一致（刻意的）
 *
 * 1. `ws://` → `http://` 的派生用同一个 `httpBaseOf`（**丢掉路径**：HTTP 端点不在 WS 那条路径上）；
 * 2. 令牌走 `Authorization: Bearer`（不进 URL），且**现读**（换令牌后立刻生效）；
 * 3. 非 2xx 与网络错误都**抛** —— 静默成功会让操作者以为名册已经在转发了，
 *    而症状是"那台手机再也连不上"。
 *
 * 与出码登记的一处不同：**名册上报要重试**。它是连接建立后的自动动作（不是人工触发），
 * 失败一次就放弃会让"中转刚起来还没就绪"变成永久失联。重试由调用方按退避驱动
 * （`Connection` 的 `onEstablished` 每次重连都会再报一遍，这就是它的兜底）。
 *
 * Note: 名册为什么存在（I7 的机制）—— 见
 * `.agents/notes/implemented/2026-10-02-pairing-bootstrap-and-device-binding.md`
 */
import { httpBaseOf } from './pairing-register.js'
import type { ChannelLogger } from './observability.js'

/** 名册里的一行（与中转 `DeviceRegistration` 同形；**只有摘要**）。 */
export interface DeviceRegistration {
  id: string
  pairingId: string
  devPubEd: string
  devPubDh: string
  name: string
  /** `sha256(设备令牌)` 的十六进制。 */
  tokenHash: string
  /**
   * 吊销时间（停用）。
   *
   * **停用的行照样上报**，带这个字段：中转据此把换票 401 说成 `device-revoked`
   * （手机侧是终态 → 清这一台的凭据回配对页）。不报的话中转只剩"没见过"，
   * 停用与"名册还没同步"在手机侧完全同一个症状（一直重试）。
   */
  revokedAt?: number
}

/** 一行设备记录（名册来源的形状：`devices` 表的一行）。 */
export interface RosterSourceRow {
  pairingId: string
  edPub: string
  dhPub: string
  name: string
  /** 没有摘要的行**报不进名册**（换不到票，报了只会让中转留一份过期的归属）。 */
  tokenHash?: string
  revokedAt?: number
}

/**
 * 把设备表的一行翻成名册的一行；**报不进名册就回 `undefined`**。
 *
 * 两条规则：
 * 1. 没有 `tokenHash` 的行不能报（缺摘要 = 换不到票，报了也没用）；
 * 2. **停用的行照样报**（带 `revokedAt`）—— 这是 `device-revoked` 唯一的来源。
 */
export function rosterEntry(id: string, row: RosterSourceRow): DeviceRegistration | undefined {
  if (row.tokenHash === undefined) return undefined
  return {
    id,
    pairingId: row.pairingId,
    devPubEd: row.edPub,
    devPubDh: row.dhPub,
    name: row.name,
    tokenHash: row.tokenHash,
    ...(row.revokedAt === undefined ? {} : { revokedAt: row.revokedAt }),
  }
}

export interface DevicePublisherOptions {
  /**
   * 连接层用的 WSS 地址（配置里的 `relayUrl`）。
   *
   * 是**函数**：面板可以热改地址，而名册打的是"当前那台中转"的 HTTP 面
   * （与出码登记同一个理由，见那里的说明）。
   */
  relayUrl: () => string
  allowInsecureLocal?: () => boolean
  /** 公网明文（自部署中转）：与配对登记同一个判据。 */
  allowInsecurePublic?: () => boolean
  /** 取连接器令牌（**函数而不是字符串**：与出码登记同一个理由，见那里的说明）。 */
  tokenSource: () => Promise<string>
  /** 注入 `fetch` 以便测（装配层用全局的那个）。 */
  fetchImpl?: typeof fetch
  log?: ChannelLogger
}

export function createDevicePublisher(
  options: DevicePublisherOptions,
): (rows: readonly DeviceRegistration[]) => Promise<void> {
  const doFetch = options.fetchImpl ?? fetch
  const endpointOf = (): string =>
    `${httpBaseOf(
      options.relayUrl(),
      options.allowInsecureLocal?.() ?? false,
      options.allowInsecurePublic?.() ?? false,
    )}/devices`

  return async (rows) => {
    const endpoint = endpointOf()
    // 空名册也要报：那正是"这台电脑上已经没有设备了"的形状（比如全部吊销）。
    // 少报这一次会让中转留着一份过期的归属。
    const token = await options.tokenSource()
    const response = await doFetch(endpoint, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${token}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({ devices: rows }),
    })
    if (!response.ok) {
      // 把状态码带上：401 是"连接器令牌不对"、400 是"名册形状不对"，两者的下一步动作不同。
      const detail = await response.text().catch(() => '')
      throw new Error(
        `设备名册被拒（HTTP ${response.status}）${detail === '' ? '' : `：${detail.slice(0, 200)}`}`,
      )
    }
    options.log?.debug('设备名册已上报', { endpoint, rows: rows.length })
  }
}
