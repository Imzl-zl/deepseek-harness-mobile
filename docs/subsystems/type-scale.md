# 字号：两层倍率（系统 × App）+ 角色表

手机上的字号**本来就是两层**：

1. **系统字号**（Android 设置 → 显示 → 字体大小 / iOS 的 Dynamic Type）由平台递进来，
   Flutter 通过 `MediaQuery.textScaler` 暴露；本 App 不覆盖它，所以系统放大已经生效。
2. **App 内档位**（设置页「界面字号」）是**倍率**，乘在系统那一份之上。

两者相乘后整体 `clamp(0.85, 2.0)`。

## 1. 档位

| 档 | 倍率 | 说明 |
|---|---|---|
| 较小 | 0.9 | 一屏塞更多 |
| 标准 | 1.0 | **默认** |
| 较大 | 1.15 | |
| 特大 | 1.3 | 上限；实测 1.3 在有工具卡/代码块/diff 的会话上仍舒服 |

常量在 `app/lib/model/preferences.dart`（`kUiScaleSteps` / `kUiScaleLabels` /
`kUiScaleDefaultIndex`）；落盘键 `device.ui_scale_index`（`data/ui_state.dart` 的 `UiKey`，
首帧前读回）；实现见 `app/lib/main.dart` 的 `_uiScaled`。

**为什么上限是 1.3**：系统 1.5 时顶栏标题开始省略、输入框占约 1/5 屏；系统 2.0 不溢出但明显发挤
（`shots-2026-10-22/sc-1_5-session.png`、`sc-2_0-session.png`）。与系统叠加后整体 clamp 到 2.0
——那是实测还能用的那条线。

## 2. 为什么是倍率，不是"内容字号 10–22"

等比缩放**不改变任何对比关系**：正文/caption 还是 14/11，只是都乘同一个数。
所以"全局"与"好看"不冲突 —— 而**只放大内容**会把对比从 1.27 拉到 2.0（14/11 → 22/11），
那正是"丑"的机械原因（历史上那一版已作废，见
`.agents/notes/archived/2026-10-22-type-scale-base-plus-delta.md`）。

## 3. 角色表（`app/lib/theme/dsh_type.dart`）

`DshType` 仍是**设计基准**（正文 14），**不随设置变**；设置由 `MediaQuery.textScaler` 乘上去。
派生公式照 DSH（`packages/client/ui-theme/src/styles/gradient-shadow-text.css:56-99`）：

| 角色 | 基准 | 行高 |
|---|---|---|
| 正文 `body` | 14 | 24 |
| 次级 `secondary` | `min(size−1, max(13, size−2))` = 13 | 20 |
| 标题 h1 / h2 / h3 | 21 / 19 / 18 | 30 / 28 / 26 |
| caption | 11（Apple HIG 的 iOS 最小字号也是 11） | — |
| 代码 | 12（固定，不跟角色表） | — |

调用点写 `context.dshType.body`，语义是"正文那一档"，不是"14px"。

## 4. 图标跟随

`DshIcon` 按 `MediaQuery.textScalerOf(context).scale(1.0)` 等比放大，**只放大不缩小**，
上限 1.4（`app/tools/dsh_icons.template.dart` → 生成物 `app/lib/theme/dsh_icons.dart`；
改模板后跑 `node app/tools/extract-dsh-icons-dart.mjs`）。
装饰性大图传 `scalesWithText: false`。

依据：Apple HIG 原文 *"Increase the size of meaningful interface icons as font size increases…
When you use SF Symbols, you get icons that scale automatically."*
（`developer.apple.com/design/human-interface-guidelines/typography`，2026-10-22 读）。

## 5. 布局约束

带文字的容器**不许写死高度**，用 `minHeight`：素材是 `chat_turns.dart` 的披露行、
`dsh_sheet.dart` 的底部按钮、`session_drawer.dart` 的「新建会话」与搜索框。
依据：Apple HIG 原文 *"Make sure your app's layout adapts to all font sizes… Keep text
truncation to a minimum as font size increases."*

## 6. 判据

- `app/test/type_scale_test.dart`：角色表逐档（10/14/15/22）对 DSH 公式；四档倍率表；
  落盘 / 越界夹取 / 重启读回（垃圾值退回默认）；390dp × 1.3 的 Markdown 与用户气泡**不溢出**
  且高度确实变大。
- `app/test/settings_font_size_test.dart`：设置行默认「标准」、sheet 四档带百分比、选完落到 `AppModel`。
- 真机（`d61cf622`，系统字号 1.0）：`ui-scale-90-chat.png` / `ui-scale-100-chat.png` /
  `ui-scale-130-chat.png` 与 `ui-scale-130-settings.png` —— 90/100/130 三档整屏等比放大，
  含 tool 卡、思考行、代码块、输入框、统计条、设置页。

## 7. 已知边角

- **右侧那对「最早 / 最新」是浮层跳转钮，不是常驻标签**：它在滚动时出现，滚动停下 1.5 秒后
  淡出（`chat_jumper.dart` 的 `AnimatedOpacity` + `IgnorePointer`）。大字号下它自己也会变大，
  所以**滚动后那一瞬**会压住右侧内容的一小块（可能是卡片右箭头）；淡出后不拦点击。
  实测对照：`shots-2026-10-22/jumper-side-by-side.png`（左=刚滚完，右=3 秒后）。
- **代码块字号固定 12**，不随角色表变（但仍跟着系统与 App 倍率走）。
- **大字号下顶栏标题会更早出现省略号**（`TextOverflow.ellipsis` 的正常行为；
  Apple 的"尽量少截断"针对内容区，顶栏标题一直是单行）。
