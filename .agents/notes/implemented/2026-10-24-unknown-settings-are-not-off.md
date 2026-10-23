# Agent Note: 没读到 ≠ 关 —— 设置页的「上传 Session Log」不再把"不知道"画成一个状态

Status: implemented

## Problem

断开桌面时，设置页里 `新会话默认权限` / `新任务默认模式` / `电脑侧 DSH 版本` 三行显示"未读到"，
而 `上传 Session Log` 那一行**显示成一个关着的开关**：

```dart
// 改之前
value: app.settingsValue('session-log-deepseek', 'enabled') == true,   // null == true ⇒ false
```

`settingsValue` 在没读到那个 ns 时返回 `null`，而 `null == true` 是 `false` —— 界面于是给出一个
**从未读到过的具体状态**。`onChanged` 那一侧本来就已经判过 `settingsOf(...) == null`（开关不可点），
所以页面上是一个"灰色但写着关"的开关：用户看到的是"这项被关掉了"，而事实是"这项没读到"。

这正是 `memory.md` 第八条教训（生产路径上的假数据）的同一形状，与旁边三行的口径不一致。

## Decision

**未读到时不出开关，trailing 写"未读到"** —— 与旁边三行同一个口径。

- `_SettingSwitchRow.value` 的类型从 `bool` 收成 `bool?`；`null` 走另一条渲染分支（普通 `ListTile`，
  保留 icon / label / note，trailing 是"未读到"），**不出现开关控件**。
- 调用点显式把"读面缺失"翻译成 `null`，而不是让 `== true` 去猜：
  `app.settingsOf(ns) == null ? null : app.settingsValue(ns, 'enabled') == true`。
- 判据的口径是**控件存在性**，不是颜色：未读到那一行里 `Switch` 必须**不存在**（`findsNothing`）。

## Alternatives considered

1. **保留开关但置灰（`onChanged: null`）** —— 这是改动前的形态，代价最小（0 行）。
   被否：置灰只说明"点不动"，画出来的位置仍然在说"关"。用户不会从灰色里读出"没读到"，
   而旁边三行已经在说"未读到"了 —— 同一个页面两种语言。
2. **复用 `_PrefRow`（trailing 值 + chevron + 可点）** —— 与三行完全同构，最"统一"。
   被否：它会丢掉这一行的 `note`（"只在使用官方模型 API 时生效"），而那句是这项设置**唯一**的
   生效范围说明；并且 chevron 暗示"点进去有东西"，而这里点进去没有页面。
3. **整行隐藏** —— 被否：用户会以为"这项被删了/不支持"，比"未读到"更误导。

## Consequences

- **收益**：页面上四种状态（读到开 / 读到关 / 未读到 / 点不动）不再混在一起；`session-log-deepseek`
  的读面缺失时，用户看到的是"未读到"，与其它电脑侧设置一致。
- **代价**：这一行的高度与布局在"未读到"分支里与开关分支不完全一致（`ListTile` vs `SwitchListTile`
  的最小高度差约 0）；`note` 在未读到分支照常显示，所以两态高度实测一致（widget 测试未断言像素，
  真机观感留观）。
- **没有新存储、没有新契约**：`settingsValue` 的 `null` 语义本来就存在，这次只是不再把它折叠成 `false`。

## 判据

`app/test/settings_sync_test.dart`：

- 新增 `没读到那个 ns：不画开关，写"未读到"` —— `_Client(includeSessionLog: false)` 让
  `settings.describe` **不回**那个 ns；断言 `settingsValue(...) == null`、行内 `Switch` 为 `findsNothing`、
  trailing 文本是"未读到"。
- 同一文件的第一条用例补**对照组**：读到时开关照常存在（`findsOneWidget`）—— 防止"开关永远不出"
  被当成修好了。
- **变异校验**（做完即还原）：把调用点改回 `settingsValue(...) == true` ⇒ **恰好**那一条新用例红
  （`findsNothing` 命中了一个 `Switch`），对照组仍绿。

门禁：flutter **1144 → 1145**、boundary **360**（无新文件）、`dart analyze --fatal-infos` 0、
`dart format --set-exit-if-changed` 0。

## 代码入口回指

`app/lib/ui/settings_page.dart` 的 `_SettingSwitchRow`（`value` 收成 `bool?`）与 `会话` 段里那个调用点。
