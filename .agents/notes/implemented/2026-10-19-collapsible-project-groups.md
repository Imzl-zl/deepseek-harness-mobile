# Agent Note: 侧边栏会话列表按项目折叠（照 DSH Web，rikkahub 没有）

Status: implemented

## Problem

用户 2026-10-19 原话：「哦还有这个侧边栏会话列表，人家的每个项目的会话可以
折叠的，你没有啊」。

## 调查：**"人家的"指 DSH Web，不是 rikkahub**

这是本次唯一一条**两个参考仓库答案相反**的反馈，值得记：

- **rikkahub 没有可折叠的项目分组**：文件夹是**一排横向筛选 chip**
  （`D:\sudy\github\rikkahub\app\src\main\java\me\rerere\rikkahub\ui\pages\chat\ChatDrawer.kt:789-856`
  的 `FolderBar`，`LazyRow`），点 chip = **筛选**，不折叠；
  会话列表只有不可折叠的 `DateHeader` / `PinnedHeader` section header
  （`ui/pages/chat/ConversationList.kt:178-223`），无箭头、无会话数。
- **DSH Web 有**：`packages/client/ui-workspace/src/client/rows/WorkspaceBrowser.tsx`
  - `:281` `setGroupExpanded: (key, expanded) => void`
  - `:370-380` `expandedGroups`
  - `:394` `foldedKeys`；`:397` `if (foldedKeys.has(owner)) return true`
    —— **折叠的组会把子组也藏掉**
  - `:484` `group.expanded ? children.map(...) : []` —— 折叠不渲染子行
  - `:564-565` 点组头 toggle
  - `:640-660` **溢出行**：折叠时显示
    `t('sessions.expand', { n: visible.hiddenCount })`
  - 组头形态：`rows/Rows.tsx:259-263` —— 展开 `IconFolderOpenRegular`、
    折叠 `IconFolderCloseRegular`、右侧 `IconTriangleRightFillRegular`
    （展开时旋转）；`:247` `aria-expanded`
  - `:211,236` `containsCurrentDescendant` —— **当前会话的祖先组即使折叠也高亮**

项目纪律说 DSH 决定业务逻辑，所以照 DSH。

## Decision

新增 `ui/collapsible_group.dart` 的 `CollapsibleGroup`，抽屉与首页内联列表
**共用同一个 widget**（两边看到的必须是同一份列表，这是 2026-10-15 就定下的规则）。

照抄 DSH 的四条：
1. 组头 = 开/关文件夹图标 + 右三角（展开旋转 90°）；
2. **折叠时不渲染子行**（`expanded ? children : []`）；
3. **折叠时显示收着的个数**（DSH 的溢出行）；
4. **当前会话所在的组折叠也高亮**（`containsCurrent`）。

## Alternatives considered（否掉的）

- **照 rikkahub 做横向筛选 chip**：用户明确说"可以折叠的"，而 chip 是筛选
  （点了会**隐藏**别的项目，不是收起来）。且 DSH 有折叠。否。
- **折叠状态落盘**：DSH 是 `setGroupExpanded(key, …)`（内存态）。
  手机侧落盘要知道每个组的稳定 key，而 `WorkspaceGroup` **没有 id**
  （只有 `workspaceId`，见 `model/workspace.dart`）—— 要用 `label` 当 key，
  而用户改个工作区名就全乱了。一期只记"这一次打开期间"，
  笔记在此留痕，将来看 `WorkspaceGroup` 有没有稳定 id 再议。
- **默认全折叠**：那会让用户以为会话少了一半。**缺省视为展开**。

## Consequences

- 收益：侧边栏能按项目收起；折叠时仍知道"这里收着 N 个"与"我在哪个项目里"。
- 代价：`_SessionListInline` 从 `StatelessWidget` 转 `StatefulWidget`
  （要存展开态）；抽屉也多一份 `_expanded` map。
- 测试：`collapsible_group_test.dart` 4 项 —— 展开（组头 + 子行 + 不显示个数）、
  折叠（子行不渲染 + 显示个数）、点组头回调、`containsCurrent` 换色。
  `flutter test 820` 全绿。
- **真机**：展开/折叠、当前会话蓝点高亮、底栏四枚顺序，都验过。
