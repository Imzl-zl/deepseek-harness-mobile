# Agent Note: 逐行差异接桌面记录，上限取手机自己的 1000 行

Status: implemented

## Problem

改动卡与侧栏此前只有路径与 `+N −M`，没有 hunks。桌面的逐行比对来自宿主
`workspaceChanges.diff(sessionId, seq, index, signal)`（`workspace-changes/src/types.ts:88-96`），
是一次性的服务调用；手机要显示，只能新开一个协议方法。

同时有一个**必须选**的数：桌面渲染上限是 5000 行
（`ui-deliverables/src/client/FileDiff.tsx:14` 的 `MAX_RENDERED_LINES`，超了显示
「只显示前 5000 行」）。手机这一版的差异视图是 `Column` 一次性铺完
（`app/lib/ui/dsh_diff.dart`：每行两个行号格 + 标记 + 正文，约 5 个 widget/行），
5000 行≈2.5 万个 widget。另有一道通道硬约束：单帧 8 MiB
（`connector/src/protocol/frame.ts:84-85`），minified 文件的整文件替换可以到 MB 级单行。

## Decision

新增 `file.diff`：坐标 **`seq` + 文件在 summary 里的下标**（不是路径），应答是
`text | binary | oversized` 判别联合；手机用同一个 `DiffView` 画侧栏与卡片标题的差异。

准入门槛（可机械判定）：

1. **坐标不是路径**：连接器把它原样交给宿主 `diff(sessionId, seq, index, signal)`
   （`connector/tests/changes.test.ts` 的"调宿主时给的是 DSH 会话 id、seq 与下标"）。
2. **四种结局照桌面**：`binary` / `oversized` / `coarse` / `before·after·空 hunks` 各自一句
   （文案取 `ui-deliverables/src/client/locales.ts:58-67`），用例逐条钉。
3. **行号折法照 `hunkRows`**：上下文行两边各进、`-` 只进旧、`+` 只进新
   （`FileDiff.tsx:66-77`；`changes_card_test.dart` 的折行用例）。
4. **上限是显式的**：连接器按 **1000 行 / 1 MiB** 裁（`changes.ts` 的
   `DIFF_MAX_LINES` / `DIFF_MAX_BYTES`），切法与桌面的 `renderedHunks`（`:116-125`）一致
   ——按顺序保留、最后一条按剩余预算切开；截了就回 `truncated:{shownLines,totalLines}`，
   没截就不带这个键（`changes.test.ts` 两条用例）。
5. **`diff: null` 是有效应答**（电脑侧没有记录），与 `summary:null` 同一条纪律。

## Alternatives considered

1. **用现有 `file.read` 读两次、手机自己算 diff**
   - 最强的理由：零协议改动，一次读数就能拼。
   - 为何被否：只有"这一轮起点"的内容才有意义，而 `file.read` 读的是现在；没有起点快照，
     算出来的 diff 是猜的 —— 桌面记录的就是起点与终点。
2. **照抄桌面的 5000 行**
   - 最强的理由：上限与文案完全一致，不需要解释差异。
   - 为何被否：桌面在浏览器里渲染；手机这一版是 eager `Column`，5000 行≈2.5 万 widget，
     首帧与重建都会卡。取 1000 行（≈5 千 widget），文案仍用桌面那句。
3. **不设上限，靠单帧预算兜**
   - 最强的理由：不截断，看到的永远是全量。
   - 为何被否：minified 文件整文件替换是单行 MB 级，算上 JSON + 封箱膨胀可以撞穿 8 MiB；
     那时是 `bad-frame` 断连，比"少显示几行"坏得多。
4. **把 `DshDiff` 改成懒加载列表**
   - 最强的理由：不截断也能滑到任意位置。
   - 为何被否：差异视图是"固定左列 + 右侧横滑"的两列结构，改懒加载要重做横滑与行号同步；
     而这块按产品判断不是关键路径，先用上限解决。

## Consequences

- 收益：卡片标题与侧栏「差异」能看逐行 hunks；数据、坐标、四种结局都与桌面同源。
- 收益：侧栏「差异」从"会话级聚合"换成**按轮的桌面记录**，数字口径与卡片一致。
- 代价：方法面 +1（51）、金样 +1（45）；长差异在手机上**只显示前 1000 行**（显式说明）。
- 代价：`DshDiff` 仍是 eager 渲染；要显示更长的差异得先做懒加载（或换虚拟列表）。
- 代价：侧栏只画**最近一轮**（没有轮次选择器）。

## 代码入口回指

- `connector/src/dsh/changes.ts`（`diff` + 两个上限常量）、`connector/src/handlers.ts`（`file.diff`）
- `app/lib/model/file_diff.dart`、`app/lib/wire/rpc/changes.dart`（`loadFileDiff`）
- `app/lib/model/file_open.dart`（`seq` / `index`）、`app/lib/data/app_model.dart`（`openedDiff`）
- `app/lib/ui/chat_page.dart`（`_OpenedFileBody._diffBody` / `_ChangesPane`）
