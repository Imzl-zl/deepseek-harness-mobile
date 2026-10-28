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
import type {
  WorkspaceArchiveSessionRequest,
  WorkspaceController,
  WorkspaceInsertSessionBeforeRequest,
} from '@deepseek-ai/dsh-api-workspace-controller'

import { asProtocolError } from '../protocol/errors.js'

/** DSH 的会话 id 类型（`SessionId` 是带品牌的字符串，跨界要显式转一次）。 */
type DshSessionId = WorkspaceArchiveSessionRequest['sessionId']

/** DSH 的工作区 id 类型（同上，`WorkspaceId` 也是品牌字符串）。 */
type DshWorkspaceId = WorkspaceInsertSessionBeforeRequest['workspaceId']

/** 一个工作区（通道 §5.7 的 `workspace.list` 行）。 */
export interface WorkspaceRow {
  workspaceId: string
  /** 用户可见的名字（Web 分组头就是它）。 */
  title: string
  /** 规范化的宿主目录。 */
  path: string
  /** 归属这个工作区的会话 id **（DSH 的 id，不是手机见的 sid）**。 */
  sessionIds: readonly string[]
  /**
   * 工作区**创建时刻**（ISO 字符串，原样过线）。
   *
   * DSH 的 `recentWorkspace`（`packages/client/ui-workspace/src/client/navigation.ts:553-572`）
   * 对**没有任何会话**的工作区用 `Date.parse(workspace.createdAt)` 当它的"最近时刻" ——
   * 少了这个字段，空工作区永远赢不了（手机侧以前记成 `-1`，是一处已记过的偏离）。
   * 宿主的 `WorkspaceView.createdAt` 就是它（`packages/api/workspace-controller/src/types.ts:27`）；
   * 手机**不解析成时间戳**，只在"谁更新"这件事上按 DSH 的规则比较（见 `model/workspace.dart`）。
   */
  createdAt: string
}

export interface WorkspacesSnapshot {
  workspaces: readonly WorkspaceRow[]
  /** 已归档的会话 id（DSH 的 id）。归档不是删除：Web 有单独的归档视图。 */
  archivedSessionIds: readonly string[]
  /**
   * 置顶的会话 id（DSH 的 id），**最近置顶的在前**
   * （`types.ts:147-150` 的 `WorkspacePinValue`，基线里同名字段见 `types.ts:152-158`）。
   *
   * 它是**registry 全局**的集合（不分工作区），与 Web 的置顶块同一条。
   */
  pinnedSessionIds: readonly string[]
}

/** 工作区读取面 + 归档 / 组内重排 / 置顶写方法（**收窄成这一层真正用到的方法**）。 */
export interface WorkspacesPort {
  list(): Promise<WorkspacesSnapshot>
  /**
   * 归档一个会话，返回**归档全集**（DSH id）。
   *
   * `stopActivity` 的语义照 DSH：**不带**它时，有在跑的轮次/子智能体/后台任务的会话
   * 会被拒（`workspace/session-active`）；带上它，宿主先请求停掉那些活动
   * （`packages/api/workspace-controller/src/types.ts:115-125`、
   * `commands.ts:162-183`）。Web 的"停止并归档"对话框走的就是带它的那条
   * （`ui-workspace/src/client/index.ts:205-208`）。
   */
  archive(sessionId: string, stopActivity: boolean): Promise<readonly string[]>
  /** 取消归档。**幂等**：没归档过的 id 也成功（DSH `commands.ts:185-195` 的原注释）。 */
  unarchive(sessionId: string): Promise<readonly string[]>

  /**
   * 在同一工作区内把会话挪到 `beforeSessionId` 之前（DOM `insertBefore` 语义）。
   *
   * DSH：`@Remote('insertSessionBefore')`（`index.ts:149-152`）→
   * `commands.ts:132-152`。请求形状 `{workspaceId, sessionId, beforeSessionId?}`
   * （`types.ts:107-112`），**不给 `beforeSessionId` 就是追加到末尾**。
   *
   * **它只重排、不改归属**：跨工作区的移动会被宿主拒成
   * `WorkspaceMoveInvalidError` → `workspace/move-invalid`（`commands.ts:137-149`）。
   *
   * @returns 该工作区**新的**会话 id 顺序（DSH id）—— 调用方据此刷新分组，
   *          不必再读一次基线。
   */
  insertSessionBefore(
    workspaceId: string,
    sessionId: string,
    beforeSessionId?: string,
  ): Promise<readonly string[]>

