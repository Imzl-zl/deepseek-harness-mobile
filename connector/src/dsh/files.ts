/**
 * 工作区文件的面（`file.list` / `file.read`，契约 §5.7）。
 *
 * ## 方法面在哪
 *
 * `packages/api/workspace-files/src/index.ts` 的 `WorkspaceFiles`（服务键 `workspaceFiles`）
 * 有四个 `@Remote` + 一个流：`read`（`:233-247`，按**行**分页读 UTF-8 文本）、
 * `readBytes`（`:257-281`，按字节窗）、`stat`（`:290-294`）、`list`（`:303-329`，
 * 直接子级）与 `changes`（`:340-342`，`mode:'stream'`）。
 *
 * 本仓只接两个：**`list` 与 `read`**。理由：
 *
 * - 手机那一屏要的是"看目录、看文本内容"，这两件够了；
 * - `readBytes` 的原样字节会撞我们这条管道的单帧预算（契约 §40），而图片预览在触屏上
 *   不是"看文件"的主路径 —— 接它要另说（先量）；
 * - `changes` 是流，接它等于给手机加一条订阅面，与"只读预览"不是同一个需求。
 *
 * ## scope 从哪来：**宿主的 lookup，不自己拼**
 *
 * 四个方法的第一参数都是 `WorkspaceFileScope`（`:55-60` 的
 * `{sessionId, workspaceRoot}`），而它由 `workspaceFiles` 自己注册的 typert lookup
 * `workspaceFileScope` 按 **sessionId** 解析（`:203-221`：活会话取 header 的 `cwd`，
 * 不然退到 `sessionPersistence.stat` 的 header，再退 `sandboxPolicy.workspaceRoot`）。
 *
 * 所以这里**调同一个 lookup**（`ctx.typert.lookups.get('workspaceFileScope').resolve(id)`，
 * registry 形状 `packages/typert/protocol/src/types.ts:782-825`、provider 的 `resolve` 在
 * `:665-670`），而不是照抄那三行回退 —— 拼一份就是第二份真值：手机看到的"工作目录"
 * 与桌面看到的会漂。
 *
 * ## 与 `@` 补全不是同一条路
 *
 * `@` 用 `fileReferences`（确定性、path-only、不需要 workspace 身份）。
 * 本文件这两个方法**要 workspace 身份**（`WorkspaceFileScope`），所以只给"文件页 / 预览"用 ——
 * 拿它去填 `@` 会把一次补全变成两步 + 一个 scope 解析。
 *
 * 取舍（为什么不接 `readBytes` 与 `changes`、为什么 scope 走 lookup）见
 * `.agents/notes/implemented/2026-10-24-workspace-file-browser.md`。
 */
import type { Context } from '@deepseek-ai/cordis'

import { asProtocolError, ProtocolError } from '../protocol/errors.js'

/** typert 注册表里本层用到的部分（`ctx.typert`，`types.ts:947-950`）。 */
interface TypertRegistry {
  lookups: {
    get(key: string): { resolve(id: string): unknown | Promise<unknown> } | undefined
  }
}

/** `workspaceFiles` 服务面（**按形状收窄、不 import DSH 类型**）。 */
interface WorkspaceFilesService {
  list(scope: unknown, path: string, signal: AbortSignal): Promise<unknown>
  read(
    scope: unknown,
    path: string,
    range: { offset?: number; limit?: number },
    signal: AbortSignal,
  ): Promise<unknown>
}

/** 给手机的一个目录项（宿主的 `WorkspaceDirectoryEntry`，`types.ts:94-106`）。 */
export interface FileEntry {
  name: string
  type: 'file' | 'directory' | 'other'
  /** 字节大小（宿主只在普通文件且后端报得出时给）。 */
  size?: number
}

/** 给手机的一份目录清单（宿主的 `WorkspaceDirectoryListing`，`types.ts:108-123`）。 */
export interface FileListing {
  /** 被列目录本身（相对工作区，根是空串）。 */
  path: string
  entries: readonly FileEntry[]
  /** 条目上限是否截掉了后面的项（**截断要说，不假装列全了**）。 */
  truncated: boolean
}

/** 给手机的一页文本（宿主的 `WorkspaceFileText`，`types.ts:48-62`）。 */
export interface FilePage {
  /** 这一页的行（`\n` 连接、末尾不带换行；空串可能是"越过末行"也可能是"一页空行"）。 */
  text: string
  /** 这一页从第几行起（1 基）。 */
  offset: number
  /** 这一页有几行（`0` = offset 越过末行）。 */
  lines: number
  /** 这一页是否含文件最后一行。 */
  eof: boolean
  /** 文件总字节（后端报得出才有）。 */
  bytes?: number
}

export interface FilesDeps {
  /** 通道别名 → DSH 会话 id（契约 §5.1）。不认识的别名返回 `undefined`。 */
  sessionOf(sid: string): string | undefined
}

export interface FilesFace {
  list(sid: string, path: string): Promise<FileListing>
  read(
    sid: string,
    path: string,
    range: { offset?: number; limit?: number },
  ): Promise<FilePage>
}

/**
 * 一次文件读取的超时。
 *
 * 宿主 `read` / `list` 都要一个 `AbortSignal`（它拿它取消文件系统读）。
 * 取契约 §10 的请求超时同一个值：手机到点就放弃这次请求。
 */
