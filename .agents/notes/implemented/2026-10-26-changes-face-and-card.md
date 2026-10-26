# Agent Note: 改动卡的数据只来自电脑的 `workspaceChances` 记录，手机不自己推

Status: implemented

## Problem

桌面在每轮收口处有一张「已编辑 N 个文件」卡（`packages/client/ui-deliverables/src/client/ChangedFiles.tsx`），
手机只有右抽屉里一份会话级的聚合清单，收口处什么都看不见。

手机那份清单是**从工具调用参数**推出来的（`model/changed_path.dart` 照 DSH 的 `mutationPath`）。
用它去画卡片看起来最省事，但两条数字会与桌面不同源：

- 桌面的行数来自 git 工作树快照与文件工具周围的整文件捕获（`workspace-changes/src/index.ts:1-9`），
  手机的 `+N −M` 来自 `tool/result` 的 `meta.diffs` 或按 hunk 折算；
- 桌面的"二进制 / 过大"是宿主判的（`workspace-changes/src/types.ts:14-21`），手机没有这两个标志。

同一个用户在两块屏幕上看到两个数，是比"没有卡片"更坏的结果。

## Decision

新增 `file.changes`：把宿主的 `workspaceChanges.summary(sessionId, seq)` 过线，卡片只读它。

准入门槛（可机械判定）：

1. **坐标是 `seq` 不是路径**：宿主按 `seq` + 文件下标取单文件比对（`types.ts:88-96`），
   连接器与手机都只认这个坐标（`connector/tests/changes.test.ts` 的"调宿主时给的是 DSH 会话 id、
   seq 原样"）。
2. **逐字段过线**：`cwd` 与 `snapshot` 不过线（`changes.test.ts` 断言序列化结果里没有它们）。
3. **两种"没有"分开**：别名不认识 ⇒ `session/not-found`；别名认识但宿主没有记录 ⇒ `{summary: null}`
   （桌面用 HTTP 404 表达同一件事，`present-open.ts:131-139`）。手机侧 `readChangesSummary`
   把 `null` 当有效值、缺 `summary` 键才是 `WireBad`（`changes_card_test.dart` 各一条）。
4. **条目身份按轮**：`workspace/changes` → itemId `w:<turn>`；同一轮多条只认最新一条
   （`workspace-changes/src/types.ts:105-106`）。
5. **能力位先于请求**：`caps.changes` 为 false 时一次 `file.changes` 都不发（用例钉住）。
6. **行点击仍只走 `AppModel.openFile`**：`file.read` 收到的就是该行的 `path`。

## Alternatives considered

1. **用手机现有的 `changedPath` 聚合直接画卡**
   - 最强的理由：零协议改动，当天就能出卡片。
   - 为何被否：行数与"二进制 / 过大"会与桌面**不同源**（见 Problem）；而卡片存在的意义
     正是"和桌面同一个记录"。
2. **连接器代理 `/api/changes.summary` 与 `/api/changes.diff`**
   - 最强的理由：宿主已经算好了，零映射。
   - 为何被否：那两条是浏览器侧对同一个服务的 HTTP 适配（`present-open.ts:131-165`），
     代理会把宿主路由与鉴权变成手机协议的第二份真值；服务本身在连接器里可取
     （`workspace-changes/src/index.ts:116-120`），一个 handler 就够。
3. **B/C 合并，一次把 `file.diff` 也接上**
   - 最强的理由：卡片标题本来要打开逐行差异，一起做少一次版本错位。
   - 为何被否：diff 还带截断与二进制降级（单帧预算），两件事一起改会让"卡片对不对"
     与"diff 截得对不对"混在一条红里；先让卡片的数字与桌面同源，再把 diff 接上。

## Consequences

- 收益：收口处有桌面同一张卡；数字、`display`、二进制 / 过大全部来自电脑的记录。
- 收益：`caps.changes` 让老连接器**不出现**这张卡，而不是出现一张永远读不到的卡。
- 代价：方法面 +1（50），能力位 +1；契约、金样、`tools.md` / `memory.md` 的计数要同步。
- 代价：右抽屉「差异」页签仍是**会话级聚合**、与卡片的"这一轮"不同口径；
  等 `file.diff` 那一批把侧栏也换成按轮记录（方案笔记批 C）。
- 代价：标题点击暂时只打开第一个文件的内容预览（逐行差异未接）。

## 代码入口回指

- `connector/src/dsh/changes.ts`（面）、`connector/src/handlers.ts` 的 `file.changes`
- `app/lib/model/changes.dart`、`app/lib/wire/rpc/changes.dart`
- `app/lib/core/items.dart`（`w:<turn>`）、`app/lib/data/projection.dart`（`ChangesItem`）
- `app/lib/ui/chat_page.dart`（`_ChangedFilesCard`）
