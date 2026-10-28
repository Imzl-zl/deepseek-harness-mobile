# 代码语法高亮：`re_highlight`（纯 Dart）

- 日期：2026-10-28
- 状态：implemented

## Problem

文件预览与聊天里的代码块都是**单色等宽**。桌面按语言上色
（`ui-primitives/src/markdown/highlight.ts`、`CodeBlock.tsx`），手机没有 ——
一段 diff、一段 Dart，关键字/字符串/注释全靠读。

## Decision

用 `re_highlight 0.0.3`（`pub:re_highlight`），**只注册常见一档语言**（28 个），
`TextSpanRenderer` 产出 `TextSpan`，亮/暗各一套 `githubTheme` / `githubDarkTheme`。

- 高亮**只覆盖颜色**：字号/行高/字体仍由调用方 `base` 给，于是与纯文本回退逐像素一致；
- 认不出语言 / 高亮抛错 ⇒ 返回 `null`，调用方按纯文本渲染（不显示半个高亮）；
- 语言表与"后缀 → 语言"映射都在 `app/lib/ui/dsh_code_highlight.dart` 一处；
- 代码块头部标签沿用桌面规则：`supportsHighlighting(lang) ? lang : 代码块`
  （`ui-primitives/src/markdown/CodeToolbar.tsx:44`）。

## Alternatives considered

- **`flutter_highlight 0.7.0`**（最"有名"的那个）。
  最强理由：158 likes / 333k 下载，几乎每个 Flutter 项目都用过，社区示例最多。
  被否：它依赖的 `highlight`（pd4d10）**已停更**，flutter_highlight 本身五年没发版；
  `re_highlight` 的作者明确说是为替代它而生，且语法规则与 highlight.js 11.9 同步。
- **`flutter_code_editor`**（带编辑器脚手架）。
  最强理由：一个包同时给"编辑 + 高亮 + 折叠"，将来要做真编辑不用换。
  被否：我们要的是**只读预览**，它的编辑器状态机、光标、快捷键都是白带的体积与复杂度。
- **`languages/all.dart`**（全语言）。
  最强理由：一行注册，` ```xxx ` 基本都能亮，不用维护表。
  被否：几百种语法全部进包，移动端体积换一个"偶尔才用到"的能力不划算。
- **自己写高亮**：只做 diff/关键字着色。
  最强理由：零依赖，几十行。
  被否：`bash` / `json` / `python` 的字符串与注释规则很快堆成维护负担，而现成实现是
  highlight.js 的逐行翻译。

## Consequences

收益：文件预览与聊天代码块按语言上色；语言表只有一处，加语言是往 map 里加一行。

代价：

1. 新增一个运行时依赖（纯 Dart，无平台通道；`flutter test` 里可直接跑）；
2. 只注册 28 种语言，`toml` / `hcl` 之类的代码按纯文本显示（头部报「代码块」）；
3. 高亮在**每次重建**都会重算一遍（没有缓存）：代码块在聊天流里是静态内容，
   帧预算内可接受；若后来发现长文件滚动掉帧，再加按 (code, language, dark) 的缓存。
