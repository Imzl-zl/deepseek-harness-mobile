/**
 * 插件清单与启停（`plugin.list` / `plugin.setEnabled`，契约 §5.7）。
 *
 * ## 方法面在哪（2026-10-24 二次核实的结论）
 *
 * `packages/host/plugin-inventory/src/index.ts:70` 只有一个 `list()`（只读快照
 * `PluginInventorySnapshot`）—— **它没有 `@Remote`**，不是方法面。
 * 真正的方法面在 `packages/boot/plugin-manager/src/index.ts`：`PluginManager`
 * （服务键 `pluginManager`，`super(ctx, 'pluginManager')` 在 `:333`）有 14 个 `@Remote`，
 * 本任务只透传其中三个：
 *
 * - `listPlugins(): Promise<PluginInfo[]>`（`:439`）
 * - `setPluginEnabled(id: PluginEntryId, enabled: boolean): Promise<ChangeResult>`（`:796`）
 * - （bundle 级 `setBundleEnabled`（`:814`）**不做**：bundle 是"一层 patch"，
 *   手机上摆一道会连带改一堆行，风险面另议。）
 *
 * **安装 / 卸载 / 升级不做**（`installBundle:835` / `removeBundle:999` /
 * `updateBundle:677`）：它们动的是 profile 的 `package.json` 与 `pnpm-lock`，
 * 失败面在手机上既看不见也修不了。
 *
 * ## 行与回执都不翻译
 *
 * 行就是 `PluginInfo`（`:55` 的 `PluginInventoryEntry & ({patchId} | {readOnlyReason})`）：
 * `entryId` / `moduleName` / `enabled` / `fiberPhase` / 可选的 `meta`（本地化展示信息，
 * `packages/util/package-manifest/src/types.ts:47-56`）/ 以及"能不能被这一层改"的
 * `patchId` 或 `readOnlyReason`（`management-required` / `unaddressable`）。
 *
 * **`meta` 原样过线，不在连接器挑语言**：`LocalizedText` 是
 * `string | {en, [locale]}`（`types.ts:44`），挑哪一档是**界面**的事（手机按自己的语言挑）。
 * 连接器翻译一遍就是第二份语言规则。
 *
 * ## 启停回的是**回读后的真值**
 *
 * 宿主 `setPluginEnabled` 写 profile patch 并热重载（`:796-810`），失败会抛
 * `ManagementFailure`（传不上来的话我们也没法解释）。**成功之后回读一次清单**，
 * 把"那一行现在到底是什么状态"给手机 —— 而不是回声我们请求的那个 bool：
 * 宿主的 `application` 可能是 `overridden`（更高优先级的层盖住了），
 * 那时 `enabled` 与请求值**不一样**，回声就是撒谎。
 */
import type { Context } from '@deepseek-ai/cordis'

import { ProtocolError } from '../protocol/errors.js'

/** `pluginManager` 服务面（**按形状收窄、不 import DSH 类型**）。 */
interface PluginManagerService {
  listPlugins(): Promise<readonly unknown[]>
  listBundles(): Promise<readonly unknown[]>
  setPluginEnabled(id: string, enabled: boolean): Promise<unknown>
}

/** 给手机的一行插件。字段以 `PluginInfo` 为准（`plugin-manager/src/types.ts:55`）。 */
export interface PluginRow {
  entryId: string
  moduleName: string
  enabled: boolean
  /** 加载器的 fiber 阶段（宿主的原值，手机只用来区分"在跑 / 已停 / 加载失败"）。 */
  fiberPhase: unknown
  /** 本地化展示信息（`title` / `description` / `icon` / `error`），**原样**。 */
  meta?: unknown
  /** 能被这一层改时宿主给的 patch 行 id（没有它就不能启停）。 */
  patchId?: string
  /** 不能改的原因（`management-required` / `unaddressable`）。 */
  readOnlyReason?: string
}

/** 一次启停的回执。 */
export interface PluginToggleResult {
  /** 那一行的 `moduleName`（回读不到时是空串）。 */
  name: string
  /** **回读后的**真实状态（不是我们请求的值）。 */
  enabled: boolean
  /** 宿主的应用结论（`applied` / `restart-required` / `overridden` / …），原样。 */
  application?: string
  /** `restart-required` 时为什么（宿主的 `RestartReason`）。 */
  restartReason?: string
}

