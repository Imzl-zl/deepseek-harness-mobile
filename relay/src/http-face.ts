/** HTTP 边界：公开邀请只准入候选，正式设备仍由电脑登记的令牌认证。 */
import { deviceIdOf, parsePairingCandidate } from '../../protocol/relay-control.mjs'
import type { RelayCore } from './core.ts'
import type { DeviceRegistry, DeviceRegistration } from './device-registry.ts'
import type { TicketStore } from './tickets.ts'
import type { ChannelLogger } from './logger.ts'

export interface Authenticated { kind: 'device' | 'connector'; id: string }
export interface HttpFaceOptions {
  tickets: TicketStore
  core: RelayCore
  authenticate: (token: string) => Authenticated | undefined
  devices: DeviceRegistry
  rateLimit?: (key: string) => { allowed: boolean; retryAfterMs: number | null }
  log?: ChannelLogger
}
export interface HttpRequest { method: string; path: string; token?: string; body?: unknown }
export interface HttpResponse { status: number; body?: unknown }
export interface HttpFace { handle(request: HttpRequest): HttpResponse }

export function createHttpFace(options: HttpFaceOptions): HttpFace {
  const { tickets, core, authenticate, devices } = options
  const limited = (key: string): HttpResponse | undefined => {
    const result = options.rateLimit?.(key)
    return result === undefined || result.allowed ? undefined : {
      status: 429, body: { error: 'rate-limited', retryAfterMs: result.retryAfterMs },
    }
  }
  return {
    handle(request) {
      if (request.method !== 'POST') return { status: 405, body: { error: 'method-not-allowed' } }
      const body = typeof request.body === 'object' && request.body !== null && !Array.isArray(request.body)
        ? request.body as Record<string, unknown> : {}
      if ('codeHash' in body) return { status: 426, body: { error: 'pairing-version-unsupported' } }

      if (request.path === '/ws-ticket' && 'offerId' in body) {
        const denied = limited('pairing:anonymous')
        if (denied !== undefined) return denied
        const candidate = body['v'] === 2 ? parsePairingCandidate(body) : undefined
        if (candidate === undefined) return { status: 400, body: { error: 'invalid-pairing-candidate' } }
        const offerDenied = limited(`pairing:offer:${candidate.offerId}`)
        if (offerDenied !== undefined) return offerDenied
        const connectorId = core.lookupPairing(candidate.offerId)
        if (connectorId === undefined) return { status: 409, body: { error: 'pairing-unavailable' } }
        const issued = tickets.issue({
          connectorId, deviceId: deviceIdOf(candidate), purpose: 'pairing', candidate,
        })
        return { status: 201, body: { ticket: issued.ticket, expiresAt: issued.expiresAt } }
      }

      const token = request.token ?? ''
      const caller = token === '' ? undefined : authenticate(token)
      const deviceId = caller === undefined ? devices.authenticate(token) : undefined
      if (caller === undefined && deviceId === undefined) return { status: 401, body: { error: 'unauthorized' } }
      const denied = limited(`${caller?.kind ?? 'device'}:${caller?.id ?? deviceId}`)
      if (denied !== undefined) return denied

      if (request.path === '/ws-ticket') {
        if (deviceId === undefined) return { status: 403, body: { error: 'wrong-credential-kind' } }
        const connectorId = devices.connectorOf(deviceId)
        // 设备凭据有效而电脑离线不是“需要重新配对”。
        if (connectorId === undefined || !core.isConnectorOnline(connectorId)) {
          return { status: 503, body: { error: 'connector-offline' } }
        }
        const issued = tickets.issue({ connectorId, deviceId, purpose: 'paired' })
        return { status: 201, body: { ticket: issued.ticket, expiresAt: issued.expiresAt } }
      }
      if (caller?.kind !== 'connector') return { status: 403, body: { error: 'wrong-credential-kind' } }
      if (request.path === '/pairing/register') {
        const offerId = body['offerId']
        if (body['v'] !== 2 || typeof offerId !== 'string' || !/^[A-Za-z0-9_-]{22}$/.test(offerId)) {
          return { status: 400, body: { error: 'offerId-required' } }
        }
        try {
          return { status: 201, body: { expiresAt: core.registerPairing(caller.id, offerId) } }
        } catch (error) {
          options.log?.warn('公开邀请登记失败', error)
          return { status: 409, body: { error: 'pairing-unavailable' } }
        }
      }
      if (request.path === '/devices') {
        const rows = parseRegistrations(body['devices'])
        if (rows === undefined) return { status: 400, body: { error: 'devices-required' } }
        return { status: 201, body: { accepted: devices.register(caller.id, rows) } }
      }
      return { status: 404, body: { error: 'not-found' } }
    },
  }
}

function parseRegistrations(value: unknown): DeviceRegistration[] | undefined {
  if (!Array.isArray(value)) return undefined
  const rows: DeviceRegistration[] = []
  for (const item of value) {
    if (typeof item !== 'object' || item === null || Array.isArray(item)) return undefined
    const record = item as Record<string, unknown>
    const id = record['id']
    const tokenHash = record['tokenHash']
    const pairingId = record['pairingId']
    const devPubEd = record['devPubEd']
    const devPubDh = record['devPubDh']
    if (typeof id !== 'string' || id === '' || typeof tokenHash !== 'string' || tokenHash === ''
      || typeof pairingId !== 'string' || typeof devPubEd !== 'string' || typeof devPubDh !== 'string') return undefined
    const name = record['name']
    const refreshHash = record['refreshHash']
    rows.push({
      id, tokenHash, pairingId, devPubEd, devPubDh, name: typeof name === 'string' ? name : '',
      ...(typeof refreshHash === 'string' && refreshHash !== '' ? { refreshHash } : {}),
    })
  }
  return rows
}
