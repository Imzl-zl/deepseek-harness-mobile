# 字号刻度（base + delta）

「设置 → 通用 → 字号大小」是**一个整数 10–22、默认 14**，只影响**会话内容**的字号
（DSH 的 `fontSize.description` 原话："仅影响会话内容的字号"）。刻度是 `base + delta`，
**不是**整体缩放。

## 1. 派生（照 DSH 逐条）

`packages/client/ui-theme/src/styles/gradient-shadow-text.css:56-63`：

| 量 | 公式 | 默认档（14） | 10 档 | 22 档 |
|---|---|---|---|---|
| delta | `size − 14` | 0 | −4 | +8 |
| 正文 | `size` | 14 | 10 | 22 |
| 正文行高 | `24 + delta` | 24 | 20 | 32 |
| secondary | `min(size−1, max(13, size−2))` | 13 | 9 | 20 |
| secondary 行高 | `20 + (secondary − 13)` | 20 | 16 | 27 |
| h1 / 行高 | `21 + delta` / `30 + delta` | 21/30 | 17/26 | 29/38 |
| h2 / 行高 | `19 + delta` / `28 + delta` | 19/28 | 15/24 | 27/36 |
| h3 / 行高 | `18 + delta` / `26 + delta` | 18/26 | 14/22 | 26/34 |
| h4 | 正文（只换字重） | 14 | 10 | 22 |

落点：`app/lib/theme/dsh_type.dart`（`DshType` + `DshTypeScope` + `context.dshType`）。
**默认档每个值都等于改造前手写的那个字面量**，所以没动设置的设备看到的是同一套像素。

## 2. 哪些文字跟刻度走

DSH 的规则是「贴着内容的尺寸写 `calc(基准 + delta)`；caption 与小字固定不跟 delta」
（`:51-55` 的注释原话 "Small typography keeps a fixed size"）。手机侧照同一条：

| 跟刻度 | 位置 |
|---|---|
| 正文 / 标题阶梯 / 行内代码 | `ui/dsh_markdown.dart`（Markdown 正文与 h1–h3） |
| 用户气泡正文 | `ui/chat_turns.dart` 的 `UserTurn` |
| 流程行标题（工具名、思考/命令标题 + 摘要、说话者标签、运行条） | `_DisclosureHeader` / `ToolCard` / `AssistantHead` / `RunningBar` |
| 输入框文字与占位 | `ui/dsh_composer.dart` |

**固定不跟**（chrome 与 caption，DSH 同一条）：顶栏、统计条、抽屉行、设置行的标签与值、
按钮与徽标、轮次摘要（`第 4 轮 · 2 分 21 秒`）、代码块（见 §3）、各类 11–12px 小字。

## 3. 代码字号是**另一个**设置（这一版没做）

DSH 的代码字号是独立设置（10–16、默认 11，`:60-63`），代码块按它排、行内代码按正文字号的
`0.875em` 跟随。手机侧这一版：**代码块固定 12**（`DshTheme.mono`），行内代码跟正文缩放。
代码字号设置列进"不做"，理由：它是另一条轴（改它不动正文），要做就得再来一套刻度与设置行。

## 4. 半点字号已经收敛

改造前 216 处 `fontSize:` 里有 5 个半点值（10.5 / 11.5 / 12.5 / 13.5 / 14.5），
DSH 的阶梯只有整数。一次性脚本 `app/tools/migrate-font-half-points.mjs` 把 **32 处**
抹平（10.5→11、11.5→11、12.5→12、13.5→13、14.5→14），带**每档命中数断言**与
"改完不许有点数字号"的残渣断言；`app/lib/` 里现在没有点数字号。

## 5. 判据

- 单测 `app/test/type_scale_test.dart`：派生公式逐档对（含 10→9 / 14→13 / 15→13 / 22→20
  那四组）；落盘 / 边界夹取 / 重启读回；
  **390dp 上到 22 不溢出**（Markdown 与用户气泡各一条，`takeException` 为空 + 字号真的生效）。
- 单测 `app/test/settings_font_size_test.dart`：设置行的步进器 ±1、到 10 / 22 不可越过。
- 真机（`d61cf622`，`shots-2026-10-22/`）：`c1-default14.png`（14）、
  `c3-chat-10.png`（10）、`c5-chat-22.png`（22）三张同屏对照 —— 内容随之缩放、
  chrome 不动、无溢出；`force-stop` 重启后设置页仍显示 22（落盘生效）。
