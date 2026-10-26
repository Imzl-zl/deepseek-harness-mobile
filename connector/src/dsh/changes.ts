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
  diff(
    sessionId: unknown,
    seq: number,
    index: number,
    signal: AbortSignal,
  ): Promise<unknown>
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

/** 一个 hunk（宿主的 `WorkspaceDiffHunk`，`types.ts:42-54`）：每行带 `+` / `-` / 空格前缀。 */
export interface DiffHunkView {
  oldStart: number
  oldLines: number
  newStart: number
  newLines: number
  lines: readonly string[]
}

/** 单文件比对（宿主的 `WorkspaceFileDiff`，`types.ts:56-76`）。 */
export type FileDiffView =
  | {
      kind: 'text'
      path: string
      display: string
      /** 文件在轮次起点 / 终点存在吗（`false` → 本轮新建 / 删除）。 */
      before: boolean
      after: boolean
      /** 逐行对比超时，宿主按**整个文件替换**给出（`types.ts:70-71`）。 */
      coarse: boolean
      hunks: readonly DiffHunkView[]
      /** 只给了前一部分（行数或字节封顶）—— **照报不假装给全**。 */
      truncated?: { shownLines: number; totalLines: number }
    }
  | { kind: 'binary'; path: string; display: string }
  | { kind: 'oversized'; path: string; display: string }

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

  /**
   * 一个改动文件的逐行比对。
   *
   * 坐标是 **`seq` + 文件在 `summary.files` 里的下标**（宿主只认这个，`types.ts:88-96`）——
   * 不是路径：同一个路径在一轮里可能出现两种拼写。
   *
   * @returns 比对；`null` = 电脑侧**没有这条记录**（会话已释放 / 没记录过），不是失败。
   */
  diff(sid: string, seq: number, index: number): Promise<FileDiffView | null>
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

  const sessionOf = (sid: string): string => {
    const dshSessionId = deps.sessionOf(sid)
    if (dshSessionId === undefined) {
      throw new ProtocolError('session/not-found', `未知的会话别名：${sid}`)
    }
    return dshSessionId
  }

  return {
    summary(sid, seq) {
      const raw = serviceOf().summary(sessionOf(sid), seq)
      return raw === undefined ? null : summaryOf(raw)
    },

    async diff(sid, seq, index) {
      const raw = await serviceOf().diff(
        sessionOf(sid),
        seq,
        index,
        AbortSignal.timeout(DIFF_TIMEOUT_MS),
      )
      return raw === undefined ? null : fileDiffOf(raw)
    },
  }
}

/**
 * 一次 diff 的等待上限。
 *
 * 与 `file.read` 同一个值（契约 §10 的请求超时）：手机到点就放弃。
 * 宿主自己另有 `diffTimeoutMs`（默认 100 ms）来把超时的比对降级成整文件替换
 * （`workspace-changes/src/index.ts:56` 的 `diffTimeoutMs`、`types.ts:70-71` 的 `coarse`），
 * 所以这里等的是"读快照 + 算"的总时长，不是逐行算法的上限。
 */
const DIFF_TIMEOUT_MS = 60_000

/**
 * 一次比对最多发多少行 —— **手机自己的数**，不是照抄桌面的 5000。
 *
 * 桌面在浏览器里渲染，上限是 `ui-deliverables/src/client/FileDiff.tsx:14` 的
 * `MAX_RENDERED_LINES = 5000`，超了显示「只显示前 5000 行」（`locales.ts:67`）。
 * 手机这一版的差异视图是**一次性铺完**的（`app/lib/ui/dsh_diff.dart`：一个 Column，
 * 每行两个行号格 + 标记 + 正文，约 5 个 widget/行）——5000 行≈2.5 万个 widget，
 * 首帧与重建都会卡。1000 行≈5 千个 widget，是"能一眼看完、滚动不卡"的量级。
 *
 * 传输不是瓶颈：1000 行通常几十 KB，离单帧 8 MiB（契约 §3）差两个数量级。
 * 所以这个数是为**渲染**定的，文案与桌面同一句（「只显示前 N 行」）。
 */
export const DIFF_MAX_LINES = 1000

/**
 * 一帧 diff 的字节兜底（**通道物理约束**，不是产品策略）。
 *
 * 单帧 8 MiB、封箱后膨胀 ≈1.78×（`memory.md` 教训 8）⇒ 明文预算 ≈4.5 MiB。
 * 取 256 KiB 只防**超长单行**（minified 文件整文件替换，一行就能到 MB 级）：
 * 正常代码下 1000 行先触顶，走不到这里。
 */
export const DIFF_MAX_BYTES = 1024 * 1024

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