  /**
   * 把一个**工作区**挪到 `beforeWorkspaceId` 之前（DOM `insertBefore` 语义）。
   *
   * DSH：`@Remote('insertBefore')`（`index.ts:135-145`）→ `commands.ts:108-125`。
   * 请求 `{workspaceId, beforeWorkspaceId?}`（`types.ts:97-105`），
   * **不给 `beforeWorkspaceId` 就是移到末尾**。
   *
   * 与 `insertSessionBefore` 的差别：那个改的是**工作区内部的会话顺序**，
   * 这个改的是**注册表里工作区自己的顺序**（侧栏项目头的上下位置）。
   *
   * @returns **整份**工作区顺序（DSH id）—— 调用方据此重排分组。
   */
  insertBefore(
    workspaceId: string,
    beforeWorkspaceId?: string,
  ): Promise<readonly string[]>

  /** 置顶（registry 全局集合）。返回**置顶全集**，最近置顶的在前。 */
  pin(sessionId: string): Promise<readonly string[]>

  /** 取消置顶。返回置顶全集（**幂等**：没置顶过的 id 也成功，照 `commands.ts:218-226`）。 */
  unpin(sessionId: string): Promise<readonly string[]>
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
              // 原样过线（ISO 字符串）：手机只拿它比"谁更新"，不做时区换算。
              createdAt: item.createdAt,
            })),
            archivedSessionIds: value.archivedSessionIds.map(String),
            pinnedSessionIds: value.pinnedSessionIds.map(String),
          }
        }
        // 流关了也没给出基线：那是宿主的形状变了，不能当成"没有工作区"。
        throw new Error('workspace.follow 没有给出基线帧')
      } finally {
        clearTimeout(timer)
        abort.abort()
      }
    },

    async archive(sessionId, stopActivity) {
      const value = await asProtocolError(() =>
        controller.archiveSession({
          sessionId: sessionId as DshSessionId,
          // 缺省时**不进请求体**：DSH 的语义是"不带就是不带"
          // （`commands.ts:160-167` 判的是 `=== true`）。
          ...(stopActivity ? { stopActivity: true } : {}),
        }),
      )
      return value.archivedSessionIds.map(String)
    },

    async unarchive(sessionId) {
      const value = await asProtocolError(() =>
        controller.unarchiveSession({
          sessionId: sessionId as DshSessionId,
        }),
      )
      return value.archivedSessionIds.map(String)
    },

    async insertSessionBefore(workspaceId, sessionId, beforeSessionId) {
      const value = await asProtocolError(() =>
        controller.insertSessionBefore({
          workspaceId: workspaceId as DshWorkspaceId,
          sessionId: sessionId as DshSessionId,
          // 缺省时**不进请求体**：DSH 的 `beforeSessionId?` 是"不给就追加到末尾"
          // （`types.ts:107-112`），塞空串会被当成一个非法锚点。
          ...(beforeSessionId === undefined
            ? {}
            : { beforeSessionId: beforeSessionId as DshSessionId }),
        }),
      )
      // 返回该工作区的新顺序：调用方据此刷新分组，不必再读一次基线。
      return value.workspace.sessionIds.map(String)
    },

    async insertBefore(workspaceId, beforeWorkspaceId) {
      const value = await asProtocolError(() =>
        controller.insertBefore({
          workspaceId: workspaceId as DshWorkspaceId,
          // 缺省时**不进请求体**：DSH 的 `beforeWorkspaceId?` 是"不给就移到末尾"
          // （`types.ts:97-105`），塞空串会被当成一个非法锚点。
          ...(beforeWorkspaceId === undefined
            ? {}
            : { beforeWorkspaceId: beforeWorkspaceId as DshWorkspaceId }),
        }),
      )
      // 返回**整份**工作区顺序：调用方据此重排分组，不必再读一次基线。
      return value.workspaceIds.map(String)
    },

    async pin(sessionId) {
      const value = await asProtocolError(() =>
        controller.pinSession({ sessionId: sessionId as DshSessionId }),
      )
      return value.pinnedSessionIds.map(String)
    },

    async unpin(sessionId) {
      const value = await asProtocolError(() =>
        controller.unpinSession({ sessionId: sessionId as DshSessionId }),
      )
      return value.pinnedSessionIds.map(String)
    },
  }
}
