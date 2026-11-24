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

## 1.5 组内显示顺序：blank 打头 → 置顶 → 其余

组内分区由纯函数 `bucketSessionsByWorkspace`（`app/lib/model/workspace.dart`）一次算清：

1. **blank 行在最前** —— `isBlank` 走 `AppModel.sessionBlankOf`，与抽屉可见性、watermark
   同一道门（不是行上的 `blank` 字段，理由见 §3.5 与 `blank-session-hero.md`）；
   blank 段**恒按传入顺序**：它的 `updatedAt` 最旧也一样在最前。
2. 置顶次之（`workspace.list` 的 `pinnedSessionIds`）；
3. 其余最后。

**2、3 两段的内部顺序由设备排序档决定**（`device.session_order`，
`app/lib/model/session_order.dart`）：

| 档 | 组内顺序 |
|---|---|
| `updated`（默认） | **`updatedAt` 降序，并列按 sid 升序** —— 逐字照桌面 `orderByRecency`（`packages/client/ui-workspace/src/client/tree.ts:151-165`）与其默认档 `orderBy: 'updated'`（同目录 `stores.ts:86`）；`sectionMembers`（`tree.ts:270-284`）只分区、不改调用方给的顺序 |
| `manual` | **账本序** —— `workspace.list` 的 `sessionIds` 行序，也就是拖动 / 上移 / 下移写回去的那个顺序 |

「未分组」桶走同一个 `partition`，不另写一条规则。

次序照桌面 `sectionMembers`（`packages/client/ui-workspace/src/client/tree.ts:269-283`：
placeholders → leading → rest）。可见集里最多一个 blank —— 非当前的 blank 被
`sessionVisible` 挡掉（`tree.ts:241`）—— 所以"blank 打头"与桌面的 `pinCurrentBlank`
（`:213-219`）在可见集上等价。

**为什么默认是"最近更新"**：点「新建会话」先复用账本里已有的 blank
（`AppModel.findBlankSession`），那一行的账本位置是它当初被建出来的位置；`updatedAt`
是"最后一次动过"，发第一条消息之后它就该在组首 —— 桌面就是这样排的。取舍见
`.agents/notes/implemented/2026-11-24-session-order-by-recency.md`。

**手动档不另存一份顺序**：拖动写的就是账本（`workspace.insertSessionBefore`），
所以 `manual` = 账本序本身。**任何一次成功的会话重排都会把档位切到 `manual`**
（唯一一处：`AppModel.moveSession`）—— `updated` 档下账本序就是显示序以外的第二种排法，
写完不换档等于"拖完看不见变化"。

**blank 行不在可重排序列里**：`DrawerSection.reorderableIds` 把它摘掉，菜单的上移/下移与
拖动都只认这一段。于是它自己怎么移都是原地，紧挨着它的那一行也上不去（越过它 = 原地），
拖动也落不到它上面 —— 松手按"最后扫过的那一格"提交（与拖到行间同一条）。它在显示上被钉在
组首，写回账本改变不了位置。

拖动这条要挡**两处**：`onWillAccept`（不接受这次放下）与 `onMove`（不把插入线画到它身上）。
Flutter 对被拒的 target 也回调 `onMove`
（`packages/flutter/lib/src/widgets/drag_target.dart:932-945`：先入 `_enteredTargets`、
再问 `didEnter`、然后对全部 entered 报 move），只挡前者等于没挡。

**切回默认档**：设置页「会话排序」一行给两档（最近更新 / 手动），切回「最近更新」立刻按
`updatedAt` 重排；账本没有改，所以再切回手动时之前拖出来的顺序还在。

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

## 3.5 每组显示几条：watermark = 5，多出来的收进「展开其余 N 个会话」

照桌面 `rows/WorkspaceBrowser.tsx:55` 的 `SESSION_WATERMARK_BASE = 5`：
每个工作区默认只列 **5 条非 blank 会话**，其余折叠成一行
「展开其余 {n} 个会话」（文案逐字照 `ui-workspace/src/client/locales.ts:34`）。
blank 行恒显示且不占名额（`:60-70`）。

- **谁算"必须可见"**：在跑 / 有子在跑 / 有待处理 / **当前**这几类不被裁掉，
  watermark 抬到刚好覆盖它（上限 50，桌面 `SESSION_WATERMARK_AUTO_MAX`，`:57`）。
  桌面还有 `unread` 一档，手机侧暂未纳入（与 `pendingCount` 口径重叠）。
- **在哪儿裁**：装配层（`main.dart` 的 `_sectionOfBucket`）调纯函数
  `model/workspace.dart` 的 `watermarkRowsOf`；抽屉只画，不自己截断。
- **点「展开其余」**只放这一组，且**不落盘** —— 与 `host.drawer_expansion`
  （组折叠的跨重启记忆）是两个意图，不复用同一个键。
- 抽屉的搜索框只筛标题、大小写不敏感，且**筛的是同一份可见集**
  （归档 / blank 规则先跑）。它 2026-10-27 之前是死控件（装配层没传 `onSearch`）。

## 4. 边界（不做）

- **跨组（跨工作区）拖动不做**：宿主的会话重排按工作区账本，没有"跨工作区移动会话"的方法。
- **边缘自动滚动不做**：抽屉列表是普通 `ListView`，拖到边缘不会自己滚。
  `SliverReorderableList` 自带这个能力，但它的指示器是"让出空隙"而不是这条线，
  且抽屉里是"组头 + 会话"两层，换过去会先丢掉"组头也能拖"。取舍见决策笔记。
- 列表最顶上那一条 `listTopDropIndicator`（DSH 为第一行专门画的、避开滚动裁剪的那条）
  没有单独实现：第一行上方的线由行的 `-8px` 提供，贴到列表顶时会被裁剪掉一截。
