/**
 * 列表行的**投影白名单**：`session.list` 每一行带哪些 `projections.values` 键。
 *
 * ## 为什么需要它
 *
 * 宿主的 `session.list` 把每行的 projection **summary 块**整块给出
 * （`api/session-controller/src/types.ts:45-58`），哪些键进 summary 由投影注册时的
 * `summary: false` 决定 —— 也就是说**块的大小由宿主的投影表决定，不由请求决定**
 * （`session-list` 的请求是 `_request` 空对象，`src/index.ts:274-282`）。
 *
 * 2026-11-01 在本机量了一次（351 行，`GET` 侧 JSON 1 480 778 B）：
 *
 * | 项 | 字节 | 占比 |
 * |---|---|---|
 * | 整个 `projections` 块 | 1 398 436 | **94.5%** |
 * | └ `turnOutline` | 645 243 | 43.6% |
 * | └ `trajectory`（本仓自带） | 353 250 | 23.9% |
 * | 行本体（没有 projections） | 77 651 | 5.2% |
 *
 * 而 `turnOutline` / `trajectory` **只有打开某个会话时才需要**（轨迹页读
 * `session.projections` 的完整快照，那条路不受这里影响）。代价是真实的：
 * 一次标题变更出站 **1 943 515 B**，其中 **1 941 638 B** 就是这一整包。
 *
 * ## 判据（白名单唯一的来源）
 *
 * 手机侧读列表行的地方只有一处：`app/lib/wire/rpc/session.dart` 的
 * `readSessionSummary`。它只取下面这五个键，其余键一眼都不读 ——
 * 所以白名单 = **手机读的那几个**：多一个就是白搬字节，少一个就是界面缺数据。
 *
 * `tests/session-row-payload.test.ts` 直接解析那个 Dart 文件两侧比对，**必须逐字相等**；
 * 手机侧哪天多读一个键，那条用例会红并指出要加哪个。
 *
 * 取舍与被否方案（新增 `session.row` 窄口 / 行级推送）见
 * `.agents/notes/implemented/2026-11-01-list-row-payload.md`。
 */
export const SESSION_ROW_PROJECTION_KEYS = [
  /** 列表标题（`_titleOf`）。 */
  'title',
  /** 模型（`modelSelectionOf`，也兜底 `model` 字段）。 */
  'modelSelection',
  /** 子会话计时（`parseSubagentTiming`）。 */
  'subagentTiming',
  /** token 计数（`parseTokenUsage`）。 */
  'tokenUsage',
  /** 父行的直接子目录（`parseSubagentCatalogValue`）。 */
  'subagentCatalog',
] as const

export type SessionRowProjectionKey = (typeof SESSION_ROW_PROJECTION_KEYS)[number]

/**
 * 从宿主那一整块 `values` 里只挑白名单的键。
 *
 * **缺席的键不补 `undefined`**：在手机侧的解析器里"键缺席"与"值是 null"是两种意思
 * （前者是"这台电脑没有这个能力"，后者是"有但为空"）；补一个 `undefined` 会让
 * `in` 判断与 JSON 形状都变样。
 */
export function pickSessionRowProjectionValues(
  values: Readonly<Record<string, unknown>>,
): Record<string, unknown> {
  const picked: Record<string, unknown> = {}
  for (const key of SESSION_ROW_PROJECTION_KEYS) {
    if (key in values) picked[key] = values[key]
  }
  return picked
}


