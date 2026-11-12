# Agent Note: 假入口的两种形态 —— 静默无操作的行、没有名字的图标钮

Status: implemented

## Problem

"假入口"在这个项目里是一个反复出现的教训（用户点下去，什么都不发生、或者发生了别的事）。
2026-11-11 扫全仓又找到两类，都是**无歧义**的（肉眼即可确认，不涉及"该不该有这个功能"的判断）：

### 1. 静默无操作的行：`onTap: () {}`

设置页有 4 行是"电脑侧的真值，这里只读"（当前模型 / 可用模型 / 连接状态 /
provider 拉取失败的原话），它们传的是 `onTap: () {}`。`SettingsRow` 照样画
**行尾箭头 + `InkWell` 水波**，朗读器还报"按钮" —— 一个完整的、承诺"会带你去别处"的
按钮，而它什么都不会做。

同一类还有 `_SettingPickerRow` 的**条件禁用**：`permissionCatalog` / `agentPresetRoster`
没读到（或没连上）时 `onTap` 是 `null`，但箭头无条件画 —— 那一行看起来能点、点不动、
也不说为什么。

### 2. 没有名字的图标钮

纯图标控件里只有字形，没有文字。**`Tooltip` 不是 label**：它给的是 `tooltip` 属性，
而朗读器读的是 `label`。全仓扫下来有两处**连 tooltip 都没有**：

- 会话抽屉行尾的「…」（`session_drawer.dart`）—— 里面只有一个 `ellipsis` 字形；
- 输入栏附件的「×」（`dsh_composer.dart`）—— `GestureDetector`，连水波都没有。

其余图标钮（顶栏 / 侧栏 / composer / 队列 / 目标条 / 代码块工具）都有 `Tooltip`，
是**扫描的假阳性**（我的脚本从 `InkWell(` 那行开始找，`Tooltip(` 在它上面）。

## Decision

1. **`SettingsRow.onTap` 从必填改成可空**：`null` = 纯展示 ⇒ 不接水波、不画箭头、
   不报按钮（`Semantics(container: true)`）。箭头是"会带你去别处"的承诺，没有去处就不画。
   `if (tappable)` 一处判定，三种表现一起走。
2. 4 个 `onTap: () {}` 改成不传。`_SettingPickerRow` 的箭头改成 `if (onTap != null)`。
3. 两处无名图标钮加 `Semantics(button: true, label: …)`（标注模式，不吞子节点 ——
   行尾「…」必须仍是独立可点节点，见 `implemented/2026-11-10-tappable-semantics.md`）。

## 准入判据

`app/test/settings_row_affordance_test.dart` 两条 + `tappable_semantics_test.dart` 加一条断言：

| 判据 | 钉什么 |
|---|---|
| 有去处 | `InkWell` 存在、`chevronRight` 恰好 1 个、节点是按钮且有点击动作 |
| 纯展示 | 没有 `InkWell`、`chevronRight` 为 0、**不是**按钮、**没有**点击动作 |
| 行尾「…」 | 独立可点节点 + `isButton` + label 是那句中文 |

变异校验（**两次都在确认"变异真的改到了代码"之后才算数**）：

- 纯展示也画箭头 → 第 2 条红（`Expected: <0> / Actual: <1>`）；
- 有去处的行不包 `Semantics` → 第 1 条红（缺 `isButton`）；
- 删掉「…」的 label → 第 3 条红（`has semantics with label: …`）。

> 第一次跑这三个变异时**全绿**，原因是我的替换串没匹配上格式化后的代码 ——
> **变异没红时先确认变异真改到了**，别急着去改用例或记"覆盖不到"
> （`tools.md` 的变异校验小节记过同一类坑）。

## Alternatives considered

1. **给纯展示行也保留一个点击（弹一句"这个只能在电脑上改"）**
   - 最强的理由：用户点了至少有反馈。
   - 为何被否：这句提示在**每一行旁边的小字里已经有了**（"提供商与密钥在电脑上改"）。
     再弹一次是把同一件事说两遍，而且把"只读"变成了"可点"—— 语义更糟。
2. **删掉箭头但保留 `onTap: () {}`**
   - 最强的理由：改动最小。
   - 为何被否：水波还在、朗读器还报按钮。假入口的三个表现里改一个，剩下两个照样骗人。
3. **把 60 处可点区一次性都加 `Semantics`**
   - 最强的理由：一次到位。
   - 为何被否：见 `implemented/2026-11-10-tappable-semantics.md` 的同名取舍 ——
     "这个可点区该念成什么"是语义判断，做不成门禁；而**有些**可点区本来就不该报按钮
     （本次就发现 4 行属于这种）。照单全改等于把假入口固化进朗读器。

## Consequences

- 收益：设置页那 4 行不再假装能点；两处纯图标钮在朗读器里第一次有名字。
  行为上**没有任何功能减少** —— 这 4 行的"功能"本来就是空的。
- 代价：`SettingsRow.onTap` 变成可空，调用方少写一个 `() {}` 而不是多写（代码更短）。
- 未做：**没有机械门禁**。"`onTap` 里是不是只有 `{}`"可以 grep，但"这一行该不该可点"
  不能 —— 后者是产品判断。所以这一批靠用例 + review，不靠门禁。
  已扫出的剩余可疑点（`queue_dock` / `takeover` / `settings_page` 的行内图标钮）
  读下来**都有 `Tooltip`**，不是问题。
- 未做：`Tooltip` 与 `label` 的统一。最干净的做法是让"有 tooltip 的图标钮自动获得
  同名 label"，但那要改 5 个共享包装控件（`_Ib` ×2 / `DshAppBarButton` /
  `_RoundIconButton` / `_SendButton`），而这 5 个已经各自带 `Semantics` 了。
  再包一层只会多一次跳转 —— 与 `implemented/2026-11-10-tappable-semantics.md` 的
  "不抽 `DshButton` 包装"理由相同。
