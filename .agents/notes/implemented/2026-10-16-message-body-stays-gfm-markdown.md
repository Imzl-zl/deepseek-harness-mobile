# Agent Note: 消息正文照旧走 GFM Markdown（不引入 HTML 渲染），代码块补上 DSH 的头部工具条

Status: implemented

## Problem

用户最早提的那条："其实还有手机端的渲染也有问题,这些都是可以参考 web 的,
就是 web 移动到手机上都能参考,像 html 的渲染啥的"。

"像 html 的渲染"这句是**假设**：用户以为 Web 把消息里的 HTML 渲染了出来。
这一轮先把 DSH 的渲染管线读完再动手（交接笔记的硬要求），结论是**没有 HTML 这回事**：

- Web 的助手正文 = `ui-chat` 的 `AssistantNodeView` → `AssistantMarkdown`
  （`packages/client/ui-chat/src/client/chat/AssistantNodeView.tsx:35`、
  `AssistantMarkdown.tsx:84`）→ `ui-primitives` 的 `MarkdownText`，
  后者把文本按 **GFM + 数学**现场解析（`MarkdownText.tsx:36` 的 `parseGfmWithMath`），
  用**自写的 mdast→React 渲染器**（`markdown/render.tsx:2`，没有 react-markdown/remark/rehype）。
- **原始 HTML 是纯文本**：`render.tsx:333-335` 原注释 "No HTML parser enters the pipeline:
  raw HTML stays literal text."；DOM 夹具 `raw-html-dropped.settled.txt` 里
  `<script>…</script>` 就是一段字面文字。正文里**没有** `dangerouslySetInnerHTML`
  渲染用户内容（全仓三处：shiki 输出的代码高亮、文件图标、启动壳）。
- 正文也**没有**分块/虚拟化（全仓 grep 无 `content-visibility`、正文无 react-virtual）；
  唯一的虚拟列表在轮次导航条（`TurnNavigator.tsx:110`）。
  流式的对策是**冻结除末尾两块以外的块**（`conversation-nodes/incremental.ts:9,38`）。
- 工具卡 / diff / 交付物 / 计划卡 / 提问回复 / 审批**都不在正文里**，是同级 Chat 节点或 turn-tail 槽
  （`ui-tool/src/client/apply.ts:36-42`、`ui-plan/src/client/index.ts:80`、
  `ui-deliverables/src/client/index.ts:64`、`ui-approval/src/client/index.ts:91-103`）。
- 代码块的**头部工具条**是 `CodeBlock` + `CodeToolbar`：语言标签、自动换行开关、
  复制按钮（`CodeBlock.tsx:157,168,195-208`、`CodeToolbar.tsx:38-61`）；
  高亮用 shiki（JS 引擎），只支持 **ts / bash / json**，**首次进入视口才高亮并缓存**
  （`markdown/highlight.ts:42,17`、`useViewportHighlighting.ts:48`）。

手机侧的现状：Markdown 已经渲染（`app/lib/ui/dsh_markdown.dart`，`flutter_markdown_plus`），
但**代码块是裸的** —— 没有语言标签、没有换行开关、没有复制（文件末的"仍未做 3"）。

## Decision

1. **正文继续按 GFM Markdown 渲染，不引入任何 HTML 渲染器。**
   原生缝里没有这一档：DSH 自己都不渲染消息里的 HTML，加一个等于自造一条
   Web 没有的注入面，而且"两端长得一样"这个目标反而更远。
2. **代码块按 `CodeBlock` / `CodeToolbar` 补齐**（`dsh_markdown.dart` 的 `_DshCodeBlock`）：
   语言标签、**默认自动换行**（`CodeBlock.tsx:157` 的 `useState(true)`）、
   复制成功后 1 秒变对勾（`:168`）、图标走 DSH 图标集（`copy`/`check`/`nowrapFill`/`wrapFill`）。
   - 语言标签照 DSH 的规则（`CodeToolbar.tsx:44`）：**能高亮才报语言，否则报"代码块"**。
     手机还没有高亮，所以恒为"代码块" —— 与 DSH 对一个它不高亮的语言完全同形；
     接上高亮后只填 `_highlightedLanguages` 这张表。
   - 为了拿 `MarkdownElementBuilder` 的签名类型（`md.Element`），
     `pubspec.yaml` 把 `markdown` **显式声明**为直接依赖 —— 它本来就在树里
     （`flutter_markdown_plus` 的依赖，7.3.1），不是新依赖。
3. **不做段落切分 / 正文虚拟化**：DSH 也没做。手机侧该做的是"流式期间只重排末尾"，
   已写进 `docs/subsystems/app-channel-client.md` §4 的对策表（引 DSH 的 `UNSTABLE_TAIL_BLOCKS`）。
4. **高亮、数学、分块渲染仍不做**，但把"怎么做"写进 `dsh_markdown.dart` 文件末与
   `app-channel-client.md` §7：高亮的三条纪律（三种语言 / 首次可见才高亮并缓存 / 未知语言退纯文本）、
   数学是独立一块、分块照 `UNSTABLE_TAIL_BLOCKS`。

## Alternatives considered

1. **照用户字面意思加一个 HTML 渲染器**（把消息里的 HTML 当网页渲染）。
   - 最强的理由：用户点名说了"html 的渲染"。
   - 为何被否：**原生没有这一档**（上面 §Problem 的四条证据）。真按字面做，就是自造一条
     Web 不存在的行为，并且要处理脚本/样式/外链 —— 一个聊天记录里的 XSS 面。
   用户的真实诉求是"正文看起来不对"，而不是"必须有 HTML 渲染"。
2. **只加复制按钮，不加换行开关与语言标签**（最小改动）。
   - 最强的理由：改动最小、当天可完。
   - 为何被否：DSH 的头部是**一个**组件（`CodeToolbar`），三个控件同源同存；
     只挑一个，下一轮又会发现"换行行为与 Web 不一致"（Web 默认换行，手机原来横滚）。
3. **顺手接语法高亮**（`highlight` 纯 Dart）。
   - 最强的理由：一次把代码块做完整。
   - 为何被否：高亮的开销纪律（缓存 + 视口触发 + 超长行不 tokenize）是独立一块，
     塞进本轮会把"代码块工具条"这件事拖成又一个半成品；本轮把纪律写成文档，
     下次接的时候有判据。

## Consequences

- 收益：代码块在两端**同形同名**（一样默认换行、一样有语言标签与复制、文案逐字照 zh 词典）；
  "HTML 渲染"这条不再悬着 —— 文档里有"原生没有这一档"的结论与出处。
- 代价：`markdown` 多了一行显式依赖（版本跟随 `flutter_markdown_plus`，**不要**自己升级）；
  语言标签在接上高亮前恒为"代码块"（比显示 `dart` 少一点信息，但那是 DSH 的规则）。
- 没做：语法高亮、数学公式、流式"只重排末尾"。三处的判据都在文档里，
  代码入口 `app/lib/ui/dsh_markdown.dart` 的文件末注释回指本节结论。