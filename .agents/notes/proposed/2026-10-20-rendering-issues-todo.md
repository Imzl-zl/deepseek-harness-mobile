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

1. **用户消息是纯 `Text`**（`chat_turns.dart:110-117`）——**现状有意为之**
   （用户打的是纯文本，不跑 Markdown）。但**未比对** DSH Web 对用户消息是否渲染
   Markdown/多行。若 DSH 渲染而我们不渲染，就是偏离。
   **证据状态**：只读了我们的代码，**没查 DSH**。

2. **附件计数文案「N 个附件（手机上不显示）」**（`chat_turns.dart:118-125`）
   —— 文本诚实（收来的事件只带引用不带字节，要 `session/attachment` 才能读），
   但"手机上不显示"作为长期形态很弱。是否要缩略图取决于要不要接
   `session/attachment` 方法（那是新方法面）。
   **证据状态**：事实清楚，**产品取舍未定**。

3. **工具卡内部未逐一比对** —— 标题行已是 DSH 规格（`.tool-r` 的
   min-height 52 / padding 13-14），展开正文刚改过（`ToolDetails.root`），
   但**正文里的字体与行高**（DSH `--dsw-font-xs-13` / `line-height`）没核对。
   **证据状态**：未比对。

4. **斜杠命令卡（`CommandCard`）未逐一比对** —— 示例数据里没有 `CommandItem`，
   真机上这一屏还没出现过（端到端验收也列着它）。
   **证据状态**：未验（demo 无样本 + 未配对）。

5. **`_CollapsibleNote`（"系统提示词"那行）是纯 `SelectableText`**
   （`chat_turns.dart:1347`）—— 与 DSH 的呈现是否一致未比对。
   **证据状态**：未比对。

6. **表格在窄屏可能横向溢出** —— 我们的 `tableBorder`/`cellsPadding` 已设，
   但**没有横向滚动容器**；`flutter_markdown` 的表格是 `Table`，
   超宽时会挤压或溢出。示例里那张表只有两列且很短，**没验过宽表**。
   **证据状态**：未验（需要一张 5-6 列的超宽表样本）。

7. **流式文本用 Markdown 渲染**（`chat_page.dart:2684`）——
   过程判据合理（边生成边渲染），但**未闭合的围栏**（```` ``` ````）在流式途中
   会把后续内容短暂显示成代码块。是"渲染抖动"的常见来源。
   **证据状态**：只读了代码，未在真机观察（需要配对）。

8. **`normalizeInlineHtml` 只处理行内** —— 块级 HTML（`<div>` `<table>`）会被
   `InlineHtmlSyntax` 之前就当成普通段落，标签被我们去掉、文字留下。
   这与"渲染 HTML"不是一回事，**用户可能期待块级也渲染**。
   **证据状态**：行为已知（有测试），**是否要支持未定**。

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
