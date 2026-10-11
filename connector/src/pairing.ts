/** 首配 v2：公开发现与秘密授权分离，规范见 docs/subsystems/pairing-v2.md。
 * 决策见 .agents/notes/implemented/2026-10-08-pairing-v2-and-device-connections.md。
 */
import { createHash, hkdfSync, randomBytes as nodeRandomBytes, timingSafeEqual } from 'node:crypto'

export const PAIRING_VERSION = 2
export const PAIRING_CODE_BYTES = 16
export const PAIRING_TTL_MS = 5 * 60 * 1000
export const PAIRING_ID_INFO = 'dsh-mobile/v1/pairing'
export const PAIRING_KEY_INFO = 'dsh-mobile/v2/pairing-keys|'
export const SAS_INFO = 'dsh-mobile/v1/sas'
export const MAX_DEVICE_NAME_BYTES = 256

const TOKEN = /^[A-Za-z0-9_-]{22}$/
const PUBLIC_KEY = /^[0-9a-f]{64}$/
const ID = /^[A-Za-z0-9_-]+$/
const base64url = (bytes: Uint8Array): string => Buffer.from(bytes).toString('base64url')
const hash = (text: string): Buffer => createHash('sha256').update(text, 'utf8').digest()

export interface PairingOffer {
  readonly offerId: string
  /** 只交给二维码，不登记到中转。 */
  readonly code: string
  readonly expiresAt: number
  readonly payload: string
}

/** 由该连接的持钥证明绑定的候选；不能从 pair-commit 载荷里再取一份身份。 */
export interface PairingCandidate {
  readonly offerId: string
  readonly devPubEd: string
  readonly devPubDh: string
  readonly name: string
}

export interface PairingRequest {
  readonly v: 2
  readonly offerId: string
  readonly code: string
}

export interface PairingAccepted {
  readonly pairingId: string
  readonly expiresAt: number
  readonly device: {
    readonly devId: string
    readonly name: string
    readonly edPubHex: string
    readonly dhPubHex: string
    readonly pairingId: string
    readonly pairedAt: number
  }
  readonly sas: string
}

export type PairingRejection = 'expired' | 'mismatch' | 'consumed' | 'invalid'

export interface PairingOptions {
  relayUrl: string
  pcId: string
  pcPubEd: string
  pcPubDh: string
  now?: () => number
  randomBytes?: (size: number) => Uint8Array
  deviceIdOf?: (candidate: PairingCandidate) => string
}

export interface Pairing {
  offer(): PairingOffer
  allows(candidate: PairingCandidate): boolean
  accept(request: PairingRequest, candidate: PairingCandidate): PairingAccepted | { rejected: PairingRejection }
  readonly pending: boolean
}

/** 只作电脑侧秘密校验与已有业务 pairingId 派生，绝不再登记到中转。 */
export function pairingCodeHash(code: string): string {
  return hash(code).toString('hex')
}

export function pairingIdOf(codeHash: string): string {
  return base64url(Buffer.from(hkdfSync('sha256', Buffer.from(codeHash, 'utf8'), Buffer.alloc(0), PAIRING_ID_INFO, 32)))
}

/** 辅助显示，不是配对授权判据。 */
export function sasOf(pcPubEd: string, devPubEd: string): string {
  return String(hash(`${SAS_INFO}|${pcPubEd}|${devPubEd}`).readUInt32BE(0) % 1_000_000).padStart(6, '0')
}

export function deviceIdOf(candidate: Pick<PairingCandidate, 'devPubDh'>): string {
  return base64url(hash(candidate.devPubDh).subarray(0, 16))
}

export function isPairingCandidate(value: unknown): value is PairingCandidate {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return false
  const record = value as Record<string, unknown>
  return typeof record['offerId'] === 'string' && TOKEN.test(record['offerId'])
    && typeof record['devPubEd'] === 'string' && PUBLIC_KEY.test(record['devPubEd'])
    && typeof record['devPubDh'] === 'string' && PUBLIC_KEY.test(record['devPubDh'])
    && typeof record['name'] === 'string' && record['name'].trim() !== ''
    && Buffer.byteLength(record['name'], 'utf8') <= MAX_DEVICE_NAME_BYTES
}

