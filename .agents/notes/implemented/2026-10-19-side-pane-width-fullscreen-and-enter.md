# Agent Note: 右抽屉统一宽度 + 全屏钮 + 停止自动解除 + 子智能体可进入

Status: implemented

## Problem

用户 2026-10-19 三条（同一条反馈里拆出来的）：

1. 「你这个文件切换到任务（是后台任务吧），子智能体还变化大小多割裂啊」
2. 「（你这个你看多大合适，不全屏，然后有一个全面的图标，点击全屏，
   点击缩回不好了」
3. 「dsh web 的后台任务点击是可以看的还有停止啥的，子智能体是列表，
   每一个点击是能进入的」

## 调查：三条的根因各不相同

### 1. 宽度跳变 —— 我们自己造的

```dart
final ratio = _sidePanel == SidePanel.file ? 0.92 : 0.78;   // 旧代码
```

文件面板 92%、任务/子智能体 78% —— 切换面板整块横向跳一下，零信息量。

### 2. 宽度该多大 —— DSH 的两个数都指向同一个方向

- `RIGHTBAR_DEFAULT_RATIO = 0.45`（`packages/client/ui-layout/src/client/columns.ts:29`）
  是**桌面比例**：1400px 窗口上 = 630px。手机 390dp 的 45% = **175dp**。
- `RIGHTBAR_MIN = 300px`（同文件 `:25`）—— **175dp 低于 DSH 自己的最小可用宽**。
- 且 DSH 规定 `autoFullscreen = viewportWidth < 768` 时自动全屏
  （`ui-sidebar-right/src/client/shell/SidebarRight.tsx:360-361`）——
  **手机永远 < 768**，按 DSH 自己的逻辑手机上就该全屏。

所以 DSH 的两个数在手机上**互相矛盾**（45% 太窄，auto 全屏又太满）。
根因是 45% 为桌面而设。手机取 **300dp**（它的最小可用宽，有出处的数），
`× 0.86` 兜住窄屏（沿用本项目抽屉已有的约定
`session_drawer.dart` 的 `min(86%, 360px)`）。

### 3. 任务面板 —— 已经做了，只差一条

`_JobRow` 的"点击展开实时输出"（`open && job.output.isNotEmpty`，
含 `gapNote` 显式渲染）与 `_StopButton` 的两段式确认**早就有了**。
缺的是 DSH 的 **armed 自动解除**：`KILL_ARM_MS = 3000`
（`packages/client/ui-jobs/src/client/JobListAction.tsx:64`）。

### 4. 子智能体"能进入" —— 卡在一个越线上

catalog 每项的 `id` 是**子会话的 DSH session id**
（`packages/subagent/subagent/src/catalog.ts:79` 的 `id: sessionIdSchema`），
而 `session.subscribe` 走 `requireSession`（`connector/src/handlers.ts:206`，
内部是 `aliases.sessionOf`）—— **原始 id 会抛 `session/not-found`**。

也就是说：这一列子智能体**原先点了打不开**，而且那些原始 id
**一直在过线**（§5.1 说手机与中继只见 `sid`）。两件事是同一个根因。

## Decision

### 1. 三个面板同一个宽度（`sidePaneWidth` 纯函数）

算术抽成 `side_pane.dart` 的 `sidePaneWidth({screenWidth, fullscreen})` ——
**签名里没有"哪个面板"**，所以"按面板分叉"在类型上就做不到。

### 2. 全屏钮（默认抽屉态）

头部标题栏右端一枚，抽屉态 ⇄ 全屏。`_sideFullscreen` 同时决定宽度与 chrome
（全屏时不画圆角与左边框，否则"铺满还留圆角"读作没收干净）。
**不落盘**：它是"这一眼想看多一点"，不是偏好。

**两态用同一枚字形**（`fullscreen`），靠 tooltip 说动作。为什么不做两枚：
DSH 的"退出全屏"glyph 是**组件内联 SVG**
（`SidebarRight.tsx:253-260`），**不在它的图标包里**（只有
`IconFullscreenOutline`，`ui-primitives/src/icons/index.tsx:796`）——
手写一枚就破了"图标集机生成"这条不变量。

### 3. 停止 armed 3 秒自动解除

`kStopArmWindow = Duration(seconds: 3)`，与 DSH 的 `KILL_ARM_MS` 同值。
**理由不是照抄**：第一下点成 armed 后去做别的事，回来随手一点就杀了
一个正在跑的任务 —— armed 是"我正在确认"，而这个意图有保质期。

### 4. 子智能体：连接器换别名 + 手机侧进入 + 面包屑返回

- **连接器**：`session.projections` 出口加 `aliasSubagentCatalog` ——
  只换 `subagentCatalog` 的 `id`，别的投影键原样过。
  这是"原样透传"的**唯一例外**，已写进 `session-projections.test.ts` 的文件头。
- **手机侧**：子智能体行的点击语义从"展开输出"改成 `onOpenSub`（进入那个会话），
  **两个回调分开**是因为两个语义（任务行=看输出，子智能体行=进会话）。
  行尾给 `chevronRight` 而不是 `chevronDown` —— 方向说明"点进去"。
- **返回**：`_subagentReturnFrom` 记"进来时的会话"，内容区上方出现一条
  `← 返回上一个会话 · 正在查看子智能体` 的面包屑。

## Alternatives considered（否掉的）

- **照 DSH 的 45%**：手机上 175dp，低于 DSH 自己的 `RIGHTBAR_MIN`。否。
- **照 DSH 的 autoFullscreen（手机永远全屏）**：用户明确要"不全屏"
  （"直接换页感觉怪怪的"）。否。
- **做页签制（DSH 的 `sidebarRightTabs`）**：DSH 是桌面形态（同时开多个文件对比），
  手机上 300dp 里再放一排页签 chip 会再压掉约 40dp 内容区。否，
  三个面板并列一个抽屉 + 头部切换。
- **子智能体点击 → 右侧栏内嵌渲染**（DSH 的 `openChildAside`，`:64-69`）：
  300dp 里再嵌一个会话，窄到不能读。否，走主对话区（DSH 的 `openChild`）。
- **用手写 SVG 补"退出全屏"图标**：破坏"图标集机生成"。否。

## Consequences

- 收益：切面板不再跳；能一键全屏读长内容；armed 不再挂到天荒地老；
  子智能体点得进去、回得来；顺手修掉 catalog id 的越线。
- 代价：`SidePane` 多两个参数（`onOpenSub`、`onToggleFullscreen`）；
  `_JobPanel`/`_JobRow` 多一个 `enterable`；面包屑是**导航记忆**而不是数据——
  直接杀掉 App 再打开子会话就看不到返回（那时从抽屉也找不到它，
  因为子会话被 `sessionVisible` 藏掉）。**这一条是已知缺口**，
  要根治得让连接器在 catalog 里带上 `parentId`（`listDescendants` 的行有，
  但那是另一个方法）。
- 测试：`flutter test 828`（`side_pane_test` 20 项：宽度纯函数 3 + 停止自动解除 1
  + 全屏钮 2 + 子智能体进入 2，其余原有）；`connector 550`（新增 2 条：
  别名替换、无 catalog 不造空键）。
  **两处变异验证**：拆掉自动解除定时器 → 1 条红；把 subs 的 `onToggle`
  改回 `onToggleJob` → 2 条红。
- **真机**：三个面板左缘同一位置（x=240 / 300dp）、全屏钮切换生效、
  任务面板空态与子智能体空态都正确，均已验过。
