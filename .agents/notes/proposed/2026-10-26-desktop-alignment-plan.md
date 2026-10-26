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

- 收口消息插入一张 `ChangedFilesCard`：标题「改动 N 个文件 / +A −D」，最多 4 行 + 展开。
  行显示的是**桌面给的 `display`**（`workspace-changes/src/types.ts:5-22`：相对 cwd 的路径、
  `../`、`~` 或绝对路径，`display` 就是"该显示的那一串"），不是手机拼的。
- **数据最终来自桌面记录**：`workspace/changes` 的 summary（`types.ts:25-40`）。
  协议里还没有 `file.changes`，所以批 B 先用**过渡来源**（`deliverables` 投影 +
  `model/changed_path.dart` 的参数投影），**批 C 落地时换成桌面记录**并在代码里回指；
  手机不替桌面决定"这一轮改了什么"（`changedPath` 只是工具调用的参数形状）。
- 行点击 → `AppModel.openFile(mode: preview)`；标题点击 → 打开 diff（等第 3 条）。
- 复制按钮已存在于收口行；分支按钮等第 4 条。

### 3. 真 diff：新增协议面，而不是让手机读宿主 HTTP

建议新增一个**只读文件面方法**（名字待调研，倾向 `file.changes` + `file.diff`）：

- 请求：`{sid, seq}`（该轮 `workspace/changes` 事件的 seq）与
  `{sid, seq, index}`（index = 文件在 summary.files 里的下标）—— **不是 path**：
  宿主只认这两个坐标（`workspace-changes/src/types.ts:88-96`、`changes.ts:122-124`）；
- 应答：summary（files/added/deleted/total + 每行的 `path`/`display`/`added`/`deleted`/
  `binary?`/`oversized?`）+ 单文件 `WorkspaceFileDiff` 结构化 hunks；
- 连接器端口：直接调宿主 `workspaceChanges` 服务（**不代理 HTTP** —— 见批 0 第 1 条，
  服务就在 `index.ts:116-120`，`/api/changes.*` 只是浏览器侧对它的适配）；
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

## 批 0 调研结论（2026-10-26，带证据）

### 1. 连接器能拿到宿主 `workspaceChanges`，**不代理 HTTP**

- 服务是 `ctx.provide('workspaceChanges', service)`：`packages/deliverables/workspace-changes/src/index.ts:116-120`；
  Context 的类型声明在 `src/types.ts:110-114`。
- 服务面只有两个方法（`src/types.ts:79-97`）：
  `summary(sessionId, seq)` **同步**、Session dispose 后 `undefined`；
  `diff(sessionId, seq, index, signal)` 异步、会抛（快照读失败）。
- 插件在 `bundle/web-app/cordis.patch.yml:358-359` 注册，**base 没有** ⇒ 能力位判据只能是
  `ctx.get('workspaceChanges') !== undefined`（与 `filesAvailable` 同一套路，`connector/src/dsh/caps.ts:193-195`）。
- **不代理 `/api/changes.summary` / `/api/changes.diff`**：那两条只是浏览器侧对**同一个服务**的适配
  （`packages/client/ui-deliverables/src/present-open.ts:131-165`，路径常量在 `src/changes.ts:6,9`），
  代理会把宿主路由与鉴权变成手机协议的第二份真值（Rejected 第 3 条）。
- **方案里 `{sid, path, seq}` 的形状要改**：宿主按 **seq + 文件在 `summary.files` 里的 index** 取 diff
  （`types.ts:88-96`、`changes.ts:122-124` 的 `?sessionId&seq&index`），没有按 path 的入口。

### 2. `SessionController.fork` **不在**连接器现有 session 端口里

- `SessionsPort`（`connector/src/dsh/sessions.ts:187-280`）只有
  list / follow / page / prompt / cancel / updateQueue / selectModel / create。
- 宿主入口：`@Remote('fork')`（`packages/api/session-controller/src/index.ts:432-443`），
  请求/应答 `{sessionId, atSeq?, allowMigration?}` → `{sessionId}`（`src/types.ts:300-312`）。
- 最小端口就是加一条 `fork(request: {sessionId, atSeq?})` + 一条 `rename({sessionId, title})`
  （`@Remote('rename')`，`index.ts:420-423`，`{sessionId,title}`→`{title,seq}`，`types.ts:288-297`）——
  后者是为了第 3 条的标题后缀。

