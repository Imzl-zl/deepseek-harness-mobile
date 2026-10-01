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
 * 满窗时**只压** `ev` 与 `live`（可丢可补），不压 `res` / `credit` / `persisted`
 * （它们是对端在等的应答或正确性所依赖的水位 —— 压住会死锁：手机在等 `res`，
 * 而 `res` 因为窗口满发不出去）。
 *
 * `credit` 自己**不再回** `credit`（见 `elicitsCredit`）：它确认的是"我收到了你那一帧"，
 * 若它也要被确认，两端会互相刷 ack 停不下来。
 */
import { ProtocolError } from './errors.js'
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
 * 满窗时该压住哪些帧。
 *
 * `ev` / `live` 是可补的（`ev` 有重放窗口与快照兜底，`live` 本来就允许丢）；
 * `res` 是对端在等的应答，`credit` / `persisted` 是正确性依赖的水位 —— 压住它们
 * 会同时压住对方的推进。
 */
export function pausable(t: FrameType): boolean {
  return t === 'ev' || t === 'live'
}

/**
 * 收到这一帧之后要不要回 `credit`。
 *
 * 只有 `credit` 自己例外：它是"我收到了"的确认，再确认它就变成两端互相刷 ack。
 * 契约 §4.3 的原话是"每收到一帧立即回 `credit`"，这句在代码里的正确读法就是本函数。
 */
export function elicitsCredit(t: FrameType): boolean {
  return t !== 'credit'
}

/**
 * `credit` 的载荷（契约 §4.3）：**累计确认**"我已收到 `[0, ack]`"。
 *
 * 它放在箱里而不是帧头：帧头的 `fc` 是发送方向自己的计数器（nonce 与重放防护的来源），
 * 而 `ack` 说的是对端的计数器 —— 同一个字段不能有两个意思。顺带把伪造也堵住：
 * 不经认证的 ack 能让对端误以为窗口已放开。
 */
export function encodeCredit(ack: number): string {
  return JSON.stringify({ ack })
}

/** 解 `credit` 载荷。坏值抛 `protocol/bad-frame`（对端发了个读不懂的 ack）。 */
export function decodeCredit(box: string): number {
  let parsed: unknown
  try {
    parsed = JSON.parse(box)
  } catch (error) {
    throw new ProtocolError('protocol/bad-frame', `credit 载荷不是合法 JSON：${String(error)}`)
  }
  const ack =
    typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)
      ? (parsed as Record<string, unknown>)['ack']
      : undefined
  if (typeof ack !== 'number' || !Number.isSafeInteger(ack) || ack < 0) {
    throw new ProtocolError('protocol/bad-frame', `credit.ack 必须是非负安全整数，收到 ${String(ack)}`)
  }
  return ack
}

export interface SendWindow {
  /**
   * 现在能不能发这一帧。
   *
   * 判定包含**优先级**：不占额度的帧（`ping` / `pong`）与不可暂停的帧
   * （`req` / `res` / `credit` / `persisted`）恒为真 —— 窗口只压可补帧。
   */
  canSend(t: FrameType): boolean
  /** 记一帧**真的发出去了**（调用方只在发出去之后调）。 */
  onSent(fc: number, t: FrameType): void
  /** 收到对端的 `credit { fc }`。 */
  onCredit(fc: number): void
  /** 已发未 credit 的帧数。 */
  readonly unacked: number
}

/**
 * @param limit - 已发未 credit 的帧数上限，默认 {@link SEND_WINDOW_FRAMES}。
 */
export function createSendWindow(limit: number = SEND_WINDOW_FRAMES): SendWindow {
  // credit 携带的是"我刚收到的那个 fc"，所以它确认的是 [0, creditedFc]。
  let creditedFc = -1
  let sent = 0

  const unackedNow = (): number => Math.max(0, sent - (creditedFc + 1))

  return {
    canSend(t) {
      if (!consumesCredit(t)) return true
      // 只压可补帧：压住 `res` / `credit` / `persisted` 会让对端等一个永远不会来的应答。
      if (!pausable(t)) return true
      return unackedNow() < limit
    },

    onSent(fc, t) {
      if (!consumesCredit(t)) return
      sent = Math.max(sent, fc + 1)
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
