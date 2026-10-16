/**
 * 工作区适配：把 DSH 的 `WorkspaceController` 映射成通道的工作区面。
 *
 * ## 为什么会话列表要按它分组
 *
 * DSH Web 的侧栏是**工作区(项目) → 该项目下的会话**：`WorkspaceView` 带
 * `title` 与 `sessionIds`（`packages/api/workspace-controller/src/types.ts:18-30`），
 * 会话与工作区的对应关系**只在这一侧** —— `SessionSummary` 里没有 `workspaceId`
 * （`packages/api/session-controller/src/types.ts:177-190`，只有 `cwd`）。
 * 所以手机要照 Web 分组，只能读这里；按 `cwd` 猜分组是第二份会漂的真值。
 *
 * ## 为什么是"打开流、取基线、就关掉"
 *
 * 工作区面只有一个入口：`@Remote({mode:'stream'})` 的 `follow(signal)`
 * （`index.ts:194-197`），首帧是**完整基线**
 * （`feed.ts:85-96`：`{type:'baseline', value:{items, archivedSessionIds, pinnedSessionIds}}`），
 * 之后才是增量。没有"一次性 list" verb —— 所以读基线就是**取第一帧后中止**：
 * `finally` 会把自己从 followers 里摘掉并关掉（`feed.ts:92-95`）。
 *
 * 手机是**拉取式**的（连上读一次），不常驻订阅：常驻要在连接层接增量帧，
 * 而本期只解决"列表能按工作区分组"。增量留白是如实的：工作区改名/新加工作区
 * 要等下一次读取。
 */
import type { WorkspaceController } from '@deepseek-ai/dsh-api-workspace-controller'

/** 一个工作区（通道 §5.7 的 `workspace.list` 行）。 */
export interface WorkspaceRow {
  workspaceId: string
  /** 用户可见的名字（Web 分组头就是它）。 */
  title: string
  /** 规范化的宿主目录。 */
  path: string
  /** 归属这个工作区的会话 id **（DSH 的 id，不是手机见的 sid）**。 */
  sessionIds: readonly string[]
}

export interface WorkspacesSnapshot {
  workspaces: readonly WorkspaceRow[]
  /** 已归档的会话 id（DSH 的 id）。归档不是删除：Web 有单独的归档视图。 */
  archivedSessionIds: readonly string[]
}

/** 工作区读取面（**收窄成这一层真正用到的方法**）。 */
export interface WorkspacesPort {
  list(): Promise<WorkspacesSnapshot>
}

/**
 * 读一次工作区基线。
 *
 * 超时只防挂死：`follow` 的首帧是同步产出 then yield 的，正常情况下立刻就有；
 * 真挂住说明宿主有问题，那时**抛出来**比返回一个空分组好 —— 空分组会让手机
 * 显示"没有工作区"，而真因是读取失败。
 */
const BASELINE_TIMEOUT_MS = 10_000

export function createWorkspacesPort(
  controller: WorkspaceController,
): WorkspacesPort {
  return {
    async list() {
      const abort = new AbortController()
      const timer = setTimeout(() => abort.abort(), BASELINE_TIMEOUT_MS)
      try {
        for await (const frame of controller.follow(abort.signal)) {
          if (frame.type !== 'baseline') continue
          const value = frame.value
          return {
            workspaces: value.items.map((item) => ({
              workspaceId: String(item.workspaceId),
              title: item.title,
              path: item.path,
              sessionIds: item.sessionIds.map(String),
            })),
            archivedSessionIds: value.archivedSessionIds.map(String),
          }
        }
        // 流关了也没给出基线：那是宿主的形状变了，不能当成"没有工作区"。
        throw new Error('workspace.follow 没有给出基线帧')
      } finally {
        clearTimeout(timer)
        abort.abort()
      }
    },
  }
}
