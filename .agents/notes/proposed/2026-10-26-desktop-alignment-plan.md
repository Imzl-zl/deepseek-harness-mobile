# 桌面四件事对齐到手机：文件提及 / 改动卡 + diff / 在新会话分支

- 日期：2026-10-26
- 状态：proposed（待新会话调研后落第一批）
- 相关：`implemented/2026-10-26-unified-toast.md`（同日完成）、
  `implemented/2026-10-26-remove-preview-and-demo.md`、
  桌面源码 `D:\sudy\github\deepseek-harness`（只读）

## Problem

手机上这四件事要么缺、要么只做了半边：

1. **会话正文里的文件路径不可点**：DSH 把正文中的文件提及解析成可点项，点开在右侧栏
   预览；手机侧 `DshMarkdown` 没有提及解析。
2. **改动卡只活在侧栏**：DSH 在收口消息里有一张「改动 N 个文件」卡（`ChangedFiles.tsx`），
   点标题/行进右侧 review；手机侧只有右抽屉的「差异」页，会话里没有这张卡。
3. **没有真正的 diff**：侧栏「差异」只有 `+N −M` 统计与路径，没有逐行 diff。
   DSH 的 diff 来自宿主 `workspace-changes`：`/api/changes.summary` 与
   `/api/changes.diff`，后者是**结构化 hunks**（`WorkspaceFileDiff`，不是一段 git 文本）。
4. **没有"在新会话中分支"**：DSH 每条收口消息的复制旁边有分支按钮，
   `forkAt(seq)`（`packages/client/ui-chat/src/client/apply.ts:299`）找该轮的收口 seq，
   调 `ctx.sessions.fork({sessionId, atSeq, increaseTitle:true})`，拿到 childId 后打开。

## 先厘清一个前提：桌面和手机"同一个接口"是哪一层

- **宿主服务层相同**：桌面直接调 `sessions.fork` / `workspaceChanges` / `chatFileMentions`；
  手机没有这些服务，只有连接器的协议子集（`connector/src/protocol/methods.ts`，69 个方法）。
- 所以"接一下"分两类：
  - **纯 UI**（提及解析、改动卡、复制、打开预览）—— App 侧就能做，不动协议；
  - **需要宿主数据/动作**（真正的 diff、fork）—— 必须 **契约方法 + 连接器端口/handler +
    wire 解码 + 金样 + App 入口**，这不是接线，是一个功能。
- 我们的协议里**没有** `session.fork`、也没有 `file.changes`/`file.diff`；
  `connector/src/dsh/files.ts:16` 明确写了 `changes` 不接。设计不能假装它们存在。

## Decision（建议）

### 1. 文件提及：一个解析器 + 一个打开动作（App 侧，无协议）

- 新增 `app/lib/model/file_mentions.dart`：纯函数
  `List<FileMentionSpan> resolveFileMentions(text, {required Set<String> knownPaths})`。
  只解析行内代码 token，命中 `knownPaths`（工作区文件清单缓存）才成为链接；
  认不出保持惰性（与 DSH `MarkdownFileMentions.resolve` 同一条：解析不到就是普通代码）。
- 新增 `AppModel.openFile(FileOpenRequest)`（`path` + `mode: preview|diff`）：
  **所有入口只走它** —— 正文提及、改动卡行、侧栏差异行、文件页自身。
  它负责：相对路径按当前会话 cwd 解析、切到右抽屉、必要时切到 diff 页。
- `DshMarkdown` 只负责把 span 画成可点；不自己决定打开哪里。

### 2. 改动卡：复用 `deliverables`，不新造数据（App 侧）

- 收口消息插入一张 `ChangedFilesCard`：标题「改动 N 个文件 / +A −D」，最多 4 行 + 展开；
  数据来自已有的 `deliverables` 投影与 `changed_path` 解析（`model/changed_path.dart`）。
- 行点击 → `AppModel.openFile(mode: preview)`；标题点击 → 打开 diff（等第 3 条）。
- 复制按钮已存在于收口行；分支按钮等第 4 条。

### 3. 真 diff：新增协议面，而不是让手机读宿主 HTTP

建议新增一个**只读文件面方法**（名字待调研，倾向 `file.changes` + `file.diff`）：

- 请求：`{sid, seq}`（该轮 `workspace/changes` 事件的 seq）与 `{sid, path, seq}`；
- 应答：summary（files/added/deleted/total）+ 单文件 `WorkspaceFileDiff` 结构化 hunks；
- 连接器端口：直接调宿主 `workspaceChanges` 服务（若连接器注入面拿不到，则代理
  `/api/changes.summary` 与 `/api/changes.diff`，但**只在这一个 handler 里**，不把 HTTP 形状
  泄给手机）；
- App：`wire/rpc/file.dart` 解码 hunks（逐行 `+`/`-`/` `），金样加两条（文本 diff、二进制/超大
  降级）；UI 用一个 `DiffView` 组件（侧栏与改动卡共用）。
