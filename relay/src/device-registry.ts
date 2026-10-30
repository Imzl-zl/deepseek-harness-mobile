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
 * ## 四条纪律
 *
 * 1. **只存摘要**（§12.2）：`token_hash` / `refresh_hash` 是 `sha256(令牌)` 的十六进制，
 *    明文令牌**从不出现在中转的任何形态里**。换票时算一次哈希再查表 —— 与
 *    `digest-auth.ts` 对连接器令牌的做法逐字一致。
 * 2. **写入方是电脑侧**：中转不自己造行、不自己算 id。它只是"记账"（§12.1 第 3 步原话：
 *    "身份判定由电脑侧做，中转只转发与记账"）。
 * 3. **同一 `id` 覆盖**：那正是"重新配对/换令牌"的形状（`appendTokenToConfig` 对
 *    连接器令牌也是同一条：否则旧令牌仍然有效 —— 那是"吊销不了"的形状）。
 * 4. **名册是全量快照，差集即删除**：电脑侧每次上报都是**整份**（`device-publish.ts`
 *    的文件头原话："空名册也要报……少报这一次会让中转留着一份过期的归属"），所以
 *    "上次报到、这次没报到"的行必须消失。只增不减的话，电脑侧删掉/吊销一台设备之后
 *    它在中转层**还换得到票** —— 2026-10-15 真机实测到这条：手机因此通过换票、
 *    死在连接器握手（close 4003），表现是无限"重连中…"，而两端的日志都没有原因。
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
  /** 归属：这台设备属于哪台连接器（由来报名册的那条连接决定）。 */
  connectorId?: string
  revokedAt?: number
}

export interface DeviceRegistryOptions {
  log?: ChannelLogger
}

/** 一枚设备令牌在中转眼里的三种状态（`classify` 的产出）。 */
export type DeviceTokenVerdict = 'ok' | 'revoked' | 'unknown'

export interface DeviceRegistry {
  /**
   * 电脑侧报名册：用 `(id, tokenHash)` 认下一行，并把归属记到 `connectorId`。
   *
   * **全量快照，差集即删除**（纪律 4）：`rows` 是这台连接器这一次报到的整份名册，
   * 上次报到而这次没报到的行会被删掉 —— 包括**空名册**（"这台电脑上没有设备了"）。
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
  /**
   * **令牌的诊断**：`ok` / `revoked` / `unknown`。
   *
   * 只为**把 401 说清楚**而存在：`authenticate` 把"已吊销"与"没见过"都折成
   * `undefined`，于是调用方只能回一句含糊的 `unauthorized`，手机也就只能显示
   * "可能已停用，或凭据已失效"（用户看到的是"凭据莫名失效"）。
   *
   * 两者在电脑侧的处置**不同**：`revoked` 要操作者去解禁（或重扫），
   * `unknown` 多半是名册还没同步过来（电脑刚启动 / 刚重配完），**重试就能好**。
   * 所以诊断必须过线，不能在下游靠猜。
   */
  classify(token: string): DeviceTokenVerdict
  /** 某设备归哪台连接器。**只有电脑侧报过名的设备才有归属**。 */
  connectorOf(deviceId: string): string | undefined
  /** 连接器断开：它的设备失去归属（但**行留着** —— 设备要靠令牌自己回来）。 */
  detachConnector(connectorId: string): number
  /** 观测：行数、有归属的行数。 */
  readonly stats: { devices: number; bound: number }
  /** 每台连接器**上次报到**的行数（管理面用；只给数字，不给设备 id）。 */
  publishedCounts(): Readonly<Record<string, number>>
}

const hashOf = (token: string): string => createHash('sha256').update(token, 'utf8').digest('hex')

