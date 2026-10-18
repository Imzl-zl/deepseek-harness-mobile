# Agent Note: 浅色主题收尾第一批（侧栏迁到 ThemeExtension）+ 主题偏好持久化修竞态

Status: implemented

## Problem

上一批（`8dd5f5f`）把两套色板与三档模式落地了，但**UI 的 250 处
`DshColors.x` 仍读深色常量** —— 浅色下这些位置不跟随。真机复现：切到浅色后
设置页与主界面变了，**侧栏还是深底**（用户会看到"一半浅一半深"）。

同时发现一个**真 bug**：切到浅色后重启 App，主题被打回"跟随系统"
（手机系统是深色 ⇒ 又变深色）。根因是 `initState` 里两条 `unawaited` 并行：

```dart
unawaited(_boot());        // 建 AppModel（持着库）
unawaited(_restoreTheme()); // 从 AppModel 读偏好 —— 此刻 _app 还是 null
```

`_readPreference` 在 `_app == null` 时返回 null，于是主题恢复读到空值、
按默认走。用户选的值每次重启都被打回。

## Decision

### 1. 侧栏迁到 `context.dshColors`

`session_drawer.dart` 的 30 处 `DshColors.x` → `c.x`，`c` 在每个 `Widget build`
开头取（`final c = context.dshColors`）。

**为什么用脚本扫而上次失败**：第一版脚本按 `Widget build(` 的偏移插入取值行，
但替换改变了字符串长度、后续偏移全部失效 —— 结果把方法体里的行也改坏
（19 处编译错误，回滚）。第二版改成**先按行切分、记录每个 build 的行号、
再从后往前插入**（行号不受前面替换影响），并且**只在该方法体里真的出现 `c.`
时才插**（否则 `unused_local_variable` 会红）。

`const` 上下文要单独处理：`const TextStyle(color: c.labelPrimary)`、
`const BoxDecoration(border: BorderSide(color: c.layer1))`、
`const DshIcon(color: c.labelTertiary)`、`const LinearGradient(colors: [c.…])`、
`const RoundedRectangleBorder(side: BorderSide(color: c.layer1))`、
`const InputDecoration(hintStyle: TextStyle(color: c.…))`、
`const Center(child: Text(style: TextStyle(color: c.…)))` ——
这些地方的 `const` 全部去掉（运行时色值进不了 const 构造）。
`BorderRadius.only(...)` 那部分是纯数值，可以保留 const。

### 2. 主题恢复排在 `_boot` 之后

```dart
unawaited(_boot().then((_) => _restoreTheme()));
```

主题恢复要从 `AppModel` 读偏好，而 `_app` 是 `_boot()` 建的 ——
**依赖关系不能并行**。`setThemeMode` 的顺序本来就是对的
（先 `_theme.setMode` 立即生效，再落盘），不用改。

## Alternatives considered（否掉的）

- **脚本全文替换 `DshColors.` → `c.` 后在每个 build 无脑插取值**：上一版实测
  会把方法体里的行改坏（偏移失效），且给不用色板的 build 插无用变量。否。
- **把 `DshColors` 改 getter + 全局开关**（一次性解决 250 处）：226 处 const
  编译错误，`8dd5f5f` 的笔记里记过。否。
- **主题改存 `PairingStore` 而不是 `meta` 表**：它与其它偏好（发送模式 /
  工作步骤展示）是同一类"只影响这台手机"的设置，而那些都在 `meta` 表。
  分两处存会让"清凭据时该不该清主题"变成要猜的问题。否。

## Consequences

- 收益：浅色主题第一次在**侧栏**上也对；主题选择重启后仍在。
- 代价：`session_drawer.dart` 少了 12 处 `const`（性能上无关紧要 ——
  这些都是每帧重建的 widget，const 的收益在 `Drawer` 这种一次性结构上）。
- **仍未迁的面**：`chat_page` / `chat_turns` / `dsh_composer` / `side_pane` /
  `queue_dock` / `dsh_markdown` / `takeover` / `settings_page` / `dsh_sheet` /
  `connection_*` / `archive_sheet` / `conversation_hero` / `dsh_state_dot` /
  `chat_jumper` / `edge_stick` / `dsh_app_bar` / `trajectory_page`。
  浅色下这些位置仍是深色 —— **这是已知未做，不是回归**。
- 迁移方法（下一批照这个做）：跑第二版脚本 → `dart analyze` 看剩几处
  `Invalid constant value` → 逐个去 const → format + analyze + 截图对比。
