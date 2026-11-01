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
// 两条**只为一个 `.d.ts` 服务**的类型依赖（都不是运行时依赖，装在 devDependencies）：
// 它们把宿主自己的 `Events` 声明并进本仓的类型程序 —— `llm/adapters-updated` 在
// `packages/llm/llm/src/types.ts:24`（`@deepseek-ai/dsh-llm`），
// `permission-presets/catalog-changed` 在 `packages/interaction/permission-presets/src/types.ts:44`。
// 为什么值得引包而不是手抄一份 `declare module`：事件键是字符串，手抄的那份在宿主改名后
// 只会表现为"通知悄悄再也不来"（tsc 看不见）；引包之后**改名就是编译错误**。
// 同一个用法 DSH 自己也有（`packages/bundle/headless/src/index.ts:18`）。
// `credentials/*` 那两条同理，由已经存在的 devDependency `@deepseek-ai/dsh-credentials` 带入。
// 两条 import 的绑定**故意不用**：空绑定（`import type {}`）会被 `verbatimModuleSyntax`
// 裁掉、声明就进不来，所以得引一个真实成员。它们也不会被误删 —— 删掉之后下面
// `ctx.on(…)` 的键立刻退回"未知事件"，`tsc` 当场报错。
import type { LlmProviderInfo } from '@deepseek-ai/dsh-llm'
import type { PermissionCatalog } from '@deepseek-ai/dsh-permission-presets'

import {
  MODEL_CATALOG_HOST_EVENTS,
  modelCatalogChangedNotice,
  permissionCatalogChangedNotice,
  type HostStateNotice,
} from '../protocol/host-state.js'

/**
 * 订阅会让**模型目录**过期的那三条宿主事件（名单与"为什么少了 `llm/models-updated`"
 * 都在 `protocol/host-state.ts` 的 {@link MODEL_CATALOG_HOST_EVENTS}）。
 *
 * 第四条 `settings/document-updated` **不在这里**：它同时命中 `settings.describe`，而那条要
 * 过命名空间过滤 —— 两个 key 的合成在 `settingsUpdatedFor` 一处（`index.ts` 的设置监听）。
 *
 * 受众与过滤一律交给 `notify`：这几条事件不认发起者、也不认订阅者（契约 §5.9 规则 4/5），
 * 所以这里一个判据都不加。
 */
export function onModelCatalogChanged(
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