### 3. `increaseTitle` 是**客户端选项**，不是宿主参数；别名与列表照 `session.create`

- `increaseTitle` 只存在于 Web 的客户端服务 `ClientSessions.fork`（`src/client/sessions/service.ts:463-487`）：
  它先读源标题（`:470-471` 的 `list.getSnapshot().byId[id].title`），fork 成功后
  `manager.rename(childId, increasedForkTitle(sourceTitle))`（`:482-485`）；后缀规则在 `:132-148`
  （ASCII 半角 `(N)` 与全角 `（N）` 各自加一，没有编号就加 ` (1)`）。
  **宿主 `SessionForkRequest` 里没有 `increaseTitle`**（`types.ts:300-307`）。
- rename 失败时客户端**抛错但不回滚**（fork 已建，`:484`）—— 手机侧照这个语义：如实报错，子会话仍在。
- 别名：`session.create` 的现成写法是 `deps.aliases.ensure(created.sessionId)` 后回 `{sid}`
  （`connector/src/handlers.ts:697-714`），列表每次 `session.list` 都重新 ensure（`:728-737`）。
  所以 `session.fork` 只需 `ensure(childId)` 回 `sid`，父级不用动；手机侧重拉 `session.list` 即并入列表
  （`app/lib/data/app_model.dart:2388` 的 `refreshSessions`）。

### 4. 单帧预算下的截断口径：**按行截 + 按字节兜，显式 `truncated`**

- 单帧上限 8 MiB（`connector/src/protocol/frame.ts:84-85`；手机侧 `app/lib/core/frame.dart:32`），
  而载荷封箱后膨胀 ≈ `1.78N`（`memory.md` 教训 8）⇒ 明文预算 ≈ 4.5 MiB。
- 宿主允许单文件 2 MiB（`workspace-changes/src/index.ts:51-57` 的 `maxFileBytes`）；
  一次整文件替换的 diff 两侧各 2 MiB 文本 ⇒ 可在封箱后撞上限。**所以连接器必须截断**。
- 既有同一条纪律的先例：`trajectory` 的 `truncated` + `dropped*`（`connector/src/dsh/trajectory.ts:53-60`）、
  `file.list` 的 `truncated`（`connector/src/dsh/files.ts:73-76`）。
- **二进制 / 超大由宿主自己说**：`WorkspaceFileDiff` 是 `text | binary | oversized`
  （`workspace-changes/src/types.ts:56-76`）；`coarse: true` 是超时降级（`:70-71`）。
  手机照报这三个 `kind`，**不自己造"太大"的判据**（不自算字节、不猜文件类型）。
- 截断只作用在 `text` 的 hunks 上：行数上限 + 字节兜底，二者都从**同一个导出常量**来，
  用例按常量取边界、不手抄数字。

### 5. 文件提及的词表 = **这一轮产出/交付的路径**，不是工作区文件清单

- DSH 的解析器 `producedFileMentions`（`packages/client/ui-deliverables/src/client/turn-deliverables.ts:269-296`）：
  `path === value || basename(path) === value`，另外按 `argumentPath` 精确别名补一条；
  **命中恰好一条**才 resolve，歧义与未知都保持惰性（`:292-294`）。
- README 原话："inline-code matching remains limited to produced or delivered files"
  （`packages/client/ui-deliverables/README.zh.md:67`）。
  ⇒ 手机侧词表 = `AppModel.changedFiles`（`app/lib/data/app_model.dart:1198-1226`，来自 `tool/call` 的
  `changedPath`），**不拿 `file.list` 的目录缓存**（那份缓存只服务文件页，且会放大误报）。
- 会话 cwd：`session.list` 行的 `cwd`（`connector/src/handlers.ts:761`、`dsh/sessions.ts:154`；
  手机侧 `app/lib/model/chat_item.dart:864-874`）。
