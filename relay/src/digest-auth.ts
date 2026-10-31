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
import { createTokenTable } from './token-table.ts'

/** 已认证的调用方。**只有连接器**：设备走名册，不走这张表。 */
export interface Authenticated {
  kind: 'connector'
  id: string
  /**
   * 多少台连接器属于同一个人（可选，来自配置里的 `owner`）。
   *
   * 中转本身不需要"用户"这个概念：路由、名册、票全都按 `(connectorId, deviceId)` 走，
   * 已经分得清"这台手机在哪台电脑名下"。`owner` 只服务**按人**的那些东西 ——
   * 限流（一个人的三台电脑共用一个桶，而不是每台各 60 rps）与日志归属。
   */
  owner?: string
}

/**
 * 限流桶的键。
 *
 * 配了 `owner` 就按人分桶：那台用户的三台电脑共用一个预算 —— 否则"多开两台电脑"
 * 就是绕过限流的免费办法。没配就退回按连接器分桶（保底行为，与旧配置一致）。
 */
export function rateKeyOf(who: Authenticated): string {
  return who.owner === undefined ? `connector:${who.id}` : `user:${who.owner}`
}

/** 一条令牌摘要（配置里的一行）。 */
export interface TokenDigest {
  kind: 'connector'
  /** 逻辑身份：连接器 id。 */
  id: string
  /** `sha256(令牌)` 的十六进制。 */
  hash: string
  /** 这台连接器属于谁（可选；同一人的多台电脑写同一个值）。见 `Authenticated.owner`。 */
  owner?: string
  /**
   * 这张令牌怎么来的：`auto` = 连接器自己在中转上兑换的（`POST /connector/enroll`）。
   *
   * **只用于展示与批量清理**：认证路径不看它 —— 自动签发出来的就是一张普通令牌，
   * 吊销/限流/名册与手工签发的完全一样。
   */
  source?: 'auto'
  /**
   * 吊销时间（§12 的中转表里就是 `revoked_at`：**软吊销**，行留着）。
   *
   * 留着而不是删掉，是为了将来能把"你被吊销了"与"这个令牌没见过"分开告诉设备
   * （今天两者都是 401 —— 那是有意的：对客户端来说下一步动作相同）。
   */
  revokedAt?: number
}

export interface DigestAuthenticator {
  (token: string): Authenticated | undefined
  /** 自检用：装了几条。 */
  readonly size: number
}

/**
 * 从摘要表建出**不可变**的 `authenticate`（启动装配用）。
 *
 * 校验失败（未知令牌）返回 `undefined` —— 调用方据此回 401，并把**不区分原因**作为原则
 * （"令牌不对"与"令牌已吊销"对客户端是同一件事：换票或重配）。
 *
 * 表本身是可变的（吊销/恢复要立刻生效），实现在 `token-table.ts`；这里只是把
 * "只需要认证函数"的调用方（`main.ts` 的自检、测试）留在旧形状上，保证校验规则
 * **只有一份**。
 */
export function createDigestAuthenticator(entries: readonly TokenDigest[]): DigestAuthenticator {
  const table = createTokenTable(entries)
  const authenticate = ((token: string) => table.authenticate(token)) as DigestAuthenticator & {
    size: number
  }
  Object.defineProperty(authenticate, 'size', { get: () => table.size })
  return authenticate
}
