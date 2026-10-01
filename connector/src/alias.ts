/**
 * 会话别名映射：`sid` ↔ `dshSessionId`（契约 §5.1、术语表）。
 *
 * `sid` 是电脑侧为每个 DSH 会话分配的**不透明路由标识**（16 字节随机、base64url）：
 * 中转只看得到它，看不到 DSH 会话 id，所以无法关联外部信息。它同时落在 AAD 的字符集
 * 要求里（`[A-Za-z0-9_-]`，base64url 天然满足）。
 *
 * ## 为什么需要 `reconcile`
 *
 * 两个方向存在两张表里，而**一次写入不可能原子地跨两张表**：崩在中间就会留下
 * 单向条目。两种残缺的后果完全不同：
 *
 * - 有 `by_session`、缺 `by_sid`：`sidOf` 查不到 → `ensure` 会**再分配一个新 sid** →
 *   同一会话有两个别名 → **手机端看到重复会话**。
 * - 有 `by_sid`、缺 `by_session`：入站 `sid` 校验失败 → 手机端拿着有效别名却被拒。
 *
 * 所以挂载时按 `by_session` 为**权威方向**对账：会话必须有且只有一个别名；
 * `by_sid` 里指向"没有回指"的条目视为残留并清掉。选 `by_session` 当权威，是因为
 * "一个 DSH 会话对应一个别名"是业务事实，而反向条目只是它的索引。
 */
import { randomBytes as nodeRandomBytes } from 'node:crypto'

import { ID_PATTERN } from './protocol/frame.js'

/** 别名长度（契约 §10 参数表：16 字节 base64url）。 */
export const SID_BYTES = 16

/** 分配别名时最多重试几次（128 位随机下第一次就撞的概率可以忽略，留几次只为稳妥）。 */
const MAX_ALLOC_ATTEMPTS = 4

/** `core` 域里用到的两张表的最小接口（与 `KvTable` 结构兼容）。 */
export interface AliasTable {
  get(key: string): string | undefined
  put(key: string, value: string): Promise<void>
  delete(key: string): Promise<boolean>
  keys(): IterableIterator<string>
}

export interface AliasStore {
  /** `sid → dshSessionId`。 */
  bySid: AliasTable
  /** `dshSessionId → sid`（权威方向）。 */
  bySession: AliasTable
}

export interface Aliases {
  sidOf(dshSessionId: string): string | undefined
  sessionOf(sid: string): string | undefined
  /** 取回或分配别名。同一会话重复调用返回同一个。 */
  ensure(dshSessionId: string): Promise<string>
  /**
   * 挂载时对账两个方向。返回被清理的残留条目数（>0 说明上次是崩在写中间的）。
   */
  reconcile(): Promise<number>
  /** 别名→会话元映射版本；`repo.info` 要报它（契约 §5.7）。分配或清理都会推进。 */
  readonly version: number
}

/** 生成一个 16 字节 base64url 别名。 */
export function newSid(randomBytes: (size: number) => Uint8Array): string {
  const bytes = randomBytes(SID_BYTES)
  return Buffer.from(bytes).toString('base64url')
}

export interface AliasOptions {
  /** 注入随机源；默认 `node:crypto` 的 `randomBytes`。 */
  randomBytes?: (size: number) => Uint8Array
  /** 起始版本号（从持久化的 meta 读回来）。 */
  initialVersion?: number
}

export function createAliases(store: AliasStore, options: AliasOptions = {}): Aliases {
  const randomBytes = options.randomBytes ?? ((size: number) => nodeRandomBytes(size))

  let version = options.initialVersion ?? 0

  return {
    sidOf(dshSessionId) {
      return store.bySession.get(dshSessionId)
    },

    sessionOf(sid) {
      return store.bySid.get(sid)
    },

    async ensure(dshSessionId) {
      const existing = store.bySession.get(dshSessionId)
      if (existing !== undefined) return existing

      for (let attempt = 0; attempt < MAX_ALLOC_ATTEMPTS; attempt += 1) {
        const sid = newSid(randomBytes)
        // 别名要过 AAD 的字符集要求；base64url 天然满足，但这里是唯一的生成点，
        // 断言一次比让它在握手时才炸要好。
        if (!ID_PATTERN.test(sid)) {
          throw new Error(`生成的别名不符合 AAD 字符集：${sid}`)
        }
        // 撞了别的会话就重来。128 位随机下几乎不可能，但"同一别名指向两个会话"
        // 会让手机端拿到错会话的帧 —— 代价不对称，值得查。
        if (store.bySid.get(sid) !== undefined) continue

        // 先写权威方向：崩在中间只会留下"有 sid 无回指"（可被 reconcile 清掉），
        // 而不是"有会话无 sid"（会导致重复分配别名）。
        await store.bySession.put(dshSessionId, sid)
        await store.bySid.put(sid, dshSessionId)
        version += 1
        return sid
      }
      throw new Error(`连续 ${MAX_ALLOC_ATTEMPTS} 次都没分到未被占用的别名`)
    },

    async reconcile() {
      let cleaned = 0

      // 1) 清掉指向"没有回指"的 sid（残留）。
      for (const sid of [...store.bySid.keys()]) {
        const session = store.bySid.get(sid)
        if (session === undefined) continue
        if (store.bySession.get(session) !== sid) {
          await store.bySid.delete(sid)
          cleaned += 1
        }
      }

      // 2) 给缺了 sid 的会话补一个（权威方向说了算）。
      for (const session of [...store.bySession.keys()]) {
        const sid = store.bySession.get(session)
        if (sid === undefined) continue
        if (store.bySid.get(sid) !== session) {
          await store.bySid.put(sid, session)
        }
      }

      if (cleaned > 0) version += 1
      return cleaned
    },

    get version() {
      return version
    },
  }
}
