/**
 * 帧编解码（契约 §3）。
 *
 * 线上是**行级 UTF-8 JSON**：一行一帧。本文件把 §3 的几条规则做成纯函数，
 * 因为它们是"写错了不会报错、只会让对端行为诡异"的那一类：
 *
 * 1. **单帧上限 8 MiB**：发送侧不得发出，收到即 `protocol/bad-frame` 并关闭。
 * 2. **未知帧类型与未知字段：忽略并不报错**（向前兼容）。**但**未知帧类型若带 `id`，
 *    要回 `res ok:false` / `protocol/unsupported-version` —— 沉默会让对端的请求永远挂着。
 * 3. **未完成握手的连接只接受握手帧**，其余一律 `protocol/bad-frame` 并关闭。
 * 4. `id` / `sid` 限于 ASCII 安全字符集 `[A-Za-z0-9_-]`：AAD 是把字段拼串再哈希，
 *    限制字符集后拼串结果与两端 JSON 转义习惯无关。
 */
import {
  HANDSHAKE_FRAME_TYPES,
  ID_PATTERN,
  MAX_FRAME_BYTES,
  WIRE_VERSION,
  isHandshakeFrameType,
  type WireFrame,
} from '../protocol/frame.js'
import { ProtocolError } from '../protocol/errors.js'

/**
 * 已知帧类型（契约 §3 的联合）。
 *
 * 握手帧的判据（谁明文、谁要密钥）**不在这里**，在 `protocol/frame.ts`：
 * 那是帧的语义，而本文件只管"线上这一行怎么解"。
 */
export const KNOWN_FRAME_TYPES = [
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
  'persisted',
  'presence',
] as const

const KNOWN: ReadonlySet<string> = new Set(KNOWN_FRAME_TYPES)

/** 帧分隔符。契约 §3 说的是**行级** UTF-8 JSON，所以分隔符由编解码层负责。 */
export const FRAME_DELIMITER = '\n'

/**
 * 编码一帧，**带行分隔符**。
 *
 * 分隔符必须在编码侧加上：它对端（`createLineSplitter`）是按行切分的，
 * 少一个换行就会被当成"半行"一直缓冲下去 —— 而症状是**对端永远收不到帧**，
 * 不是报错。（这个 bug 真的发生过一次，是端到端测试逼出来的。）
 *
 * 超限直接抛，不给调用方"先发了再说"的机会。
 */
export function encodeFrame(frame: WireFrame): string {
  const line = JSON.stringify(frame)
  const bytes = Buffer.byteLength(line, 'utf8')
  if (bytes > MAX_FRAME_BYTES) {
    throw new ProtocolError(
      'protocol/bad-frame',
      `帧 ${bytes} 字节超过上限 ${MAX_FRAME_BYTES}（类型 ${frame.t}）`,
    )
  }
  return line + FRAME_DELIMITER
}

export type DecodeResult =
  /** 已知帧。 */
  | { kind: 'frame'; frame: WireFrame }
  /** 未知帧类型且**没有** `id` —— 按 §3 忽略，不报错。 */
  | { kind: 'ignored'; type: string }
  /** 未知帧类型但**带** `id` —— 必须回 `res ok:false` / `protocol/unsupported-version`。 */
  | { kind: 'unsupported'; id: string; type: string }

/**
 * 解码一帧。
 *
 * @throws {ProtocolError} 超限、不是 JSON、不是对象、或版本不符。
 */
export function decodeFrame(line: string): DecodeResult {
  const bytes = Buffer.byteLength(line, 'utf8')
  if (bytes > MAX_FRAME_BYTES) {
    throw new ProtocolError('protocol/bad-frame', `收到 ${bytes} 字节的帧，超过上限`)
  }

  let parsed: unknown
  try {
    parsed = JSON.parse(line)
  } catch (error) {
    throw new ProtocolError('protocol/bad-frame', `不是合法 JSON：${String(error)}`)
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new ProtocolError('protocol/bad-frame', '帧必须是 JSON 对象')
  }

  const record = parsed as Record<string, unknown>
  const version = record['v']
  if (version !== WIRE_VERSION) {
    // 版本不认识就别猜语义 —— 直接告诉对端升级，别让它在错误的假设上继续。
    throw new ProtocolError('protocol/unsupported-version', `帧版本 ${String(version)} 不受支持`)
  }

  const type = record['t']
  if (typeof type !== 'string') {
    throw new ProtocolError('protocol/bad-frame', '帧缺少 t')
  }

  if (!KNOWN.has(type)) {
    const id = record['id']
    if (typeof id === 'string' && id !== '') return { kind: 'unsupported', id, type }
    return { kind: 'ignored', type }
  }

  // `id` / `sid` 的字符集限制要在解码处拦：它们是 AAD 的组成部分，放进去一个需要
  // 转义的字符，两端算出的 AAD 就可能不同 —— 而那表现为"解不开"，不是"字段非法"。
  for (const key of ['id', 'sid'] as const) {
    const value = record[key]
    if (value === undefined) continue
    if (typeof value !== 'string' || !ID_PATTERN.test(value)) {
      throw new ProtocolError('protocol/bad-frame', `${key} 不是 ASCII 安全字符集：${String(value)}`)
    }
  }

  return { kind: 'frame', frame: record as unknown as WireFrame }
}

/**
 * 握手门禁：未完成握手的连接只接受握手帧（契约 §2.2）。
 *
 * 做成显式函数而不是散在收到帧的分支里 —— 「业务帧在握手前到达」是**攻击面**
 * （对端可能在密钥还没协商好时就想塞业务数据），值得一个能被测试直接点名的判据。
 */
export function assertHandshakePhase(frame: WireFrame, handshakeDone: boolean): void {
  if (handshakeDone) return
  if (isHandshakeFrame(frame)) return
  throw new ProtocolError(
    'protocol/bad-frame',
    `握手未完成时收到 ${frame.t} 帧：本阶段只接受 ${HANDSHAKE_FRAME_TYPES.join(' / ')}`,
  )
}

/**
 * 是不是握手帧。
 *
 * 实现直接转给协议层的 `isHandshakeFrameType`：**判据只有一处**，
 * 连接层用它决定「交给握手驱动器还是交给上层」「要不要盖 `fc`」「要不要封箱」。
 * 本文件留这个别名只是为了让读 codec 的人不必跳文件。
 */
export function isHandshakeFrame(frame: WireFrame): boolean {
  return isHandshakeFrameType(frame.t)
}

/**
 * 行级分帧：把 TCP/WS 分片拼回完整的行。
 *
 * WebSocket 的消息边界本身是一帧，但按行切更稳：将来换 TCP 或加压缩都不会退化。
 * **前提是发送方带上了分隔符**（`encodeFrame` 会带）；漏了的话这一侧会一直等
 * "半行"，直到超过 8 MiB 才以 `protocol/bad-frame` 报出来 —— 是有声音的失败，
 * 不是静默挂死。
 *
 * 超限的未闭合行会在**拼完之前**就被拦掉，避免一个不走空格的攻击者把内存吃光。
 */
export function createLineSplitter(): (chunk: string) => string[] {
  let buffer = ''
  return (chunk) => {
    buffer += chunk
    if (Buffer.byteLength(buffer, 'utf8') > MAX_FRAME_BYTES) {
      buffer = ''
      throw new ProtocolError('protocol/bad-frame', '未闭合的行超过单帧上限')
    }
    const lines = buffer.split(FRAME_DELIMITER)
    // 最后一段可能是半行，留到下一片。
    buffer = lines.pop() ?? ''
    return lines.filter((line) => line.trim() !== '')
  }
}