/** 双端从自己的可信输入构造；中转篡改任一字段会使 transcript 签名不匹配。 */
export function pairingHandshakeContext(
  pc: { pcId: string; pcPubEd: string; pcPubDh: string },
  candidate: PairingCandidate,
): string {
  if (!isPairingCandidate(candidate) || !ID.test(pc.pcId)
    || !PUBLIC_KEY.test(pc.pcPubEd) || !PUBLIC_KEY.test(pc.pcPubDh)) {
    throw new TypeError('配对认证上下文字段不合法')
  }
  return [
    'dsh-mobile/pairing/v2', candidate.offerId, pc.pcId, pc.pcPubEd, pc.pcPubDh,
    deviceIdOf(candidate), candidate.devPubEd, candidate.devPubDh, pairingCodeHash(candidate.name),
  ].join('|')
}

function isRequest(value: unknown): value is PairingRequest {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return false
  const record = value as Record<string, unknown>
  return record['v'] === PAIRING_VERSION
    && typeof record['offerId'] === 'string' && TOKEN.test(record['offerId'])
    && typeof record['code'] === 'string' && TOKEN.test(record['code'])
    && !('codeHash' in record)
}

export function createPairing(options: PairingOptions): Pairing {
  const now = options.now ?? (() => Date.now())
  const random = options.randomBytes ?? ((size: number) => nodeRandomBytes(size))
  const identify = options.deviceIdOf ?? deviceIdOf
  let current: {
    offerId: string
    codeHash: Buffer
    expiresAt: number
    candidate: string | null
    accepted: PairingAccepted | null
  } | null = null

  return {
    get pending() {
      return current !== null && current.expiresAt > now() && current.accepted === null
    },

    offer() {
      const offerId = base64url(random(PAIRING_CODE_BYTES))
      const code = base64url(random(PAIRING_CODE_BYTES))
      if (!TOKEN.test(offerId) || !TOKEN.test(code) || offerId === code) {
        throw new Error('配对随机源必须生成独立的邀请与秘密')
      }
      const expiresAt = now() + PAIRING_TTL_MS
      current = { offerId, codeHash: hash(code), expiresAt, candidate: null, accepted: null }
      return {
        offerId, code, expiresAt,
        payload: JSON.stringify({
          v: PAIRING_VERSION, relay: options.relayUrl, pcId: options.pcId,
          pcPubEd: options.pcPubEd, pcPubDh: options.pcPubDh, offerId, code,
        }),
      }
    },

    allows(candidate) {
      if (!isPairingCandidate(candidate) || current === null || current.expiresAt <= now()
        || candidate.offerId !== current.offerId) return false
      return current.candidate === null || current.candidate === pairingHandshakeContext(options, candidate)
    },

    accept(request, candidate) {
      if (!isRequest(request) || !isPairingCandidate(candidate)) return { rejected: 'invalid' }
      if (current === null) return { rejected: 'consumed' }
      if (current.expiresAt <= now()) return { rejected: 'expired' }
      if (request.offerId !== current.offerId || candidate.offerId !== current.offerId
        || !timingSafeEqual(hash(request.code), current.codeHash)) return { rejected: 'mismatch' }

      const fingerprint = pairingHandshakeContext(options, candidate)
      if (current.accepted !== null) {
        return current.candidate === fingerprint ? current.accepted : { rejected: 'consumed' }
      }
      const pairingId = pairingIdOf(current.codeHash.toString('hex'))
      const accepted: PairingAccepted = {
        pairingId,
        expiresAt: current.expiresAt,
        sas: sasOf(options.pcPubEd, candidate.devPubEd),
        device: {
          devId: identify(candidate), name: candidate.name,
          edPubHex: candidate.devPubEd, dhPubHex: candidate.devPubDh,
          pairingId, pairedAt: now(),
        },
      }
      current.candidate = fingerprint
      current.accepted = accepted
      return accepted
    },
  }
}
