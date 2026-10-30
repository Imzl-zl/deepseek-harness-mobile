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

import type { Authenticated, TokenDigest } from './digest-auth.ts'

const digestOf = (token: string): string => createHash('sha256').update(token, 'utf8').digest('hex')

/**
 * 面板能看到的行：**没有 `hash`**。
 *
 * 摘要也不该离开这个模块 —— 管理面只需要"有哪几个身份、谁被吊销了"。
 */
export interface TokenRow {
  readonly id: string
  readonly owner?: string
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
  /** 当前**可用**条目数（已吊销的不算，与旧 `size` 同义）。 */
  readonly size: number
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

  const identityOf = (entry: TokenDigest): Authenticated => ({
    kind: 'connector',
    id: entry.id,
    ...(entry.owner === undefined || entry.owner === '' ? {} : { owner: entry.owner }),
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
      const rows: TokenRow[] = []
      for (const entry of byId.values()) {
        rows.push({
          id: entry.id,
          ...(entry.owner === undefined ? {} : { owner: entry.owner }),
          ...(entry.revokedAt === undefined ? {} : { revokedAt: entry.revokedAt }),
        })
      }
      return rows
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
      return true
    },

    restore(id) {
      const entry = byId.get(id)
      if (entry === undefined) return false
      const active: TokenDigest = {
        kind: 'connector',
        id: entry.id,
        hash: entry.hash,
        ...(entry.owner === undefined ? {} : { owner: entry.owner }),
      }
      byId.set(id, active)
      byHash.set(active.hash, identityOf(active))
      return true
    },
  }
}
