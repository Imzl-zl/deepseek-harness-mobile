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
  /**
   * 这一行替换掉的上一个 devId（重新配对才有）。
   *
   * 写进设备行，由装配层在新身份握手成功时据此裁掉旧行 —— 见
   * `pairing-endpoint.ts` 的 `commit` 与 `index.ts` 的 `pruneReplaced`。
   */
  replaces?: string
}

/** 重新配对要找的**上一行**（按手机自报的 `previousPairingId` 定位）。 */
export interface PreviousPairingRow {
  readonly devId: string
  readonly pairedAt: number
}

/**
 * 按 `pairingId` 在设备表里找旧行。**纯函数** —— 单测不需要真域表。
 *
 * **不按 `revokedAt` 过滤**：重新扫码本身就是停用设备的恢复路径（2026-10-15
 * 定的语义），旧行停没停用过都允许被替换；替换后写进去的新行天然不带吊销标记。
 * 反过来过滤会让"停用 → 重扫"退化成"停用 → 重扫 → 又多一行停用记录"。
 *
 * @param rows - `[devId, 行]` 的可迭代（域表的 `keys()` + `get()`）
 * @returns 命中的旧行；没有（首配 / 凭据丢过 / 被清理过）返回 `null`
 */
export function findPreviousPairingRow(
  rows: Iterable<readonly [string, { pairingId: string; pairedAt: number }]>,
  pairingId: string,
): PreviousPairingRow | null {
  for (const [devId, row] of rows) {
    if (row.pairingId === pairingId) return { devId, pairedAt: row.pairedAt }
  }
  return null
}

/**
 * 这台设备（`devId`）替换掉的旧行 —— 重新配对的收尾要删的那一条。
 *
 * **纯函数**：装配层照它删，单测不需要真域表。判据在**自己这行**上：
 * `replaces` 指着的就是它取代的旧 devId。方向不能反 —— 旧行上没有
 * "我被谁替换了"的字段（那样需要改动旧行，且崩溃窗口里会两边都不一致）。
 *
 * @returns 旧 devId（没有 `replaces` 或指向自己 ⇒ 空数组）
 */
export function replacedRowsOf(
  rows: Iterable<readonly [string, { replaces?: string }]>,
  devId: string,
): string[] {
  for (const [id, row] of rows) {
    if (id !== devId) continue
    return row.replaces === undefined || row.replaces === devId ? [] : [row.replaces]
  }
  return []
}

export interface PairingEndpointOptions {
  issueCredentials?: () => Promise<IssuedDeviceTokens>
  pcId: string
  pairing: Pairing
  putDevice: (devId: string, row: PairedDeviceRow) => Promise<void>
  /**
   * 按 `pairingId` 找这台手机**上一次**的配对行（重新配对的替换钩子）。
   *
   * 返回 `null` = 没有旧行：首配、手机凭据丢过、或那行被管理面删了。
   * 必填而不是可选 —— 可选端口会让"替换旧行"悄悄退化回"又攒一行"，
   * 而那种退化没有任何报错。
   */
  findPreviousPairing: (pairingId: string) => PreviousPairingRow | null
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
        // **重新配对 = 换凭证、替换旧行**（2026-10-17 用户："为啥每次扫都是
        // 一个新设备"）：手机自报的 `previousPairingId` 是**行定位符，不是凭据**
        // —— 授权已由一次性二维码秘密 + 候选持钥证明完成（`pairing.accept` 先验
        // 秘密才 accept）。据此找到这台手机上一次的记录，换密钥 / 换令牌 /
        // 换 pairingId 写成新行，**保留首次配对的 pairedAt**。没有旧行（首配、
        // 凭据丢过、被管理面清理过）就照旧写新行。
        // 威胁模型与取舍：`.agents/notes/implemented/2026-10-17-repair-replaces-device-row.md`。
        const previous = accepted.previousPairingId === undefined
          ? null
          : options.findPreviousPairing(accepted.previousPairingId)
        // **旧行先留着**，只在新行上记下"我替换了谁"。
        //
        // 不能在这里删旧行：轮换与"新令牌送达手机"不是一件事，而 `pair-result`
        // 可能根本没到手机（`:197-199` 就有这条 warn）。旧行一删，手机手里那把
        // 凭据就成了孤儿 —— 下次握手 `protocol/not-paired`，手机按契约清凭据，
        // 用户看到的是"凭据莫名失效"。裁剪改在**新身份真的握手成功之后**
        // （装配层 `pruneReplaced`），那时旧行才确定没人用了。
        // 同一个 devId（手机复用密钥）就只覆盖 —— 那种情况没有两行可留。
        const replaces = previous !== null && previous.devId !== accepted.device.devId
          ? previous.devId
          : undefined
        await options.putDevice(accepted.device.devId, {
          name: accepted.device.name,
          edPubHex: accepted.device.edPubHex,
          dhPubHex: accepted.device.dhPubHex,
          pairingId: accepted.pairingId,
          pairedAt: previous?.pairedAt ?? accepted.device.pairedAt,
          tokenHash: tokenHashOf(credentials.deviceToken),
          ...(replaces === undefined ? {} : { replaces }),
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
