# Agent Note: 抽屉改成「拖动排序 + 组头常显计数」

Status: implemented

## Problem

用户 2026-10-21 在真机上看侧边栏，提了两件事（原话）：

> 还有左侧会话列表居然不是按照工作区分类然后每个工作区下面多少会话？
> 然后会话和工作区都可以拖拽换位置而不是弹框啊，弹框多麻烦啊，你参考人家web端的啊

三件事分别是：**分组**（已有）、**每组会话数常显**（原来只在折叠时显示）、
**拖动排序**（原来是长按菜单里的上移/下移）。

## Decision

1. **组头常显会话数**：`CollapsibleGroup` 不再判断 `expanded`。
   DSH 只在折叠时给 `hiddenCount`（`WorkspaceBrowser.tsx:640-660`），手机没有 hover ——
   "有多少"藏在折叠态里等于不给。有意偏离，写进 `design-and-tech-plan.md` §6。
2. **会话拖动**：长按行起拖，落在目标行的上半/下半 = 插到它前/后。
   锚点由纯函数 `dropAnchorInDisplayOrder`（`model/workspace.dart`）算：
   拖到自己 / 跨置顶分区 / 顺序没变 → 返回 `null`，**不发请求**。
   跨分区那条与 Web 的 `drag.pinned === node.pinned`（`WorkspaceBrowser.tsx:593-596`）同一条。
3. **工作区拖动**：项目头长按拖动，落到另一个头的上半/下半 = 插到它前/后。
   落点用"这个组之后第一个工作区"当锚点（没有就是末尾）。
   需要一个新的 Host 方法：`workspace.insertBefore`（DSH `index.ts:135-145`），
   连接器本轮补上（方法面 36 → **37**，实现 32 → **33**）。
4. **菜单退到行尾「…」**：长按已经给了拖动，两个手势不能抢同一个动作。
   菜单四项（置顶 / 上移 / 下移 / 归档）**一条不少** —— 拖动在滚动列表里对手指不友好，
   精确移动留一条退路。

## Alternatives considered

1. **用 `ReorderableListView`**
   - 最强的理由：Flutter 自带、动画与自动滚动都是现成的。
   - 为何被否：它是**一个**平铺列表的重排；这里是"工作区分组 + 组内分区 + 组头也可拖"，
     塞进去要先把树拍平再拼回去，而"拍到哪一层"正是这个界面的语义。
     `LongPressDraggable` + `DragTarget` 直接表达"落到哪一行"。
2. **只做会话拖动，工作区排序下轮**
   - 为何被否：用户原话把两者并列（"会话和工作区都可以拖拽"），
     而工作区排序在 Host 侧已有方法，缺的只是连接器一行 —— 半截做会留下"拖不动项目头"的疑问。
3. **拖动时用被拖的整行当 feedback**
   - 为何被否：整行（300dp×56dp）会盖住落点，看不见"松手会插到哪"；
     改成 220dp 的小卡片 + `pointerDragAnchorStrategy`（`DragTargetDetails.offset` 因此
     就是**手指位置**，不是卡片左上角 —— 后者带一段触摸偏移，会把上半/下半判错）。
4. **给拖动加一个专门的拖动手柄**
   - 为何被否：300dp 的抽屉里再切一刀；Web 的行本身就是可拖的。

## Consequences

- 收益：排序从"长按→菜单→点上移"三步变成"按住拖"，与 Web 一致；
  组头一眼看到"这个项目有几条"。
- 代价：**菜单的触发方式变了**（长按 → 行尾「…」）。三个已有用例改成点「…」，
  断言一条没删（四项、无删除、边界不可点、锚点距离全部保留）。
- 代价：连接器多一个方法（契约 §5.7 + 方法数 + 幂等集 + 两条用例），
  `tools.md` / `memory.md` 的"x/37"三处要同步。
- 代价：`CollapsibleGroup` 多一个 `headerWrapper`（抽屉挂拖动，内联列表不传）——
  做成包装器而不是把拖动写进组件，是因为这一层还服务内联列表。
- **已知边界**：会话只能在**同一工作区内**换位（`insertSessionBefore` 的签名如此，
  跨工作区会被宿主拒成 `workspace/move-invalid`）；把会话拖进另一个工作区不是排序，
  是改归属，DSH 自己也没有这个动作。
- **真机未验**：隔离实例里凑不出"同一工作区下两条可见会话"（新会话是 blank，
  `sessionVisible` 不列；宿主的工作区账本只记 `workspaceId` 建出来的会话），
  所以拖动只在 widget 测试里验过几何与回调，真机那一条记为「未验」。
  工作区拖动同理（只有一个可拖的组）。
- 验证：`workspace_grouping_test.dart`（`dropAnchorInDisplayOrder` 五条）、
  `session_drawer_test.dart`（拖到下半 / 跨分区拒绝 / 项目头落点）、
  `workspace_actions_test.dart`（`moveWorkspace` 的载荷、整份顺序、丢组兜底）、
  `collapsible_group_test.dart`（展开也显示计数）。
