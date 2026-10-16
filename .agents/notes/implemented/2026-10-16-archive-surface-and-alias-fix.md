# Agent Note: 归档面接上（两个写方法 + 归档列表 + 左滑归档；顺手修掉只在生产发作的别名 bug）

Status: implemented

## Problem

抽屉底栏五个出口（文件 / 归档 / 演示 / 自动化 / 设置）**都不是编的** —— 原型基线全有，
DSH 各有原生缝 —— 而手机侧「归档」一直是 `_notYet('归档列表')` 空桩，
抽屉行的左滑归档参数（`SessionDrawer.onArchive`）**从写下来那天起就没人传过**。

同时有三处不一致（探索原生时逐条发现的）：

1. **`archivedSessionIds` 没过别名**：`workspace.list` 把 `sessionIds` 换成了手机见的 `sid`，
   归档集却原样透传 DSH 的 id（`connector/src/handlers.ts:417-422` 相邻两行，两种约定）。
   症状是"手机认不出哪条是归档的"，不报错 —— 又一个只在生产里发作的形状错。
2. **`app/lib/model/workspace.dart` 的注释说"连接器也还没给归档清单"** ——
   而连接器从 2026-10-15 起就在发。注释与实现不一致（这份注释把"没接"说成了"上游没有"）。
3. **DSH 的归档不是一个"另一个列表页"**：Web 把它做成列表的**过滤档**
   （隐藏 / 混显 / 只看归档，`ArchivedFilter`，`ui-workspace/src/client/tree.ts:225-230`），
   归档行**不能直接打开**（`toast.archivedNotOpenable`），取消归档**回原位**
   （`tree.ts:234-236` 原注释："their accounting slots remain either way so unarchiving restores position"）。

## Decision

**读面**（`workspace.list`）

- 归档集与会话 id **一起过 `aliases.ensure`**（同一份载荷只能有一种 id 约定）。
- 手机侧 `AppModel` 解析 `archivedSessionIds` → `archivedSids`，并新增
  `archivedSessions`（**从同一份 `sessions` 过滤出来**，不从列表里删 —— 取消归档要有行可回）。
- `sessionVisible` 增加第四个判据 `archived`（照 Web 的 `default` 档）。

**写面**（两个新方法，都带幂等键）

- `workspace.archive`（`{sid, stopActivity?}`）与 `workspace.unarchive`（`{sid}`）；
  与 Web 调的是**同一个 DSH 方法**（`workspace-controller/src/index.ts:154,164`）。
- `stopActivity` **只在为 true 时进请求体**：DSH 判的是 `=== true`，
  塞一个 `false` 是另一种语义（`commands.ts:164-167`）。
- 归档运行中的会话时宿主回 `workspace/session-active`（`commands.ts:172-178`）——
  它是**信息不是故障**：手机弹「停止并归档」确认（文案照 `archive.confirm.*`），
  用户点了才带 `stopActivity: true` 重发。**照 Web 的门，不自己发明**
  （`ui-workspace/src/client/index.ts:190-208`；Web 自己的归档动作就是带 `true` 的
  `uiWorkspace.archiveSession(sessionId, { stopActivity: true })`）。
- **错误码进封闭表**：`workspace/session-active` 补进 TS `ERROR_TABLE` 与 Dart `ErrorCode`
  （两边逐字一致，由 parity 测试断言）—— 不收它就会被归一成 `internal`，
  于是"会话在跑"看起来像"内部错误"，界面只会让用户重试。

**界面**

- 抽屉底栏「归档」→ `showArchiveSheet`（`app/lib/ui/archive_sheet.dart`）：
  列归档会话 + 行内「取消归档」+ 顶部一行 DSH 的原话
  （`已归档对话暂时无法查看，请取消归档后查看`）。**行本身不可点** —— 已归档的不能打开。
- 抽屉行左滑的 `onArchive` 接上（此前是死参数）。

## Alternatives considered

1. **照 Web 做成列表的三态过滤档**（隐藏 / 混显 / 只看归档）。
   - 最强的理由：与 Web 逐字同构，一套 UI 覆盖三种视图。
   - 为何被否：手机抽屉是 390px 的一列、**没有悬浮态**，三态过滤要占一整行，
     而且看不出"里面有没有东西"；原型基线的底栏本来就有「归档」这一项。
     语义（不能直接打开 / 取消归档回原位）照抄，形态按触屏。
2. **归档时本地先判断 `running`，是就不发请求、直接弹确认**。
   - 最强的理由：少一次失败往返。
   - 为何被否：本地 `running` 是上一份 `session.list` 的快照（可能已经过时），
     而宿主的判据才是权威。发出去、被拒、按错误码决定 —— 这条路径**恰好**也是 Web 的路径，
     并且顺带把 `workspace/session-active` 这个码收进了封闭表。
3. **归档成功后只改本地集合，不读应答**。
   - 为何被否：应答里带的是**宿主的权威归档全集**（`WorkspaceArchiveValue`）。
     本地算一份 = 第二份真值；而它对不上时的症状只是"少一条/多一条"，最难查。
4. **给归档列表做"撤销"toast**（Web 有 `toast.archivedUndo`）。
   - 为何被否：本轮先给**取消归档**一个常驻入口（列表行上），够用；
     撤销是锦上添花，等真机上有人抱怨再说（不做的理由写在 §Consequences）。

## Consequences

- 收益：底栏「归档」不再是空桩；左滑归档真的通到电脑；归档集与会话 id 只有一种约定；
  `workspace/session-active` 进了封闭表（不会被降级成 `internal`）。
- 代价：方法面 **27 → 29**（契约 §5.7 / `METHODS` / `tools.md` / `memory.md` 四处同步，
  由 `methods.test.ts` 与 `method-name-table.test.ts` 两个断言钉住）；错误码 **30 → 31**。
- 没做：归档的**撤销 toast**（Web 的 `toast.archivedUndo`）、
  多选归档 / 批量操作、`workspace.pin`（置顶）那一条写面。
- 回归：`connector/tests/workspaces-archive.test.ts`（7 条，含"归档集也过别名"与
  "`stopActivity` 只在为 true 时进请求体"）、`app/test/archive_test.dart`（7 条，含
  "错误码原样透传"与"取消归档那一行当场消失"）、
  `app/test/workspace_grouping_test.dart` 的「已归档的不列(哪怕是当前会话)」。