# Agent Note: Markdown 覆盖度实测 + 行内 HTML 归一

Status: implemented

## 用户问的是「能渲染 md、html 常见的格式嘛？」

不能凭印象答，所以先查**本地包源码**（权威、离线、可复现），再用探针测试验**渲染结果**。

## 一、解析能力（源码事实，不是猜）

- `flutter_markdown_plus/lib/src/widget.dart:289`：
  > `extensionSet` — Defaults to `md.ExtensionSet.gitHubFlavored`

  而我们**没有**传 `extensionSet`，所以走的就是 `gitHubFlavored`。
- `markdown-7.3.1/lib/src/extension_set.dart`：
  - `gitHubFlavored` 块级 = FencedCode / **Table** / 无序 checkbox / 有序 checkbox / FootnoteDef
  - `gitHubFlavored` 行内 = **InlineHtmlSyntax** / Strikethrough / Autolink
  - `gitHubWeb` 额外还有 HeaderWithId / SetextHeaderWithId / **AlertBlockSyntax** / Emoji / ColorSwatch

## 二、渲染结果（探针实测）

`test/markdown_coverage_test.dart` 7 条：

| 格式 | 结果 |
|---|---|
| 标题 / 段落 / 粗体 / 斜体 / 删除线 / 行内码 | ✅ |
| 表格（表头 + 单元格） | ✅ |
| 任务列表 `- [x]` | ✅ |
| 引用 `>` | ✅ |
| **行内 HTML** | ❌ **标签原样露出**（正文里能看到 `<b>`） |
| **GFM 警示块** `> [!NOTE]` | ❌ 标记被当正文（`AlertBlockSyntax` 只在 `gitHubWeb`） |

第 5 条是最反直觉的：`InlineHtmlSyntax` **开着**，所以 HTML 会被**解析**成元素，
但 flutter_markdown 只为它认识的标签提供构建器，其余标签**把原始源码当文本吐出来**。

## 三、改了什么

### 1. 行内 HTML 归一成 Markdown（`normalizeInlineHtml`）

只做**确定等价**的四种，其余标签去掉（宁可丢样式，不丢文字）：

| HTML | 归一为 |
|---|---|
| `<br>` `<br/>` | 换行（`softLineBreak: true` 下真换行） |
| `<b>` `<strong>` | `**…**` |
| `<i>` `<em>` | `*…*` |
| `<code>` | `` `…` `` |

**代码块（```…```）里一个字都不动** —— 那里是用户在看的源码。
按"成对围栏"切分，奇数段跳过；**一处变异验证**：把 `i += 2` 改成 `i += 1`
（等于改代码块）→ 有 1 条红。

没有 `<` 的串**原样返回**（绝大多数消息走这条快路径，不做正则扫描）。

### 2. GFM 警示块：**没改**，只记录事实

改 `extensionSet: md.ExtensionSet.gitHubWeb` 就能支持，但那是**换整套扩展集**：
会同时引入 HeaderWithId / Emoji / ColorSwatch，其中 Emoji 会改用户正文的渲染
（`:smile:` 变表情），而这一步没有需求驱动。**记录事实、不动**，等有明确诉求再说。

## 四、没做的（明确边界）

- **语法高亮**：`flutter_markdown_plus` 不带；本仓 §7 说高亮要"可缓存、可后台预热"，
  是独立一块（`dsh_markdown.dart` 文件末"仍未做"已记）。
- **块级 HTML**（`<div>` `<table>` 这类整块）：`InlineHtmlSyntax` 只管**行内**。
  块级 HTML 在 markdown 里本来就会被当普通段落，`normalizeInlineHtml` 会把标签去掉、
  文字留住 —— 这正是现在的行为，不额外处理。
- **数学公式 / Mermaid**：两套参考实现各用各的插件，本仓未接，不在本次范围。

## 五、验证

- `test/markdown_coverage_test.dart` 7 条全绿（3 条渲染探针 + 4 条纯函数）。
- 一处变异验证（代码块保护）。
- `flutter test 895` / `analyze 0` / `format 0` / `boundary 300`。