- **预算**：diff 可能很大；契约已有单帧上限，响应必须按行截断并显式标记
  （与 `file.read` 的 `truncated` 同一条纪律）。

### 4. 分支：新增 `session.fork`，连接器调宿主

- 协议：`session.fork` `{sid, atSeq?}` → `{sid}`（新会话的别名）。
- 连接器：`sessions.fork` 端口调宿主 `SessionController.fork({sessionId, atSeq})`
  （`packages/api/session-controller/src/index.ts:433`，请求形状
  `types.ts:301-314`：`{sessionId, atSeq?, allowMigration?}` → `{sessionId}`）；
  必须像 `session.create` 一样把 child 的 DSH id **过别名**、并把新会话并进列表。
- App：收口行的分支图标 → `wire.forkSession(client, sid, atSeq)` → 打开 child；
  失败如实弹（`DshToastKind.error`），不假装成功。
- 契约/文档：`docs/` 的方法表与 `protocol/methods.ts` 同步；金样收一条 fork 应答。

## Alternatives considered

1. **分支纯客户端做（复制事件另建会话）**。
   最强理由：不动宿主，看起来最省事。
   被否：fork 是宿主状态（快照/标题/快照 id/允许迁移），客户端复制只会造出一个"像分支"的
   假会话，且与桌面不共享后续——这正是"看起来连上了"的那类假象。
2. **用 `file.read` 两次自己算 diff**。
   最强理由：现有协议够用，不加方法。
   被否：只有当轮起点的内容才有意义，而 `file.read` 读的是现在；没有 turn-start 快照，
   算出来的 diff 是猜的。DSH 的 diff 由 `workspace-changes` 记录并算好，必须用它。
3. **连接器把宿主 HTTP 路由原样转发给手机**。
   最强理由：零映射，桌面与手机吃同一份 JSON。
   被否：把宿主路由/鉴权/资源地址变成手机协议的第二份真值；我们的协议是 curated 子集，
   一个 handler 里做适配即可，不能把 URL 面暴露出去。
4. **正则匹配所有像路径的 token 都做成链接**。
   最强理由：零状态、不要文件清单。
   被否：误报会把普通代码变成可点链接，点开 404；DSH 的 resolver 也是"认不出就保持惰性"。
5. **加一个通用 `host.invoke` 透传**。
   最强理由：以后什么都能接，不用逐个加方法。
   被否：等于放弃协议边界与能力位；手机端会重新长出一堆"猜形状"的代码，回到这轮之前。

## 批次（建议）

| 批 | 范围 | 验收 |
|---|---|---|
| 0 | 调研：`workspaceChanges` 在连接器的注入面、`SessionController.fork` 是否在端口、别名如何拿 child sid、diff 大小预算 | 每条结论带 `packages/...:行号` 或连接器注入面证据；不许写"应该可以" |
| A | 提及解析器 + `openFile` 单一动作 + 正文可点 → 文件页预览（无协议） | 纯函数单测（命中/不命中/相对路径）；widget 用例点链接打开预览；回退惰性 |
| B | 收口改动卡（标题/行/复制；行打开预览） + 侧栏与卡片共用组件 | 卡片行数与金样一致；点行打开同一路径；无新增网络调用 |
| C | `file.changes` / `file.diff` 协议 + 连接器 handler + wire 解码 + `DiffView` | 金样两条（文本 / 二进制降级）；截断显式；连接器测试不手写端口行 |
| D | `session.fork` 协议 + 连接器 + App 分支按钮 + 别名/列表刷新 | fork 应答金样；child sid 是别名；失败弹 error；契约与 docs 同步 |
| E | 收尾：docs/memory/notes、真机（用户操作，App 侧不碰辅助功能） | 门禁全绿；真机四项各一条证据 |

## Consequences

- 收益：四件事的入口各只有一个（mention resolver / openFile / DiffView / fork action），
  不会出现"正文一套、侧栏一套、卡片一套"。
- 收益：diff 与 fork 走协议，手机不感知宿主路由；能力位继续可查。
- 代价：C/D 两批要动契约、连接器、金样与 App 四处；fork 还要处理别名与列表刷新，
  是本轮最大的一批。
- 代价：diff 受单帧预算限制，长 diff 必须截断；"完整 diff"在手机上不是默认保证。

## 代码入口回指（待落地后补）

- `app/lib/model/file_mentions.dart`、`app/lib/data/app_model.dart`（openFile）
- `app/lib/ui/dsh_markdown.dart`、`app/lib/ui/side_pane.dart`、`app/lib/ui/chat_page.dart`
- `connector/src/dsh/files.ts`、`connector/src/handlers.ts`、`connector/src/protocol/methods.ts`
- `app/lib/wire/rpc/file.dart`、`app/lib/wire/rpc/session.dart`
