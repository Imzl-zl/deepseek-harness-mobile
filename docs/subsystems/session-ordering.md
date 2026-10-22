# 会话与项目的顺序（谁拥有它、拖动怎么反馈）

抽屉里有两层可拖：**项目头**（工作区）与**会话行**。两层都长按起拖、都画同一条插入线，
但**顺序的归属不一样**，这一页把这件事和拖动的手感规格写清。

## 1. 顺序归谁：会话是电脑侧，项目是电脑侧，而 DSH Web 的会话序是**浏览器本地**

| 对象 | 手机怎么改 | 电脑侧真值 | DSH Web 怎么改 |
|---|---|---|---|
| **项目（工作区）** | `workspace.insertBefore` → `AppModel.moveWorkspace`（`app/lib/data/app_model.dart`） | `workspace.json` 的 `global.workspaceIds` | 同一个方法（`ui-workspace/src/client/WorkspaceBrowser.tsx:451` 的 `commitWorkspaceDrag` → `insertWorkspaceBefore`）——**两边都写电脑侧** |
| **会话（组内）** | `workspace.insertSessionBefore` → `AppModel.moveSession`（`app/lib/data/app_model.dart`） | `workspace.json` 里该工作区的 `sessionIds` | **浏览器本地**：`sessionDragOrder`（`ui-workspace/src/client/WorkspaceBrowser.tsx:218-239`）→ `setSessionOrder`（`stores.ts:19-24`，`orderBy: 'manual'` + `sessionOrderByAccount`，persist key `dsh.workspace.view.v5`）。**Web 客户端一次都没调 `insertSessionBefore`**（宿主有这个能力，只有测试提到它） |

**结论（设计差异，不是 bug）**：同一台电脑上，**手机拖出来的会话顺序与浏览器里看到的顺序
可能不一致** —— 手机改的是电脑侧账本，Web 改的是它自己 localStorage 里的 manual order。
项目顺序两边一致（都落电脑侧）。

真机判据（不是"看起来动了"）：`storages/workspace.json` 里该工作区的 `sessionIds`
顺序真的变了，且 `storages/dsh_mobile_core.json` 的 dedupe 表出现 `mv-<requestId>`。

## 2. 拖动的反馈：一条线、扫到就显示、松手提交最后扫过的那一格

照 DSH Web 三条（`ui-workspace/src/client/rows/WorkspaceBrowser.module.css:451-493`、
`Rows.tsx:200-203`、`WorkspaceBrowser.tsx:618`）：

1. **插入线是一条线**，不是整行变色：12px 高的带子画在落行 `top: -8px`（插到它前面）/
   `bottom: -8px`（插到它后面），左端一个 5×7 的「〈」+ 从 `x=4px` 到右边缘的 2px 横线，
   颜色 `--dsw-alias-state-business-primary`（手机 = `DshColors.businessBlue`）。
   落点只在**会话行 / 项目头**上出现，一次只有一条。
2. **扫到就显示**：`DragTarget.onMove` 里持续更新（**不是**等松手）。
   落行的上半 / 下半由指针位置与行矩形中线比较决定。
3. **松手提交"最后扫过的那一格"**：松在空白、行间、甚至抽屉底栏，都算数
   （`LongPressDraggable.onDragEnd` 里 `!wasAccepted` 时提交最后标记）。
   "不会改变顺序"的落点（拖到自己身上、位置没变、跨置顶分区、跨组）**不静默** ——
   线照样跟着手指，只是松手不发请求。

## 3. 为什么落点必须在 `onMove` 里算（一次真机血泪）

Flutter 的 `DragTarget` 只在指针**进入**目标时问一次 `onWillAcceptWithDetails`
（`packages/flutter/lib/src/widgets/drag_target.dart:752-774` 的 `didEnter`），
在目标内继续移动只走 `onMove`（`:804-808`）。

旧实现把"落在上半还是下半"算在 `onWillAcceptWithDetails` 里，于是**往上拖永远不动**：
指针一定从下方进入上一行 ⇒ 那一刻算成"下半 = 原地" ⇒ 被拒；之后移到上半
**再也不会回调**。2026-10-22 真机探针日志（`d61cf622`）逐条印证，见
`.agents/notes/implemented/2026-10-22-drawer-drag-insertion-line.md`。

现在 `onWillAcceptWithDetails` 只回答"能不能落"（同一组、同一置顶分区、不是自己），
与指针位置无关；指针位置只影响标记与锚点。

## 4. 边界（不做）

- **跨组（跨工作区）拖动不做**：宿主的会话重排按工作区账本，没有"跨工作区移动会话"的方法。
- **边缘自动滚动不做**：抽屉列表是普通 `ListView`，拖到边缘不会自己滚。
  `SliverReorderableList` 自带这个能力，但它的指示器是"让出空隙"而不是这条线，
  且抽屉里是"组头 + 会话"两层，换过去会先丢掉"组头也能拖"。取舍见决策笔记。
- 列表最顶上那一条 `listTopDropIndicator`（DSH 为第一行专门画的、避开滚动裁剪的那条）
  没有单独实现：第一行上方的线由行的 `-8px` 提供，贴到列表顶时会被裁剪掉一截。
