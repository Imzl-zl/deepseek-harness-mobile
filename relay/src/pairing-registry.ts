/**
 * 中转的配对登记（契约 §12.1 的"出码登记"）。
 *
 * 配对帧**没有 `sid`**，所以 `routing.ts` 那张"`sid` → 连接器"的归属表帮不上它：
 * 手机来配对时，中转必须先知道"这个 `codeHash` 属于哪台连接器"。答案由**电脑侧出码时登记**给出。
 *
 * ## 为什么登记的是哈希而不是码
 *
 * 与第 18 轮把请求改成带 `codeHash` 是同一条理由，也与 §12 的中转表里那一列 `code_hash` 一致：
 * 中转**不需要**码就能完成它的职责（绑定 ticket 与连接器），而拿到码就等于它能自己配上一台设备。
 * 于是这里连"码"这个类型都不存在 —— 它收不到，也就没法泄露。
 *
 * ## 三条失效规则都必须有，缺一条都会留下"指向不存在连接的 ticket"
 *
 * 1. **认领即消费**：同一 `codeHash` 只能被认领一次（配对码本身一次性）。
 * 2. **过期**：登记活 5 分钟，与配对码同寿。
 * 3. **连接器断开即失效**：不然设备会拿到一张指向一条已经不存在的连接的 ticket，
 *    症状是"扫码后一直连不上"，而中转侧看起来一切正常。
 */
import type { ChannelLogger } from './logger.ts'

/** 登记寿命：与配对码同寿（契约 §12.1：5 分钟）。 */
export const PAIRING_REGISTRATION_TTL_MS = 5 * 60 * 1000

export interface PairingRegistryOptions {
  now?: () => number
  ttlMs?: number
  log?: ChannelLogger
}

export interface PairingRegistry {
  /**
   * 电脑侧出码时登记。同一个 `codeHash` 再登记会**覆盖**（重新出码的场景）。
   *
   * @returns 登记的过期时刻。
   */
  register(codeHash: string, connectorId: string): number
  /**
   * 设备带 `codeHash` 来换 ticket：**认领即消费**。
   *
   * @returns 该绑定到哪台连接器；没有登记（或已过期/已被认领）返回 `undefined`。
   */
  claim(codeHash: string): string | undefined
  /** 连接器断开：清掉它全部**未认领**的登记。返回清掉几条。 */
  forgetConnector(connectorId: string): number
  /** 清掉过期登记。返回清掉几条。 */
  prune(): number
  /** 观测：当前登记数与它们的所属连接器。 */
  readonly stats: { registrations: number; connectors: number }
}

export function createPairingRegistry(options: PairingRegistryOptions = {}): PairingRegistry {
  const now = options.now ?? (() => Date.now())
  const ttlMs = options.ttlMs ?? PAIRING_REGISTRATION_TTL_MS
  const log = options.log

  /** `codeHash → { connectorId, expiresAt }`。 */
  const registrations = new Map<string, { connectorId: string; expiresAt: number }>()

  const isLive = (entry: { expiresAt: number }, at: number): boolean => entry.expiresAt > at

  return {
    get stats() {
      const connectors = new Set<string>()
      for (const entry of registrations.values()) connectors.add(entry.connectorId)
      return { registrations: registrations.size, connectors: connectors.size }
    },

    register(codeHash, connectorId) {
      const expiresAt = now() + ttlMs
      registrations.set(codeHash, { connectorId, expiresAt })
      log?.debug(`配对登记：${codeHash.slice(0, 8)}… → ${connectorId}`)
      return expiresAt
    },

    claim(codeHash) {
      const entry = registrations.get(codeHash)
      if (entry === undefined) return undefined
      const at = now()
      // 过期就地作废（与去重表的惰性过期同一条纪律：TTL 是语义，不是"什么时候清"）。
      if (!isLive(entry, at)) {
        registrations.delete(codeHash)
        log?.debug(`配对登记已过期：${codeHash.slice(0, 8)}…`)
        return undefined
      }
      // 一次性：先删再返回，任何路径都不会让同一个登记被认领两次。
      registrations.delete(codeHash)
      return entry.connectorId
    },

    forgetConnector(connectorId) {
      let removed = 0
      for (const [codeHash, entry] of registrations) {
        if (entry.connectorId !== connectorId) continue
        registrations.delete(codeHash)
        removed += 1
      }
      if (removed > 0) log?.debug(`连接器 ${connectorId} 断开：清掉 ${removed} 条配对登记`)
      return removed
    },

    prune() {
      const at = now()
      let removed = 0
      for (const [codeHash, entry] of registrations) {
        if (isLive(entry, at)) continue
        registrations.delete(codeHash)
        removed += 1
      }
      return removed
    },
  }
}
