/** 配对提交的挂载级所有者；只接受受限加密连接确认过的候选身份。
 * 决策：.agents/notes/implemented/2026-10-08-pairing-v2-and-device-connections.md。
 */
import { issueDeviceTokens, tokenHashOf, type IssuedDeviceTokens } from './device-token.js'
import type { ChannelLogger } from './observability.js'
import type { Pairing, PairingCandidate, PairingRequest, PairingAccepted } from './pairing.js'

export type PairingReply =
  | { ok: true; devId: string; sas: string; pcId: string; deviceToken: string; refreshToken: string }
  | { ok: false; reason: string }

export interface PairedDeviceRow {
  name: string
  edPubHex: string
  dhPubHex: string
  pairingId: string
  pairedAt: number
  /** 安装级展示/定位码；老客户端行没有，不据名称归并。 */
  deviceCode?: string
  /** 登记时的旧身份集合，不包含后续注册的身份。 */
  replacesAll?: string[]
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
  readonly replacesAll?: readonly string[]
}

/**
 * 精确旧 `pairingId` 优先关联无 code 的旧行，其次按完整设备码定位。
 * 同 code 可有多代待收尾行；本函数只选择 pairedAt/替换锚点，不宣称行唯一。
 *
 * **不按 `revokedAt` 过滤**：重新扫码本身就是停用设备的恢复路径（2026-10-15
 * 定的语义），旧行停没停用过都允许被替换；替换后写进去的新行天然不带吊销标记。
 * 反过来过滤会让"停用 → 重扫"退化成"停用 → 重扫 → 又多一行停用记录"。
 *
 * @param rows - `[devId, 行]` 的可迭代（域表的 `keys()` + `get()`）
 * @returns 命中的旧行；没有（首配 / 凭据丢过 / 被清理过）返回 `null`
 */
type ReplacementLinks = {
  deviceCode?: string
  replaces?: string
  replacesAll?: readonly string[]
}

/** 只沿已记录的替换关系；不根据同 code 的实时清单推断未来身份。 */
function replacementClosure(
  table: ReadonlyMap<string, ReplacementLinks>,
  roots: Iterable<string>,
  exclude?: string,
  code?: string,
): string[] {
  const pending = [...roots]
  const visited = new Set(exclude === undefined ? [] : [exclude])
  const result: string[] = []
  for (let index = 0; index < pending.length; index += 1) {
    const id = pending[index]!
    if (visited.has(id)) continue
    visited.add(id)
    const row = table.get(id)
    if (row === undefined) continue
    if (code !== undefined && row.deviceCode !== undefined && row.deviceCode !== code) continue
    result.push(id)
    if (row.replaces !== undefined) pending.push(row.replaces)
    if (row.replacesAll !== undefined) pending.push(...row.replacesAll)
  }
  return result
}

export function findPreviousPairingRow(
  rows: Iterable<readonly [string, { pairingId: string; pairedAt: number } & ReplacementLinks]>,
  pairingId: string,
  deviceCode?: string,
): PreviousPairingRow | null {
  const table = new Map(rows)
  let exact: PreviousPairingRow | null = null
  let first: PreviousPairingRow | null = null
  const matching = new Set<string>()
  for (const [devId, row] of table) {
    const sameCode = deviceCode !== undefined && row.deviceCode === deviceCode
    if (pairingId !== '' && row.pairingId === pairingId
      && (deviceCode === undefined || row.deviceCode === undefined || sameCode)) {
      exact = { devId, pairedAt: row.pairedAt }
    }
    if (sameCode) {
      matching.add(devId)
      // 时间仅继承定位锚点的展示值，不据此猜谁是旧代次。
      first ??= { devId, pairedAt: row.pairedAt }
    }
  }
  const anchor = exact ?? first
  if (anchor === null) return null
  if (exact !== null) matching.add(exact.devId)
  const replacesAll = replacementClosure(table, matching, undefined, deviceCode).sort()
  // 无code的既有单行定位保持旧返回形状；有已知旧链时也必须捕获完整集合。
  return deviceCode === undefined && replacesAll.length <= 1 ? anchor : { ...anchor, replacesAll }
}

