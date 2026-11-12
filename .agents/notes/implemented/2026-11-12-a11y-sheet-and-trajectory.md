# Agent Note: a11y 按屏推进第三批 —— 选择类列表行与轨迹页

Status: implemented

## Problem

`implemented/2026-11-10-tappable-semantics.md` 之后，a11y 的推进方式是"按屏补 + 每屏一条
`isSemantics(...)` 用例"（约 50 处自绘可点区还没带角色）。这一批按"每天点几十次"排到两屏：

### 1. 选择类列表行（`ui/dsh_sheet.dart` 的 `DshPickerRow`）

它是模型 / 权限档 / Agent 预设 / 工作区 / 主机 / 端点 / 设置里那些选择器的**唯一行形状**
（20 处调用），而它**一条 `Semantics` 都没有**。`InkWell` 只装点击动作、不装角色，
"当前项"只画成一个 `check` 字形 —— 朗读器听到的是一行普通文字：

- 不知道**能点**；
- 不知道**它已经是当前项**（字形对读屏用户不存在）；
- 更差的是"正在用的那条连接"这种行：`selected: true` + `enabled: false`（点它没有去处，
  那是重连不是换），既该说"已选中"又**不该**被念成按钮。

### 2. 轨迹页（`ui/trajectory_page.dart` / `trajectory_timeline.dart`）

三件事，性质各不相同：

| 位置 | 现状 | 问题 |
|---|---|---|
| `_TurnRow`（一轮一行） | `InkWell`，无 `Semantics` | 朗读器念完文字就停，不知道能点 |
| `_Track`（时间轴） | 整条轨道一个 `GestureDetector`，无名字 | 语义树里出现一个**无名可点区** —— 假入口的语义版；每一格（段）对读屏用户完全不可达 |
| `_TurnRow` 的行尾箭头 | 无条件画 `chevronRight` | 与 `implemented/2026-11-11-fake-affordances.md` 同形：没有回调也画"会带你去别处"的箭头（`onTapTurn` 为 `null` 时） |

时间轴那一条值得单独说清楚：触摸命中是**按 x 坐标**算的（`segmentAt` + `kTimelineHitSlop`，
因为段只有 3dp 宽，自己收不到点击）。而朗读器的双击是**激活当前节点**，不按坐标、
也不需要 48dp 的身体 —— 所以"一格一个 `Semantics` 节点"正好把这份数据第一次变成可达的。

## Decision

1. `DshPickerRow`：`Semantics(button: enabled, selected: selected)` 包在 `Opacity` 外层。
   两个属性各自表达一件事：**能不能点**与**是不是当前项** —— 勾字形不再是唯一表达。
   禁用行（当前连接）仍是"已选中、不是按钮"。
2. `_TurnRow`：`Semantics(key: ValueKey('trajectory-row-<n>'), button: onTap != null)`
   —— 只加角色，不合并子节点（时间轴里每一格自己还是独立节点）。
3. `_Track`：`GestureDetector(excludeFromSemantics: true)`（手势不再自己造无名节点；
   触摸命中不受影响）+ 每一格 `Semantics(button: onTap != null, label: …, onTap: …)`。
   标签由 `segmentSemanticsLabel` 生成：`工具 bash` / `模型` / 合并格 `工具 等 3 段` /
   失败 `，失败` / 进行中 `，进行中`。**不拼时长** —— 合并格的总时长要手机自己加，
   而本仓的纪律是"用时只读电脑侧算好的数"（`model/trajectory.dart` 文件头）。
4. `_TurnRow` 的箭头改成 `if (onTap != null)`：没有去处就不画箭头（与 `settings_row.dart`
   同一条判据）。

## 准入判据

| 用例 | 钉什么 |
|---|---|
| `app/test/picker_row_semantics_test.dart` 第 1 条 | 选中且可点 ⇒ `isButton` + `isSelected` + `hasTapAction`，label 里有名称**与标签组** |
| 同文件第 2 条 | 当前项（勾着但点不动）⇒ `isSelected` 且**不是**按钮 |
| 同文件第 3 条 | 未选中可点 ⇒ 按钮（`isSelected: false` 与"没有这一位"同义，不做断言，见下） |
| `app/test/trajectory_semantics_test.dart` 第 1 条 | 轮次行是按钮，label 里仍有「第 N 轮」 |
| 同文件第 2 条 | 时间轴一格一个节点、名字说得出类别/工具名/失败；**动作真的到达那一步**（`performAction` 后回调收到 seq 73） |
| 同文件第 3 条 | 没有回调时**不报按钮、不画箭头** |
| 同文件第 4 条 | 行里**没有无名可点区**（遍历子树，凡带 tap 动作的节点 label 必须非空） |
| `app/test/connection_actions_sheet_test.dart` 新增 1 条 | 连接动作行是按钮、label 含副标题（钉"它们走的是 `ListTile`"这个事实） |