/** 宿主的单文件比对 → 手机的形状（**逐字段构造**；`truncated` 只在真的截了才出现）。 */
function fileDiffOf(raw: unknown): FileDiffView {
  if (typeof raw !== 'object' || raw === null) {
    throw new ProtocolError('internal', 'workspaceChanges.diff 的应答形状认不出')
  }
  const record = raw as Record<string, unknown>
  const kind = record['kind']
  const path = record['path']
  const display = record['display']
  if (
    typeof path !== 'string' ||
    path.length === 0 ||
    typeof display !== 'string' ||
    display.length === 0
  ) {
    throw new ProtocolError('internal', 'workspaceChanges.diff 缺 path / display')
  }
  if (kind === 'binary') return { kind: 'binary', path, display }
  if (kind === 'oversized') return { kind: 'oversized', path, display }
  if (kind !== 'text') {
    throw new ProtocolError(
      'internal',
      `workspaceChanges.diff 的 kind 认不出：${String(kind)}`,
    )
  }
  const before = record['before']
  const after = record['after']
  const coarse = record['coarse']
  const hunks = record['hunks']
  if (
    typeof before !== 'boolean' ||
    typeof after !== 'boolean' ||
    typeof coarse !== 'boolean' ||
    !Array.isArray(hunks)
  ) {
    throw new ProtocolError(
      'internal',
      'workspaceChanges.diff 缺 before / after / coarse / hunks',
    )
  }
  const mapped = hunks.map((hunk) => hunkOf(hunk))
  const totalLines = mapped.reduce((count, hunk) => count + hunk.lines.length, 0)
  const { kept, shownLines } = cutHunks(mapped)
  return {
    kind: 'text',
    path,
    display,
    before,
    after,
    coarse,
    hunks: kept,
    // **截了才说**：与 `file.list` / `trajectory` 的 `truncated` 同一条纪律。
    ...(shownLines < totalLines ? { truncated: { shownLines, totalLines } } : {}),
  }
}

function hunkOf(raw: unknown): DiffHunkView {
  if (typeof raw !== 'object' || raw === null) {
    throw new ProtocolError('internal', 'workspaceChanges.diff 的 hunk 认不出')
  }
  const record = raw as Record<string, unknown>
  const oldStart = record['oldStart']
  const oldLines = record['oldLines']
  const newStart = record['newStart']
  const newLines = record['newLines']
  const lines = record['lines']
  if (
    !_isCount(oldStart) ||
    !_isCount(oldLines) ||
    !_isCount(newStart) ||
    !_isCount(newLines) ||
    !Array.isArray(lines) ||
    !lines.every((line) => typeof line === 'string' && /^[+ -]/.test(line))
  ) {
    throw new ProtocolError(
      'internal',
      'workspaceChanges.diff 的 hunk 缺字段，或某一行没有 `+` / `-` / 空格前缀',
    )
  }
  return { oldStart, oldLines, newStart, newLines, lines: lines as string[] }
}

/**
 * 按行数 / 字节两道上限裁 hunks。
 *
 * **切法与桌面一致**（`FileDiff.tsx:116-125` 的 `renderedHunks`）：按顺序保留，
 * 最后保留的那条按剩余预算切开；切了就结束（不再补后面的 hunk）。
 * 行数上限用桌面的 5000，字节上限是通道帧预算的兜底（见 [DIFF_MAX_BYTES]）。
 */
function cutHunks(hunks: readonly DiffHunkView[]): {
  kept: DiffHunkView[]
  shownLines: number
} {
  const kept: DiffHunkView[] = []
  let shownLines = 0
  let bytes = 0
  for (const hunk of hunks) {
    const roomLines = DIFF_MAX_LINES - shownLines
    const roomBytes = DIFF_MAX_BYTES - bytes
    if (roomLines <= 0 || roomBytes <= 0) break
    const hunkBytes = hunk.lines.reduce((sum, line) => sum + line.length + 1, 0)
    if (hunk.lines.length <= roomLines && hunkBytes <= roomBytes) {
      kept.push(hunk)
      shownLines += hunk.lines.length
      bytes += hunkBytes
      continue
    }
    // 放不下整条：按预算切一刀（切到哪算哪，不猜）。
    const sliced: string[] = []
    let used = 0
    for (const line of hunk.lines) {
      if (sliced.length >= roomLines) break
      if (used + line.length + 1 > roomBytes) break
      sliced.push(line)
      used += line.length + 1
    }
    // 一行都放不下（超长单行撞字节上限）：**不推空 hunk**，如实报截断。
    if (sliced.length > 0) {
      kept.push({ ...hunk, lines: sliced })
      shownLines += sliced.length
    }
    break
  }
  return { kept, shownLines }
}
