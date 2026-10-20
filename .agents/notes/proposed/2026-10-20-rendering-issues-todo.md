# 会话页渲染：剩余问题清单（逐条标证据状态）

Status: proposed（**清单，不是决定**；每条都写了"证据状态"，未取证的不许先改）

用户 2026-10-20 晚：「其他的也有问题还是啥。有问题都记录一下，开新会话优化」

## 已修（同日，留档以免重复排查）

| 问题 | 依据 | 笔记 |
|---|---|---|
| 代码块没有底色（用 `bgBase`，与页面同色） | `CodeBlock.module.css:15-21` | `implemented/2026-10-20-markdown-codeblock-and-list-styling.md` |
| 代码块圆角 `sm`（应为 `lg`）、多一圈 border | 同上（`border-radius: radius-lg`、无 border） | 同上 |
| 代码块缺 16px 外边距 | 同上（`margin: 16px 0`） | 同上 |
| 代码块 banner 底色没接 | `CodeBlock.module.css:5,38` + `design-platform.css:229,347` | 同上 |
| 列表 marker 用正文色（应 `label-secondary`） | `MarkdownText.module.css:111-118` | 同上 |
| 行内 HTML 标签原样露出 | 探针实测 + `markdown-7.3.1` ExtensionSet | `implemented/2026-10-20-markdown-coverage-and-inline-html.md` |
| 空态文字折行后左对齐 | — | `implemented/2026-10-20-empty-state-and-bottom-strip.md` |
| 底部一条 `sidebar` 色的缝 | 真机像素 | 同上 |
| 系统栏不跟主题 | SDK 注释（`targetSdk 36` 忽略 `SystemUiMode`） | 同上 |

## 未修 / 未验（**本清单要解决的就是这些**）

> **2026-10-20 第二轮进度**：1 / 3 / 5 / 6 / 7 已改（依据与断言见
> `implemented/2026-10-20-render-alignment-to-dsh-spec.md`）；2 / 8 已判定
> "不是缺陷、不改"；4 仍需真机（阶段二）。

1. **用户消息是纯 `Text`**（`chat_turns.dart:110-117`）——**已核对：与 DSH 一致，不改**。
   DSH 的用户正文走 `conversation.user.text` → `UserTextRun`
   （`packages/client/ui-primitives/src/user-text.tsx:18-20`，"without Markdown or
   reference recognition"），气泡只负责 `white-space: pre-wrap`。我们少的只是
   `@文件` / `/skill` 引用 chip（那是 `ui-reference` / `ui-skill` 的匹配器，未接）。
   断言：`test/render_alignment_test.dart` 的"用户消息：DSH 不跑 Markdown"。

2. **附件计数文案「N 个附件（手机上不显示）」**（`chat_turns.dart:127-134`）
   —— 文本诚实（收来的事件只带引用不带字节，要 `session/attachment` 才能读），
   但"手机上不显示"作为长期形态很弱。是否要缩略图取决于要不要接
   `session/attachment` 方法（那是新方法面）。
   **证据状态**：事实清楚，**产品取舍未定**（本轮不改）。

3. **工具卡内部未逐一比对** —— **已改**：正文按 `.ioCard` / `.ioSection` / `.ioText`
   （11/16 等宽、`label-secondary`、上限 150 + 内滚、内边距 12×16），
   不再是 `ToolDetails.module.css` 的 `.root`（那是结构化字段卡）。
   断言：`render_alignment_test.dart` 的"工具卡展开正文"。

4. **斜杠命令卡（`CommandCard`）未逐一比对** —— 示例数据里没有 `CommandItem`，
   真机上这一屏还没出现过（端到端验收也列着它）。
   **证据状态**：未验（demo 无样本 + 未配对）—— 阶段二看。

5. **`_CollapsibleNote`（"系统提示词"那行）是纯 `SelectableText`**
   —— **已改**：行照 `DisclosureRow`（行高 24→36 的触屏偏离、标题 13/24、
   `label-tertiary`、图标 14），正文分两种：思考 = compact Markdown（13/20、
   `label-tertiary`、收起时显示首行摘要），系统提示词 / 上下文注入 = 11/16 等宽
   + 上限 141 的滚动区（`ContextInjectionRow.module.css:50-64`）。
   系统提示词的图标改成 `browse`（`SystemPromptRow.tsx:30`）。
   断言：`message_rendering_test.dart` 的"思考过程块"两条 +
   `render_alignment_test.dart` 的"系统提示词"两条。

6. **表格在窄屏可能横向溢出** —— **已改**：`tableColumnWidth` 用
   `IntrinsicColumnWidth`（`flutter_markdown_plus-1.0.12/lib/src/builder.dart:447-463`
   只在两种列宽下才套横向滚动），于是宽表按自然宽度横滚、不再被压成窄列；
   边框改成只有行分隔线、表头左对齐、单元格 10×16（`MarkdownText.module.css:192-262`）。
   **已知偏离**：窄表不铺满（DSH 三列以内会 `width:100%`），
   且没有 `min-width:100px` / `max-width:30vw` 的等价物。
   断言：`render_alignment_test.dart` 的"宽表要有横向出路"（360 视口）。

