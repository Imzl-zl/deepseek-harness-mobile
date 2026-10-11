/** 一次性票绑定连接器、设备与用途；票只做路由准入，不授予电脑操作权。 */
import { createHash, randomBytes as nodeRandomBytes } from 'node:crypto'
import { parseDeviceBinding, type DeviceBinding } from '../../protocol/relay-control.mjs'
import type { ChannelLogger } from './logger.ts'

export const TICKET_BYTES = 16
export const TICKET_TTL_MS = 60_000
const PRUNE_EVERY = 64

export interface TicketIssue {
  readonly ticket: string
  readonly expiresAt: number
  readonly deviceId: string
}
export interface TicketStoreOptions {
  now?: () => number
  ttlMs?: number
  randomBytes?: (size: number) => Uint8Array
  log?: ChannelLogger
}
export interface TicketStore {
  issue(binding: DeviceBinding): TicketIssue
  consume(ticket: string): DeviceBinding | undefined
  prune(): number
  readonly stats: { tickets: number }
}
const hashOf = (value: string): string => createHash('sha256').update(value, 'utf8').digest('hex')

export function createTicketStore(options: TicketStoreOptions = {}): TicketStore {
  const now = options.now ?? (() => Date.now())
  const ttlMs = options.ttlMs ?? TICKET_TTL_MS
  const random = options.randomBytes ?? ((size: number) => nodeRandomBytes(size))
  const tickets = new Map<string, { binding: DeviceBinding; expiresAt: number }>()
  let issued = 0
  const prune = (): number => {
    let removed = 0
    for (const [key, entry] of tickets) {
      if (entry.expiresAt > now()) continue
      tickets.delete(key)
      removed += 1
    }
    return removed
  }
  return {
    get stats() { return { tickets: tickets.size } },
    issue(input) {
      const binding = parseDeviceBinding(input)
      if (binding === undefined) throw new TypeError('票据身份绑定不合法')
      issued += 1
      if (issued % PRUNE_EVERY === 0) prune()
      const ticket = Buffer.from(random(TICKET_BYTES)).toString('base64url')
      const expiresAt = now() + ttlMs
      tickets.set(hashOf(ticket), { binding, expiresAt })
      options.log?.debug(`已发票给 ${binding.purpose} 设备 ${binding.deviceId}`)
      return { ticket, expiresAt, deviceId: binding.deviceId }
    },
    consume(ticket) {
      const key = hashOf(ticket)
      const entry = tickets.get(key)
      if (entry === undefined) return undefined
      tickets.delete(key)
      if (entry.expiresAt <= now()) return undefined
      return parseDeviceBinding(entry.binding)
    },
    prune,
  }
}
