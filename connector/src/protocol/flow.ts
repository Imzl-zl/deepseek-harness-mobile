/**
 * 流控窗口（契约 §4.3）。
 *
 * 发送方维护 `unacked`（已发但还没收到 `credit` 的帧数），上限 **W = 128**；
 * 达到上限即暂停发送。接收方**每收到一帧立即回 `credit { fc }`**（不要求落盘）。
 *
 * **这一层是连接层信用，与会话层的落盘水位是两件事**（契约 §4.3 明写）：
 * - 流控要求即时反馈，所以 `credit` 收到帧就回、不等落盘；
 * - 落盘要求持久确认，用 `persisted { sid, seq }`，手机落盘后才发。
 *
 * 混用一个 ack 会让两者互相拖累 —— 等 fsync 才能继续收帧。
 *
 * 两处策略在这里被写成可机械判定的函数，而不是散在发送路径的 if 里：
 * `ping` / `pong` 不占额度（否则满窗时保活会把自己饿死，双方互等超时）；
 * 满窗时优先暂停 `ev` 与 `live`（可丢可补），不压 `res` / `credit` / `persisted`
 * （它们是对端在等的应答或正确性所依赖的水位）。
 */
import type { WireFrame } from './frame.js'

/** 已发未 credit 的帧数上限（契约 §4.3）。 */
export const SEND_WINDOW_FRAMES = 128

export type FrameType = WireFrame['t']

/**
 * 该帧是否占用流控额度。
 *
 * `ping` / `pong` 不占：保活帧若占额度，满窗时双方都发不出 ping、也回不了 pong，
 * 会一起走进"半开检测 → 断开重连"的假故障。
 */
export function consumesCredit(t: FrameType): boolean {
  return t !== 'ping' && t !== 'pong'
}

/**
 * 满窗时该优先暂停哪些帧。
 *
 * `ev` / `live` 是可补的（`ev` 有重放窗口与快照兜底，`live` 本来就允许丢）；
 * `res` 是对端在等的应答，`credit` / `persisted` 是正确性依赖的水位 —— 压住它们
 * 会同时压住对方的推进。
 */
export function pausable(t: FrameType): boolean {
  return t === 'ev' || t === 'live'
}

export interface SendWindow {
  /** 现在能不能再发一帧 `t`。 */
  canSend(t: FrameType): boolean
  /**
   * 记一帧已发出。
   *
   * @returns `false` 表示**已经满窗、这一帧不该发出**；调用方必须据此回退，
   *   而不是"先发了再说"（那正是窗口要防的）。
   */
  onSent(fc: number, t: FrameType): boolean
  /** 收到对端的 `credit { fc }`。 */
  onCredit(fc: number): void
  /** 已发未 credit 的帧数。 */
  readonly unacked: number
}

/**
 * @param limit - 已发未 credit 的帧数上限，默认 {@link SEND_WINDOW_FRAMES}。
 */
export function createSendWindow(limit: number = SEND_WINDOW_FRAMES): SendWindow {
  let sent = 0
  // credit 携带的是"我刚收到的那个 fc"，所以它确认的是 [0, creditedFc]。
  let creditedFc = -1

  const unackedNow = (): number => Math.max(0, sent - (creditedFc + 1))

  return {
    canSend(t) {
      if (!consumesCredit(t)) return true
      return unackedNow() < limit
    },

    onSent(fc, t) {
      if (!consumesCredit(t)) return true
      if (unackedNow() >= limit) return false
      sent = Math.max(sent, fc + 1)
      return true
    },

    onCredit(fc) {
      // 只前进不后退：乱序或迟到的 credit 不该把窗口"放大"回一个已确认过的状态。
      creditedFc = Math.max(creditedFc, fc)
    },

    get unacked() {
      return unackedNow()
    },
  }
}