export function createDeviceRegistry(options: DeviceRegistryOptions = {}): DeviceRegistry {
  const log = options.log

  /** `设备 id → 行`。 */
  const rows = new Map<string, DeviceRegistration>()
  /** `token_hash → 设备 id`（换票的最热路径，单独一张索引）。 */
  const byToken = new Map<string, string>()
  /**
   * `连接器 → 它上次报到的设备 id 集`。
   *
   * 名册是全量快照，所以差集（上次有、这次没有）就是要删的行。这张表要**跨
   * `detachConnector` 存活**：连接器断开时行留着、归属清掉，但它回来时报一份
   * 更短的名册时，仍然要能算出"哪些行过期了"—— 否则断开一次就让过期的行复活。
   */
  const published = new Map<string, Set<string>>()

  /**
   * 删掉"这台连接器上次报到、这次没报到"的行，返回删了几行。
   *
   * **只删自己的行**：归属已经是别的连接器的（被它覆盖过）不动 —— 多连接器部署时
   * 一份短名册不该把别人的设备抹掉。归属为空（`detachConnector` 清掉的）算自己的：
   * 那正是"断开前报过、回来时报少了"的形状。
   */
  const dropUnpublished = (connectorId: string, next: ReadonlySet<string>): number => {
    const previous = published.get(connectorId)
    if (previous === undefined) return 0
    let pruned = 0
    for (const id of previous) {
      if (next.has(id)) continue
      const row = rows.get(id)
      if (row === undefined) continue
      if (row.connectorId !== undefined && row.connectorId !== connectorId) continue
      byToken.delete(row.tokenHash)
      rows.delete(id)
      pruned += 1
    }
    return pruned
  }

  /**
   * 一枚令牌现在的状态。
   *
   * **"已吊销"与"没见过"必须分开**：行还在但带 `revokedAt` 是操作者停用了这台设备
   * （电脑侧解禁或重扫），而压根没这行通常只是名册还没同步过来。
   * 软吊销保留原行正是为了能分辨这两件事（`issue-token.ts:84-90` 的说明）。
   */
  const verdictOf = (token: string): DeviceTokenVerdict => {
    if (token === '') return 'unknown'
    const deviceId = byToken.get(hashOf(token))
    if (deviceId === undefined) return 'unknown'
    return rows.get(deviceId)?.revokedAt === undefined ? 'ok' : 'revoked'
  }

  return {
    get stats() {
      let bound = 0
      for (const row of rows.values()) if (row.connectorId !== undefined) bound += 1
      return { devices: rows.size, bound }
    },

    publishedCounts() {
      const counts: Record<string, number> = {}
      for (const [connectorId, ids] of published) counts[connectorId] = ids.size
      return counts
    },

    register(connectorId, incoming) {
      let accepted = 0
      let refused = 0
      const next = new Set<string>()
      for (const row of incoming) {
        // 首配那一跳的临时身份**永不落表**（它不是设备，只是让 `pair` 能进门）。
        if (isPendingDevice(row.id)) continue
        if (row.tokenHash === '') continue
        const previous = rows.get(row.id)
        // **归属校验：别的连接器的行不许被覆盖**。这张表的键是设备 id，**不带租户前缀**
        // （设备 id 由设备公钥派生，正常不会撞）。没有这道闸，任何持有合法连接器令牌的
        // 人只要知道对方的设备 id，就能把那一行换成自己的摘要 —— 原设备从此换票
        // `401 device-unknown`（定向 DoS），而中转看不出异常。多连接器共用一个进程
        // 时这不是"会不会串"的问题，是"谁能写谁的键"的问题：答案必须是"只有主人"。
        if (
          previous !== undefined
          && previous.connectorId !== undefined
          && previous.connectorId !== connectorId
        ) {
          refused += 1
          continue
        }
        next.add(row.id)
        // 换令牌 = 同一 id 换摘要：旧摘要必须**立刻失效**，否则"换令牌"等于"多一把钥匙"。
        if (previous !== undefined) byToken.delete(previous.tokenHash)
        rows.set(row.id, { ...row, connectorId })
        byToken.set(row.tokenHash, row.id)
        accepted += 1
      }
      if (refused > 0) {
        // 只记行数与被拒的连接器：设备 id 本身不是秘密，但也不必进日志。
        log?.warn('roster.refused', { connectorId, refused })
      }
      // **差集即删除**（纪律 4）：上次报到、这次没报到的行必须消失。
      // 只增不减的话，电脑侧删掉/吊销一台设备后它在中转层还换得到票 ——
      // 2026-10-15 真机实测到这条（手机通过换票、死在连接器握手，无限"重连中…"）。
      const pruned = dropUnpublished(connectorId, next)
      published.set(connectorId, next)
      // 一次上报一个事件：面板要知道"这台电脑此刻有几台设备、这次收敛掉几行"。
      log?.debug('roster.applied', { connectorId, accepted, pruned, rows: rows.size })
      return accepted
    },

    authenticate(token) {
      if (verdictOf(token) !== 'ok') return undefined
      return byToken.get(hashOf(token))
    },

    classify(token) {
      return verdictOf(token)
    },

    connectorOf(deviceId) {
      const row = rows.get(deviceId)
      if (row === undefined || row.revokedAt !== undefined) return undefined
      return row.connectorId
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
        // **`published` 不清**：连接器回来时报一份更短的名册时，还要靠它算差集
        // （纪律 4）—— 清掉就等于"断开一次，过期的行又复活"。
        const rest: DeviceRegistration = {
          id: row.id,
          pairingId: row.pairingId,
          devPubEd: row.devPubEd,
          devPubDh: row.devPubDh,
          name: row.name,
          tokenHash: row.tokenHash,
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
