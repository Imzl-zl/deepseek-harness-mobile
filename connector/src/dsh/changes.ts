/**
 * 改动面（`file.changes`，契约 §5.7）：**把桌面的改动记录原样过线**。
 *
 * ## 数据从哪来（不在这里产生）
 *
 * 宿主的 `workspaceChanges` 服务（`packages/deliverables/workspace-changes/src/index.ts:116-120`
 * 注册，类型声明在 `src/types.ts:110-114`）：
 *
 * - `summary(sessionId, seq)`：**同步**，Session 被释放或这台电脑没记录过 ⇒ `undefined`；
 *   非 git 仓库或没有 git 时只列文件工具改过的文件（`index.ts:6-9`）；
 * - 记录本身带 `cwd` 与 `snapshot` 两个 id（`types.ts:25-40`），**这两个不过线**：
 *   手机不需要，而且少一个泄漏面（与 `file.list` 不带绝对路径同一个理由）。
 *
 * 桌面浏览器侧也是从**同一个服务**取数据（`packages/client/ui-deliverables/src/present-open.ts:131-165`
 * 的 `/api/changes.summary` 只是它的 HTTP 适配）。所以这里**不代理那条路由** —— 代理会把
 * 宿主路由与鉴权变成手机协议的第二份真值。
 *
 * ## 坐标是 `seq`，不是路径
 *
 * 宿主按"`workspace/changes` 事件的 seq + 文件在 `summary.files` 里的下标"取 diff
 * （`types.ts:88-96`）。所以这一层也只认 `seq`；路径是记录自带的字段，不是查询键。
 *
 * 取舍见 `.agents/notes/implemented/2026-10-26-changes-face-and-card.md`。
 */
import type { Context } from '@deepseek-ai/cordis'

import { ProtocolError } from '../protocol/errors.js'

/** `workspaceChanges` 服务里本层用到的部分（`types.ts:79-97`；**按形状收窄、不 import DSH 类型**）。 */
interface WorkspaceChangesService {
  summary(sessionId: unknown, seq: number): unknown
}

/** 给手机的一个改动文件（宿主的 `WorkspaceChangedFile`，`types.ts:5-22`）。 */
export interface ChangedFileView {
  /** 相对会话工作目录的路径（或宿主认得的绝对路径）—— 打开文件时原样交回。 */
  path: string
  /** 显示用的那一串（宿主的排序键与标签，`types.ts:9-13`）。 */
  display: string
  added: number
  deleted: number
  /** 宿主说它是二进制（或捕获的一侧含 NUL）—— 没有行数可比。 */
  binary?: true
  /** 捕获的一侧超过插件的 `maxFileBytes` —— 没有行数、也没有比对。 */
  oversized?: true
}

/** 给手机的一份改动记录（宿主的 `WorkspaceChangesSummary` 去掉 `cwd` / `snapshot`）。 */
export interface ChangesSummaryView {
  turn: number
  /** 按 `display` 排好序、被插件 `maxFiles` 截过（`types.ts:30-31`）。 */
  files: readonly ChangedFileView[]
  /** **完整**的改动文件数（含被上限截掉的）。 */
  total: number
  /** 全部改动文件的行数（含被截掉的）。 */
  added: number
  deleted: number
}

export interface ChangesDeps {
  /** 通道别名 → DSH 会话 id（契约 §5.1）。不认识的别名返回 `undefined`。 */
  sessionOf(sid: string): string | undefined
}

export interface ChangesFace {
  /**
   * 一个 `workspace/changes` 事件宣告的改动记录。
   *
   * @returns 记录；`null` = 电脑侧**没有这条记录**（会话已释放 / 从没记录过）。
   *   那不是故障：桌面用 HTTP 404 表达同一件事（`present-open.ts:131-139`），
   *   手机据此不画卡片。
   */
  summary(sid: string, seq: number): ChangesSummaryView | null
}

/**
 * 建改动面。
 *
 * 服务键走 `ctx.get`，**缺席的判定在装配层**（`index.ts` 按 `changesAvailable(ctx)` 决定挂不挂）；
 * 走到这里缺键只可能是装配写错了，那时如实抛 —— 返回 `null` 会被手机读成"这一轮没改文件"。
 */
export function createChangesFace(ctx: Context, deps: ChangesDeps): ChangesFace {
  const serviceOf = (): WorkspaceChangesService => {
    const service = ctx.get('workspaceChanges') as
      | WorkspaceChangesService
      | undefined
    if (service === undefined) {
      throw new ProtocolError('internal', 'workspaceChanges 服务不在：改动面不可用')
    }
    return service
  }

  return {
    summary(sid, seq) {
      const dshSessionId = deps.sessionOf(sid)
      if (dshSessionId === undefined) {
        throw new ProtocolError('session/not-found', `未知的会话别名：${sid}`)
      }
      const raw = serviceOf().summary(dshSessionId, seq)
      return raw === undefined ? null : summaryOf(raw)
    },
  }
}

/** 宿主的记录 → 手机的形状（**逐字段构造**，不让将来的新字段悄悄过线）。 */
function summaryOf(raw: unknown): ChangesSummaryView {
  if (typeof raw !== 'object' || raw === null) {
    throw new ProtocolError('internal', 'workspaceChanges.summary 的应答形状认不出')
  }
  const record = raw as Record<string, unknown>
  const turn = record['turn']
  const total = record['total']
  const added = record['added']
  const deleted = record['deleted']
  if (
    !_isCount(turn) ||
    !_isCount(total) ||
    !_isCount(added) ||
    !_isCount(deleted)
  ) {
    throw new ProtocolError(
      'internal',
      'workspaceChanges.summary 缺 turn / total / added / deleted（或不是安全非负整数）',
    )
  }
  const files = Array.isArray(record['files']) ? record['files'] : []
  return {
    turn,
    files: files
      .map((file) => fileOf(file))
      .filter((file): file is ChangedFileView => file !== null),
    total,
    added,
    deleted,
  }
}

/** 一行改动（认不出的行**整行不要**：没有路径的行点不动也叫不出路径）。 */
function fileOf(raw: unknown): ChangedFileView | null {
  if (typeof raw !== 'object' || raw === null) return null
  const record = raw as Record<string, unknown>
  const path = record['path']
  const display = record['display']
  const added = record['added']
  const deleted = record['deleted']
  if (
    typeof path !== 'string' ||
    path.length === 0 ||
    typeof display !== 'string' ||
    display.length === 0 ||
    !_isCount(added) ||
    !_isCount(deleted)
  ) {
    return null
  }
  return {
    path,
    display,
    added,
    deleted,
    // 宿主的两个标记都是 `true` / 缺席（`types.ts:18-21`）；不是 `true` 就不写。
    ...(record['binary'] === true ? { binary: true as const } : {}),
    ...(record['oversized'] === true ? { oversized: true as const } : {}),
  }
}

function _isCount(value: unknown): value is number {
  return typeof value === 'number' && Number.isSafeInteger(value) && value >= 0
}
