/**
 * 宿主事件的订阅器（契约 §5.9 里两个**宿主级目录**的触发点）。
 *
 * 与 `dsh/jobs.ts` 的 `onJobsLifecycle` 同形：事件名与"该发哪个 key"的映射都在
 * `protocol/host-state.ts`（那是触发点表的唯一代码化），这里只负责把监听挂到 `ctx` 上、
 * 交回注销函数（挂 `ctx.effect`，随 fiber 回收）。
 *
 * 为什么这两组单独一个模块而不是写在 `index.ts` 里：`index.ts` 是装配面，那里只该看见
 * "订阅什么、回调什么"；而这几条事件在连接器里都是**首次使用**
 * （`credentials/record-updated`、`credentials/reference-updated`、
 * `permission-presets/catalog-changed`），其中所属包不在依赖里的三条还要就地补类型声明 ——
 * 用法与类型留在同一处更好核。
 *
 * 取舍与被否方案见 `.agents/notes/implemented/2026-11-01-refetch-scope-by-trigger.md`
 * 的第 2 批。
 *
 * @module dsh-mobile-connector/dsh/host-events
 */
import type { Context } from '@deepseek-ai/cordis'

import {
  MODEL_CATALOG_HOST_EVENTS,
  modelCatalogChangedNotice,
  permissionCatalogChangedNotice,
  type HostStateNotice,
} from '../protocol/host-state.js'

/**
 * 三条宿主事件在本仓的类型程序里看不见，因为对应的包不是连接器的依赖
 * （`@deepseek-ai/dsh-llm` / `@deepseek-ai/dsh-permission-presets` 都没有出现在
 * `package.json` 里；`credentials/*` 那两条则**能**看见，因为 `@deepseek-ai/dsh-credentials`
 * 是 devDependency）。下面补的全是**宿主已经声明过的事实**，不是我们的发明，
 * 逐条给出处：
 *
 * - `llm/adapters-updated`：`packages/llm/llm/src/types.ts:24`（无参数；emit 在
 *   `packages/llm/llm/src/index.ts:371` 的注册表提交点）；
 * - `llm/models-updated`：同上 `:30`（参数是改动那条 route 的 provider；emit 在
 *   `packages/llm/llm-deepseek/src/host.ts:32` 等适配器的 `changed` 回调）；
 * - `permission-presets/catalog-changed`：`packages/interaction/permission-presets/src/types.ts:48`
 *   （无参数；emit 在 `src/index.ts:461`，只有注册 / 撤回 Auto 预设会动进程目录 ——
 *   README.md:135 的原话是 "The configured preset table is fixed for the plugin lifetime"）。
 *
 * 补充只影响类型：值仍然由宿主发出。若将来把这些包加成依赖，这里可以删（同名同型的
 * 声明合并是合法的，删之前 tsc 会告诉你哪一条已经不需要了）。
 */
declare module '@deepseek-ai/cordis' {
  interface Events {
    'llm/adapters-updated'(): void
    'llm/models-updated'(provider: string): void
    'permission-presets/catalog-changed'(): void
  }
}

/**
 * 订阅会让**模型目录**过期的那四条宿主事件。
 *
 * 第五条 `settings/document-updated` **不在这里**：它同时命中 `settings.describe`，而那条要
 * 过命名空间过滤 —— 两个 key 的合成在 `settingsUpdatedFor` 一处（`index.ts` 的设置监听）。
 *
 * 受众与过滤一律交给 `notify`：这几条事件不认发起者、也不认订阅者（契约 §5.9 规则 4/5），
 * 所以这里一个判据都不加。
 */
export function onModelCatalogInvalidated(
  ctx: Context,
  notify: (notice: HostStateNotice) => void,
): () => void {
  const stops = MODEL_CATALOG_HOST_EVENTS.map((event) =>
    ctx.on(event, () => { notify(modelCatalogChangedNotice()) }))
  return () => { for (const stop of stops) stop() }
}

/** 订阅权限预设目录的失效事件（无载荷、不动会话 `seq`）。 */
export function onPermissionCatalogChanged(
  ctx: Context,
  notify: (notice: HostStateNotice) => void,
): () => void {
  return ctx.on('permission-presets/catalog-changed', () => {
    notify(permissionCatalogChangedNotice())
  })
}
