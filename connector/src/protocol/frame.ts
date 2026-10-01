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
import { randomBytes } from 'node:crypto'

/**
 * 线上帧类型 —— **唯一一份**。
 *
 * 编解码的白名单、中转的路由视图、窗口算术全都从它取。此前这里只列了 8 项、
 * 且带着一个化石 `'ack'`（那是 `credit` 之前的旧设计），而编解码那边另有一份 13 项的清单 ——
 * 两份必然会漂移：`RoutingView.t` 与 `canSend()` 看到的类型集合比实际小，
 * 新增帧类型时也只改一处。（`ack` 作为**字段**仍存在于 `credit` 的载荷里，与帧类型无关。）
 */
export const FRAME_TYPES = [
  'hello',
  'hello-ack',
  'confirm',
  'ping',
  'pong',
  'credit',
  'req',
  'res',
  'ev',
  'live',
  'job',
  'persisted',
  'presence',
] as const

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
 *
 * 例外是握手三帧（`hello` / `hello-ack` / `confirm`）：它们的 `box` 是**明文编码容器**
 * （§4.1）——此刻两侧还没有可用的会话密钥，而这三帧正是用来建立它的。
 * 三帧为什么必须是三个独立类型见 `.agents/notes/implemented/2026-10-01-handshake-third-frame.md`
 */
export type WireFrame =
  | { v: 1; t: 'hello'; id: string; box: string }
  | { v: 1; t: 'hello-ack'; id: string; box: string }
  | { v: 1; t: 'confirm'; id: string; box: string }
  | { v: 1; t: 'ping'; fc: number; box: string }
  | { v: 1; t: 'pong'; fc: number; box: string }
  | { v: 1; t: 'credit'; fc: number; box: string }
  | { v: 1; t: 'req'; id: string; sid?: string; fc: number; box: string }
  | { v: 1; t: 'res'; id: string; sid?: string; fc: number; ok: true; box: string }
  | { v: 1; t: 'res'; id: string; sid?: string; fc: number; ok: false; box: string }
  | { v: 1; t: 'ev'; sid: string; seq: number; fc: number; box: string }
  | { v: 1; t: 'live'; sid: string; stream: number; rev: number; fc: number; box: string }
  | { v: 1; t: 'job'; sid: string; fc: number; box: string }
  | { v: 1; t: 'persisted'; sid: string; seq: number; fc: number; box: string }
  | { v: 1; t: 'presence'; computer: 'online' | 'offline'; app?: 'foreground' | 'background' }

export function wireRoutingOf(frame: WireFrame): WireRoutingView {
  const view: WireRoutingView = { t: frame.t }
  if ('sid' in frame && frame.sid !== undefined) view.sid = frame.sid
  if ('seq' in frame && frame.seq !== undefined) view.seq = frame.seq
  if ('fc' in frame && frame.fc !== undefined) view.fc = frame.fc
  return view
}

/**
 * 这一帧是不是**必须封箱**的（契约 §3）。
 *
 * 只有两类例外：握手三帧（密钥还没建立）与 `presence`（由中继合成，它必须能原样转发）。
 * 其余每种帧都带 `box` —— **包括 `ping` / `pong` / `credit` / `persisted` 这些"没有内容"的
 * 控制帧**：它们的载荷是空串，封箱买到的不是保密而是**认证**。
 *
 * 判据只写在这里：连接层要用它决定"发之前封什么、收之后解什么"，还要用它决定
 * "没有密钥时哪些帧根本不许发"。三处各写一遍迟早漂移，而漂移的表现是某一类帧悄悄明文上线。
 *
 * 为什么控制帧也要封箱见 `.agents/notes/implemented/2026-10-01-business-frame-sealing.md`
 */
export function needsBox(type: string): boolean {
  if (type === 'presence') return false
  return !isHandshakeFrameType(type)
}

/** 带 `box` 字段的帧（握手三帧 + 除 `presence` 外的全部）。 */
export type BoxedFrame = Extract<WireFrame, { box: string }>

