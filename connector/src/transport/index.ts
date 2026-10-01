/**
 * 出站 WSS（契约 §2.2、§9、§10）。
 *
 * 本目录拆成四个**纯逻辑**单元：
 *
 * | 文件 | 职责 | 关键取值 |
 * |---|---|---|
 * | `backoff.ts` | 重连退避 | 1→30 s 指数，抖动 ±20% |
 * | `keepalive.ts` | 心跳与半开检测 | 心跳 60 s（前台空闲），半开 = 2 个周期 |
 * | `batch.ts` | 批量合并 | 50 ms 或累计 ≥4 KiB |
 * | `state.ts` | 连接状态机 | 六态白名单迁移 |
 *
 * 它们都不碰 I/O、不读时钟、不起定时器 —— 时间与随机数一律注入。这样「连接行为」
 * 能在没有网络、没有对端的情况下被完整测到，而真正碰 socket 的那一层只剩接线。
 *
 * **WSS 接线尚未实现**：它需要中转地址与连接器令牌，属第 5 步真机连通的范畴。
 * 接线时要做的只有三件事：
 *
 * 1. 用全局 `WebSocket`（Node 22+ 自带，不引依赖）按 `state.ts` 的迁移表驱动状态；
 * 2. 握手帧走 `protocol/crypto.ts` 的 `seal` / `open`；**未完成握手时拒绝一切业务帧**
 *    （`state.acceptsBusinessFrames` 就是这个判据）；
 * 3. 收到的帧喂 `keepalive.onFrame(now)`，待发帧喂 `batcher.push(...)`，
 *    并让 `keepalive.tick(now)` 的 `half-open` 动作触发关闭重连。
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