const FILE_TIMEOUT_MS = 60_000

/**
 * 建文件面。
 *
 * 服务键走 `ctx.get`，**缺席的判定在装配层**（`index.ts` 按 `filesAvailable(ctx)` 决定挂不挂）；
 * 走到这里缺键只可能是装配写错了，那时如实抛 —— 回空清单会被手机读成"这个目录是空的"。
 */
export function createFilesFace(ctx: Context, deps: FilesDeps): FilesFace {
  const serviceOf = (): WorkspaceFilesService => {
    const service = ctx.get('workspaceFiles') as WorkspaceFilesService | undefined
    if (service === undefined) {
      throw new ProtocolError('internal', 'workspaceFiles 服务不在：工作区文件面不可用')
    }
    return service
  }

  /**
   * 别名 → `WorkspaceFileScope`（**走宿主自己的 lookup**，见文件头）。
   *
   * 会话不存在 / 没有工作目录时宿主回 `undefined` —— 那是"这个会话没有工作目录"，
   * 不是"这条链路坏了"，所以按 `internal` 说清楚（不伪装成 `session/not-found`：
   * 那个码的客户端动作是"从列表移除"，会删掉一个好会话）。
   */
  const scopeOf = async (sid: string): Promise<unknown> => {
    const dshSessionId = deps.sessionOf(sid)
    if (dshSessionId === undefined) {
      throw new ProtocolError('session/not-found', `未知的会话别名：${sid}`)
    }
    const typert = ctx.get('typert') as TypertRegistry | undefined
    const lookup = typert?.lookups.get('workspaceFileScope')
    if (lookup === undefined) {
      throw new ProtocolError('internal', 'workspaceFileScope lookup 不可用：不是文件服务的部署')
    }
    const scope = await lookup.resolve(dshSessionId)
    if (scope === undefined) {
      throw new ProtocolError(
        'internal',
        `这个会话没有工作目录（${sid}）：文件页需要会话带 cwd，或部署给了工作区根`,
      )
    }
    return scope
  }

  return {
    // **宿主的拒绝要抬成协议错误**：`workspace-file/not-text` / `-too-large` /
    // `-not-found` / `-not-regular-file` 都在 §3.1 的封闭表里（桌面按它们换文案，
    // `ui-sidebar-documentpreview/src/client/failure-line.ts:24-35`）。
    // 不抬的话 `protocol/methods.ts:361-370` 会把它们归成 `internal`，
    // 手机只剩宿主的英文原文可显示 —— 真机上就是「读取失败：<english>」。
    list: (sid, path) =>
      asProtocolError(async () => {
        const raw = await serviceOf().list(
          (await scopeOf(sid)) as never,
          path,
          AbortSignal.timeout(FILE_TIMEOUT_MS),
        )
        return listingOf(raw, path)
      }),

    read: (sid, path, range) =>
      asProtocolError(async () => {
        const raw = await serviceOf().read(
          (await scopeOf(sid)) as never,
          path,
          { ...(range.offset === undefined ? {} : { offset: range.offset }), ...(range.limit === undefined ? {} : { limit: range.limit }) },
          AbortSignal.timeout(FILE_TIMEOUT_MS),
        )
        return pageOf(raw)
      }),
  }
}

/** 宿主的清单 → 手机的形状（**逐字段构造**，不让将来的新字段悄悄过线）。 */
function listingOf(raw: unknown, requested: string): FileListing {
  if (typeof raw !== 'object' || raw === null) {
    throw new ProtocolError('internal', 'workspaceFiles.list 的应答形状认不出')
  }
  const record = raw as Record<string, unknown>
  const entries = Array.isArray(record['entries']) ? record['entries'] : []
  return {
    path: typeof record['path'] === 'string' ? record['path'] : requested,
    entries: entries.flatMap((entry): FileEntry[] => {
      if (typeof entry !== 'object' || entry === null) return []
      const row = entry as Record<string, unknown>
      const name = row['name']
      if (typeof name !== 'string' || name === '') return []
      const type = row['type']
      const size = row['size']
      return [
        {
          name,
          // 认不出的类型归 `other`（宿主的第三档就是"既不是文件也不是目录"）。
          type: type === 'file' || type === 'directory' ? type : 'other',
          ...(typeof size === 'number' && Number.isFinite(size) && size >= 0 ? { size } : {}),
        },
      ]
    }),
    truncated: record['truncated'] === true,
  }
}

/** 宿主的一页文本 → 手机的形状（同上：逐字段）。 */
function pageOf(raw: unknown): FilePage {
  if (typeof raw !== 'object' || raw === null) {
    throw new ProtocolError('internal', 'workspaceFiles.read 的应答形状认不出')
  }
  const record = raw as Record<string, unknown>
  const text = record['text']
  const offset = record['offset']
  const lines = record['lines']
  if (typeof text !== 'string' || typeof offset !== 'number' || typeof lines !== 'number') {
    throw new ProtocolError('internal', 'workspaceFiles.read 的应答缺 text / offset / lines')
  }
  const bytes = record['bytes']
  return {
    text,
    offset,
    lines,
    eof: record['eof'] === true,
    ...(typeof bytes === 'number' && Number.isFinite(bytes) && bytes >= 0 ? { bytes } : {}),
  }
}