- **路径是桌面侧的值，手机只做映射**（这条是架构结论，不是待选的实现细节）：
  `file.read` 的 scope 由宿主 `workspaceFileScope` lookup 按 sessionId 解析
  （`packages/api/workspace-files/src/index.ts:203-221`，连接器 `dsh/files.ts:136-154`）；
  绝对路径与 `..` 由宿主 `locateFile` 接手（`workspace-files/src/index.ts:228,241`：
  "absolute path or path relative to the workspace root; files outside it are allowed"）；
  连接器只原样转交（`connector/src/handlers.ts:1296-1309`）；桌面 `openFile` 也只是
  "先看 `workingDirectory` 投影、退到 list 行 cwd"再交给同一套地址
  （`ui-chat/src/client/apply.ts:271-278`）。
  ⇒ 手机把 token **原样**交给 `file.read`；不拼 cwd、不规范化分隔符 / 大小写、
  不判断工作区归属、不查本地文件、不算 diff、不判断二进制。
  手机复刻的只有**桌面前端的展示规则**（`producedFileMentions` 本身也是客户端函数），
  真实文件与真实处理都在电脑上。

### 6. 顺带查到的两处前置事实

- `workspace/changes` 事件**只带 `turn` 号**（`workspace-changes/src/types.ts:99-108`），
  diff 的坐标要该事件的 `seq`；手机侧投影目前把它归到 `OtherItem`（`app/lib/data/projection.dart:614-624`）——
  批 C 要在投影里留下"这一轮 → 该事件 seq"。
- 收口行的 fork 用的是**该轮 `turn/end` 的 seq**（`ui-chat/src/client/apply.ts:299-305`），
  手机侧正好是 `TurnProcessItem.seq`（`projection.dart:481-495`）。
- **提及只给"收口那条助手正文"，且只算成功的变更调用**：
  `ui-chat/src/client/chat/AssistantNodeView.tsx:19-27` 要求轮次已收口
  （`turn.status === 'closed'`）且是 `tail.closing.finalNode.seq` 那条；
  产出路径的判据在 `ui-deliverables/src/client/turn-deliverables.ts:119-124,132-137`
  （成功调用的记录目标，老结果退回参数拼写；"failed results contribute nothing"）。
- **顺带查到的手机侧老缺陷**：`tool/result` 用同一 itemId 覆盖调用条目，而结果载荷
  没有路径字段 —— 不继承的话右侧文件面板与正文词表在结果一到就全空。
  已在 `app/lib/data/projection.dart` 的 tool/result 分支修掉（从调用继承，
  失败给 `null`），用例走 `call → result → turn/end → 收口正文` 的真序列。

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
| B | 收口改动卡（标题/行/复制；行打开预览） + 侧栏与卡片共用组件（数据先走过渡来源，批 C 换桌面记录） | 卡片行数与金样一致；点行打开同一路径；无新增网络调用 |
| C | `file.changes` / `file.diff` 协议（坐标 `seq`+`index`）+ 连接器 handler + wire 解码 + `DiffView` + 改动卡换源 | 金样两条（文本 / 二进制降级）；截断显式；连接器测试不手写端口行；`changedPath` 退出卡片与差异面板 |
| D | `session.fork` 协议 + 连接器 + App 分支按钮 + 别名/列表刷新 | fork 应答金样；child sid 是别名；失败弹 error；契约与 docs 同步 |
| E | 收尾：docs/memory/notes、真机（用户操作，App 侧不碰辅助功能） | 门禁全绿；真机四项各一条证据 |

进度：**A 已落地**（`implemented/2026-10-26-file-mentions-and-open-file.md`）；
**B 已落地**（`implemented/2026-10-26-changes-face-and-card.md`：`file.changes` + 改动卡 +
`docs/subsystems/changes-card.md`；方法面 50/48）。
门禁数字以 `memory.md` 的表为准。
A 之后按"App 只重画桌面已经显示的东西"复核过一遍，修了两处判据不一致：
提及只给收口正文 + 只算成功的变更调用，以及结果到达时路径要从调用继承。
C 起待续（`file.diff` + `DiffView` + 侧栏换源）。

**B/C 的顺序要改**：改动卡与差异面板的**数字与行**来自桌面记录
（`workspace/changes` 的 summary/diff），手机自己从工具调用推出来的 `+N −M` 与桌面**不同源**。
所以 B 先做 `file.changes`（summary）+ 卡片 + 侧栏换源，C 再做 `file.diff` + `DiffView`。
A 的提及词表是**唯一**保留工具调用投影的地方（桌面前端也是这么折叠的），
批 C 不把它换成 summary —— 桌面自己就是两套：提及看 deliverables，卡片看 changes。

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
