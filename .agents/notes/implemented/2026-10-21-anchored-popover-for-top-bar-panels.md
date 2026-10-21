# Agent Note: 顶栏触发的面板改成锚定浮层 —— 「跟手」是一条可量的判据

Status: implemented

## Problem

用户 2026-10-21 在真机上当场指出（原话）：

> 点击切换智能体的弹出抽屉，点击在上面，下面弹出你不觉得不跟手吗？差太远了吧？
> 这个 APP 还有多少这个种不跟手的操作习惯？你这个距离太远用户体验不好。

具体形态：点的是**顶栏标题**（y≈177），面板从**屏幕最底部**升起来（y≈1736 起）——
视线要跨过 1500+ px 去找结果。第一版的理由是"手机没有 hover，300dp 的抽屉已经承担了目录"
（`docs/subsystems/subagent-page.md` §4 的"有意偏离 2"），但那条理由只解释了**为什么不用
Web 的浮层下拉**，没有解释**为什么要用底部 sheet** —— 两者不是同一个问题。

## Decision

**按触发点位置选形态，并把它写成可量的判据**：

| 触发点 | 形态 |
|---|---|
| 顶栏 / 屏幕上半部 | 锚定浮层 `showDshPopover`（`app/lib/ui/dsh_popover.dart`） |
| 输入栏 / 屏幕下半部 | 底部 sheet `showDshSheet`（拇指本来就够得着） |

「切换子智能体」改为锚定在标题正下方的 360dp 卡片：120ms 淡入 + 8px 位移，
下方放不下就翻到上方，整块永远在屏内（`left` 夹在 `[12, 屏宽-宽-12]`）。

判据（机械、进测试）：`panel.top - crumb.bottom < 80` 且水平偏移 < 80
（`app/test/subagent_enter_test.dart` 的「头部条：点标题开…面板」那条）。
"看起来还行"不算判据——**触发点矩形与面板矩形的距离**才算。

## Alternatives considered

1. **保留底部 sheet，只把动画改快**
   - 最强的理由：零结构改动，用户抱怨的"慢"可能只是动画。
   - 为何被否：抱怨的是**位置**不是速度（"差太远了吧"）。动画再快，视线仍要
     跨大半屏；而"从哪长出来"是位置问题，改速度治不了。
2. **用 `showMenu` / `PopupMenuButton`（Material 自带锚定菜单）**
   - 最强的理由：官方控件，锚点、避让、点击外部关闭都是现成的。
   - 为何被否：它只收 `PopupMenuItem`（等高文本行）。这里的内容是**目录树**
     （带展开按钮、活动点、token 列、当前行加粗），塞不进菜单项；
     硬塞等于把树压成一列文本，把刚做好的行规格丢掉。
3. **自绘 OverlayEntry + `CompositedTransformFollower`（LayerLink）**
   - 最强的理由：跟随最精确（锚点移动时面板跟着动）。
   - 为何被否：要自己管插入/移除/遮罩/返回键，四件事都得与 `Navigator` 对齐；
     而 `showGeneralDialog` 已经给了"点外部关闭 + 返回键关闭 + 结果回传"，
     锚点在这里是**一次性的矩形**（顶栏不会在面板开着时移动）。
4. **顺便把抽屉里的行长按菜单也改成锚定浮层**
   - 最强的理由：同一类问题，用户问的正是"还有多少这种"。
   - 为何被否（本轮）：那一处有 4 项 + 禁用态 + 二次确认（归档会接「停止并归档」），
     改成浮层要连带改 `session_drawer_test.dart` 与原型 `verify-drawer.mjs` 的
     落点断言。先把它记进 `tools.md` 的 Pitfalls 与验收表（**同一类，未改**），
     不在一轮里同时动两处交互。

## Consequences

- 收益：点哪出哪。子会话里"我在哪 / 能切到谁"不再需要一次视线长跳。
- 代价：多了一个面板原语（`dsh_popover.dart`，约 140 行）要维护；
  它的 `Material` 外壳是**必需的**（面板里放 `InkWell`，没有 `Material` 祖先会在
  build 期抛 "No Material widget found"，整块面板连同行文字一起消失 —— 换形态时当场踩到，
  两条 sheet 用例红了）。
- 代价：`ChatAppBar.onTitleTap` 的类型从 `VoidCallback` 变成
  `void Function(Rect anchor)`。锚点必须由**触发控件自己**量（只有它知道自己在哪），
  所以这个签名变化是对的，但它会打到所有构造点（当前只有 `chat_page.dart` 一处）。
- 仍未改（同一类问题，已在 `tools.md` 的 Pitfalls 里登记）：抽屉里的**会话行长按菜单**
  仍是底部 sheet；用户若也要改，走同一个原语即可。
- 验证：`app/test/subagent_enter_test.dart` 的锚点断言（`panel.top - crumb.bottom < 80`）；
  真机截图 `b06-popover.png`（面板顶边贴在标题下方）。