/** 新身份只能裁登记时记录的集合与兼容旧 replaces 链，旧重连不能删未来身份。 */
export function replacedRowsOf(
  rows: Iterable<readonly [string, ReplacementLinks]>,
  devId: string,
): string[] {
  // Note: .agents/notes/implemented/2026-11-24-stable-device-code-and-pairing-continuity.md
  const table = new Map(rows)
  const current = table.get(devId)
  if (current === undefined) return []
  if (current.replacesAll !== undefined) {
    // 当代快照是完整事实；目标的关系若后来被重写，不得带进未来身份。
    return [...new Set(current.replacesAll)].filter(id => {
      const row = table.get(id)
      return id !== devId && row !== undefined
        && (current.deviceCode === undefined || row.deviceCode === undefined || row.deviceCode === current.deviceCode)
    })
  }
  // 只有旧格式没有快照时，沿已存的replaces关系传递。
  return replacementClosure(table, current.replaces === undefined ? [] : [current.replaces], devId, current.deviceCode)
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
  findPreviousPairing: (pairingId: string, deviceCode?: string) => PreviousPairingRow | null
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
  registration: PairedDeviceRow | null
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
  let registrationTail: Promise<void> = Promise.resolve()

  const register = (state: Commit, credentials: IssuedDeviceTokens): Promise<void> => {
    // 找旧集合→put→registered是一条写链；announce不在链内，不阻塞后续授权。
    const work = registrationTail.then(async () => {
      if (disposed) throw new Error('连接器已关闭，授权未保存')
      if (state.registered) return
      if (state.registration === null) {
        const accepted = state.accepted
        const previous = accepted.previousPairingId === undefined && accepted.device.deviceCode === undefined
          ? null
          : options.findPreviousPairing(accepted.previousPairingId ?? '', accepted.device.deviceCode)
        const replaces = previous !== null && previous.devId !== accepted.device.devId ? previous.devId : undefined
        const replacesAll = [...new Set(previous?.replacesAll ?? (previous === null ? [] : [previous.devId]))]
          .filter(id => id !== accepted.device.devId).sort()
        // 关系随本次授权缓存，写库失败重试不得改写成另一套代次事实。
        state.registration = {
          name: accepted.device.name,
          edPubHex: accepted.device.edPubHex,
          dhPubHex: accepted.device.dhPubHex,
          pairingId: accepted.pairingId,
          pairedAt: previous?.pairedAt ?? accepted.device.pairedAt,
          tokenHash: tokenHashOf(credentials.deviceToken),
          ...(accepted.device.deviceCode === undefined ? {} : { deviceCode: accepted.device.deviceCode }),
          ...(replaces === undefined ? {} : { replaces }),
          replacesAll,
        }
      }
      await options.putDevice(state.accepted.device.devId, state.registration)
      state.registered = true
    })
    // 只结算写链控制句柄；原work仍失败，由commit如实回报。
    registrationTail = work.catch(() => {})
    return work
  }

  const commit = async (state: Commit): Promise<PairingReply> => {
    try {
      state.issued ??= await issue()
      if (disposed) return { ok: false, reason: '连接器已关闭，请重新连接' }
      const accepted = state.accepted
      const credentials = state.issued
      await register(state, credentials)
      // **名册上报失败不是配对失败**（2026-11-03）：
      //
      // - 设备行已经落盘、令牌已经签发 —— 手机拿到的是**真凭据**；
      // - 名册会在下一次连上中转时**整份重放**（`index.ts` 的 `onConnected`），
      //   中转侧那段时间只会说 `device-unknown`（可恢复，手机提示"稍后重试"）；
      // - 纯局域网配对根本没有中转，这条上报**必然**失败 —— 把它当失败，
      //   就会让"关掉中转也能配对"在最后一步前功尽弃。
      //
      // 把它当失败的旧行为还有个更贵的代价：手机丢掉刚签发的令牌、用户重扫，
      // 而电脑侧那一行已经写了 —— 于是同一台手机攒出第二行。
      //
      // Note: 为什么名册失败不再算配对失败 —— 见
      // `.agents/notes/implemented/2026-11-03-pairing-without-relay.md`
      try {
        await options.announce()
      } catch (error) {
        options.log?.warn(
          '设备名册未上报（中转不可用或还没连上）：这台设备已配对，名册会在下次连上中转时重发',
          error,
        )
      }
      return {
        ok: true, devId: accepted.device.devId, pcId: options.pcId, sas: accepted.sas,
        deviceToken: credentials.deviceToken, refreshToken: credentials.refreshToken,
      }
    } catch (error) {
      options.log?.warn('配对提交未能完成', error)
      return { ok: false, reason: '电脑未能保存授权，请重试' }
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
        current = { offerId: candidate.offerId, accepted, issued: null, registered: false, registration: null, work: null }
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
