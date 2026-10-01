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

// ---------------------------------------------------------------------------
// 以下为**真实线级**帧层（契约 §3）。上面那部分是 fixtures 用的词汇层
// （`protocol/reference/frame.mjs` 的对应物，`seal` / `unseal` 在那里是可逆占位）。
// 两层刻意放在同一文件：设计文档 §1.2 把「帧编解码 + AAD 规范化」都归给 frame.ts。
// ---------------------------------------------------------------------------

/** 帧版本。对端版本不支持即 `protocol/unsupported-version`（契约 §3.1）。 */
export const WIRE_VERSION = 1

/** 单帧上限 8 MiB（契约 §3）。发送侧不得发出，收到即 `protocol/bad-frame`。 */
export const MAX_FRAME_BYTES = 8 * 1024 * 1024

/**
 * **中继的路由视图是四个字段**（契约 §3）：`t`、`sid`、`seq`、`fc`。
 *
 * 注意它与上面 `ROUTING_KEYS`（三个字段）**不是同一件事**：那是 fixtures 词汇层，
 * 产品实现比它多一个 `fc`（`protocol/reference/frame.mjs` 的注释也点明了这处差异）。
 */
export const WIRE_ROUTING_KEYS = ['t', 'sid', 'seq', 'fc'] as const

export type WireRoutingKey = (typeof WIRE_ROUTING_KEYS)[number]

/** 中继侧对一帧建立的路由视图。 */
export interface WireRoutingView {
  t: string
  sid?: string
  seq?: number
  fc?: number
}

/**
 * 线上帧（契约 §3）。**明文头只保留路由、补课与密码学需要的最小字段**；
 * 方法名、事件类型与内容全在密封载荷 `box` 里。`res ok:false` 的错误也封箱。
 */
export type WireFrame =
  | { v: 1; t: 'hello'; id: string; box: string }
  | { v: 1; t: 'hello-ack'; id: string; box: string }
  | { v: 1; t: 'ping'; fc: number }
  | { v: 1; t: 'pong'; fc: number }
  | { v: 1; t: 'credit'; fc: number }
  | { v: 1; t: 'req'; id: string; sid?: string; fc: number; box: string }
  | { v: 1; t: 'res'; id: string; sid?: string; fc: number; ok: true; box: string }
  | { v: 1; t: 'res'; id: string; sid?: string; fc: number; ok: false; box: string }
  | { v: 1; t: 'ev'; sid: string; seq: number; fc: number; box: string }
  | { v: 1; t: 'live'; sid: string; stream: number; rev: number; fc: number; box: string }
  | { v: 1; t: 'persisted'; sid: string; seq: number; fc: number }
  | { v: 1; t: 'presence'; computer: 'online' | 'offline'; app?: 'foreground' | 'background' }

export function wireRoutingOf(frame: WireFrame): WireRoutingView {
  const view: WireRoutingView = { t: frame.t }
  if ('sid' in frame && frame.sid !== undefined) view.sid = frame.sid
  if ('seq' in frame && frame.seq !== undefined) view.seq = frame.seq
  if ('fc' in frame && frame.fc !== undefined) view.fc = frame.fc
  return view
}

/**
 * `id` / `sid` 限定的 ASCII 安全字符集（契约 §3）。
 *
 * 存在理由：AAD 是把字段拼成串再哈希，而两端 JSON 转义习惯不同 —— 限制字符集后
 * 拼串结果与 JSON 转义无关，AAD 才可能做到「两端字节一致」。
 */
export const ID_PATTERN = /^[A-Za-z0-9_-]+$/

/** AAD 需要参与规范化的字段（契约 §3）。缺字段的位置用**空串**占位。 */
export interface AadFields {
  v?: number
  t: string
  id?: string
  sid?: string
  seq?: number
  fc?: number
}

/**
 * AAD 规范化：`v "|" t "|" id "|" sid "|" seq "|" fc`（契约 §3）。
 *
 * 数字一律十进制无前导零、无小数点 —— 这里直接依赖 JS 的 `String(number)`，
 * 它本身就满足这两条。**不要**在这里做补零或十六进制格式化。
 */
export function aadOf(fields: AadFields): Uint8Array {
  const { v = WIRE_VERSION, t, id = '', sid = '', seq = '', fc = '' } = fields
  return new TextEncoder().encode([v, t, id, sid, seq, fc].join('|'))
}
