# Agent Note: 字号要不要「全局」——调研、诊断与三条路线

Status: proposed

## Problem

2026-10-22 用户原话：「这个字体大小我看了非常的丑，而且有的地方字又很小，所以我想的是全局，
但是我不知道你的标准规范不，我也不知道 APP 这种的样式字体怎么规范的，字体大了布局又怎么办，
我没做过 APP 开发我不懂，你规范想让你调研看看分析一下」。

背景：同一天刚落地的 C（`2026-10-22-type-scale-base-plus-delta.md`）按 DSH 的规范把
"字号大小"做成了 **base + delta，只作用于会话内容**（正文 / 标题 / 用户气泡 / 工具名 /
运行条 / 输入框），chrome 与 caption 固定。用户看到的就是那个结果。

## 诊断（为什么"丑"、为什么"有的地方字小"）

### 1. 62% 的文字挤在 11–12px

`app/lib/` 当前 **217 处** `fontSize:` 的分布（本轮实测）：

```
11×72   12×63   13×47   14×19   15×7   16×4   10×2   18/20/34 各 1
```

**135 处（62%）在 11–12**，最大的一桶是 11px（72 处）。这台机器 411dp 宽
（`wm size` 1080×2400 / 560dpi），11dp ≈ 2.8mm —— 放在聊天界面里就是"字小"。
所以"有的地方字很小"不是个别控件，是**主要字号**。

### 2. 只让内容跟刻度 ⇒ 对比被放大成 2 倍

DSH 的规范是"内容跟 delta、小字固定"（`type-scale.md` §2）。默认档 14 下
内容/小字 = 14/11 = **1.27**；把设置拉到 22 时变成 22/11 = **2.0**。

两块差一倍的界面读起来不像同一个 App —— 这是"丑"的机械解释，而不是审美问题。
**要么让 chrome 一起长，要么把设置范围收窄**；现状是两者都没做。

### 3. App 本来就跟随系统字号，但图标不跟

Flutter 的 `MediaQuery.textScaler` 由平台提供（`packages/flutter/lib/src/painting/text_scaler.dart:20-76`
的 `TextScaler.linear` / `clamp`），我们的 `MaterialApp` 没有覆盖它 ⇒ **Android 设置 → 显示 →
字体大小 会直接放大我们的全部文字**。本机实测（`shots-2026-10-22/font-a…font-g`）：

| 系统 font_scale | 结果 |
|---|---|
| 1.3 | 顶栏 / 抽屉 / 输入框 / 按钮全部变大，**无溢出**（抽屉行、按钮都是弹性的） |
| 2.0 | 输入框占位换三行、标题被省略号截断，**仍无黄黑溢出条**；但 `…` 菜单、图标、36/44 的定高**没变** ⇒ 文字与 chrome 脱节 |

结论：**"全局放大"在布局上已经过了一次压力测试（2.0 没崩）**；真正缺的是
①App 内没有这个开关（只有系统那一处），②图标 / 内边距 / 定高不跟着走。

### 4. 有数据的页面实测（2026-10-22 晚，隔离实例 63900）

在有工具卡 / 代码块 / diff / 长正文的会话（`Run 3 separate shell commands`）上，
App 内字号先退回 14，再逐档改系统 `font_scale`（**不用跑模型**，只是选会话读历史）：

| 系统 font_scale | 观感与问题 |
|---|---|
| 1.0（基准） | 正常。正文 14、工具名 13、chrome 11–13 |
| 1.15 | 正常，无截断 |
| 1.3 | 舒适；工具卡、思考行、代码块都撑得住；只有底部统计条要横滑（它本来就是横滚的） |
| 1.5 | 仍然没有溢出条；顶栏标题开始省略、输入框占到约 1/5 屏 |
| 2.0 | 不溢出但**明显发挤**：顶栏标题 `Run 3 se…`、统计条尾巴被裁、输入框占 1/3 屏、`…` 菜单与图标尺寸没变、文字与图标脱节 |

截图：`shots-2026-10-22/sc-100-session.png`（1.0）、`sc-1_3-session.png`、`sc-1_5-session.png`、
`sc-2_0-session.png`；空态与抽屉另有一组 `font-a…font-g`。

**结论（上限）**：1.5 以内是"舒服"的，2.0 是"能用但挤"。所以 App 自己的倍率上限取
**≈1.5**（并且与系统字号叠加后整体 clamp 到 2.0，别超过系统已经证明能用的那条线）。

## 行业怎么规范的（这次抓到了原文）

用已连的 Chrome 读 `developer.apple.com/design/human-interface-guidelines/typography`
（`web_fetch` 只能拿到标题，浏览器里 innerText 是完整的）：

