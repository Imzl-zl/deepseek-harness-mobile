/**
 * 宿主状态变更提示（契约 §5.9，`host` 帧的载荷）。
 *
 * ## 它是什么、不是什么
 *
 * **只是"这些快照可能过期了"的提示**：不带值、不带版本号、不占会话 `seq`、不要应答。
 * 收到的一方按 key 重取对应快照方法，值永远以快照为准 —— 这条通道存在的唯一理由是
 * "桌面改了模型 / 权限档 / 设置 / 标题 / 任务表，手机还显示旧值"是一类症状，不是一处 bug。
 *
 * ## 为什么 key 是**方法名**
 *
 * 判据只有一条：这个名字要能直接回答"该调谁"。状态键（`session.model`）回答不了 ——
 * 它与 `session.permission` 都指向同一个 `session.projections`，按状态键走就得再合并
 * 一次；而快照方法一次返回一整包，也不存在"只拉一个字段"的省法。方法名粒度下
 * 新增一个宿主状态**协议一个字都不用改**。
 *
 * ## 为什么清单在协议层（而不是调用点各写一份）
 *
 * 连接器要发、app 要认、契约要写；三处各写一份字面量就必然漂移，而漂移的表现是
 * **某一类变更永远不推**（静默）。所以清单只在这里，`handlers.ts` / `index.ts`
 * 只引用不重复。契约的中文表在 `docs/subsystems/remote-channel.md` §5.9。
 *
 * 取舍与被否方案见 `.agents/notes/implemented/2026-10-31-host-state-sync.md`。
 */

/**
 * 允许出现在 `host` 帧里的 key —— **封闭集**。
 *
 * 加一项要同时改：本清单、契约 §5.9 的 key 表、app 侧的登记表
 * （`app/lib/data/host_state.dart`）。app 侧有一条机械测试**逐字比对两端清单**，
 * 所以漏配会红，而不是静静失效。
 *
 * 清单里**今天没有生产者的三项**也在这里（`agentPresets.list` / `workspace.list` /
 * `repo.info`：宿主根本没有"这张表变了"的事件）。收进来的理由是：手机侧"能不能推"与
 * "该不该拉"是同一张表的两列，让清单保持一处，比"用到才加"少一次协议改动
 * （§5.9 规则 8）。取舍见 `.agents/notes/implemented/2026-11-01-refetch-scope-by-trigger.md`。
 */
export const HOST_STATE_KEYS = [
  'session.list',
  'session.projections',
  'settings.describe',
  'job.list',
  'session.modelCatalog',
  'permission.catalog',
  'agentPresets.list',
  'workspace.list',
  'repo.info',
] as const

export type HostStateKey = (typeof HOST_STATE_KEYS)[number]

/** 一条通知：要重取哪些快照、属于哪个会话。 */
export type HostStateNotice = {
  keys: readonly HostStateKey[]
  /** 会话级 key 的定向依据（帧头 `sid`，不是 `box` 里的数据）。 */
  sid?: string
}

/**
 * `box` 的载荷：`{"keys":[...]}`。
 *
 * 空数组没有任何意义（"可能过期了，但没有东西要重取"），所以这里不发：
 * 让调用方在发之前就别调，比让对端去判一条空通知更简单。
 */
export function hostStatePayload(keys: readonly HostStateKey[]): string {
  return JSON.stringify({ keys: [...keys] })
}

// ---------------------------------------------------------------------------
// 触发点 → 发哪几个 key（契约 §5.9 的触发点表的**唯一代码化**）
//
// 构造函数 vs 在调用点各写一遍 `['session.list', …]`：触发点分散在
// `index.ts` 的几处宿主事件监听上，而"哪次变更影响哪些快照"是**同一张表**。
// 写在调用点就意味着改一次要改几处，且漏一处不报错。
// 测试直接断言这些函数与名单的返回值（`tests/host-state-notice.test.ts`）。
// ---------------------------------------------------------------------------

/** 切了模型：清单行带 `model`（chip 读它），投影包带 `modelSelection`。 */
export function modelSelectedNotice(sid: string): HostStateNotice {
  return { keys: ['session.list', 'session.projections'], sid }
}

/** 切了权限档 / 沙箱档：当前值只在 `permissions` 投影里。 */
export function permissionSwitchedNotice(sid: string): HostStateNotice {
  return { keys: ['session.projections'], sid }
}

/**
 * **会话事件 → 通知**：哪些持久事件意味着"某个快照变了"。
 *
 * ## 为什么模型与权限档走这里，而不是走我们自己的 handler
 *
 * 因为它们**可以从桌面 Web 改**：Web 直接调宿主的 `selectModel` /
 * `/permission`，那条路根本不经过连接器。听 handler 就只覆盖"手机自己改"，
 * 而 P1 的验收恰恰是"Web 改了、手机要跟上"。
 *
 * 宿主侧这件事的真值就是**它落的持久事件**：
 * - `model/selection`：`AgentModel.select` 落的（`core/agent/src/model-selection.ts:118-121`），
 *   而 `modelSelection` 投影正是 fold 它；
 * - `permission/preset` / `sandbox/mode`：权限档与沙箱档的落点
 *   （`interaction/permission-presets/src/index.ts:132-135`）。
 *
 * **`request/header` 刻意不在内**：它也会改 `modelSelection` 投影，但改的是
 * `lastUsed`（"这一轮用了什么"），不是"选了哪个" —— 每一轮都通知等于把快照拉成轮询。
 *
 * @param type - 会话事件类型（宿主 `session/event` 的 `event.type`）。
 * @param sid - 该会话的别名；未知时返回 `undefined`（手机不认识这个会话）。
 * @returns 要发的通知，或 `undefined`（这条事件不影响任何快照）。
 */
