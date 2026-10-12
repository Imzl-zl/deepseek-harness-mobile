/** 配对提交的挂载级所有者；只接受受限加密连接确认过的候选身份。
 * 决策：.agents/notes/implemented/2026-10-08-pairing-v2-and-device-connections.md。
 */
import { issueDeviceTokens, tokenHashOf, type IssuedDeviceTokens } from './device-token.js'
import type { ChannelLogger } from './observability.js'
import type { Pairing, PairingCandidate, PairingRequest, PairingAccepted } from './pairing.js'

export type PairingReply =
  | { ok: true; devId: string; sas: string; pcId: string; deviceToken: string; refreshToken: string }
  | { ok: false; reason: string; registered?: boolean }

export interface PairedDeviceRow {
  name: string
  edPubHex: string
  dhPubHex: string
  pairingId: string
  pairedAt: number
  tokenHash?: string
}
export interface PairingEndpointOptions {
  issueCredentials?: () => Promise<IssuedDeviceTokens>
  pcId: string
  pairing: Pairing
  putDevice: (devId: string, row: PairedDeviceRow) => Promise<void>
  announce: () => Promise<void>
  log?: ChannelLogger
}
export interface PairingEndpoint {
  handle(box: string, candidate: PairingCandidate): Promise<PairingReply>
  dispose(): void
}
interface Commit {
  offerId: string
  accepted: PairingAccepted
  issued: IssuedDeviceTokens | null
  registered: boolean
  work: Promise<PairingReply> | null
}
const REASONS: Record<string, string> = {
  expired: '配对码已过期，请在电脑上重新出码',
  mismatch: '配对秘密或连接身份不匹配，请重新核对二维码',
  consumed: '这个邀请已经授权给另一台设备，请重新出码',
  invalid: '配对 v2 请求或候选身份不合法，请升级客户端并重新出码',
}

export function createPairingEndpoint(options: PairingEndpointOptions): PairingEndpoint {
  const issue = options.issueCredentials ?? (() => Promise.resolve(issueDeviceTokens()))
  let current: Commit | null = null
  let expiry: ReturnType<typeof setTimeout> | null = null
  let disposed = false

  const commit = async (state: Commit): Promise<PairingReply> => {
    try {
      state.issued ??= await issue()
      if (disposed) return { ok: false, reason: '连接器已关闭，请重新连接' }
      const accepted = state.accepted
      const credentials = state.issued
      if (!state.registered) {
        await options.putDevice(accepted.device.devId, {
          name: accepted.device.name,
          edPubHex: accepted.device.edPubHex,
          dhPubHex: accepted.device.dhPubHex,
          pairingId: accepted.pairingId,
          pairedAt: accepted.device.pairedAt,
          tokenHash: tokenHashOf(credentials.deviceToken),
        })
        state.registered = true
      }
      await options.announce()
      return {
        ok: true, devId: accepted.device.devId, pcId: options.pcId, sas: accepted.sas,
        deviceToken: credentials.deviceToken, refreshToken: credentials.refreshToken,
      }
    } catch (error) {
      options.log?.warn('配对提交未能完成', error)
      return {
        ok: false, registered: state.registered,
        reason: state.registered
          ? '电脑已保存授权，但中转尚未确认；请保持同一设备身份重试'
          : '电脑未能保存授权，请重试',
      }
    }
  }

  return {
    async handle(box, candidate) {
      if (disposed) return { ok: false, reason: '连接器已关闭，请重新连接' }
      let request: PairingRequest
      try { request = JSON.parse(box) as PairingRequest } catch {
        return { ok: false, reason: '配对请求不是合法 JSON' }
      }
      const accepted = options.pairing.accept(request, candidate)
      if ('rejected' in accepted) return { ok: false, reason: REASONS[accepted.rejected] ?? '配对被拒绝' }
      if (current?.offerId !== candidate.offerId) {
        if (expiry !== null) clearTimeout(expiry)
        current = { offerId: candidate.offerId, accepted, issued: null, registered: false, work: null }
        const state = current
        expiry = setTimeout(() => {
          if (current === state) current = null
          expiry = null
        }, Math.max(0, accepted.expiresAt - accepted.device.pairedAt))
        expiry.unref()
      }
      const state = current
      // 同一邀请已经由 pairing.accept 绑定到同一候选，网络重试不能换一对令牌。
      state.work ??= commit(state).finally(() => { state.work = null })
      return state.work
    },
    dispose() {
      disposed = true
      if (expiry !== null) clearTimeout(expiry)
      expiry = null
      current = null
    },
  }
}
