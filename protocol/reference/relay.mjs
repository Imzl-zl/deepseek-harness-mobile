/**
 * 参考实现：中转侧的有界重放窗口。
 *
 * 它只做三件事：按会话留存最近的若干帧、按游标给出**连续**区间、在区间不连续时
 * 明确说自己给不了。它不产生修订号、不推断语义、也不解封 `box`。
 */
import { routingOf } from './frame.mjs'

export function createRelay(windowSize = 1000) {
  const windows = new Map()

  return {
    put(frame) {
      const list = windows.get(frame.sid) ?? []
      // 路由视图与内容分开存：中转只读 routing，box 原样搬运
      list.push({ routing: routingOf(frame), box: frame.box })
      while (list.length > windowSize) list.shift()
      windows.set(frame.sid, list)
    },

    /**
     * 从 since 之后起能否给出一段连续帧。
     * 给不了就返回 null——由电脑侧回答，绝不"少发几条"。
     */
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

    /** 供校验用：中转实际建立的路由视图字段。 */
    routingKeys() {
      return [...windows.values()].flat().map((entry) => Object.keys(entry.routing))
    },
  }
}
