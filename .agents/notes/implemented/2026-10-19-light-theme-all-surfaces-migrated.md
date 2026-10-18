# Agent Note: 浅色主题收尾第三批（剩余 13 个面全部迁完 + 三个脚本坑）

Status: implemented

## Problem

第二批后仍有 13 个面直接写 `DshColors.x`（浅色下不跟随）：`dsh_app_bar` /
`dsh_state_dot` / `edge_stick` / `side_pane` / `queue_dock` / `dsh_markdown` /
`takeover` / `settings_page` / `dsh_sheet` / `connection_summary_block` /
`connection_actions_sheet` / `archive_sheet` / `trajectory_page`。

## Decision

同一套迁移法（`DshColors.x` → `c.x`，`c` 在每个 build / 方法开头取），
三类位置单独处理：

### 1. 私有 helper 方法（拿不到 context）

`dsh_state_dot._solidColor`、`settings_page._EndpointRow._statusOf`
改成**传参**（`Color _solidColor(DshColorTokens c)`）—— 与"色板只有一个真值源"
不冲突，值仍然来自 `DshColorTokens`。调用方（build）传 `c` 进去。

### 2. 顶层函数（`showDshSheet` / `showArchiveSheet`）

箭头函数体（`=> showModalBottomSheet(...)`）改成**块体**，在块里取 `c`。
`showArchiveSheet` 的 `builder: (context, _) {...}` 闭包里也取一份
（闭包的 context 是 builder 的参数，不是外层的）。

### 3. enum 字段值（`TraceKind`）

`trajectory_page.dart` 的 `TraceKind` 把 `Color` 存在 enum 字段里 ——
enum 字段是编译期常量，放不了运行时色值。改成
`Color colorOf(DshColorTokens c)` 方法（用时取），图标与标签留字段
（它们不随亮暗变）。

## 三个脚本坑（都实测踩到，下一批别再踩）

1. **按字符偏移插入会全盘错位**：第一版迁移脚本记录 `Widget build(` 的
   字符偏移，而 `DshColors.` → `c.` 的替换改变了长度，后续偏移全部失效 ——
   把方法体里的行也改坏（19 处编译错误）。**改成按行号记录、从后往前插**。
2. **`const ` 的长度是 6 不是 7**：`deconst4.mjs` 写 `constStart + 7`，
   把类型名首字母吃掉（`const BoxDecoration(` → `oxDecoration(`），
   报 `The method 'oxDecoration' isn't defined`。**修正版按
   `m[0].length - m[1].length - 1` 算**（匹配全长 − 类型名 − 左括号）。
3. **别给不用色板的方法插 `c`**：会触发 `unused_local_variable`。
   脚本按"后续 200 行内出现 `c.`"判断，仍然误判了 5 处（跨方法边界），
   最后靠 `dart analyze` 的 warning 列表逐个删。

## Consequences

- 收益：浅色主题覆盖**全部 UI 面**。真机验证：hero 白底深字、徽章浅蓝、
  顶栏变浅、输入栏白底、侧栏白底深字。
- 代价：约 100 处 `const` 被去掉（性能无关紧要 —— 都是每帧重建的 widget）。
- `DshColors` / `DshLightColors` 两个 const 类仍然是色值的唯一出处；
  `DshColorTokens` 只做"选一套"。核对 DSH 源码时仍然只有两处。
- **下一步（可选）**：`app/lib` 里已无 `DshColors.` 的直读（除 theme 层自身），
  浅色主题这条线可以收了。剩下的大议题是用户点名的**用量统计汇总**
  （要连接器加聚合能力）与**输入栏重设计**。
