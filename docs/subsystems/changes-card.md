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
| 点击 | 行 → `AppModel.openFile(path, preview)`；标题 → 第一个文件的**逐行差异**（`file.diff`，坐标 `seq` + 下标 `0`） |

三态：没读到 ⇒ 不画；`summary: null`（电脑侧没有这条记录）⇒ 不画；读失败 ⇒ 卡片位置摆出
电脑侧原话 + 重试。

## 4. 逐行差异（`file.diff`）

侧栏「差异」页签与卡片标题共用同一个 `DiffView`（`app/lib/ui/dsh_diff.dart`），数据来自
`file.diff` → 宿主 `workspaceChanges.diff(sessionId, seq, index, signal)`
（`workspace-changes/src/types.ts:88-96`）。坐标是 **`seq` + 文件在记录里的下标**，不是路径。

四种结局与桌面的文案同一份（`ui-deliverables/src/client/locales.ts:58-67`）：

| 结局 | 显示 |
|---|---|
| `kind: binary` | 二进制文件，无法显示改动 |
| `kind: oversized` | 文件过大，无法显示改动 |
| `coarse: true` | 逐行对比超时，按整个文件替换显示 |
| `before:false` / `after:false` / 空 hunks | 本轮新建的文件 / 本轮删除的文件 / 两侧内容相同 |

**上限**：行数 **1000**、字节 1 MiB（连接器 `dsh/changes.ts` 的 `DIFF_MAX_LINES` /
`DIFF_MAX_BYTES`）。桌面渲染上限是 5000（`FileDiff.tsx:14`），手机上取 1000 是因为
`DshDiff` 一次性铺完（约 5 个 widget/行），5000 行≈2.5 万个 widget。超了按桌面的切法
（`FileDiff.tsx:116-125`）切最后一条 hunk，并回 `truncated:{shownLines,totalLines}`，
界面显示「只显示前 N 行（共 M 行）」。

行号折法照 `FileDiff.tsx:66-77` 的 `hunkRows`：上下文行两边各进一格、`-` 只进旧行号、
`+` 只进新行号。

## 5. 能力位

`caps.changes`（连接器 `dsh/caps.ts` 的 `changesAvailable`：宿主 `workspaceChanges` 在不在）。
缺了（老连接器 / 没装 `workspace-changes` 的部署）就**一次 `file.changes` / `file.diff` 都不发**，
也不画卡；侧栏退回旧的会话级清单。

## 6. 已知边界

- 侧栏画的是**最近一轮**有改动记录的 `workspace/changes`（桌面右栏也是按轮 review）；
  没有轮次选择器。
- 卡片只反映 `workspace/changes` 记录到的改动（非 git 仓库只列文件工具改过的文件，
  `workspace-changes/src/index.ts:6-9`）。
- **记录是宿主进程内存态**（`workspace-changes/src/recorder.ts` 的 `byId` map）：
  电脑侧 DSH 重启之后，之前那些轮次的 `summary` 就查不到了（回 `{summary:null}`），
  卡片**不画**。这与桌面一致（`ui-deliverables/src/client/Deliverables.tsx:69-72`
  "A summary the Host no longer serves leaves no card"），不是手机独有的降级。
- 真机已确认（2026-10-26）：`caps.changes` 为 **true**，`workspace/changes` 事件**会**到手机
  （卡槽存在）；卡面空只可能是宿主那边已不再提供服务。
