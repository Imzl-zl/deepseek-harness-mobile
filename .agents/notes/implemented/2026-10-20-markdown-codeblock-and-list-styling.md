# Agent Note: 代码块与列表的 Markdown 样式对齐 DSH（会话页渲染问题排查第一轮）

Status: implemented

## 起因

用户 2026-10-20 晚：「我看你的会话页面渲染还有一部分问题是吧？」
—— 让我系统找渲染问题，先别急着做文件上传。

## 排查方式

不看代码猜，**看真机截图**（示例会话「超长文本与代码块」），再回 DSH 找权威规格。

## 发现的三处偏离（全部有出处）

### 1. 代码块没有自己的底色（最明显）

我们的 `codeblockDecoration` 用的是 `c.bgBase` —— **和页面同一个色**，
于是代码块看着像"没有底"，整块和正文糊在一起。

DSH 的 `ui-primitives/src/markdown/CodeBlock.module.css` 的 `.block`：

```css
--dsl-code-block-background: var(--dsw-alias-markdown-code-block);
--dsl-code-block-border-radius: var(--dsw-radius-lg);
margin: 16px 0;
background: var(--dsl-code-block-background);
border-radius: var(--dsl-code-block-border-radius);
```

即：底色是 **`markdown-code-block`**、圆角是 **`lg`**、**没有 border**。
我们三处都不对（`bgBase` / `sm` / 多画了一圈 `layer3` 边框）。

修：`color: c.codeBlock`（今天为 `ToolDetails` 加的那个 token，名字正是
`markdown-code-block`）、`borderRadius: DshRadius.lg`、**去掉 border**、
`codeblockPadding: EdgeInsets.zero`（内边距由 `_DshCodeBlock` 自己管）。

### 2. 列表 marker 用了正文色

`MarkdownText.module.css:111-118`：

```css
.markdown li::marker { line-height: 24px; color: var(--dsw-alias-label-secondary); }
```

marker 应当比正文**淡**。我们 `listBullet: body` 用的是正文色 ⇒ `•` 比正文抢眼。
改成 `body.copyWith(color: c.labelSecondary)`。

（`listIndent: 18` 本来就是对的 —— DSH 的 `padding-left: 18px`。这条不改。）

### 3. 已确认**正确**、不需要动的

- 表格、任务列表、删除线、引用、标题层级、行内码：探针测试全绿
  （`test/markdown_coverage_test.dart`）。
- 助手正文与**流式文本**都走 `DshMarkdown`
  （`chat_page.dart:2684` 的 `_LiveTurn`、`chat_turns.dart:197`）。
- 用户消息是纯 `Text`（`chat_turns.dart:110-117`）—— 用户自己打的字不跑 Markdown，
  与"输入的是纯文本"一致，**有意为之，不改**。

## 同批补上的两处（用户：「你改搞得都搞一下啊」）

### 4. banner 自己的底色

DSH `CodeBlock.module.css:5,38`：`.banner { background: var(--dsl-code-block-banner-background-color) }`，
而 `--dsl-code-block-banner-background-color: var(--dsw-alias-markdown-code-block-banner)`。

新增 token `codeBlockBanner`：

| | 亮色 | 暗色 |
|---|---|---|
| `--dsw-alias-markdown-code-block-banner` | `neutral-bluish-50` = `#F9FAFB`（`:229`） | `neutral-bluish-850` = `#2C2C2E`（`:347`） |

**注意**：亮色下 banner 与块底**同为** `neutral-bluish-50`
（`design-platform.css:229` 与 `:230` 两行用的是同一个静态色）——
也就是说这条在浅色主题里看不出差别，只在暗色下分得开。这是 DSH 的既定行为。

### 5. 16px 外边距

DSH `.block { margin: 16px 0 }`。`BoxDecoration` **没有 margin**，
而 `codeblockDecoration` 是 flutter_markdown 包在**我们返回的 widget 外面**的，
它包不到更外层 ⇒ 外边距只能由我们出。

所以结构改成：**`codeblockDecoration` 退化为空装饰**（`const BoxDecoration()`），
由 `_DshCodeBlock` 自己画这一层：

```
Padding(vertical: 16)              ← DSH 的 margin: 16px 0
  ClipRRect(radius: lg)            ← 裁切，让 banner 的上圆角跟着走
    Container(color: codeBlock)    ← DSH 的 .block 底色
      Container(color: codeBlockBanner)  ← banner 底色
        Row(语言 + 换行 + 复制)
      Padding(14,6,14,12) → 正文
```

这样 `.block` 的四个属性（底色 / 圆角 / 外边距 / 无边框）与 DSH 一一对应，
而不是"看起来差不多"。

## 仍未做 / 待查

- 其余渲染面（轨迹页、工具卡内部、斜杠命令卡）本轮没逐一比对，
  但它们各自已有真机验证记录，不在"会话页正文渲染"这条线上。

## 验证

- 真机截图（深色/浅色）：代码块现在是一块独立的浅底 + `lg` 圆角 + 无边框。
- `flutter test 895` / `analyze 0` / `format 0` / `boundary 300`。
- 这一批是**样式**改动，不新增断言：视觉回归不在门禁里，
  判据是"截图看起来与 DSH 同一套规格"，规格本身已逐条引用到 CSS 行号。
