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
 * 清单里**今天没有生产者的几项**也在这里（`session.modelCatalog` /
 * `permission.catalog` 等宿主失效事件还没接；`agentPresets.list` /
 * `workspace.list` / `repo.info` 宿主根本没有"这张表变了"的事件）。
 * 收进来的理由是：手机侧"能不能推"与"该不该拉"是同一张表的两列，
 * 让"接上生产者"只改连接器一处，协议与跨端门禁都不用动（§5.9 规则 8）。
 * 取舍见 `.agents/notes/implemented/2026-11-01-refetch-scope-by-trigger.md`。
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
// 五个构造函数 vs 在调用点各写一遍 `['session.list', …]`：触发点分散在
// `index.ts` 的三处宿主事件监听上，而"哪次变更影响哪些快照"是**同一张表**。
// 写在调用点就意味着改一次要改五处，且漏一处不报错。
// 测试直接断言这五个函数的返回值（`tests/host-state-notice.test.ts`）。
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

/** 写了设置：宿主级，没有会话。 */
export function settingsUpdatedNotice(): HostStateNotice {
  return { keys: ['settings.describe'] }
}

/**
 * 设置文档变了（宿主 `settings/document-updated`）—— 只关心手机**读得到**的命名空间。
 *
 * 过滤的理由：宿主每个命名空间的变化都会发这条事件（`settings/src/index.ts:317,338`），
 * 包括手机上根本没有入口的那些（主题、插件配置…）。为它们让手机重拉一次 `settings.describe`
 * 只会换回同一份数据 —— 那正是"多一次往返"的价钱，没必要付。
 *
 * @param ns - 变化的命名空间。
 * @param readable - 手机可读的命名空间（`dsh/settings-face.ts` 的 `READABLE_NAMESPACES`）。
 */
export function settingsUpdatedFor(
  ns: string,
  readable: readonly string[],
): HostStateNotice | undefined {
  return readable.includes(ns) ? settingsUpdatedNotice() : undefined
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
