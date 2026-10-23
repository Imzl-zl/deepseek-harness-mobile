/** HTTP 边界：公开邀请只准入候选，正式设备仍由电脑登记的令牌认证。 */
import { deviceIdOf, parsePairingCandidate } from '../../protocol/relay-control.mjs'
import type { Authenticated } from './digest-auth.ts'
import type { RelayCore } from './core.ts'
import type { DeviceRegistry, DeviceRegistration } from './device-registry.ts'
import type { TicketStore } from './tickets.ts'
import type { ChannelLogger } from './logger.ts'

// 从本模块再导出一次：`Authenticated` 的唯一定义在 `digest-auth.ts`（摘要表只放连接器，
// 于是"已认证调用方"只有一种），但调用方历来从这里 import 它。
export type { Authenticated }

export interface HttpFaceOptions {
  tickets: TicketStore
  core: RelayCore
  authenticate: (token: string) => Authenticated | undefined
  devices: DeviceRegistry
  rateLimit?: (key: string) => { allowed: boolean; retryAfterMs: number | null }
  log?: ChannelLogger
}
export interface HttpRequest {
  method: string
  path: string
  token?: string
  body?: unknown
  /**
   * 这条请求的网络来源（`request.socket.remoteAddress`）。
   *
   * **只给未认证的那一跳用**：认证过的调用方按身份取桶（设备 id / 连接器 id），
   * 而"还没配对"的请求没有任何身份 —— 来源地址是唯一能区分的维度（见 `pairing-anonymous` 键）。
   */
  remoteAddress?: string
}
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
        // **未认证的那一跳按来源地址分桶**：它没有任何身份可用，而"所有人共用一个桶"
        // 的后果是"一个人刷坏请求就把所有人的首配限成 429"（约 6 req/s 就够）。
        // 取不到地址时退到 `unknown` —— 那时等价于改动前的全局桶（不更坏）。
        // 在反向代理之后所有客户端会塌成一个地址，同样等价于改动前（见 `rate-limit.ts` 的头注）。
        const denied = limited(`pairing:anonymous:${request.remoteAddress ?? 'unknown'}`)
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

      // **认证顺序：先名册、后摘要表**。设备令牌只可能由电脑侧签发（摘要进名册），
      // 连接器令牌只可能在摘要表里 —— 两者不重叠，所以顺序不影响结果；写成"先名册"
      // 是为了让"设备凭据面在名册"这条分层不依赖别处的校验也成立。
      const token = request.token ?? ''
      const deviceId = token === '' ? undefined : devices.authenticate(token)
      const caller = deviceId === undefined && token !== '' ? authenticate(token) : undefined
      if (caller === undefined && deviceId === undefined) return { status: 401, body: { error: 'unauthorized' } }
      const denied = limited(`${caller?.kind ?? 'device'}:${caller?.id ?? deviceId}`)
      if (denied !== undefined) return denied

      if (request.path === '/ws-ticket') {
        // 走到这里的一定是连接器（摘要表只放连接器令牌）：它拿自己的令牌来换**设备**票，
        // 属于凭据类型用错 —— 与"令牌不对"区分开，操作者才知道该换哪一张。
        if (deviceId === undefined) return { status: 403, body: { error: 'wrong-credential-kind' } }
        const connectorId = devices.connectorOf(deviceId)
        // 设备凭据有效而电脑离线不是“需要重新配对”。
        if (connectorId === undefined || !core.isConnectorOnline(connectorId)) {
          return { status: 503, body: { error: 'connector-offline' } }
        }
        const issued = tickets.issue({ connectorId, deviceId, purpose: 'paired' })
        return { status: 201, body: { ticket: issued.ticket, expiresAt: issued.expiresAt } }
      }
      // 下面三个端点（登记 / 名册 / 404）只有连接器能调：设备令牌换到票就去升级了，
      // 它没有理由来调这些。这里用 `caller === undefined` 判"是不是连接器" ——
      // 摘要表只放连接器令牌（`digest-auth.ts`），所以这个判据与 `kind === 'connector'` 等价。
      if (caller === undefined) return { status: 403, body: { error: 'wrong-credential-kind' } }
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
    rows.push({
      id, tokenHash, pairingId, devPubEd, devPubDh, name: typeof name === 'string' ? name : '',
    })
  }
  return rows
}
