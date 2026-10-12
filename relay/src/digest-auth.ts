/**
 * 中转的令牌校验（契约 §12.2：**中转只存摘要**）。
 *
 * 于是配置里存的也是摘要（`sha256(token)` 的十六进制），而校验就是"算一次哈希再查表" ——
 * 明文令牌**从不出现在中转的任何持久形态里**，这正是 §12.2 那条表结构的意图。
 *
 * ## 这张表只服务**连接器**令牌
 *
 * 设备令牌不在这里：它由**电脑侧签发**、摘要经 `POST /devices` 进名册（§8.2）。
 * 中转自己签设备令牌 = 转发器凭空造出"我是某台设备"的凭据，正是 v2 否掉的形状
 * （`pairing-v2.md` §1：中转只做连接路由；身份判定在电脑侧）。
 * 所以表里出现 `device` 条目**直接抛错**：那种配置在中转起来之后也只会得到 403，
 * 而"起来了但谁都连不上"比"起不来"难查得多。
 *
 * ## 两处必须的细节
 *
 * 1. **比较用哈希，不用 `===` 比原文**：原文比较要求我们把令牌留在内存里，
 *    而这里从始到终只有摘要。
 * 2. **查不到就 `undefined`**（不抛）：`http-face` / `server.ts` 已经按"未认证"处理它
 *    （401），抛异常只会让调用方多写一层 catch 而行为不变。
 *
 * 这一层零依赖、可脱离网络测。
 */
import { createHash } from 'node:crypto'

/** 已认证的调用方。**只有连接器**：设备走名册，不走这张表。 */
export interface Authenticated {
  kind: 'connector'
  id: string
}

/** 一条令牌摘要（配置里的一行）。 */
export interface TokenDigest {
  kind: 'connector'
  /** 逻辑身份：连接器 id。 */
  id: string
  /** `sha256(令牌)` 的十六进制。 */
  hash: string
  /**
   * 吊销时间（§12 的中转表里就是 `revoked_at`：**软吊销**，行留着）。
   *
   * 留着而不是删掉，是为了将来能把"你被吊销了"与"这个令牌没见过"分开告诉设备
   * （今天两者都是 401 —— 那是有意的：对客户端来说下一步动作相同）。
   */
  revokedAt?: number
}

const digestOf = (token: string): string => createHash('sha256').update(token, 'utf8').digest('hex')

export interface DigestAuthenticator {
  (token: string): Authenticated | undefined
  /** 自检用：装了几条。 */
  readonly size: number
}

/**
 * 从摘要表建出 `authenticate`。
 *
 * 校验失败（未知令牌）返回 `undefined` —— 调用方据此回 401，并把**不区分原因**作为原则
 * （"令牌不对"与"令牌已吊销"对客户端是同一件事：换票或重配）。
 */
export function createDigestAuthenticator(entries: readonly TokenDigest[]): DigestAuthenticator {
  const table = new Map<string, Authenticated>()
  for (const entry of entries) {
    // 表里只放连接器令牌：设备凭据在名册（见文件头）。v1 遗留的 device 条目
    // 会让"起来了但谁都连不上"，所以在入口就拒绝，而不是等它对 403。
    if (entry.kind !== 'connector') {
      throw new Error(
        `令牌摘要表里出现 ${String(entry.kind)} 条目（id=${entry.id}）：v2 起中转只签连接器令牌，`
        + '设备令牌由电脑侧签发、摘要经 POST /devices 进名册。请删掉这条并重新出码配对。',
      )
    }
    // **已吊销的摘要不进表**：它留在配置里是为了可辨识，不是为了还能用。
    if (entry.revokedAt !== undefined) continue
    // 同一条摘要不该出现两次（配置写重了）：后一条覆盖前一条会让"谁是谁"变得看运气。
    if (table.has(entry.hash)) {
      throw new Error(`令牌摘要表里有重复条目（${entry.hash.slice(0, 8)}…）：拒绝启动，先修配置`)
    }
    table.set(entry.hash, { kind: 'connector', id: entry.id })
  }

  const authenticate = ((token: string) => table.get(digestOf(token))) as DigestAuthenticator & {
    size: number
  }
  Object.defineProperty(authenticate, 'size', { get: () => table.size })
  return authenticate
}
