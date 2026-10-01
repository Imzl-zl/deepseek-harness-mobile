/**
 * 出站 WSS（契约 §2.2、§4、§9、§10）。
 *
 * 本目录拆成四个**纯逻辑**单元 + 一个接线文件：
 *
 * | 文件 | 职责 | 关键取值 |
 * |---|---|---|
 * | `backoff.ts` | 重连退避 | 1→30 s 指数，抖动 ±20% |
 * | `keepalive.ts` | 心跳与半开检测 | 心跳 60 s（前台空闲），半开 = 2 个周期 |
 * | `batch.ts` | 批量合并 | 50 ms 或累计 ≥4 KiB |
 * | `state.ts` | 连接状态机 | 六态白名单迁移 |
 * | `codec.ts` | 行级分帧 + §3 的四条规则 | 8 MiB 上限、握手门禁、`id`/`sid` 字符集 |
 * | `connection.ts` | **接线**：把上面五件接到一个 socket 上 | `idle → connecting → handshake → serving` |
 *
 * 前五个都不碰 I/O、不读时钟、不起定时器 —— 时间与随机数一律注入。这样「连接行为」
 * 能在没有网络、没有对端的情况下被完整测到，而真正碰 socket 的那一层只剩接线。
 *
 * 握手本身不在这里：`connection.ts` 只负责在进入 `handshake` 时启动注入的驱动器
 * （`protocol/handshake-driver.ts`），并在它报成功后进 `serving`。
 * 所以「握手怎么写」与「帧怎么发」是两件可以各自测的事。
 */

export {
  BACKOFF_BASE_MS,
  BACKOFF_JITTER,
  BACKOFF_MAX_MS,
  createBackoff,
  type Backoff,
} from './backoff.js'

export {
  BATCH_FLUSH_BYTES,
  BATCH_FLUSH_MS,
  createBatcher,
  type Batch,
  type Batcher,
  type BatcherOptions,
} from './batch.js'

export {
  createConnection,
  type Connection,
  type ConnectionLogger,
  type ConnectionOptions,
  type DialSocket,
  type OutboundFrame,
} from './connection.js'

export {
  FRAME_DELIMITER,
  KNOWN_FRAME_TYPES,
  assertHandshakePhase,
  createLineSplitter,
  decodeFrame,
  encodeFrame,
  isHandshakeFrame,
  type DecodeResult,
} from './codec.js'

/** 帧的语义判据（谁明文、谁要密钥）在协议层，这里只做转发，方便通道侧的调用点就近取。 */
export {
  HANDSHAKE_FRAME_TYPES,
  aadFieldsOf,
  hasBox,
  isHandshakeFrameType,
  needsBox,
  type BoxedFrame,
} from '../protocol/frame.js'

export {
  HALF_OPEN_PERIODS,
  HEARTBEAT_MS,
  createKeepalive,
  type Keepalive,
  type KeepaliveAction,
  type KeepaliveOptions,
} from './keepalive.js'

export {
  CONNECTION_STATES,
  IllegalTransitionError,
  createConnectionMachine,
  type ConnectionMachine,
  type ConnectionState,
} from './state.js'
