/**
 * 存储适配：`ctx.storageDomain` 的 domain KV（契约 §8.1）。
 *
 * **schema 的唯一出处是契约 §8.1**；`connector-and-relay.md` §1.4 只写使用纪律。
 *
 * ## 为什么拆成两个域
 *
 * domain 的写入走**单写链**（`packages/storage/storage-domain/src/domain.ts:263-270`
 * 的 `enqueue`：入队 → 先落盘 → 再改内存 → 再发 `domain/changed`）。
 * 也就是说同一个域里的写是**串行**的。而契约 §1.4 对两类数据的要求正好相反：
 *
 * - `dedupe` / `lastPersisted` **必须同步落盘**（它们决定正确性，滞后就会在崩溃后重放）；
 * - `windows` 是 16 MiB 的增量缓冲，巨型写会长时间占住写链。
 *
 * 放同一个域里，一次 `windows` 大写的落盘会把后面的 `dedupe` 写堵在队列里，
 * 而「同步落盘」这条纪律恰恰是靠不被堵来兑现的。所以按写入特征拆域：
 * `dsh_mobile_core`（小、正确性关键、同步写）与 `dsh_mobile_windows`（大、可批量、可丢）。
 *
 * ## 两条会被 `defineDomain` 在模块加载期就抛出来的规则
 *
 * 1. 域名与表名必须匹配 `UNIT_NAME_RE = /^[a-z][a-z0-9_]*$/` —— **不允许连字符**
 *    （`packages/storage/storage/src/backend.ts:10`）。注意 `CredentialKey` 那套规则
 *    **相反**（要求连字符、不允许下划线），同一插件里两套规则，写错即刻抛。
 * 2. **global schema 不得接受 `null`**：后端把 global 当不透明 JSON 存，`null` 是
 *    「从未写过」的哨兵，可空的 global 重开时会被静默当成没写过
 *    （`packages/storage/storage-domain/src/spec.ts` 的 `defineDomain` 注释）。
 *
 * ## 两个独立的版本号
 *
 * `defineDomain` 的 `version` 是**介质格式**版本（配 `compatibleVersions`）；
 * `meta.schema` 是**业务 schema** 版本。逐代迁移按后者做，别混。
 *
 * `pairingId` 为什么必须随设备存、schema 为什么升到 v2 见
 * `.agents/notes/implemented/2026-10-01-connector-identity-home.md`
 */
import { defineDomain, domainTable } from '@deepseek-ai/dsh-storage-domain'
import { z } from 'zod'

/** 业务 schema 版本，写在 `meta.schema`（契约 §1.4）。 */
export const SCHEMA_VERSION = 2

/** 32 字节公钥的十六进制长度。 */
const PUB_HEX = 64

/** 设备记录（契约 §8.1）。公钥命名照 §4.1：Ed25519 签名密钥 + X25519 DH 密钥。 */
const deviceSchema = z.object({
  /** Ed25519 身份签名公钥（32 字节 hex）。 */
  edPub: z.string().length(PUB_HEX),
  /** X25519 静态 DH 公钥（32 字节 hex）。 */
  dhPub: z.string().length(PUB_HEX),
  name: z.string().min(1),
  pairedAt: z.number(),
  /**
   * 配对标识（契约 §12.1）：配对码的 HKDF 输出，参与 §4.1 的 `info`。
   *
   * **必须随设备存住**：每次重连都要用它重算 `master`，而配对码本身一次性、5 分钟就失效了。
   * 缺了这个字段，设备能配对却再也握不上手（而且看起来像"验签失败"）。
   */
  pairingId: z.string().min(1),
  /** 吊销时间；存在即已吊销（电脑侧删除公钥）。 */
  revokedAt: z.number().optional(),
})

const metaSchema = z.object({
  /** 业务 schema 版本。 */
  schema: z.number().int().nonnegative(),
  /** 空串 = **尚未配置**；生命周期在挂载时校验并拒绝服务（契约 §1.3 的第一步）。 */
  connectorId: z.string(),
  relayUrl: z.string(),
  /** 连接器令牌的**凭据引用**；令牌本体走 `ctx.credentials`，不落这里。 */
  connTokenSecretRef: z.string(),
  /** `repo.info` 要报的「别名→会话元映射版本」（契约 §5.7）。 */
  aliasVersion: z.number().int().nonnegative(),
})

/**
 * 未配置时的初值。
 *
 * `initial` 是 `defineDomain` 的必填项，且 **global schema 不得接受 `null`**（null 是
 * 「从未写过」的哨兵）。所以「尚未配置」只能用一个**合法值**表达 —— 这里用空串，
 * 由生命周期在挂载时校验后拒绝服务，而不是让存储层去表达"没有"。
 */
