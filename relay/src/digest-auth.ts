/**
 * 中转的令牌校验（契约 §12.2：**中转只存摘要**）。
 *
 * 于是配置里存的也是摘要（`sha256(token)` 的十六进制），而校验就是"算一次哈希再查表" ——
 * 明文令牌**从不出现在中转的任何持久形态里**，这正是 §12.2 那条表结构的意图。
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

import type { Authenticated } from './http-face.ts'

/** 一条令牌摘要（配置里的一行）。 */
export interface TokenDigest {
  kind: 'device' | 'connector'
  /** 逻辑身份：设备 id 或连接器 id。 */
  id: string
  /** `sha256(令牌)` 的十六进制。 */
  hash: string
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
    // 同一条摘要不该出现两次（配置写重了）：后一条覆盖前一条会让"谁是谁"变得看运气。
    if (table.has(entry.hash)) {
      throw new Error(`令牌摘要表里有重复条目（${entry.hash.slice(0, 8)}…）：拒绝启动，先修配置`)
    }
    table.set(entry.hash, { kind: entry.kind, id: entry.id })
  }

  const authenticate = ((token: string) => table.get(digestOf(token))) as DigestAuthenticator & {
    size: number
  }
  Object.defineProperty(authenticate, 'size', { get: () => table.size })
  return authenticate
}
