# Agent Note: 字号刻度用 base + delta，不用全局缩放

Status: superseded（2026-10-22 晚：被 `.agents/notes/implemented/2026-10-22-global-ui-scale.md`
取代。本篇的**角色表派生公式**仍然有效并被沿用；被推翻的只是"设置只放大内容、chrome 固定"
这一条 —— 真机上那会把内容/chrome 的对比从 1.27 拉到 2.0，用户当场退回）

## Problem

用户原话：「能不能统一控制字体大小…最好是可以设置大中小，但是大了我怕有的样式崩了」。

改造前的现状：`app/lib/` 里 **216 处**手写 `fontSize:`、**17 个**不同值，其中 5 个是半点
（10.5 / 11.5 / 12.5 / 13.5 / 14.5）；正文基准 13，而 DSH 是 14；没有任何设置项能把它们
一起放大或缩小。

## Decision

### 1. 刻度照 DSH 的 `base + delta`

`app/lib/theme/dsh_type.dart`：`DshType(size)`，派生正文 / secondary / 标题阶梯 / 行高，
公式逐条抄 `ui-theme/src/styles/gradient-shadow-text.css:56-99`（表格见
`docs/subsystems/type-scale.md` §1）。设置是一个整数 **10–22、默认 14**
（`ui-theme/src/theme-settings.ts:24-30`），落手机本地（`AppModel.contentFontSize`，
meta 键 `content_font_size`，与其余纯 UI 偏好同一条路）。

### 2. 只让**贴着内容**的文字跟刻度走

DSH 的注释原话是 "Small typography keeps a fixed size"（`:51-55`），设置自己的说明是
"仅影响会话内容的字号"。所以只换这些调用点：Markdown 正文与标题阶梯、用户气泡正文、
流程行标题（工具名 / 思考与命令标题 / 说话者标签 / 运行条）、输入框文字。
顶栏、统计条、抽屉、设置行、按钮、徽标、轮次摘要一律保持字面量。

### 3. 半点字号一次性收敛

32 处半点用一个带**每档命中数断言 + 残渣断言**的一次性脚本抹平
（`app/tools/migrate-font-half-points.mjs`，10.5→11 / 11.5→11 / 12.5→12 / 13.5→13 /
14.5→14）。DSH 的阶梯只有整数。

## Alternatives considered

1. **`MediaQuery.textScaler` 全局放大**
   - 最强理由：一行代码，所有文字一起变大，不用碰 216 处。
   - 为何被否：它同时放大图标、间距、行高与触达区，而我们的尺寸是各自写死的字面量、
     不跟着缩放 —— 结果是文字撑出容器、图标与文字错位。这正是用户担心的"大了样式崩了"。
     而且它不是 DSH 的语义：DSH 只动内容那一维。
2. **全局 `Transform.scale`**
   - 最强理由：连布局一起放大，"看起来比例不变"。
   - 为何被否：那是缩放一整张图（顶栏变高、点击区变位置、键盘顶起的视口重算），
     不是字号设置；真机上一放大就会露出"给桌面做的"那股味。
3. **把 216 处全部换成 `DshType` 档位**
   - 最强理由："收敛"最彻底的判据就是没有一处字面量。
   - 为何被否：DSH 自己**没有**这么做 —— caption 与小字固定，chrome 不跟设置。
     盲目全换会把徽标、统计条、按钮一起缩放，正是被否方案 1 的后果换个写法。
     剩下的字面量按"chrome / caption，固定"记档，见 `docs/subsystems/type-scale.md` §2。
4. **字号做成 `ThemeExtension`（跟亮暗色板同一套机制）**
   - 最强理由：与 `DshColorTokens` 同一形状，读法统一。
   - 为何被否：色板随主题重建，而字号在**运行中**变（步进器每点一次），
     重建 `ThemeData` 会把整棵树连同 `MaterialApp` 的过渡一起重来。
     `InheritedWidget` + 一个值比较的 `updateShouldNotify` 只重建真正依赖字号的文字。
5. **代码字号也一起做（DSH 的 10–16、默认 11）**
   - 最强理由：DSH 里它是并列的一个设置，一起做才叫"对齐"。
   - 为何被否：它是**另一条轴**（改它不动正文，正文改了它也不动），要有独立刻度与独立
     设置行；本轮的目标是"一个设置治住会话内容"。列入 `docs/subsystems/type-scale.md` §3
     的"不做"，代码块继续固定 12。

## Consequences

- 收益：字号只有一个控制点；10 与 22 两端都不溢出（390dp 单测 + 真机截图）；
  半点字号清零，`app/lib/` 里不再有点数字号。
- 代价：
  - **不是所有文字都跟着变**：chrome 与 caption 固定（DSH 的语义），用户若期待"整个界面
    一起大"会失望 —— 设置行里那句"仅影响会话内容的字号"就是为这件事写的。
  - 默认档从 13 改成 14（正文基准对齐 DSH）：Markdown 正文、用户气泡、工具名一起大 1px。
    这是有意的对齐，逐屏在真机上过过一遍（10/14/22 三档）。
  - `DshTypeScope` 必须挂在 `MaterialApp.builder` 上：挂不上（单测直接 pump 某页）时
    回默认档 14，不崩也不缩放。
  - `data/app_model.dart` 不能 import `theme/dsh_type.dart`（后者依赖
    `package:flutter/widgets.dart`，而 `data/` 禁止）—— 范围常量放在
    `model/preferences.dart`（纯 Dart），`DshType` 反过来引用它。
- 单测：`app/test/type_scale_test.dart`（8 条，含 390dp / 22px 两条溢出断言）+
  `app/test/settings_font_size_test.dart`（步进器与边界）。
  **变异校验**：把 `DshTypeScope.of` 改成恒回默认档 ⇒ 两条 390dp 用例当场红
  （`Expected: <22> / Actual: <14.0>`、高度 432 < 496.8）。
- 真机证据（`d61cf622`，`shots-2026-10-22/`）：`c1-default14.png` / `c3-chat-10.png` /
  `c5-chat-22.png` 三档同屏；`force-stop` 重启后设置页仍显示 22（落盘生效）。
