/** 公开邀请登记，不持有配对秘密，不在匿名查询时消费授权。 */
import type { ChannelLogger } from './logger.ts'

export const PAIRING_REGISTRATION_TTL_MS = 5 * 60 * 1000

export interface PairingRegistryOptions {
  now?: () => number
  ttlMs?: number
  log?: ChannelLogger
}

export interface PairingRegistry {
  register(offerId: string, connectorId: string): number
  lookup(offerId: string): string | undefined
  forgetConnector(connectorId: string): number
  prune(): number
  readonly stats: { registrations: number; connectors: number }
}

export function createPairingRegistry(options: PairingRegistryOptions = {}): PairingRegistry {
  const now = options.now ?? (() => Date.now())
  const ttlMs = options.ttlMs ?? PAIRING_REGISTRATION_TTL_MS
  const registrations = new Map<string, { connectorId: string; expiresAt: number }>()

  const forgetConnector = (connectorId: string): number => {
    let removed = 0
    for (const [offerId, entry] of registrations) {
      if (entry.connectorId !== connectorId) continue
      registrations.delete(offerId)
      removed += 1
    }
    return removed
  }

  return {
    get stats() {
      return { registrations: registrations.size, connectors: new Set([...registrations.values()].map((v) => v.connectorId)).size }
    },
    register(offerId, connectorId) {
      if (!/^[A-Za-z0-9_-]{22}$/.test(offerId)) throw new TypeError('公开邀请标识不合法')
      const previous = registrations.get(offerId)
      if (previous !== undefined && previous.connectorId !== connectorId) throw new Error('邀请已属于另一连接器')
      forgetConnector(connectorId)
      const expiresAt = now() + ttlMs
      registrations.set(offerId, { connectorId, expiresAt })
      options.log?.debug(`已登记公开邀请，归属 ${connectorId}`)
      return expiresAt
    },
    lookup(offerId) {
      const entry = registrations.get(offerId)
      if (entry === undefined) return undefined
      if (entry.expiresAt <= now()) {
        registrations.delete(offerId)
        return undefined
      }
      return entry.connectorId
    },
    forgetConnector,
    prune() {
      let removed = 0
      for (const [offerId, entry] of registrations) {
        if (entry.expiresAt > now()) continue
        registrations.delete(offerId)
        removed += 1
      }
      return removed
    },
  }
}
