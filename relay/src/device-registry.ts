/**
 * 中转的**设备投影**（契约 §8.2 的 `devices` 表、§12.1 第 3 步）。
 *
 * ## 它解决什么
 *
 * 设备经中转走两条路：配对帧与握手帧**没有 `sid`**，只能靠"这台设备此刻属于哪台连接器"
 * 路由（§1 的 I10 说明）。而这张归属表原先只在内存的 `binding` 里，
 * 且**连接器一断就清**（那样设备重连就无处可归，症状是"重新连上却永远握不上手"）。
 *
 * 所以归属要有落点，落点就是这张表 —— 它同时是"设备令牌能不能换到票"的判据。
 *
 * ## 三条纪律
 *
 * 1. **只存摘要**（§12.2）：`token_hash` / `refresh_hash` 是 `sha256(令牌)` 的十六进制，
 *    明文令牌**从不出现在中转的任何形态里**。换票时算一次哈希再查表 —— 与
 *    `digest-auth.ts` 对连接器令牌的做法逐字一致。
 * 2. **写入方是电脑侧**：中转不自己造行、不自己算 id。它只是"记账"（§12.1 第 3 步原话：
 *    "身份判定由电脑侧做，中转只转发与记账"）。
 * 3. **同一 `id` 覆盖**：那正是"重新配对/换令牌"的形状（`appendTokenToConfig` 对
 *    连接器令牌也是同一条：否则旧令牌仍然有效 —— 那是"吊销不了"的形状）。
 *
 * ## 本期落点如实记录
 *
 * 表是**进程内**的，不是 SQL。I7（"中转可被清空后重启，已配对设备仅凭电脑侧数据收敛"）
 * 靠**电脑侧每次连上中转时重放名册**重建，而不是靠中转自己持久化 ——
 * 换 SQL 是部署侧的事，本接口不变。
 *
 * Note: 为什么设备令牌由连接器签发、首配为什么凭配对码换票 —— 见
 * `.agents/notes/implemented/2026-10-02-pairing-bootstrap-and-device-binding.md`
 */
import { createHash } from 'node:crypto'

import type { ChannelLogger } from './logger.ts'

/** 设备令牌的字节数（与连接器令牌、配对码同规格：128 位）。 */
export const DEVICE_TOKEN_BYTES = 16

/**
 * 首配那一跳的临时设备身份前缀。
 *
 * v1 靠"配对码哈希派生的临时身份"进首配那一跳（那时手机还没有任何凭据）；
 * v2 改由**候选身份 + 公开邀请**进门，于是这个前缀**再也没有生产者**——
 * `pendingDeviceIdOf` 已随之删除。留着这两行是因为 `isPendingDevice` 仍是一道
 * 对"名册里出现旧形状 id"的防御（它的代价只有一次 `startsWith`）。
 */
export const PENDING_DEVICE_PREFIX = 'pending:'

/** 是不是首配那一跳的临时身份（v1 遗留形状，见上）。 */
export const isPendingDevice = (deviceId: string): boolean =>
  deviceId.startsWith(PENDING_DEVICE_PREFIX)

/** 一行设备（契约 §8.2）。**没有明文令牌**。 */
export interface DeviceRegistration {
  id: string
  pairingId: string
  devPubEd: string
  devPubDh: string
  name: string
  /** `sha256(设备令牌)` 的十六进制。 */
  tokenHash: string
  /** `sha256(刷新令牌)` 的十六进制；没有刷新令牌时缺席。 */
  refreshHash?: string
  /** 归属：这台设备属于哪台连接器（由来报名册的那条连接决定）。 */
  connectorId?: string
  revokedAt?: number
}

export interface DeviceRegistryOptions {
  log?: ChannelLogger
}

export interface DeviceRegistry {
  /**
   * 电脑侧报名册：用 `(id, tokenHash)` 认下一行，并把归属记到 `connectorId`。
   *
   * @returns 认下几行。
   */
  register(connectorId: string, rows: readonly DeviceRegistration[]): number
  /**
   * 用**设备令牌**解析出设备身份。
   *
   * @returns 该设备 id；令牌无效 / 已吊销 / 没见过 → `undefined`（调用方回 401）。
   */
  authenticate(token: string): string | undefined
  /** 某设备归哪台连接器。**只有电脑侧报过名的设备才有归属**。 */
  connectorOf(deviceId: string): string | undefined
  /** 刷新令牌对应的设备（§12.2 的 `refresh_hash`）。 */
  deviceOfRefreshToken(token: string): string | undefined
  /** 连接器断开：它的设备失去归属（但**行留着** —— 设备要靠令牌自己回来）。 */
  detachConnector(connectorId: string): number
  /** 观测：行数、有归属的行数。 */
  readonly stats: { devices: number; bound: number }
}

