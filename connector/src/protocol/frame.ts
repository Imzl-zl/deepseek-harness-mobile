/**
 * 帧层共用词汇。
 *
 * `seal` / `unseal` 在本层是**可逆的明文包装**，不是加密：真实实现换成
 * X25519 协商 + AEAD 封箱（算法与 nonce 策略见 `docs/subsystems/remote-channel.md` §5），
 * 而帧的明文头字段（t / sid / seq）保持不变。
 * 这样 fixtures 只测恢复语义，不依赖任何密码学实现。
 *
 * `live` 是易变流式帧：不占会话 seq、不进重放窗口、不参与 ack、恢复时不回带。
 * 为什么需要它、以及中继路由视图为什么不含它，见
 * `.agents/notes/implemented/2026-09-30-channel-review-corrections.md`
 *
 * 移植源：`protocol/reference/frame.mjs`（行为基准，不是可搬运的代码）。
 */

/** 线上帧类型。 */
export const FRAME_TYPES = ['req', 'res', 'ev', 'live', 'ack', 'presence', 'ping', 'pong'] as const

export type FrameType = (typeof FRAME_TYPES)[number]

/** 中转允许读到并使用的字段；其余一律视为不透明内容。 */
export const ROUTING_KEYS = ['t', 'sid', 'seq'] as const

export type RoutingKey = (typeof ROUTING_KEYS)[number]

/** 中转侧对一帧建立的路由视图：只有这三个字段。 */
export interface RoutingView {
  t: FrameType
  sid: string
  seq: number
}

/** 线上帧：路由头 + 不透明封箱内容。 */
export interface Frame extends RoutingView {
  box: string
}

export function seal(payload: unknown): string {
  return JSON.stringify(payload)
}

export function unseal<T>(box: string): T {
  return JSON.parse(box) as T
}

export function routingOf(frame: Frame): RoutingView {
  return { t: frame.t, sid: frame.sid, seq: frame.seq }
}
