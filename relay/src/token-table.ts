/**
 * 可变的令牌摘要表（契约 §12.2：中转只存摘要）。
 *
 * ## 为什么从"启动时建死"改成可变
 *
 * 面板要能**吊销立刻生效**。原先摘要表在启动那一刻由 `createDigestAuthenticator`
 * 建好就再也不变，吊销只能改配置 + 重启 —— 那会让"已吊销的连接器"在重启前
 * 继续连得上，也让管理面没法叫管理面。
 *
 * ## 三条纪律（与 `device-registry.ts` 同一个口径）
 *
 * 1. **只存摘要**：表里是 `sha256(令牌)` 的十六进制；明文从不出现在任何持久形态里。
 * 2. **单一身份键**：`id` 是逻辑身份，`hash` 是凭据面。同一个 `id` 出现两次会
 *    拒绝建表 —— 吊销/恢复按 `id` 定位，重复会让"吊销的是哪一条"变成猜。
 * 3. **吊销是软吊销**：条目留在表里、带 `revokedAt`（配置里也留着），
 *    只是不再进认证索引。
 *
 * 可变性只在这一层：`authenticate` 仍是"算一次哈希再查表"，与旧实现逐字同义。
 *
 * Note: 为什么必须是可变的、为什么同一 id 重复要拒绝启动 —— 见
 * `.agents/notes/implemented/2026-10-30-relay-mutable-token-table-and-admin-credential.md`
 */
import { createHash } from 'node:crypto'

import { connectorIdOf, type Authenticated, type TokenDigest } from './digest-auth.ts'

const digestOf = (token: string): string => createHash('sha256').update(token, 'utf8').digest('hex')

/**
 * 面板能看到的行：**没有 `hash`**。
 *
 * 摘要也不该离开这个模块 —— 管理面只需要"有哪几个身份、谁被吊销了"。
 */
export interface TokenRow {
  readonly id: string
  readonly owner?: string
  /** accounts 模式下的账号 id。 */
  readonly userId?: string
  /** 已绑定的连接器 id（新令牌第一次连上时写入）。 */
  readonly connectorId?: string
  /** 控制台里给这台电脑起的名字。 */
  readonly name?: string
  readonly createdAt?: number
  /** `auto` = 连接器自己兑换的（面板据此标"来源：自动"，并支持一键清理）。 */
  readonly source?: 'auto'
  readonly revokedAt?: number
}

export interface TokenTable {
  /** 认证热路径：令牌原文 → 身份（认不出 / 已吊销 → `undefined`）。 */
  authenticate(token: string): Authenticated | undefined
  /** 管理面读面：身份清单（不含摘要）。 */
  list(): readonly TokenRow[]
  /**
   * 按 `id` 软吊销。返回"这个身份现在是否处于吊销态"：
   * 不存在 → `false`；已吊销过 → `true`（幂等，与 `revokeTokenInConfig` 同义）。
   */
  revoke(id: string, at?: number): boolean
  /** 把一条软吊销的条目放回认证索引。返回它现在是否可用。 */
  restore(id: string): boolean
  /**
   * **硬删除**一条记录（行与摘要一起消失，不可恢复）。
   *
   * 调用方必须先确认它已吊销：这里只负责删，不替你判"该不该删"——
   * 那条规矩（先停用再删）在路由层，因为它对用户可见。
   */
  remove(id: string): boolean
  /**
   * 运行时追加一条**刚签发**的令牌（自动兑换用，见 `server.ts` 的 `/connector/enroll`）。
   *
   * 摘要只在本模块内流转：调用方给的是 `TokenDigest`（含 `hash`），本表不回读任何明文。
   * 重复 `id` / 重复摘要直接抛 —— 与启动时的校验同一条纪律。
   */
  add(entry: TokenDigest): void
  /** 当前**可用**条目数（已吊销的不算，与旧 `size` 同义）。 */
  readonly size: number
  /** `connectorId → 额度主体`（userId 优先，旧配置退回 owner）。 */
  ownerOf(connectorId: string): string | undefined
  /** `connectorId → 账号 id`（旧令牌没有）。 */
  userIdOf(connectorId: string): string | undefined
  /** `connectorId → 令牌 id`（按控制面自报的 id 查签发记录）。 */
  tokenIdOf(connectorId: string): string | undefined
  /**
   * 把一枚新令牌绑定到第一次连上来的 `connectorId`。
   *
   * 已绑定的令牌再绑必须一致（`true`）；不一致 / 该 connectorId 已被别的记录占用 → `false`。
   */
  bindConnector(id: string, connectorId: string): boolean
  /** 管理面把一枚旧令牌归属给账号（`null` = 取消归属）。 */
  setUserId(id: string, userId: string | null): boolean
  /** 改展示名（控制台重命名）。 */
  setName(id: string, name: string): boolean
  /** 清掉绑定（那台电脑重装过、pcId 变了时用）。 */
  clearConnectorBinding(id: string): boolean
  /** 这个账号名下的令牌数（默认只数未吊销的）。 */
  countForUser(userId: string, includeRevoked?: boolean): number
  listForUser(userId: string): readonly TokenRow[]
}

