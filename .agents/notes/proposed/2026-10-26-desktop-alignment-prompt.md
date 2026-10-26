# 新会话提示词：桌面四件事对齐（文件提及 / 改动卡 + diff / 分支）

> 用法：新会话第一句整段粘贴。仓库 `D:\sudy\myproject\dsh-mobile`。

---

你在 `D:\sudy\myproject\dsh-mobile` 工作（Windows / pwsh，Flutter + Dart + TS connector）。
先读根 `AGENTS.md`、`tools.md`、`memory.md`、`.agents/notes/AGENTS.md`，再读
`implemented/2026-10-26-desktop-alignment-plan.md`（本任务的方案与源码证据；已落地）。

## 目标

把 DSH 桌面已有的四件事对齐到手机 App，**先调研、再分批实现**；每一批先写失败用例，
再改实现，跑门禁后提交。不要一次性全改。

1. 会话正文里的文件路径可点 → 右侧栏预览。
2. 收口消息里有「改动 N 个文件」卡（标题/行/复制）→ 点行打开预览。
3. 真 diff（逐行 hunks）→ 侧栏与改动卡共用 `DiffView`。
4. 收口消息的「在新会话中分支」→ 调宿主 fork，打开子会话。

## 已定事实（不要再猜）

- 桌面与手机**共享宿主服务**，但手机没有宿主 API；手机只走连接器的 curated 协议
  （`connector/src/protocol/methods.ts`，69 个方法）。新增能力分两类：
  **纯 UI**（提及解析、改动卡、复制）不动协议；**要宿主数据/动作**（真 diff、fork）
  必须加「契约方法 + 连接器端口/handler + wire 解码 + 金样 + App 入口」。
- DSH 文件提及：`MarkdownFileMentions.resolve(value)`，认不出就保持惰性代码
  （`packages/client/ui-primitives` 的契约；chat 侧由 `chatFileMentions` 提供，
  `packages/client/ui-chat/src/client/apply.ts:256`）。
- DSH 改动卡：`packages/client/ui-deliverables/src/client/ChangedFiles.tsx`；
  数据是宿主 `workspace-changes` 的 summary + 按需 diff，路由
  `/api/changes.summary`、`/api/changes.diff`（`ui-deliverables/src/changes.ts`），
  diff 是**结构化 hunks**（`WorkspaceFileDiff`，`packages/deliverables/workspace-changes/src/types.ts`）。
- DSH 分支：`forkAt(seq)`（`packages/client/ui-chat/src/client/apply.ts:299`）→
  `ctx.sessions.fork({sessionId, atSeq, increaseTitle:true})` → childId → 打开。
  宿主签名 `packages/api/session-controller/src/index.ts:433`，
  请求/应答 `SessionForkRequest` / `SessionForkValue`（`src/types.ts:301-314`）。
- 我们协议里**没有** `session.fork`，也没有 `file.changes`/`file.diff`；
  `connector/src/dsh/files.ts:16` 明确写了 `changes` 不接。别假设它们存在。

## 必须遵守的设计（这是"优雅"的落点）

- **一个打开动作**：`AppModel.openFile(FileOpenRequest{path, mode: preview|diff})`。
  正文提及、改动卡行、侧栏差异行、文件页全部只走它；路径按当前会话 cwd 解析。
- **一个提及解析器**：`model/file_mentions.dart` 的纯函数，行内代码 token 命中工作区文件清单
  才成为链接，认不出保持惰性；不要每个 widget 各写一套正则。
- **一个 diff 组件**：`DiffView` 只吃结构化 hunks；侧栏与改动卡共用；长 diff 按行截断并显式
  标记（与 `file.read` 的 `truncated` 同一条纪律）。
- **不做通用透传**（`host.invoke`）、不把宿主 HTTP 路由暴露给手机、不在客户端伪造 fork。
- 新增协议方法时：契约先改、连接器端口/handler、wire 解码、金样、App 用例、docs 同一批；
  名称与参数形状只在一处（`wire/rpc/<面>.dart` + `protocol/methods.ts`）。

## 先做的调研（批 0，产出写进方案笔记，必须带行号或注入面证据）

1. 连接器能不能拿到宿主 `workspaceChanges` 服务？注入面/端口形状是什么？
   拿不到时是否只剩代理 `/api/changes.summary|diff` 一条路（只许在 handler 内）。
2. `SessionController.fork` 是否在连接器现有的 session 端口里？没有的话怎么加最小端口。
3. fork 返回的 child DSH id 如何过别名、如何并进会话列表；`increaseTitle` 是否需要。
4. 单帧预算下 diff 的截断口径（多少行/字节）；二进制与 oversized 如何降级。
5. 文件提及的工作区清单来源：`file.list` 缓存还是 `refs.files`；会话 cwd 从哪取。

## 分批（每批一个提交）

- A：`file_mentions` + `openFile` + 正文可点 → 文件页预览（无协议）。
- B：收口改动卡（标题/行/复制；行打开预览），复用 `deliverables` 与 `changed_path`。
- C：`file.changes` / `file.diff` 协议 + 连接器 + wire + `DiffView` + 截断 + 金样。
- D：`session.fork` 协议 + 连接器 + App 分支按钮 + 别名/列表刷新 + 契约/docs + 金样。
- E：docs/memory/notes 收口；真机由用户操作，App 侧不得打开 TalkBack 或改辅助功能。

## 验收与纪律

- 每批：先红后绿；变异校验至少一次（把规则删掉要能红）；`dart analyze --fatal-infos lib test`、
  `dart format`、`flutter test`、`connector` 的 tsc/build/test、boundary、single-caller 全绿。
- 断言值来自生产路径/金样，不手抄常量；不删旧测试来变绿；不静默兜底。
- 决策笔记与代码同批；笔记放 `implemented/` 才算落地；旧决策被取代时标注并归档。
- 手机真机只做"用户点、你记录"；不要 `adb input` 盲点、不要改 TalkBack/导航模式。
- 有任何一条事实查不到：写「未找到」并停下问，不许猜。

## 交付

每批结束给：改了哪些文件、先红后绿的输出、门禁数字、下一步。
第一批（A）完成后停下来让我过一眼，再继续 B。