- **字号有下限**：iOS/iPadOS **默认 17pt、最小 11pt**；macOS 13/10；watchOS 16/12。
- **"不是每个字都要一起变大"**：原话 —— *"Prioritize important content when responding to
  text-size changes… they don't always want to increase the size of every word on the screen.
  For example… they don't expect the tab titles to increase in size."*
  ⇒ **DSH 的"内容跟 delta、chrome 固定"在方向上是对的**，问题出在我们的**默认值与对比度**。
- **图标要跟着字号变大**：原话 —— *"Increase the size of meaningful interface icons as font
  size increases… When you use SF Symbols, you get icons that scale automatically."*
  ⇒ 我们 `DshIcon` 固定 px 是不符合这条的，至少"行内、信息性"的图标要跟着走。
- **布局必须自适应**：*"Make sure your app's layout adapts to all font sizes… Keep text
  truncation to a minimum as font size increases."*
- **Material 3**（`m3.material.io/styles/typography/type-scale-tokens`，同样是浏览器读的）：
  15 个 baseline 档（Display/Headline/Title/Body/Label 各 3 档）+ 15 个 emphasized 档，
  原话 *"No single product will use all the styles"* —— 也就是说**档位是选出来用的**，
  不是每个控件随手写一个字号（我们 217 处手写字面量正是反面）。
- **Flutter 的机制**（本地源码）：`TextScaler.linear(f)` 乘所有 `fontSize`；
  `TextScaler.clamp(min,max)` 限定倍率（`packages/flutter/lib/src/painting/text_scaler.dart:20-76`）。
  `MediaQuery.textScaler` 是平台给的那一份，我们已经在吃 —— 所以"全局"不是发明新机制。
- **我们自己的规范**：`docs/subsystems/type-scale.md`（DSH 的 base + delta）。
  它对"内容"已经对了，对"全局"没有立场 —— DSH 的设置本来就只管内容。

## 三条路线

### A（推荐）全局倍率 + 类型表重排

1. 设置项语义从"内容字号 10–22"改成**界面字号**：四档（`较小 85% / 标准 100% / 较大 115% /
   特大 130%`）或连续百分比；实现为在 `MaterialApp.builder` 里包一层
   `MediaQuery(data: …copyWith(textScaler: platform.clamp(...) * 用户倍率))` ——
   **叠加在系统字号上**（系统调大 + App 再乘，两者不打架）。
2. 同时把类型表收成 4 档：`caption 11 / secondary 13 / body 14–15 / title 17–22`，
   并把 72 处 11px 里**内容型**的（工具参数、思考摘要、行预览、设置值）提到 12–13；
   真正的 caption（时间戳、徽标、`共 N 行`）留 11。
3. 把 8 处**带文字的定高**（`chat_turns.dart:1411`、`dsh_sheet.dart:516`、
   `settings_page.dart:659/863`、`session_drawer.dart:276/307/801`、`chat_jumper.dart:242`）
   改成 `minHeight` + padding；`DshIcon` 加一个 `scale` 参数（或关键图标按倍率乘），
   让图标与文字同步。
4. 判据：390dp × 85% / 100% / 130% 三档，每个主要屏幕一张截图 + `takeException()`
   为空的 widget 断言；11px 只允许出现在 caption 白名单里（可机械扫）。

### B 只重排类型表（不动缩放）

把 11px 里内容型的提到 12–13、caption 留 11。**解决"有的地方字小"，不解决"全局"**。
代价最小（无布局风险），但用户明确要的是全局。

### C 保持现状（只内容缩放）

零改动。代价：对比随设置放大到 2 倍（见诊断 2），且已被用户当场否掉。

## 需要用户定的三件事

1. **设置形态**：百分比滑杆 / 四档（较小·标准·较大·特大）/ 保留现在的 10–22 数字？
   （我推荐四档：手机上一眼能选，"10–22 的数字"对用户没有意义。）
2. **上限**：130%（实测 1.3 无溢出）还是 150%（未测，风险高）？
   Android 系统最大可到 2.0，我们自己的开关不必给到那么大。
3. **图标要不要一起放大**：一起放大更协调，但会牺牲 DSH 的像素对齐（图标尺寸是按 14/16 定的）。

## Consequences（若走 A）

- 收益：一个开关治住**整个界面**；11–12px 的字变少（"字小"）；对比不再随设置翻倍（"丑"）。
- 代价：
  - 217 处字号里有 **~60 处要重新归档**（内容型小字提档），这是一次逐屏核对的活；
  - 8 处定高 + 若干 36/44 的触达区要改成弹性，否则大字下会挤压；
  - `DshIcon` 的尺寸策略要改一处（全局），影响所有图标；
  - 与 DSH 的 `base + delta` 规范**有意偏离**（DSH 只管内容）—— 要在
    `docs/subsystems/type-scale.md` 写明理由：手机屏幕更小、用户对"全局"的预期更强。
- 不做 A 的后果（也就是现在）：用户已经说了丑。这是本轮唯一被用户当场退回的件。
