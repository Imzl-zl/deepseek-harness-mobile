/**
 * 插件配置(Schemastery)。
 *
 * 字段表见 docs/subsystems/connector-and-relay.md §1.1。
 * `.volatile()` 的字段会进手机端的通用表单;`.role('credential-ref')` 表示这里只放凭据引用,本体走 ctx.credentials。
 *
 * 写法照 DSH 的 volatile 配置样例
 * packages/web/web-search-deepseek/src/index.ts:49-76:interface 字段用 `Volatile<T>`,
 * 无 default 的字段带 `| undefined`;有 `.volatile()` 时不写 `Schema<Interface>` 标注。
 *
 * 工程形态与版本策略见 .agents/notes/implemented/2026-10-01-connector-workspace-shape.md
 */
import type { Volatile } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'

export interface ConnectorConfig {
  /** 中转地址(wss)。挂载时校验存在性,故无 schema 默认值。 */
  relayUrl: Volatile<string | undefined>
  /** 连接器令牌的凭据引用;本体走 ctx.credentials,不进配置文件。 */
  relayTokenRef: Volatile<string | undefined>
  /**
   * **直连拓扑**的监听端口(契约 §14.6 的第一跳)。`0` = 不监听(只走中转)。
   *
   * 默认 0 而不是某个固定端口:不配置就等于这个功能不存在,而不是"监听了但没人用"。
   */
  listenPort: Volatile<number>
  /** 监听地址。默认只在本机;直连要走 tailnet 时显式写那个地址。 */
  listenHost: Volatile<string>
  /** 允许配对的设备数。 */
  deviceLimit: Volatile<number>
  /** 审批接管档位,判定表见契约 §6.2。 */
  approvalTakeover: Volatile<'never' | 'foreground' | 'always'>
  /** claim 后的看护超时(分钟),超时按 fail-closed 结束。 */
  approvalWatchdogMin: Volatile<number>
  /** 推送摘要粒度。 */
  pushDigest: Volatile<'rich' | 'doorbell'>
  /** 单帧上限。 */
  frameLimitBytes: Volatile<number>
  /** 超过此体积的对象改走重取,不内联。 */
  refetchThresholdBytes: Volatile<number>
  /** 增量缓冲的帧数上界。 */
  windowFrames: Volatile<number>
  /** 增量缓冲的字节上界。 */
  windowMaxBytes: Volatile<number>
}

export const Config = z.object({
  relayUrl: z.string().volatile(),
  relayTokenRef: z.string().role('credential-ref').volatile(),
  // `0` = 关。范围到 65535;`.min(0)` 允许"显式关掉"这个写法。
  listenPort: z.number().step(1).min(0).max(65535).default(0).volatile(),
  listenHost: z.string().default('127.0.0.1').volatile(),
  deviceLimit: z.number().step(1).min(1).default(8).volatile(),
  approvalTakeover: z.union([z.const('never'), z.const('foreground'), z.const('always')]).default('foreground').volatile(),
  approvalWatchdogMin: z.number().step(1).min(1).default(10).volatile(),
  pushDigest: z.union([z.const('rich'), z.const('doorbell')]).default('rich').volatile(),
  frameLimitBytes: z.number().step(1).min(1).default(8_388_608).volatile(),
  refetchThresholdBytes: z.number().step(1).min(1).default(1_048_576).volatile(),
  windowFrames: z.number().step(1).min(1).default(10_000).volatile(),
  windowMaxBytes: z.number().step(1).min(1).default(16_777_216).volatile(),
})
