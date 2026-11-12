# Agent Note: 自绘可点区补上「按钮」语义角色 —— 朗读器才认得出

Status: implemented

## Problem

本仓大量交互是手写的 `InkWell` / `GestureDetector`（实测 64 处），而全仓
`Semantics` / `semanticLabel` 只有 **3 处**、`InkWell` 带 `Semantics` 的 **0 处**。

事实上的后果（查 SDK 源码确认，不是猜）：`InkWell` 把点击交给
`RawGestureDetector(excludeFromSemantics: false)`，它装的是
`_GestureSemantics.assignSemantics`（`packages/flutter/lib/src/widgets/gesture_detector.dart:1591`）
—— 那是**点击动作**（`SemanticsAction.tap`），**不是角色**（`SemanticsFlag.isButton`）。
`Tooltip` 补的是名字（`tooltip` 属性），也不装角色。

所以打开 TalkBack 之后：

- 会话行的读法是一串字（标题、预览、时间），但**不会说"按钮"**；
- 纯图标钮（顶栏、侧栏、输入栏的模型/权限 chip）**连字都没有** —— 只有一个 tooltip，
  而 tooltip 与 label 在朗读器里不是同一件事；
- 用户要靠"随便双击一下看会发生什么"来用这个 App。

`proposed/2026-09-30-experience-first-three-layer-split.md` 把"无障碍"明确列进了
**体验触发点**（与首帧、掉帧、崩溃、后台限制并列），但这条从来没落到代码。

## Decision

**只加角色，不改任何视觉/布局/手势。** `Semantics` 在标注模式（`container: false`）里
把属性并到子节点上，不影响 RenderObject 树的大小与命中区。

这一批覆盖**纯图标钮 + 会话抽屉的行**（用户每天要点几百次的那几处）：

| 位置 | 改动 |
|---|---|
| `ui/dsh_app_bar.dart` `DshAppBarButton` | `Semantics(button: true)` 包住 tooltip 那一层 |
| `ui/session_drawer.dart` `_Ib`（抽屉头部图标钮） | 同上 |
| `ui/side_pane.dart` `_Ib`（侧栏图标钮） | 同上 |
| `ui/dsh_composer.dart` `_RoundIconButton` / `_IconChip` / `_SendButton` | `button:` + `enabled:`（这三处真有禁用态） |
| `ui/session_drawer.dart` `_SessionRow` | `Semantics(button: true)` + `key: session-row-<sid>` |
| `ui/session_drawer.dart` `_DrawerMenuItem` | `button: enabled`（边界项点不动，就不该被念成按钮） |
| `ui/session_drawer.dart` 展开其余 N 个 | `button: true` |

**行的文字保持原样，不合并节点**。两个显而易见的写法都被否了：

- `MergeSemantics`：会把行尾「…」菜单一起合进同一个语义节点，**菜单就摸不到了**；
- `Semantics(excludeSemantics: true)`：同样吞掉行尾按钮，还顺带吞掉预览与时间。

判据是 `app/test/tappable_semantics_test.dart` 的 5 条（写完先跑红再改绿）：

1. 会话行的节点是 `isButton` 且 `hasTapAction`，label 里仍有标题；
2. 行尾「…」**仍是独立可点节点**（这条保护的正是 1 的写法没把菜单压扁）；
3. 菜单项「取消置顶」是按钮，「上移」（边界、不可点）不是；
4. 顶栏纯图标钮是按钮，且 tooltip 就是它的名字；
5. 「展开其余 N 个会话」是按钮。

**变异校验**（不是只跑一次绿）：把 `_SessionRow` 的 `button: true` 删掉，
第 1 条用例立刻红（`Expected: flags: isButton / Actual: ...`），恢复后回绿。

## Alternatives considered

1. **整行 `MergeSemantics`**
   - 最强的理由：朗读器会把整行当成一个对象念，体验最接近原生列表。
   - 为何被否：行尾「…」是这一行唯一的菜单入口，被合掉之后**朗读器用户无法归档/置顶**
     —— 用"多念几个字"换"一个功能不可达"是亏的。真要做，得先把菜单移出合并范围，
     那是改结构（当前 `InkWell` 包着整行含菜单），不属于这批。
2. **抽一个 `DshButton` 包装 widget 统一这几个位置**
   - 最强的理由：同一段 `Semantics` 写在 7 处，将来判据变了一次改。
   - 为何被否：`Semantics(button: true, child: …)` 是框架原语、一行，包装层只会多一次
     跳转而不带来约束力；这 7 处的共同点已经在**用例**里钉住了，比在代码里合并更硬。
     真正会漂的是"以后新写的可点区忘了加"—— 那要靠门禁，不是靠包装。
3. **这一批就把 64 处全补完**
   - 最强的理由：一次到位，不留半成品。
   - 为何被否：其余位置分布在各屏，需要逐个判断"这个可点区该念什么"（有的带文字、
     有的纯图标、有的本身是声明式的）。一次性改 60 处而没有门禁兜住，下一轮又会退回原样。
     先覆盖每天点几百次的那几处，剩下按屏推进。

## Consequences

- 收益：TalkBack 用户第一次能听到"按钮"，并且**纯图标钮有了名字**（顶栏/侧栏/发送键）。
  这不是"更规范"，是这个 App 对一组用户从"不可用"变成"可用"。
- 收益：`app/test/tappable_semantics_test.dart` 把这条判据变成可执行的 —— 以后谁把
  `Semantics` 删掉，用例会红。
- 代价：新增 5 条用例（1807 → 1812），并给 `_SessionRow` 加了一个 `session-row-<sid>` 的 key
  （只为定位，不参与布局与命中）。
- 未做：**没有机械门禁**。`verify-*.mjs` 里没有一条能判"这个可点区该不该有角色"——
  它的判据是"这个名字念出来能不能让用户知道会发生什么"，是语义判断。
  已知缺口：其余约 50 处自绘可点区（对话框行、设置行、时间轴、插件页）仍未带角色。
  推进方式：按屏补，每补一屏就加一条 `isSemantics(isButton: true)` 用例。
- 未做：`liveRegion`（流式输出的朗读）。它涉及"念到什么密度才算合适"，需要真机上用
  朗读器调，属于另一个决定面。
