/**
 * 中转的日志面（与连接器的 `observability.ts` 同形：只依赖结构，不依赖具体实现）。
 *
 * 单独一份是因为**中转不依赖连接器**（方向不对：连接器是中转的客户端）。
 * 与 `protocol-view.ts` 里那份"第三份帧类型清单"同理：这里只写下"我需要什么形状"，
 * 具体实现（控制台 / DSH logger / 测试替身）由装配方注入。
 */
export interface ChannelLogger {
  info(message: string, detail?: unknown): void
  warn(message: string, detail?: unknown): void
  error(message: string, detail?: unknown): void
  debug(message: string, detail?: unknown): void
}