export interface TokenTableOptions {
  now?: () => number
}

export function createTokenTable(
  entries: readonly TokenDigest[],
  options: TokenTableOptions = {},
): TokenTable {
  const now = options.now ?? (() => Date.now())
  /** `id → 条目`（带摘要，只在模块内流转）。 */
  const byId = new Map<string, TokenDigest>()
  /** `摘要 → 身份`（认证热路径，单独一张索引）。 */
  const byHash = new Map<string, Authenticated>()
  /** `connectorId → 令牌 id`：额度主体、账号归属与控制面自报都对它查。 */
  const byConnector = new Map<string, string>()

  const connectorKeyOf = (entry: TokenDigest): string => connectorIdOf(entry)

  const identityOf = (entry: TokenDigest): Authenticated => ({
    kind: 'connector',
    id: entry.id,
    ...(entry.userId === undefined || entry.userId === '' ? {} : { userId: entry.userId }),
    ...(entry.connectorId === undefined || entry.connectorId === '' ? {} : { connectorId: entry.connectorId }),
    ...(entry.owner === undefined || entry.owner === '' ? {} : { owner: entry.owner }),
  })

  const rowOf = (entry: TokenDigest): TokenRow => ({
    id: entry.id,
    ...(entry.owner === undefined ? {} : { owner: entry.owner }),
    ...(entry.userId === undefined ? {} : { userId: entry.userId }),
    ...(entry.connectorId === undefined ? {} : { connectorId: entry.connectorId }),
    ...(entry.name === undefined ? {} : { name: entry.name }),
    ...(entry.createdAt === undefined ? {} : { createdAt: entry.createdAt }),
    ...(entry.source === undefined ? {} : { source: entry.source }),
    ...(entry.revokedAt === undefined ? {} : { revokedAt: entry.revokedAt }),
  })

  for (const entry of entries) {
    // 表里只放连接器令牌：设备凭据在名册（见 `digest-auth.ts` 的文件头）。
    // v1 遗留的 device 条目会让"起来了但谁都连不上"，所以在入口就拒绝。
    if (entry.kind !== 'connector') {
      throw new Error(
        `令牌摘要表里出现 ${String(entry.kind)} 条目（id=${entry.id}）：v2 起中转只签连接器令牌，`
        + '设备令牌由电脑侧签发、摘要经 POST /devices 进名册。请删掉这条并重新出码配对。',
      )
    }
    // 同一个 id 两次：吊销/恢复按 id 定位，重复会让"吊销的是哪一条"变成猜。
    // 配置写入方（`appendTokenToConfig`）本来就按 (kind,id) 去重，这里接住手写的重复。
    if (byId.has(entry.id)) {
      throw new Error(
        `令牌摘要表里同一个 id 出现两次（${entry.id}）：吊销与恢复按 id 定位，重复条目会让`
        + '「吊销的是哪一条」变成猜。拒绝启动，先修配置',
      )
    }
    byId.set(entry.id, { ...entry })
    // **同一个 connectorId 只能有一条记录**：控制面自报的 `?id=`、额度主体与账号归属
    // 都靠这张索引；两条记录指向同一个连接器时，"吊销的是哪一条"又变成猜。
    const connectorKey = connectorKeyOf(entry)
    if (byConnector.has(connectorKey)) {
      throw new Error(
        `令牌摘要表里有两个条目指向同一个连接器（${connectorKey}）：拒绝启动，先修配置`,
      )
    }
    byConnector.set(connectorKey, entry.id)
    // **已吊销的摘要不进认证索引**：它留在表里是为了可辨识，不是为了还能用。
    if (entry.revokedAt !== undefined) continue
    // 同一条摘要不该出现两次（配置写重了）：后一条覆盖前一条会让"谁是谁"变得看运气。
    if (byHash.has(entry.hash)) {
      throw new Error(`令牌摘要表里有重复条目（${entry.hash.slice(0, 8)}…）：拒绝启动，先修配置`)
    }
    byHash.set(entry.hash, identityOf(entry))
  }

  return {
    get size() {
      return byHash.size
    },

    authenticate(token) {
      if (token === '') return undefined
      return byHash.get(digestOf(token))
    },

    list() {
      return [...byId.values()].map(rowOf)
    },

    ownerOf(connectorId) {
      const id = byConnector.get(connectorId)
      if (id === undefined) return undefined
      const entry = byId.get(id)
      if (entry === undefined) return undefined
      return entry.userId ?? entry.owner
    },

    userIdOf(connectorId) {
      const id = byConnector.get(connectorId)
      return id === undefined ? undefined : byId.get(id)?.userId
    },

    tokenIdOf(connectorId) {
      return byConnector.get(connectorId)
    },

    bindConnector(id, connectorId) {
      const entry = byId.get(id)
      if (entry === undefined) return false
      if (entry.connectorId !== undefined) return entry.connectorId === connectorId
      // 这个连接器已经有别的记录：两枚令牌抢同一个 `?id=`，不能靠"谁先连上"决定。
      if (byConnector.has(connectorId)) return false
      const previousKey = connectorKeyOf(entry)
      const updated: TokenDigest = { ...entry, connectorId }
      byId.set(id, updated)
      // 未绑定时索引键是令牌 id；绑定后应只剩 `connectorId` 这一个键。
      if (previousKey !== connectorId && byConnector.get(previousKey) === id) byConnector.delete(previousKey)
      byConnector.set(connectorId, id)
      if (updated.revokedAt === undefined) byHash.set(updated.hash, identityOf(updated))
      return true
    },

    setUserId(id, userId) {
      const entry = byId.get(id)
      if (entry === undefined) return false
      const updated: TokenDigest = { ...entry }
      if (userId === null) delete updated.userId
      else updated.userId = userId
      byId.set(id, updated)
      if (updated.revokedAt === undefined) byHash.set(updated.hash, identityOf(updated))
      return true
    },

    setName(id, name) {
      const entry = byId.get(id)
      if (entry === undefined) return false
      byId.set(id, { ...entry, name })
      return true
    },

    clearConnectorBinding(id) {
      const entry = byId.get(id)
      if (entry === undefined) return false
      if (entry.connectorId === undefined) return true
      const key = connectorKeyOf(entry)
      if (byConnector.get(key) === id) byConnector.delete(key)
      const { connectorId: _dropped, ...rest } = entry
      byId.set(id, rest)
      // 回到"未绑定"形状：索引键是令牌自己的 id，等下一次首连再绑。
      byConnector.set(id, id)
      if (rest.revokedAt === undefined) byHash.set(rest.hash, identityOf(rest))
      return true
    },

    countForUser(userId, includeRevoked = false) {
      let count = 0
      for (const entry of byId.values()) {
        if (entry.userId !== userId) continue
        if (!includeRevoked && entry.revokedAt !== undefined) continue
        count += 1
      }
      return count
    },

    listForUser(userId) {
      return [...byId.values()].filter((entry) => entry.userId === userId).map(rowOf)
    },

    revoke(id, at = now()) {
      const entry = byId.get(id)
      if (entry === undefined) return false
      // 先摘索引再记账：任何顺序下"索引里没有它"都是立刻成立的。
      byHash.delete(entry.hash)
      if (entry.revokedAt === undefined) byId.set(id, { ...entry, revokedAt: at })
      return true
    },

    remove(id) {
      const entry = byId.get(id)
      if (entry === undefined) return false
      byHash.delete(entry.hash)
      byId.delete(id)
      const key = connectorKeyOf(entry)
      if (byConnector.get(key) === id) byConnector.delete(key)
      return true
    },

    add(entry) {
      if (byId.has(entry.id)) throw new Error(`令牌表里已经有 id=${entry.id} 的条目`)
      if (byHash.has(entry.hash)) throw new Error('这条摘要已经在表里')
      const key = connectorKeyOf(entry)
      if (byConnector.has(key)) throw new Error(`连接器 ${key} 已经有别的令牌记录`)
      byId.set(entry.id, { ...entry })
      byConnector.set(key, entry.id)
      if (entry.revokedAt === undefined) byHash.set(entry.hash, identityOf(entry))
    },

    restore(id) {
      const entry = byId.get(id)
      if (entry === undefined) return false
      const active: TokenDigest = {
        kind: 'connector',
        id: entry.id,
        hash: entry.hash,
        ...(entry.owner === undefined ? {} : { owner: entry.owner }),
        ...(entry.userId === undefined ? {} : { userId: entry.userId }),
        ...(entry.connectorId === undefined ? {} : { connectorId: entry.connectorId }),
        ...(entry.name === undefined ? {} : { name: entry.name }),
        ...(entry.createdAt === undefined ? {} : { createdAt: entry.createdAt }),
        ...(entry.source === undefined ? {} : { source: entry.source }),
      }
      byId.set(id, active)
      byHash.set(active.hash, identityOf(active))
      return true
    },
  }
}
