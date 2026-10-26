# Agent Note: 正文提及只认「这一轮产出过的路径」，打开文件只有一个动作

Status: implemented

## Problem

桌面端会话正文里的文件路径可点、点开在右侧栏预览；手机侧的 `DshMarkdown` 把行内代码
一律画成静态代码，没有任何入口能从一个路径跳到文件内容。同期手机有四个"看文件"的入口
（正文提及、改动卡行、侧栏差异行、文件页），每个入口若各自读文件、各自判断能力位，
就会长出四份会漂的规则 —— 2026-10-20 已经踩过一次同类的"表头说改了 128 行、面板说还没有改动"。

还有一条具体的判定要先钉死：**什么 token 才算提及**。直觉做法是"匹配工作区文件清单"，
但那会把正文里大量普通代码变成 404 链接。DSH 的解析器不是这么做的：

- `packages/client/ui-deliverables/src/client/turn-deliverables.ts:269-296`
  的 `producedFileMentions`：词表是**这一轮产出/交付的路径**，
  条件只有 `path === value` 或 `basename(path) === value`，且**恰好命中一条**才 resolve；
- `packages/client/ui-deliverables/README.zh.md:67` 原话：
  "inline-code matching remains limited to produced or delivered files"。

## Decision

提及解析收成一个纯函数（`app/lib/model/file_mentions.dart`），打开文件收成一个动作
（`AppModel.openFile(FileOpenRequest)`）；两者都**不碰协议**。

准入门槛（可机械判定）：

1. **只有行内代码是候选，且只在围栏外**：`file_mentions_test.dart` 的
   "围栏代码块里的路径不算提及"与"未闭合的围栏一直算围栏内"两条；围栏判据与
   `ui/dsh_markdown.dart` 的 `normalizeInlineHtml` 同一套。
2. **命中恰好一条才算**：`basename 歧义保持惰性` 两条（解析器一条、模型词表一条）。
   变异校验：把 `_uniqueMatch` 改成"先匹配先赢"，恰好这两条红。
3. **词表按轮、只给收口那条正文、只算成功的变更调用**（三条都照桌面）：
   - 按轮：`file_open_test.dart` 的"同一轮里 write 过的路径 ⇒ 提及；别的轮的同一 token ⇒ 惰性"；
   - 只给收口那条：`AssistantNodeView.tsx:19-27` 要求轮次已收口、且是
     `tail.closing.finalNode` 那条；用例是"一轮里有多条助手正文 ⇒ 只有收口那条认提及"
     与"还没收口的一轮不给提及"；
   - 只算成功：`turn-deliverables.ts:132-137` 的 "failed results contribute nothing"；
     用例"失败的写调用不算产出"。
4. **产出路径要能从结果继承**：真机上 `tool/result` 用同一 itemId **覆盖**调用条目，
   而结果载荷没有路径字段（`turn-deliverables.ts:119-124` 的 `mutationResultPath`
   就是从结果记录里取目标、老结果退回参数拼写）。不继承的话右侧文件面板与正文词表
   在结果一到就**全空** —— 这是 2026-10-25 之前就存在的缺陷，测试只喂 `tool/call`
   条目所以一直没暴露；用例"同一轮里 write 过的路径"现在走
   `call → result → turn/end → 收口正文` 的真序列。
5. **路径是桌面侧的值，手机只映射**：`file.read` 收到的就是 token 原样
   （`file_open_test.dart` 第一条），手机不拼 cwd、不规范化、不判断归属 ——
   scope 由宿主 `workspaceFileScope` lookup 按会话解析
   （`packages/api/workspace-files/src/index.ts:203-221`；连接器 `connector/src/dsh/files.ts:136-154`），
   绝对路径与 `..` 也由宿主接手（`workspace-files/src/index.ts:228,241`），
   桌面 `openFile` 的兜底用的是同一个 cwd（`packages/client/ui-chat/src/client/apply.ts:271-278`）。
   手机复刻的只有**桌面前端的展示规则**，不含任何文件语义。
6. **点击只改模型**：`openFile` 记请求 + 读第一页，界面（右抽屉 / 文件页）自己听
   `AppModel` 画三态；`file.read` 失败照报电脑侧原话。

## Alternatives considered

1. **匹配工作区文件清单（`file.list` 的目录缓存）**
   - 最强的理由：一个词表覆盖全部文件，用户随手写个路径也能点开，最省事。
   - 为何被否：误报会把正文里任意普通代码变成可点链接，而且点开是 404；
     DSH 的词表刻意只限"这一轮产出/交付"，我们照它，不新增宿主没有的宽边界。
2. **让每个渲染点各自解析（`DshMarkdown` 一处正则、改动卡一处、侧栏一处）**
   - 最强的理由：每处只看自己那一段文本，改动局部、互不影响。
   - 为何被否：判定会分叉成好几份，"同一个路径在正文里能点、在卡片里不能点"是必然结果。
3. **手机侧按当前会话 cwd 拼绝对路径再请求**
   - 最强的理由：看起来与桌面 `openFile` 的"先解析再打开"完全一致。
   - 为何被否：**这条不是偏好问题**。手机里没有文件系统，真实文件、`cd`、归属、
     存在性都在电脑上（宿主 `locateFile` 明确接受绝对路径与 `..`，
     `packages/api/workspace-files/src/index.ts:228,241`）；手机再拼一份就是
     在电脑之外长出第二套文件语义，会话中途 `cd` 后必然漂。
4. **在 `AppModel` 里直接 push 路由**
   - 最强的理由：一个动作从头做到尾，调用方什么都不用管。
   - 为何被否：数据层不认识 `Navigator`（本项目跨屏导航统一走 `main.dart` 的
     `navigatorKey`，见 `app/lib/main.dart:465-483` 的事故注释）。所以 `openFile` 只记
     状态与内容，导航由持有 `Scaffold` 的那一层做。

## Consequences

- 收益：四个入口共用一处解析 + 一个动作；文件页的预览也不再自己维护 chunks
  （`FilePreviewPage` 现在从 `AppModel.openedFile` 画，关页即 `closeFile`）。
- 收益：正文提及与 DSH 同一条判定，误报面与桌面一致。
- 代价：**只有工具调用改过的文件**才可点；用户在正文里随手写的其他路径仍是普通代码
  （与桌面一致，但比"全部可点"少）。
- 代价：**词表的来源是过渡的**。它现在是 `tool/call` 的 `changedPath`（DSH 的
  `mutationPath` 同一层），比桌面少了"成功结果的 `meta.path` 校验"与 `presented`
  交付物那一路，失败的写调用也会进词表。桌面记录（`workspace/changes` 的
  summary/diff）过线后以它为准：**批 C 把改动卡与差异面板换成桌面记录**，
  `changedPath` 只留给正文提及当词表。手机不替桌面决定"这一轮改了什么"。
- 代价：正文提及在 **流式尾条目**（`_LiveTurn`）里不可点（那条没有 itemId，也就没有
  "这一轮"的词表）；落定后同一条消息立刻可点。

## 代码入口回指

- `app/lib/model/file_mentions.dart`（解析器）
- `app/lib/model/file_open.dart` + `app/lib/data/app_model.dart` 的 `openFile` / `fileMentionsOf`
- `app/lib/ui/dsh_markdown.dart`（`_FileMentionCodeBuilder`）
- `app/lib/ui/chat_page.dart`（`_onAppFileOpen` / `_OpenedFileBody`）、`app/lib/ui/files_page.dart`（预览页）
