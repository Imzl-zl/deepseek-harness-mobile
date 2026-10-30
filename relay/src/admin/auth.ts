/**
 * 管理面凭据（中转自带面板的唯一入口）。
 *
 * ## 为什么单独一张表，不复用连接器令牌
 *
 * 1. 连接器令牌的权力是"替一台电脑报名册、拨数据面"；把它放进浏览器，等于把
 *    长期电脑凭据交给一个网页。管理面只需要"看与管"，权限小得多。
 * 2. 摘要表在 `digest-auth.ts` / `token-table.ts` 里**硬拒非 connector 条目**，
 *    复用就要在那边开口子，而"表里只有连接器"这条正是 v2 的分层。
 *
 * ## 三条性质
 *
 * 1. **只存摘要**：配置里是 `sha256(令牌)` 的十六进制，与连接器令牌同一纪律（§12.2）。
 * 2. **原样比较摘要**：先把请求带来的令牌算成摘要再比 —— 明文从不进日志、不进内存表。
 * 3. **认不出就 `undefined`**：调用方据此回 401，且**不返回任何数据**。
 *
 * 不设 cookie：浏览器不会自动带 `Authorization`，所以这套面天然没有 CSRF 可打
 * （写操作那批同样只认这个头）。
 */
import { createHash } from 'node:crypto'

/** 已通过管理面认证的调用方。目前只有一个字段：配置里那个 `id`。 */
export interface AdminIdentity {
  readonly id: string
}

export interface AdminAuthenticator {
  (token: string): AdminIdentity | undefined
  /** 配置里的管理身份 id（日志归属用；不是秘密）。 */
  readonly id: string
}

/** 配置里的一段：只放摘要，不放明文。 */
export interface AdminDigest {
  id: string
  /** `sha256(令牌)` 的十六进制。 */
  hash: string
}

const digestOf = (token: string): string => createHash('sha256').update(token, 'utf8').digest('hex')

export function createAdminAuthenticator(admin: AdminDigest): AdminAuthenticator {
  const expected = admin.hash.toLowerCase()
  const authenticate = ((token: string) => {
    if (token === '') return undefined
    return digestOf(token) === expected ? { id: admin.id } : undefined
  }) as AdminAuthenticator & { id: string }
  Object.defineProperty(authenticate, 'id', { get: () => admin.id })
  return authenticate
}