const UNCONFIGURED_META: z.infer<typeof metaSchema> = {
  schema: SCHEMA_VERSION,
  connectorId: '',
  relayUrl: '',
  connTokenSecretRef: '',
  aliasVersion: 0,
}

const dedupeEntrySchema = z.object({
  at: z.number(),
  status: z.enum(['pending', 'done']),
  resultRef: z.string().optional(),
})

const windowSchema = z.object({
  frames: z.array(z.object({ seq: z.number().int(), itemId: z.string(), text: z.string() })),
  trimmedUpto: z.number().int().nonnegative(),
  lastPersisted: z.number().int(),
})

const takeoverSchema = z.object({
  mode: z.enum(['never', 'foreground', 'always']),
  lastInteractedAt: z.record(z.string(), z.number()),
})

/**
 * 小、正确性关键、需要同步落盘的那批。
 *
 * `meta` 用 `global`（单条记录）而不是单行表 —— 后端把 global 当不透明 JSON 整体读写，
 * 正好对应「一份配置」的语义。
 */
export const coreDomain = defineDomain({
  name: 'dsh_mobile_core',
  version: 1,
  // `global` 是 `{ schema, initial }` 而不是裸 schema —— 后端把 global 当不透明 JSON
  // 整体读写，`initial` 是"从未写过"时返回的值。
  global: { schema: metaSchema, initial: UNCONFIGURED_META },
  tables: {
    devices: domainTable<string, z.infer<typeof deviceSchema>>(deviceSchema),
    /** `sid → dshSessionId`。中继只看得到 `sid`。 */
    by_sid: domainTable<string, string>(z.string()),
    /** `dshSessionId → sid`，反向查询用。 */
    by_session: domainTable<string, string>(z.string()),
    dedupe: domainTable<string, z.infer<typeof dedupeEntrySchema>>(dedupeEntrySchema),
    takeover: domainTable<string, z.infer<typeof takeoverSchema>>(takeoverSchema),
  },
})

/**
 * 大、可批量、可丢的那批。单独一个域，避免它的巨型写堵住 `core` 的同步写。
 */
export const windowsDomain = defineDomain({
  name: 'dsh_mobile_windows',
  version: 1,
  tables: {
    windows: domainTable<string, z.infer<typeof windowSchema>>(windowSchema),
  },
})

export type DeviceRecord = z.infer<typeof deviceSchema>
export type MetaRecord = z.infer<typeof metaSchema>
export type DedupeEntry = z.infer<typeof dedupeEntrySchema>
export type WindowRecord = z.infer<typeof windowSchema>
export type TakeoverRecord = z.infer<typeof takeoverSchema>

/** 两个域的初始 meta。首次启动时写入，之后只按 `schema` 迁移。 */
export function initialMeta(input: {
  connectorId: string
  relayUrl: string
  connTokenSecretRef: string
}): MetaRecord {
  return { schema: SCHEMA_VERSION, aliasVersion: 0, ...input }
}

/**
 * 业务 schema 的逐代迁移（契约 §1.4）。
 *
 * **只按代迁移，不把兼容分支写进主路径**：低版本逐代升到当前版本；
 * 高于当前版本一律拒绝启动（`connector/unsupported`）—— 老插件读新数据是
 * 「看起来能跑但语义已经错了」，比直接不启动危险得多。
 *
 * 现在到 v2，所以迁移表里只有一条。`SCHEMA_VERSION` 涨上去时在这里逐代补，
 * **不要**写成 `if (v <= 1) … else if (v <= 3) …` 那种跳代分支。
 *
 * v1 → v2 只动 `meta`：`devices` 增加了 `pairingId`，而**设备行从来没有任何写入方**
 * （配对流程还没落地，本插件至今只读这张表），所以不存在需要补字段的历史行 ——
 * 迁移不该凭空造一个配对标识出来。
 */
export function migrateMeta(from: MetaRecord): MetaRecord {
  if (from.schema > SCHEMA_VERSION) {
    throw new Error(
      `connector/unsupported: 存储 schema v${from.schema} 高于本插件支持的 v${SCHEMA_VERSION}`,
    )
  }
  let current = from
  // 逐代迁移表：key = 起始版本，每步只升一代。新增版本时在这里加一行。
  const steps: Record<number, (meta: MetaRecord) => MetaRecord> = {
    1: (meta) => ({ ...meta, schema: 2 }),
  }
  while (current.schema < SCHEMA_VERSION) {
    const step = steps[current.schema]
    if (step === undefined) {
      throw new Error(`connector/unsupported: 缺少 v${current.schema} → v${current.schema + 1} 的迁移`)
    }
    current = step(current)
  }
  return current
}