/**
 * 手机眼里的一个**包**（宿主的 `BundleInfo`，`types.ts:84-138`）。
 *
 * 与"插件行"是两个东西：一行是一个 Loader entry（可以单独启停），一个包可能带来多行。
 * **卸载只按包名**（宿主 `removeBundle(name)`），所以手机上要卸载就得有这份清单 ——
 * 它同时给出"能不能卸"（`removable`）与"装没装"（`installed`），手机不猜。
 */
export interface BundleRow {
  name: string
  /** 版本（宿主 `BundleInfo.version`，可能没有：本地链接包）。 */
  version?: string
  /** profile manifest 里声明了这个依赖。 */
  installed: boolean
  /** 被 profile 选中（它的 patch 层生效）。 */
  enabled: boolean
  /** 宿主说能不能 `pnpm remove` 它。 */
  removable: boolean
  /** 这一层能不能在这里启停（宿主给了 `readOnlyReason` 就是不能）。 */
  readOnlyReason?: string
}

export interface PluginsFace {
  list(): Promise<readonly PluginRow[]>
  listBundles(): Promise<readonly BundleRow[]>
  setEnabled(id: string, enabled: boolean): Promise<PluginToggleResult>
}

/**
 * 建插件面。
 *
 * 服务键走 `ctx.get`，**缺席的判定在装配层**（`index.ts` 按
 * `pluginsAvailable(ctx)` 决定挂不挂方法）；走到这里缺键只可能是装配写错了，
 * 那时如实抛 —— 回空数组会被手机读成"这台电脑一个插件都没有"。
 */
export function createPluginsFace(ctx: Context): PluginsFace {
  const managerOf = (): PluginManagerService => {
    const manager = ctx.get('pluginManager') as PluginManagerService | undefined
    if (manager === undefined) {
      throw new ProtocolError('internal', 'pluginManager 服务不在：插件面不可用')
    }
    return manager
  }

  const rowsOf = async (): Promise<readonly unknown[]> => await managerOf().listPlugins()

  return {
    async list() {
      const rows = await rowsOf()
      return rows.flatMap((row): PluginRow[] => {
        if (typeof row !== 'object' || row === null) return []
        const record = row as Record<string, unknown>
        const entryId = record['entryId']
        // 没有 `entryId` 的行**点不动也认不出**：整个丢掉，而不是给一个空串当 id
        // （空串会让 `plugin.setEnabled` 回宿主的一句 `unknown-plugin`）。
        if (typeof entryId !== 'string' || entryId === '') return []
        const moduleName = record['moduleName']
        return [
          {
            entryId,
            moduleName: typeof moduleName === 'string' ? moduleName : '',
            enabled: record['enabled'] === true,
            fiberPhase: record['fiberPhase'] ?? null,
            ...(record['meta'] === undefined ? {} : { meta: record['meta'] }),
            ...(typeof record['patchId'] === 'string' ? { patchId: record['patchId'] } : {}),
            ...(typeof record['readOnlyReason'] === 'string'
              ? { readOnlyReason: record['readOnlyReason'] }
              : {}),
          },
        ]
      })
    },

    async listBundles() {
      const rows = await managerOf().listBundles()
      return rows.flatMap((row): BundleRow[] => {
        if (typeof row !== 'object' || row === null) return []
        const record = row as Record<string, unknown>
        const name = record['name']
        if (typeof name !== 'string' || name === '') return []
        return [
          {
            name,
            ...(typeof record['version'] === 'string' ? { version: record['version'] } : {}),
            installed: record['installed'] === true,
            enabled: record['enabled'] === true,
            removable: record['removable'] === true,
            ...(typeof record['readOnlyReason'] === 'string'
              ? { readOnlyReason: record['readOnlyReason'] }
              : {}),
          },
        ]
      })
    },

    async setEnabled(id, enabled) {
      const change = await managerOf().setPluginEnabled(id, enabled)
      // **回读**：`application === 'overridden'` 时请求值不是终态（见文件头）。
      const row = (await rowsOf()).find(
        (item) =>
          typeof item === 'object' &&
          item !== null &&
          (item as Record<string, unknown>)['entryId'] === id,
      ) as Record<string, unknown> | undefined
      const application =
        typeof change === 'object' && change !== null
          ? (change as Record<string, unknown>)['application']
          : undefined
      const restartReason =
        typeof change === 'object' && change !== null
          ? (change as Record<string, unknown>)['restartReason']
          : undefined
      return {
        name: typeof row?.['moduleName'] === 'string' ? (row['moduleName'] as string) : '',
        enabled: row?.['enabled'] === true,
        ...(typeof application === 'string' ? { application } : {}),
        ...(typeof restartReason === 'string' ? { restartReason } : {}),
      }
    },
  }
}
