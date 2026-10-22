# Agent Note: 抽屉拖拽 —— 插入线、扫到即显示、松手提交最后扫过的那一格

Status: implemented

## Problem

用户原话：「web 人家拖拽移动的时候会有一个线标记到哪个位置了，上下都可以移动，
你这个移动我往上不动，就是有时候都不动」。

现状三处不足（都在 `app/lib/ui/session_drawer.dart`）：反馈只有"整行变底色"；
"不会改变顺序"的落点**直接拒绝**（`onWillAcceptWithDetails` 返回 false ⇒ 屏幕上一点反馈都没有）；
只在 `onAcceptWithDetails` 里提交，松在空白 / 行间 = 什么都不发生。

### 探针（先测再改，未猜）

`_SessionDragState.onWillAcceptWithDetails` 里临时打 `debugPrint`（带 `details.offset`、
算出来的行矩形与 anchor）。真机 `d61cf622` 长按第二行、往**上**拖一次，日志只有两条：

```
PROBE target=GthgIiCkbWJnO3znqoV7Xw drag=GthgIiCkbWJnO3znqoV7Xw dy=553.9 row=521.6..586.6 after=false anchor=null order=2 canMove=true
PROBE target=tIxSCa_6lGMOTAGV2Y63SQ drag=GthgIiCkbWJnO3znqoV7Xw dy=495.2 row=456.6..521.6 after=true  anchor=null order=2 canMove=true
```

（`dy` / `row` 是逻辑像素；row 那两行就是"上一行"和"自己"。）

判定：**分支 ②**"进了 `onWillAccept`，但 `beforeSid` 算成原地" —— 而且比这更糟：
第二条日志之后**再也没有回调**。根因在框架：
`DragTarget.onWillAcceptWithDetails` **只在指针进入目标时**问一次
（`packages/flutter/lib/src/widgets/drag_target.dart:752-774` 的 `didEnter`），
在目标内继续移动只走 `onMove`（`:804-808` 的 `didMove`）。
往上拖时指针必然从**下方**进入上一行 ⇒ 那一瞬永远是"下半 ⇒ 插到它后面 ⇒ 位置没变"，
之后移到上半不会再问 —— 于是"往上不动"，且因为被拒，连整行底色都不给。

## Decision

1. **`onWillAcceptWithDetails` 只回答"能不能落"，与指针落在哪一半无关**：
   同一组（`order.contains(data.sid)`）、同一置顶分区、不是自己。
2. **落点（上半/下半）改到 `onMove` 里持续算**，更新一个 `ValueNotifier<_DropMark?>`
   （抽屉一份 `_DropHover`）：谁被扫到、落在它上边还是下边。插入线由这个 notifier 驱动，
   **不重建整棵树**（行内容作为同一个 widget 实例复用）。
3. **插入线照 DSH**：12px 带子画在落行 `top: -8px` / `bottom: -8px`；左端 5×7 的「〈」
   （55°/125° 两条斜线）+ 从 `x=4px` 起的 2px 横线；颜色 `businessBlue`
   （= `--dsw-alias-state-business-primary`）。出处
   `ui-workspace/src/client/rows/WorkspaceBrowser.module.css:451-493`。
4. **松手提交"最后扫过的那一格"**：`LongPressDraggable.onDragEnd` 里
   `if (!details.wasAccepted) hover.commitLast()` —— 松在空白、行间、抽屉底栏都算数
   （DSH `ui-workspace/src/client/WorkspaceBrowser.tsx:618` 的 `commitSessionDrag(drag, drag.over)` 同一条）。
5. **项目头（工作区）与会话行走同一套**：它们本来就是两套 `DragTarget`，
   现在共用同一个 `_DropHover`（同一时刻只可能有一次拖动），标记与提交语义一致。

## Alternatives considered

1. **换 `SliverReorderableList`（框架自带自动滚 + 让位动画）**
   - 最强理由：自动滚动、跨行命中、让位动画全部白拿，代码能少一半；
     `settings_page.dart:434` 已经在用它排端点。
   - 为何被否：它的指示器是**"让出空隙"**，而 DSH 是**一条线**；抽屉里还是"组头 + 会话"
     两层可拖，`SliverReorderableList` 只认一条扁平列表 —— 换过去会先把"组头也能拖"做丢。
     本轮的目标是"与 Web 同构的反馈"，不是"最省代码"。
2. **保留 `onWillAccept` 里算落点，改成每次 `onMove` 用 `setState` 触发重新问一次**
   - 最强理由：改动最小，锚点仍只在一处算。
   - 为何被否：`didEnter` 只在进入时调用，`setState` 不会让它重问；而"让 `onWillAccept`
     返回 true 再在 `onAccept` 里纠正"就是方案 3 的做法，绕一圈只是把同一件事写得更难读。
3. **插入线用 `Overlay` 画在整屏上（跟 DSH 的绝对定位一致）**
   - 最强理由：不受行 / 列表裁剪影响，最顶上那条 `listTopDropIndicator` 也能画。
   - 为何被否：要自己算每一行的全局矩形、并在滚动时同步（抽屉随时可能滚）。
     行内 `Stack(clipBehavior: Clip.none)` 只有一处代价：第一行上边的线贴到列表顶会被裁一截。

## Consequences

- 收益：往上、往下、松在空白三种路径都成立；过程中**始终看得见**要插到哪（真机截图
  `shots-2026-10-22/f3-mid-drag-line.png`：蓝线 + 左端「〈」画在落行下边，chip 跟手）。
- 代价：
  - `_DropHover.mark` 是**一个** `ValueNotifier`，所有行都监听它：一次拖动里每次跨行
    会让所有行各重建一次 `Stack`（行内容本身复用，不重建）。抽屉几十行，代价可接受。
  - 落点判定的"能不能落"不再包含"位置会不会变"：拖到自己身上 / 位置没变时，
    线照样跟着手指，松手不发请求（**看得见但不生效**，正是用户要的反馈）。
  - 跨组（跨工作区）拖动仍然不做 —— 宿主的会话重排按工作区账本，没有对应方法。
  - 边缘自动滚仍然没有（普通 `ListView`）。
- 单测（`app/test/session_drawer_test.dart` 新增三条）：插入线在落行上/下边跟着走、
  松手在空白处提交最后扫过的那一格、往上拖一行能移动。**做过变异校验**：
  把 `onMove` 里的 `hover.take` 去掉（= 回到"只有 enter 时更新"的旧行为），
  前两条当场红（找不到插入线 / 提交为空），第三条仍绿 —— 证明这三条钉的是过程而不是结果。
- 真机证据（`d61cf622`，最终包上复验）：上行与下行各一次都真的改了宿主账本
  （`storages/workspace.json` 的 `sessionIds` 顺序变化），松在底栏空白也提交
  （日志里 `before=tIxS…` 而指针当时不在任何行上）。
- **顺序归属的设计差异**已写进 `docs/subsystems/session-ordering.md` §1：
  手机写电脑侧 `workspace.insertSessionBefore`，DSH Web 写浏览器本地 manual order
  （`ui-workspace/src/client/stores.ts:19-24`，persist key `dsh.workspace.view.v5`），
  所以**两边的会话顺序可能不一致**；项目顺序两边都写电脑侧。
