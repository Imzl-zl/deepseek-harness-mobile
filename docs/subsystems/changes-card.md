# 改动卡（收口消息的「已编辑 N 个文件」）

会话流里一轮收口处的改动卡：这一轮改了哪些文件、各增删多少行、是不是二进制 / 过大。
点一行打开那个文件的内容预览。

## 1. 数据从哪来（手机不产生这份数据）

| 环节 | 出处 |
|---|---|
| 事件 | `workspace/changes`，**只带轮号**（`packages/deliverables/workspace-changes/src/types.ts:99-108`） |
| 记录 | 宿主 `workspaceChanges.summary(sessionId, seq)`（`workspace-changes/src/index.ts:116-120`、`types.ts:79-97`） |
| 过线 | `file.changes` → `{summary: {turn, files, total, added, deleted} \| null}`（契约 §5.7） |
| 手机 | `app/lib/wire/rpc/changes.dart` 解码、`app/lib/model/changes.dart` 取值、`ChatPage` 的 `_ChangedFilesCard` 画 |

**手机不自己算 `+N −M`**：真实文件、行数、二进制与超大的判定都在电脑上
（`types.ts:14-21` 的两个标记就是宿主给的）。自己从工具调用推一份会与桌面**不同源**。

## 2. 条目与坐标

- `workspace/changes` 投影成 `ChangesItem`，itemId 是 **`w:<turn>`**：同一轮的多条只认最新一条
  （`workspace-changes/src/types.ts:105-106`），用 `seq` 当身份会让卡片重复。
- 卡片的查询坐标是该事件的 **`seq`**（不是路径）：一键一查，键是 `'<sid>:<seq>'`。
- 条目本身不是"过程"，轮组折叠时**不藏**（与 DSH 的 `turnTail` 位置一致）。

## 3. 界面

| 部分 | 规则 |
|---|---|
| 标题 | 单文件：`已编辑 <文件名>`；多文件：`已编辑 <total> 个文件`（`total` 是**完整**数，含被截掉的） |
| 计数 | 单文件用记录 totals；行用该行 `added` / `deleted`；`binary` → `二进制`、`oversized` → `过大` |
| 行 | 显示宿主的 `display`（相对 cwd / `../` / `~` / 绝对路径，`types.ts:9-13`），等宽 |
| 折叠 | 默认 4 行（桌面 `ChangedFiles.tsx:18` 的 `COLLAPSED_ROWS`），超过给「全部 N 个文件 / 收起」 |
| 截断 | `files.length < total` 时明说「还有 M 个文件没列出（超过电脑侧上限）」——照报不假装列全 |
| 点击 | 行 → `AppModel.openFile(path, preview)`；标题 → 第一个文件（逐行差异等 `file.diff`） |

三态：没读到 ⇒ 不画；`summary: null`（电脑侧没有这条记录）⇒ 不画；读失败 ⇒ 卡片位置摆出
电脑侧原话 + 重试。

## 4. 能力位

`caps.changes`（连接器 `dsh/caps.ts` 的 `changesAvailable`：宿主 `workspaceChanges` 在不在）。
缺了（老连接器 / 没装 `workspace-changes` 的部署）就**一次 `file.changes` 都不发**，也不画卡。

## 5. 已知边界

- **没有逐行差异**：`file.diff` 未接，卡片与侧栏都没有 hunks（方案笔记批 C）。标题点击因此
  先开内容预览。
- **侧栏「差异」页签仍是会话级聚合**，不是这一轮的记录；两者的数字口径不同源，等 `file.diff`
  那一批一起收口。
- 卡片只反映 `workspace/changes` 记录到的改动（非 git 仓库只列文件工具改过的文件，
  `workspace-changes/src/index.ts:6-9`）。