export function hostStateForSessionEvent(
  type: string,
  sid: string | undefined,
): HostStateNotice | undefined {
  if (sid === undefined) {
    // 标题是**列表行**的字段，别名未知时列表照样要刷新（其余两种只有投影一个落点）。
    return type === 'session/title' ? titleChangedNotice(undefined) : undefined
  }
  switch (type) {
    case 'session/title':
      return titleChangedNotice(sid)
    case 'model/selection':
      return modelSelectedNotice(sid)
    case 'permission/preset':
    case 'sandbox/mode':
      return permissionSwitchedNotice(sid)
    default:
      return undefined
  }
}

/**
 * 模型目录变了：宿主级，没有会话。
 *
 * 判据是 DSH 浏览器侧那张失效表 —— `ModelCatalogDirectory` 只在显式 `refresh()` 时重拉，
 * 而 `ui-model-selection` 把五条宿主事件全接到它上面
 * （`packages/client/ui-model-selection/src/client/service.ts:54-58`），
 * 见 {@link MODEL_CATALOG_HOST_EVENTS}。
 *
 * **不按发起者 / 订阅者过滤、不带 `sid`**（契约 §5.9 规则 3/4/5）：目录是进程级事实，
 * 而宿主事件不知道是谁改的。取舍与被否方案见
 * `.agents/notes/implemented/2026-11-01-refetch-scope-by-trigger.md`（第 2 批）。
 */
export function modelCatalogChangedNotice(): HostStateNotice {
  return { keys: ['session.modelCatalog'] }
}

/**
 * 权限预设目录变了（宿主 `permission-presets/catalog-changed`）：宿主级，没有会话。
 *
 * 判据：浏览器侧收到就 `invalidate()` + `refresh()`
 * （`packages/client/ui-permission-presets/src/client/catalog.ts:46-49`）；
 * 事件本身无载荷、不追加会话事件、不动会话 `seq`
 * （`packages/api/remotes/README.md:51`）。
 */
export function permissionCatalogChangedNotice(): HostStateNotice {
  return { keys: ['permission.catalog'] }
}

/**
 * 会让**模型目录**过期的宿主事件（除 `settings/document-updated` 外的那四条）。
 *
 * 五条的出处逐条核过：`llm/adapters-updated`（声明 `packages/llm/llm/src/types.ts:24`，
 * emit 在 `packages/llm/llm/src/index.ts:371`）、`llm/models-updated`
 * （`types.ts:30`，emit 在 `packages/llm/llm-deepseek/src/host.ts:32`）、
 * `credentials/record-updated`（`packages/credentials/credentials/src/types.ts:99`，emit 在
 * `src/index.ts:276`）、`credentials/reference-updated`（`types.ts:87`，emit 在 `src/index.ts:267`）。
 *
 * `settings/document-updated` **刻意不在这个数组里**：它同时命中 `settings.describe`，
 * 而那条要过命名空间过滤 —— 两个 key 的合成在 {@link settingsUpdatedFor} 一处表达。
 * 这张名单与那个函数必须一起读：漏掉一条的表现是"改了模型 / 密钥，手机的模型选择器不动"，
 * 而 `tests/host-state-notice.test.ts` 逐字钉住它。
 */
export const MODEL_CATALOG_HOST_EVENTS = [
  'llm/adapters-updated',
  'llm/models-updated',
  'credentials/record-updated',
  'credentials/reference-updated',
] as const

/**
 * 设置文档变了（宿主 `settings/document-updated`）—— **一条事件命中两个 key**。
 *
 * - `settings.describe` **只对手机读得到**的命名空间发：宿主每个命名空间的变化都会发这条事件
 *   （`packages/settings/settings/src/index.ts:317,338`），包括手机上根本没有入口的那些
 *   （主题、插件配置…）。为它们重拉一次只会换回同一份数据 —— 那个往返没必要付。
 * - `session.modelCatalog` **不过滤**：`settings/document-updated` 是模型目录的五条失效
 *   事件之一（`ui-model-selection/src/client/service.ts:54-58`）。按命名空间筛就得先知道
 *   "哪些设置影响模型"，那是第二份知识，漏一项的表现是"改了设置、手机不跟"；DSH 浏览器侧
 *   同样不筛（`service.ts:56`）。代价是设置页改一行带来一次目录重取 —— 低频动作，返回的
 *   又是缓存内的一整包。
 *
 * 两个 key 各自独立，所以返回值**永不为空**（读不到的命名空间照样要刷模型目录）。
 *
 * @param ns - 变化的命名空间。
 * @param readable - 手机可读的命名空间（`dsh/settings-face.ts` 的 `READABLE_NAMESPACES`）。
 */
export function settingsUpdatedFor(
  ns: string,
  readable: readonly string[],
): HostStateNotice {
  return readable.includes(ns)
    ? { keys: ['settings.describe', 'session.modelCatalog'] }
    : { keys: ['session.modelCatalog'] }
}

/**
 * 标题生成 / 改名（宿主落的 `session/title` 事件）。
 *
 * 会话别名未知时**只发清单**：手机还不认识这个会话，投影没有可指定的目标，
 * 而列表行里的标题提示照样要刷新。
 */
export function titleChangedNotice(sid: string | undefined): HostStateNotice {
  return sid === undefined
    ? { keys: ['session.list'] }
    : { keys: ['session.list', 'session.projections'], sid }
}

/** 任务表增删 / 终态：只影响这一个会话的 `job.list`。 */
export function jobListChangedNotice(sid: string): HostStateNotice {
  return { keys: ['job.list'], sid }
}
