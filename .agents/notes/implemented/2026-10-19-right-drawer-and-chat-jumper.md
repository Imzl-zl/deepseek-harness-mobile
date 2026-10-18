# Agent Note: 右抽屉改真抽屉 + 对话流快速跳转钮（rikkahub MessageJumper）

Status: implemented

## Problem

真机反馈（2026-10-19，用户原话）：

> "然后就是这个右侧侧滑就是文件，子智能体那几个的，我觉得左右都可以全局侧滑，
> 往哪边就打开哪边，然后右侧的我感觉做成抽屉好看点，因为这个滑动也就看下
> 现在这样直接换页了感觉怪怪的"
> "然后就是 rikkahub 滑动右侧还有快速滚动的按钮那些，就是能直接到顶，直接到底，
> 还有两个我没用不确定的，你可以看看"

两件事：

1. **右抽屉铺满整屏**：`endDrawer: Drawer(width: MediaQuery.sizeOf(context).width)`
   —— 从右缘滑入后盖住一切，读作"翻到另一页"而不是抽屉。
2. **没有快速跳转**：长会话（真机上这个会话 24 轮 575 步）要划很久才能回到开头。

## Decision

### 1. 右抽屉改成真抽屉

`Drawer(width: _sideDrawerWidth(context))` + `shape: RoundedRectangleBorder(左侧两角圆)`
+ `SidePane(fullscreen: false)`（圆角与左边框交给它画）。

两个宽度按面板分工：**文件 92%**（diff 预览要宽度）、**任务 / 子智能体 78%**
（一行 `label + kind + 状态 + 时长` 放得下，窄一些让下层露得更多）。下限 300。

DSH 的对应规则是 `fullscreen ? 100vw : width`，且
"Below 768px fullscreen is derived from viewport width"
（`ui-sidebar-right/src/client/shell/SidebarRight.tsx:5-7,310`）——
手机上走全屏是它的**派生默认**，而它同时保留 manual mode。
触屏上用户要抽屉感，所以按 manual mode 走，并在笔记里记下这是有意偏离。

### 2. 快速跳转钮（`ui/chat_jumper.dart`）

逐条对照 rikkahub 源码（`app/src/main/java/me/rerere/rikkahub/ui/pages/chat/ChatList.kt`）：

| 项 | rikkahub | 我们 |
|---|---|---|
| 四个钮与顺序 | `:769-839` 的 ArrowUpDouble / ArrowUp01 / ArrowDown01 / ArrowDownDouble，`spacedBy(8.dp)` | 同序，`SizedBox(height: 8)` |
| 显隐 | `:513` 的 `isRecentScroll && !isScrollInProgress && showMessageJumper` | `_recent`（滚动后真、停 1.5 s 假） |
| "最近滚动过" | `:293-302` 的 `LaunchedEffect(isScrollInProgress)` + `delay(1500)` | 同一时长；每次滚动重置计时 |
| 半透明底 | `:777-779` 的 `copy(alpha = 0.65f)` | `DshColors.layer2.withValues(alpha: 0.65)` |
| 左右可选 | `:514` 的 `messageJumperOnLeft` | `onLeft` 参数（默认右） |

用户说的"两个没用不确定的"经查源码确认是**上一条 / 下一条**，且是
**按条目挪**（`:791` 的 `animateScrollToItem(firstVisibleItemIndex - 1)`）——
不是按像素：一条可以占满一屏（长 diff / 长输出），按像素只会在这条内部滑。

### 3. "跳到一个 index"不猜高度

Flutter **没有**"跳到第几条"的 API（SDK 只有 `animateTo(offset)`）。
两条路：

- **估平均高度再跳**：`extent / itemCount * index` —— 条目高度不定
  （一条消息可能 3 行也可能 300 行），差一点就偏出半屏。**否掉**。
- **官方自己的做法**：`material/popup_menu.dart:997` 的
  `Scrollable.ensureVisible(itemKeys[selectedIndex].currentContext!)` ——
  每条目一个 `GlobalKey`，用 element 的 context 让它滚进视口。**采用**。

`reverse: true` 下的方向（都写在代码注释里）：offset 0 是**最新**一端，
`maxScrollExtent` 是**最早**一端；"上一条" = index **+1**（更早）。

### 4. 图标：到顶 / 到底用带文字的胶囊

DSH 图标集里**没有**"双上箭头 / 双下箭头"（只有 `chevronUp` / `chevronDown` /
`chevronsUpDown`），而两枚同图标的钮用户分不出哪个是哪个。
`verify-icons.cjs` 只放行集合内的 100 个名字，不能新造字形 ——
所以这两枚带文字（「最早」/「最新」，11px），另外两枚纯图标。
（2026-10-19 同一天为这个门禁红过两次：`'model'` / `'file'` 都不在集合里。）

## Alternatives considered（否掉的）

- **右抽屉仍全屏，只加圆角**：用户明说"直接换页感觉怪怪的"，圆角救不了
  "盖住一切"这个形态。
- **快速跳转做成"回到最新"一颗钮**：用户点名要"直接到顶、直接到底"两个端，
  而"上一条 / 下一条"是查源码后发现的第三个能力（按条目浏览）。
- **跳转用估算高度**：见上，条目高度不定，那是猜。
- **跳转钮常驻右侧**：它浮在对话流上会挡住文字；rikkahub 也是滚动后显示、
  停 1.5 秒淡出。淡出时还要 `IgnorePointer` —— 否则出现"看不见但挡着手"的鬼钮。

## Consequences

- 收益：右抽屉读作抽屉（露出的下层会话 + 左圆角）；长会话能一键到顶 / 到底、
  按条目逐条看。
- 代价：`ChatJumper` 是新控件（+`ChatJumperController` 公开接口，为的是
  调用方不必 dynamic 调私有 `State` —— `avoid_dynamic_calls` 过不了
  `--fatal-infos`）；`_ChatTab` 里多一层 `_ConversationFlow`（持
  `ScrollController` 与每条目 `GlobalKey`）。
- **边界尺寸**：抽屉宽度两个比例 + 下限 300（再窄下去顶栏的关闭钮与行内钮
  会挤成一团）。跳转钮 36×36（够手指点）、间距 8。
- 测试：`chat_jumper_test.dart` 5 项（四动作 / 空会话不占位 / 没滚过透明且
  点不到 / 滚一下显示再淡出 / 淡出后点不到）。`AnimatedOpacity` 与
  `IgnorePointer` 都加了 Key —— `find.byType` 在整棵树上不唯一，
  用例会撞 "Too many elements"（实测踩到）。