/**
 * 这一帧有没有 `box` 字段（类型收窄用）。
 *
 * 存在的理由：`needsBox(t)` 只是"应该封箱"，`hasBox` 才是"真的有这个字段"。
 * 两者之间一旦出现漂移（比如某个类型要封箱、联合却忘了加字段），
 * 症状是**它被明文发出去**或**跳过解箱与重放守卫** —— 都是静默的。所以调用方
 * 两个判据都要过：`needsBox` 决定"要不要封"，`hasBox` 决定"字段在不在"。
 */
export function hasBox(frame: WireFrame): frame is BoxedFrame {
  return 'box' in frame && typeof frame.box === 'string'
}

/**
 * 握手帧的类型集合（契约 §3/§4.1 的明文例外之一）。
 *
 * 定义在协议层：这是**帧的语义**（谁明文、谁要密钥），不是通道实现细节；
 * 通道层只负责"按这个判据放行/拒绝"，不再自己维护一份。
 */
export const HANDSHAKE_FRAME_TYPES = ['hello', 'hello-ack', 'confirm'] as const

const HANDSHAKE_TYPE_SET: ReadonlySet<string> = new Set(HANDSHAKE_FRAME_TYPES)

/** 同上，只要类型字符串（`OutboundFrame` 与解码前都只有类型可用）。 */
export function isHandshakeFrameType(type: string): boolean {
  return HANDSHAKE_TYPE_SET.has(type)
}

/**
 * 取一帧的 AAD 字段（契约 §3 的规范化输入）。
 *
 * 与 `wireRoutingOf` 同一个形状：**缺字段就不放进对象**，交给 `aadOf` 用空串占位 ——
 * 这样"缺字段"只有一种表达，不会出现 `undefined` 与 `''` 两种写法在两端各算一遍。
 */
export function aadFieldsOf(frame: WireFrame): AadFields {
  const fields: AadFields = { v: frame.v, t: frame.t }
  if ('id' in frame && frame.id !== undefined) fields.id = frame.id
  if ('sid' in frame && frame.sid !== undefined) fields.sid = frame.sid
  if ('seq' in frame && frame.seq !== undefined) fields.seq = frame.seq
  if ('fc' in frame && frame.fc !== undefined) fields.fc = frame.fc
  return fields
}

/**
 * `id` / `sid` 限定的 ASCII 安全字符集（契约 §3）。
 *
 * 存在理由：AAD 是把字段拼成串再哈希，而两端 JSON 转义习惯不同 —— 限制字符集后
 * 拼串结果与 JSON 转义无关，AAD 才可能做到「两端字节一致」。
 */
export const ID_PATTERN = /^[A-Za-z0-9_-]+$/

/** 帧 `id` 的长度（契约 §3：16 字节 base64url）。 */
export const FRAME_ID_BYTES = 16

/**
 * 生成一个帧 `id`。
 *
 * 与 `ID_PATTERN` 放在同一个文件：**字符集约束与生成点是同一件事的两端**。
 * 分开写就会出现手拼 id 的代码（base64 而非 base64url 会带 `+` `/` `=`），
 * 而它的症状是 AAD 拼串两端不一致 —— 表现为"解不开"，不是"字段非法"。
 */
export function newFrameId(): string {
  return Buffer.from(randomBytes(FRAME_ID_BYTES)).toString('base64url')
}

/**
 * AAD 需要参与规范化的字段（契约 §3）。缺字段的位置用**空串**占位。
 *
 * 于是「缺」有两种等价写法：**省掉这个键**，或显式写 `''` —— 规范化把它们都变成空串。
 * 两种都收，是因为跨端向量（`protocol/vectors/*.json`）里缺字段就写作 `''`，
 * 而产品代码习惯省掉；类型若只认一种，另一侧就得靠断言硬转。
 */
export interface AadFields {
  v?: number
  t: string
  id?: string
  sid?: string
  seq?: number | ''
  fc?: number | ''
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
