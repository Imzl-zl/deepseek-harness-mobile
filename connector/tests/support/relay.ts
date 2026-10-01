/**
 * 测试替身：中转侧的有界重放窗口（**不是 connector 的产品代码**）。
 *
 * connector 不实现中转 —— 见 `docs/cookbook/channel-bootstrap.md` 第 3 步的移植表：
 * `relay.mjs` → 不需要，中转侧才有。但 fixture 的三角色拓扑
 * （手机 ⇄ 中转 ⇄ 电脑侧桥接）要求中转在场，所以它作为测试替身放在这里。
 *
 * 行为与 `protocol/reference/relay.mjs` 一致：按会话留存最近的若干帧、按游标给出
 * **连续**区间、区间不连续时明确说自己给不了（绝不「少发几条」）。它不产生修订号、
 * 不推断语义、也不解封 `box`。
 */
import { routingOf, type Frame, type RoutingView } from '../../src/protocol/frame.js'

export interface RelayFrame extends RoutingView {
  box: string
}

export interface Relay {
  put(frame: Frame): void
  /** 从 since 之后起能否给出一段连续帧；给不了返回 null，由电脑侧回答。 */
  since(sid: string, since: number): { frames: RelayFrame[] } | null
  evictAll(): void
  /** 供校验用：中转实际建立的路由视图字段。 */
  routingKeys(): string[][]
}

export function createRelay(windowSize = 1000): Relay {
  const windows = new Map<string, Array<{ routing: RoutingView; box: string }>>()

  return {
    put(frame) {
      const list = windows.get(frame.sid) ?? []
      // 路由视图与内容分开存：中转只读 routing，box 原样搬运
      list.push({ routing: routingOf(frame), box: frame.box })
      while (list.length > windowSize) list.shift()
      windows.set(frame.sid, list)
    },

    since(sid, since) {
      const list = windows.get(sid) ?? []
      const after = list.filter((entry) => entry.routing.seq > since)
      if (after.length === 0) return null
      let expected = since + 1
      for (const entry of after) {
        if (entry.routing.seq !== expected) return null
        expected += 1
      }
      return { frames: after.map((entry) => ({ ...entry.routing, box: entry.box })) }
    },

    evictAll() {
      windows.clear()
    },

    routingKeys() {
      return [...windows.values()].flat().map((entry) => Object.keys(entry.routing))
    },
  }
}