const hashOf = (token: string): string => createHash('sha256').update(token, 'utf8').digest('hex')

export function createDeviceRegistry(options: DeviceRegistryOptions = {}): DeviceRegistry {
  const log = options.log

  /** `设备 id → 行`。 */
  const rows = new Map<string, DeviceRegistration>()
  /** `token_hash → 设备 id`（换票的最热路径，单独一张索引）。 */
  const byToken = new Map<string, string>()
  /** `refresh_hash → 设备 id`。 */
  const byRefresh = new Map<string, string>()

  return {
    get stats() {
      let bound = 0
      for (const row of rows.values()) if (row.connectorId !== undefined) bound += 1
      return { devices: rows.size, bound }
    },

    register(connectorId, incoming) {
      let accepted = 0
      for (const row of incoming) {
        // 首配那一跳的临时身份**永不落表**（它不是设备，只是让 `pair` 能进门）。
        if (isPendingDevice(row.id)) continue
        if (row.tokenHash === '') continue
        const previous = rows.get(row.id)
        // 换令牌 = 同一 id 换摘要：旧摘要必须**立刻失效**，否则"换令牌"等于"多一把钥匙"。
        // 两张索引都要清 —— 只清一张会让旧刷新令牌继续可用。
        if (previous !== undefined) {
          byToken.delete(previous.tokenHash)
          if (previous.refreshHash !== undefined) byRefresh.delete(previous.refreshHash)
        }
        rows.set(row.id, { ...row, connectorId })
        byToken.set(row.tokenHash, row.id)
        // 空串不是摘要：写进索引会让"没有刷新令牌"与"刷新令牌是空串"混成一条，
        // 而那张索引的键在设备之间共享 —— 一台设备就能把另一台的条目顶掉。
        if (row.refreshHash !== undefined && row.refreshHash !== '') {
          byRefresh.set(row.refreshHash, row.id)
        }
        accepted += 1
      }
      if (accepted > 0) {
        log?.debug(`名册已更新：${accepted} 行（共 ${rows.size} 台，归属 ${connectorId}）`)
      }
      return accepted
    },

    authenticate(token) {
      if (token === '') return undefined
      const deviceId = byToken.get(hashOf(token))
      if (deviceId === undefined) return undefined
      // 已吊销的行认不下：与 `digest-auth.ts` 的软吊销同一条纪律（行留着是为了可辨识）。
      if (rows.get(deviceId)?.revokedAt !== undefined) return undefined
      return deviceId
    },

    connectorOf(deviceId) {
      const row = rows.get(deviceId)
      if (row === undefined || row.revokedAt !== undefined) return undefined
      return row.connectorId
    },

    deviceOfRefreshToken(token) {
      if (token === '') return undefined
      return byRefresh.get(hashOf(token))
    },

    detachConnector(connectorId) {
      let cleared = 0
      for (const [id, row] of rows) {
        if (row.connectorId !== connectorId) continue
        // **行留着、只清归属**：设备重连时连接器会重放名册把它接回去（I7）。
        // 顺手删行的话，设备令牌就再也换不到票了 —— 而那正是"中转重启即失联"。
        // 用解构重建而不是 `{ ...row, connectorId: undefined }`：后者在
        // `exactOptionalPropertyTypes` 下**类型不通过**（可选属性不能显式赋 undefined），
        // 而它恰好也是更准确的语义 —— "没有归属"就是没有这个字段。
        const rest: DeviceRegistration = {
          id: row.id,
          pairingId: row.pairingId,
          devPubEd: row.devPubEd,
          devPubDh: row.devPubDh,
          name: row.name,
          tokenHash: row.tokenHash,
          ...(row.refreshHash === undefined ? {} : { refreshHash: row.refreshHash }),
          ...(row.revokedAt === undefined ? {} : { revokedAt: row.revokedAt }),
        }
        rows.set(id, rest)
        cleared += 1
      }
      if (cleared > 0) log?.debug(`连接器 ${connectorId} 断开：${cleared} 台设备失去归属（行留着）`)
      return cleared
    },
  }
}
