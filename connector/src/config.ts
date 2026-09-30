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
  deviceLimit: z.number().step(1).min(1).default(8).volatile(),
  approvalTakeover: z.union([z.const('never'), z.const('foreground'), z.const('always')]).default('foreground').volatile(),
  approvalWatchdogMin: z.number().step(1).min(1).default(10).volatile(),
  pushDigest: z.union([z.const('rich'), z.const('doorbell')]).default('rich').volatile(),
  frameLimitBytes: z.number().step(1).min(1).default(8_388_608).volatile(),
  refetchThresholdBytes: z.number().step(1).min(1).default(1_048_576).volatile(),
  windowFrames: z.number().step(1).min(1).default(10_000).volatile(),
  windowMaxBytes: z.number().step(1).min(1).default(16_777_216).volatile(),
})