变异校验（每条都先 `grep` 确认变异落地）：

| 变异 | 结果 |
|---|---|
| `DshPickerRow` 去掉 `selected: selected` | 第 1、2 条红（`Expected: has semantics with flags: isSelected,…`） |
| `DshPickerRow` 的 `button: enabled` → `false` | 第 1、3 条红，第 2 条仍绿（它本来就断言"不是按钮"） |
| `_TurnRow` 的 `button: onTap != null` → `false` | 轨迹第 1 条红 |
| 段节点的 `label:` 改成 `''` | 轨迹第 2、4 条红 |
| `_Track` 的 `excludeFromSemantics` 改回 `false` | 轨迹第 4 条红（无名可点区回来了） |
| 箭头改成 `if (true)` | 轨迹第 3 条红 |

门禁：`dart format` / `dart analyze --fatal-infos` 0、`flutter test` **1867 项**、
`verify-size` 19 条自检、`verify-platform-boundary` 873 项、`verify-rpc-single-caller`、
`verify-icons`、`verify-tool-paths`。

## Alternatives considered

1. **时间轴整条轨道一个 `Semantics(button: true, label: '过程时间轴')`**
   - 最强的理由：一个节点，读屏用户划过这一段只多一次停顿。
   - 为何被否：它无法给出**一个确定的动作**。轨道的点击要靠 x 坐标选段，
     而语义节点的 `onTap` 没有坐标 —— 只能替用户挑一格，那是编的。
     一格一个节点则是"哪一格 = 哪一步"，动作确定。
2. **每格节点 + 合并所有子节点（`MergeSemantics`）**
   - 理由：一行合成一个对象念起来更顺。
   - 为何被否：会吞掉时间轴的每一格（同 `2026-11-10-tappable-semantics.md` 否掉
     `MergeSemantics` 的理由），而那正是这一批要让读屏用户够得着的东西。
3. **给段的 label 拼上时长**（`工具 bash，20 秒`）
   - 最强的理由：时间轴的语义就是"花了多久"。
   - 为何被否：合并格要手机自己把多段时长加起来，而本仓禁止在 `app/lib` 里做这类时间统计
     （`model/trajectory.dart` 文件头：用时只读电脑侧算好的数）。时长在点开后的 sheet 里
     逐段列着，那里是现成的。
4. **把"未选中"也写成断言**（`isSemantics(isSelected: false)`）
   - 最强的理由：三态（选中 / 未选中 / 不参与选择）都该有用例。
   - 为何被否：`isSelected: false` 与"节点没有这一位"在 matcher 里**同义**，
     变异校验证明它不会因删掉 `selected:` 而红 —— 一条分不出两种情形的断言是装饰。
     留着的那两条（选中 / 非按钮）才是有判据的。

## Consequences

- 收益：20 处 `DshPickerRow` 调用点一次全部获得角色与选中态（它们共用这一个行形状）；
  轨迹页的两处可点区第一次对读屏用户可达，并且**未命名的可点区没了**。
- 收益：`_TurnRow` 的箭头从此与"有没有去处"绑定，与 `SettingsRow` 同一条判据 ——
  "有箭头、点不动"在这两处都不会再出现。
- 代价：时间轴多出的是 `Semantics` 节点，个数 = **画出来的格数**（已按
  `kTimelineMinSegmentWidth` 合并，见 `trajectory_timeline.dart` 文件头），一轮通常几条到
  十几条。极宽屏 + 上百步时会偏多；那时真正的解法是分页或"只看失败"，不是撤掉语义。
- 代价：`_Track` 的手势不再进语义树（`excludeFromSemantics: true`）—— 触摸命中与视觉
  一点没变（`Listener` 仍在），但"整条轨道作为一个可点区"这件事在语义树里不存在了，
  它是被**每一格**替代的。
- 未做：其余屏（插件页、设置页的行内图标钮、用量页）仍未覆盖；按
  `2026-11-10-tappable-semantics.md` 的口径继续按屏推进，不一次改完 50 处。
- 未做：仍**没有机械门禁**。"这个可点区该念成什么"是语义判断，做不成规则；
  防回归靠的是每屏那条 `isSemantics` 用例。
