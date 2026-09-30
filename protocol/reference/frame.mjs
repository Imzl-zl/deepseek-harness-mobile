/**
 * 帧层共用词汇（参考实现）。
 *
 * `seal` / `unseal` 在参考实现里是**可逆的明文包装**，不是加密：真实实现换成
 * X25519 协商 + AEAD 封箱（算法与 nonce 策略见 docs/subsystems/remote-channel.md §5），
 * 而帧的明文头字段（t / sid / seq）保持不变。
 * 这样 fixtures 只测恢复语义，不依赖任何密码学实现。
 *
 * `live` 是易变流式帧：不占会话 seq、不进重放窗口、不参与 ack、恢复时不回带。
 * 为什么需要它、以及中继路由视图为什么不含它，见
 * .agents/notes/implemented/2026-09-30-channel-review-corrections.md
 */

export const FRAME_TYPES = ['req', 'res', 'ev', 'live', 'ack', 'presence', 'ping', 'pong']

/** 中转允许读到并使用的字段；其余一律视为不透明内容。 */
export const ROUTING_KEYS = ['t', 'sid', 'seq']

export function seal(payload) {
  return JSON.stringify(payload)
}

export function unseal(box) {
  return JSON.parse(box)
}

/** 中转侧对一帧建立的路由视图：只有这三个字段。 */
export function routingOf(frame) {
  return { t: frame.t, sid: frame.sid, seq: frame.seq }
}
