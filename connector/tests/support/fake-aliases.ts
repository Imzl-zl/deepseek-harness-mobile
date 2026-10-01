/**
 * 别名表的测试替身：两个方向都在（契约 §5.1）。
 *
 * `ensure` 与 `sessionOf` 是一对反函数，测试里若只假一个，就会出现
 * "写得出来但跑不通"的断言（`session.list` 只用到 `ensure`，而 `job.list` 要反解）。
 * 所以替身同时提供两个方向，并且**保留真实语义**：`ensure` 幂等、反解查不到就是 `undefined`。
 */
import type { AliasPort } from '../../src/handlers.js'

export interface FakeAliases extends AliasPort {
  /** 直接看内容（断言"分配了什么"用）。 */
  readonly bySid: Map<string, string>
}

export function createFakeAliases(options: {
  /** 别名怎么生成；默认 `sid_<dshSessionId>`。手机侧看到的一律是不透明的，测试里可换成定值。 */
  sidFor?: (dshSessionId: string) => string
} = {}): FakeAliases {
  const sidFor = options.sidFor ?? ((dshSessionId: string) => `sid_${dshSessionId}`)
  const bySid = new Map<string, string>()
  const bySession = new Map<string, string>()

  return {
    bySid,
    ensure(dshSessionId) {
      const existing = bySession.get(dshSessionId)
      if (existing !== undefined) return Promise.resolve(existing)
      const sid = sidFor(dshSessionId)
      bySession.set(dshSessionId, sid)
      bySid.set(sid, dshSessionId)
      return Promise.resolve(sid)
    },
    sessionOf: (sid) => bySid.get(sid),
  }
}
