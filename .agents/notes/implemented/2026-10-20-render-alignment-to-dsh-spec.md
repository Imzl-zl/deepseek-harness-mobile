# Agent Note: 会话页渲染按 DSH 规格重排 —— 正文 14/24、工具卡正文用 ioCard、折叠行按节点分两种正文

Status: implemented

## Problem

渲染清单（`.agents/notes/proposed/2026-10-20-rendering-issues-todo.md`）里 8 条大半只有
"只读代码未比对"的证据等级。逐条回 DSH 找规格后，暴露出**四条判断是错的**，
而且错法相同：拿一个名字像的 DSH 类当规格，或把次要档当正文。

1. `dsh_markdown.dart` 写"DSH 的正文只有 13，标题不该喧宾夺主"——13 是
   **secondary 档**（流程行标题、工具标题、compact 正文）。正文是
   `--dsh-content-font-size`，默认 **14/24**。
2. `ToolCard` 的展开正文引的是 `ToolDetails.module.css` 的 `.root`（13/20 比例字体）。
   那是 **todo/goal/schedule 这类结构化字段卡**；工具**结果原文**在 DSH 里走
   `.ioCard` / `.ioSection` / `.ioText`（11/16 等宽、上限 150、自己滚）。
3. `_CollapsibleNote` 把「思考过程」和「系统提示词」当成同一种正文。DSH 里它们是
   **两种**：思考是 `MarkdownText variant="compact"`（13/20、`label-tertiary`、跑 Markdown），
   系统提示词是代码字体的 141px 滚动区。
4. `normalizeInlineHtml` 用 `split('```')` 判围栏 —— `~~~` 也是围栏
   （`markdown-7.3.1/.../fenced_code_block_syntax.dart:13`），只认反引号就会把
   `~~~` 里的 `<T>` 当 HTML 改写，**改掉用户看的源码**。

另外两处是"没出处"而不是"错"：系统提示词的标题图标用 `info`（DSH 是 `browse`），
流式尾条目自己抄了一份头像行（DSH 的流式与落定是同一个节点类型）。

顺带发现的第五处：`CommandCard` 抄的是**工具卡**的形状（`roleToolBg` 标题行 +
24×24 图标块 + 等宽橙色命令名 + 圆角卡片）。DSH 的命令行是 `DisclosureRow` +
一个代码正文（`GenericCommandCard.module.css:38-49`），**不是卡片**。

## Decision

**渲染规格一律以 DSH 源码行号为准；能拿到的值照抄，拿不到的（触屏/包能力）写成
有理由的偏离，并落在 `docs/subsystems/app-channel-client.md` §4.1 的两张表里。**

准入门槛（可机械判定）：

1. **每个字号/行高/上限值都有一行 DSH 出处**，或明确标注"有意偏离 + 理由"。
   两条路径之外的值不许出现。
2. **偏离必须能说清"是谁的能力不够"**：触屏（没有 hover、行高要 ≥36）、
   `flutter_markdown` 的整表单值列宽、或手机阅读密度。写不出这一句的不算偏离，算错。
3. **判据进 widget test，且每条新判据做一次变异验证**（故意破坏实现，确认恰好那一条红）。
   视觉回归不在门禁里，所以规格本身必须变成断言（字号、行高、上限、图标名、围栏内外）。

## Alternatives considered

1. **保留 13/20 的正文，只改清单里点名的四处**
   - 最强的理由：改动面最小，正文是主阅读面，13→14 会让每条消息变高，
     且会牵动所有已验收的截图口径。
   - 为何被否：13 的来源是一句**错的前提**（"DSH 的正文只有 13"）。留着它，
     下一个人会继续拿它当规格去对齐别的面；而且 13 与 h3（18）之间的层级
     在 DSH 里本来由 14/24 撑起来。改一档、连带标题表一起对齐，比留一个错值便宜。

2. **工具卡正文继续用 `ToolDetails.module.css` 的 `.root`（13/20 比例字体）**
   - 最强的理由：`.root` 确实是"工具卡展开区"的样式，比例字体在手机上比 11px
     等宽好读，而且我们那张卡长得就像 `.root`（圆角 lg、0.5 边框、code-block 底）。
   - 为何被否：`.root` 服务的是 `ToolDetails` 的**结构化字段**（title/fields/lines/
     markdown/code）。我们的 `detail` 是 `toolOutputOf` 摊平的**结果原文**，
     在 DSH 里对应 `.ioCard` 的「输出」一节（`ToolRow.tsx:345-351`）。
     两者字号差两档、一个 13/20 比例一个 11/16 等宽，套错就是"出处看着对、结果不是它"。

3. **给表格写一个自定义 `table` builder（自己拼 `Table`）**
   - 最强的理由：能按列数分支（≥4 列自然宽度 + 横滚、<4 列铺满），
     完整复刻 DSH 的 `.tableScroll` / `.tableFill` 两档，还能量出
     `max-width: min(30vw,320px)` 的等价物。
   - 为何被否：`MarkdownElementBuilder` 接管 `table` 之后，行/单元格/对齐/
     行内子节点全要自己重建 —— 等于把 `builder.dart` 的表格路径抄进我们的仓库，
     而它正是随包升级会变的部分。用 `IntrinsicColumnWidth` 换来的横滚是包**已经写好**
     的那条路径（`builder.dart:447-463`），代价只是窄表不铺满。

4. **`_CollapsibleNote` 保持一个正文形态（纯文本），只把上限补上**
   - 最强的理由：一个组件一个形态，最不容易漂；思考过程里出现 Markdown 记号
     是模型的表达习惯，不是我们必须渲染的承诺。
   - 为何被否：DSH 的思考正文明确是 `MarkdownText variant="compact"`
     （`ReasoningContent.tsx:16`），我们按纯文本渲染会把 `**重点**` 原样露出来 ——
     那正是 2026-10-19 修过的同一类问题（Markdown 记号当正文）。
     行共用、正文分两种，与 DSH 的 `DisclosureRow` + 两个 Body 同构。

5. **流式期间把未闭合围栏的尾巴藏起来（"修抖动"）**
   - 最强的理由：围栏未闭合时后面所有内容都被当代码块，藏掉尾巴看起来"不抖"。
   - 为何被否：DSH 的流式 arm 同样把未闭合围栏渲染成代码块并逐块冻结
     （`incremental.ts:10-14`），藏尾巴等于**在流式期间显示与落定后不同的内容**，
     那才是真抖动（内容凭空出现）。要保的是"闭合那一帧形态不变"。

## Consequences

- 收益：正文、工具卡、折叠行、表格、围栏五处从"看着像"变成"有行号 + 有断言"；
  `~~~` 围栏内的源码不再被改写；系统提示词展开后不再把对话顶走（141 上限）；
  流结束不再跳一下（流式尾与持久条目共用 `AssistantHead`）；
  斜杠命令回到"流程行 + 代码正文"，与工具卡不再同形。
- 代价：正文 13→14 让每条消息变高，已验收的截图口径全部作废（阶段二重拍）；
  工具卡正文 11px 比原来 12.5 小，长输出要滚（上限 150）；
  窄表不再铺满整列；折叠行失去卡片边框，在长会话里更"平"（与 DSH 一致，
  但触屏上少了"这是一块可点区域"的暗示，靠 36 的行高与 chevron 补）。