7. **流式文本用 Markdown 渲染**（`chat_page.dart:2684`）—— **已核：不是缺陷**。
   DSH 的流式 arm 同样把未闭合围栏渲染成代码块并逐块冻结
   （`ui-primitives/src/markdown/incremental.ts:10-14`）。本轮做的是两件相关的事：
   ① `normalizeInlineHtml` 改成逐行扫描围栏（`~~~` 也是围栏，未闭合一直算围栏内，
   否则会改写围栏内的源码）；② 流式尾条目与持久条目共用 `AssistantHead` + `DshMarkdown`，
   流结束换条目时不再跳一下。
   断言：`markdown_coverage_test.dart` 的"流式：未闭合围栏"两条 + 围栏扫描四条。

8. **`normalizeInlineHtml` 只处理行内** —— **已判定：不改**。DSH 把原始 HTML 当
   **字面文本**显示（`ui-primitives/src/markdown/render.tsx:333-335`："No HTML parser
   enters the pipeline: raw HTML stays literal text"），所以"块级 HTML 也渲染"
   不是 DSH 的行为，我们不该做。我们的偏离（四种行内标签归一、其余去标签保文字）
   已写进 `docs/subsystems/app-channel-client.md` §4.1 的偏离表。

## 隔离实例真机验收（2026-10-20 晚）新发现的两条 —— **下一轮第一、二项**

9. **一轮没有"轮组"，与 DSH Web 结构不同（用户当场指出）**。
   同一轮在两端：
   - DSH Web：`已完成，用时 1 分 7 秒 ⌃` 一个**可展开的轮组**，组内再分
     `已完成分析` / `执行了命令`；上下文注入、思考、工具调用、正文都在组里，
     收起时只剩摘要（`ui-chat/src/client/locale.ts:35,64-65,150-151`、
     `conversation-nodes/step-process.ts`、`TurnProcessNodeView.tsx`）。
   - 手机：**平铺**。上下文注入三行、思考行、工具卡、正文、轮摘要各占一块；
     `TurnProcessRow` 只是"一轮末尾的一行收口"，不收任何东西
     （`chat_turns.dart` 里那句"不做收起该轮 —— 那是组级交互，而我们没有 turn 组"）。

   要补的是**一层结构**（不是样式）：事件里的 `turn`/`step` 进投影 → 条目带轮号 →
   列表按轮分组 → 组头复用 `TurnProcessRow`（加展开/收起，默认收起过程、正文不藏）→
   文案换成 DSH 的 `已完成，用时 ` / `已完成` / `已完成分析` / `N 次工具调用`。
   代价：列表结构、`_keysById` 的跳转语义、以及一组"收起只剩摘要"的测试。

10. **`ask_user_question` 在真机上直接失败**（用户当场指出"提问报错"）。
    模型调了 `ask_user_question`，工具结果是我们的原文：
    `提问缺少 callId：无法为手机答复建立稳定身份`
    （`connector/src/interaction-claims.ts:255`）。
    根因：**DSH 的 ask 载荷里 `wait` 是可选的** —— "absent for indefinite waits"
    （`packages/interaction/user-questions/src/types.ts:140-145`），而未计时的
    `ask_user_question` 正是 indefinite 那种；`callId` 只出现在
    `tool/call.callId` 与 `userQuestions` 投影的 `active[].callId` 上
    （`types.ts:76,142`）。我们只在 `request.wait?.callId` 上取
    （`connector/src/dsh/interactions.ts:205`），于是**所有未计时的提问都答不了**。
    修法方向：从会话事件里最近一条未应答的 `ask_user_question` 工具调用取 `callId`
    （我们已经在收 `tool/call`），或从 `userQuestions` 投影的 `active[]` 里按问题内容配对；
    两条都要在 `connector/tests/` 里钉住"未计时提问也能答"。


## 不算问题（用户 2026-10-20 纠正）

**「示例数据下轨迹页是空态」不是产品缺陷。** 示例数据只是开发辅助，
它显示不出某屏 ≠ 功能坏了。更根本的是：**评估手段不该反过来塑造产品**。
要验真实行为就走**隔离实例**（见下），不靠补示例数据。

示例数据本身可只留给测试用；它在生产路径上只由「看示例数据」这一个
显式动作触发，不会冒充真实数据，所以暂时留着没有害处 —— 但**不必为它加样本**。

## 端到端验收：起隔离实例（可行，已查实）

`DSH_HOME` 是官方支持的数据根覆盖（`packages/util/home-paths/src/index.ts:17,135`，
`resolveDshHome()` 优先级 = 显式配置 → `$DSH_HOME` → `~/.dsh`）。
设 `$env:DSH_HOME='<临时目录>'` 再启动，credentials / sessions / storages /
attachments 全落在那里，**不碰用户的 `~/.dsh`** —— 于是可以放心配对、建会话、
跑一轮，把上面这些「未验」逐条变成「已验」。

注意：新根里没有装连接器，得先把它装进那个实例（`dsh plugin install …` 之类，
具体命令见 `docs/cookbook/channel-bootstrap.md`）；这也正是这条路径一直没走的
真实成本 —— 不是"不允许"，是"要装一遍"。

## 排查方法（给下一轮，别重新发明）

- **视觉问题没有测试兜底**，所以判据是"真机截图 + DSH 的 CSS/TSX 行号"。
- 探针测试的写法见 `app/test/markdown_coverage_test.dart`：
  用 `find.textContaining(..., findRichText: true)`（`flutter_markdown` 产出
  `RichText`，默认 `find.text` 只看 `Text`，会误判成"什么都没渲染"）。
- 截图前先 `adb shell uiautomator dump` 拿**当前**坐标 ——
  坐标不能跨状态复用（这一条踩过三次）。
