# Agent Note: 顶栏状态位缩成「圆点 + 独立右抽屉按钮」，标题限宽 220px

Status: implemented

## Problem

用户两条原话（同一轮）：

> "还有这个已连接是不是占地方?显示个绿点啥的就行?没链接就红的,连接中就转圈,
> 需要重连啥的你可以显示其他的可以点击去重连啥的"

> "web 屏幕大能显示很多,手机屏小,你需要限制大小,给子智能体,后台任务,这些留位置"

当时的顶栏是 `☰ 标题(Expanded) 文字胶囊 ＋`：胶囊被夹在中间，被长标题挤到
`max-width: 42vw`，而它同时还要承担两件不相干的事 —— **显示连接状态**（常驻）与
**开右抽屉**（serving 时点它），外加一个从没接上的"文件变更"档。

## Decision

**顶栏四个位置各做一件事**，每一件都指回一个 DSH 原生缝：

1. `●` **连接状态点**，点它弹「连接操作」sheet（重试 / 重新配对 / 打开侧面板 / 断开）。
   - 点的形状与颜色照 DSH `ui-primitives/src/StateDot.tsx:44-77` + `StateDot.module.css:1-45`：
     实心态 = **10px 槽里画 6px 核**；转圈态 = **14px 环、1.5s 匀速**（图标集里没有"带整环的转圈"，
     用同出自 DSH 图标集的 `loading` 那条弧旋转）。
   - 三档语义照 `ui-primitives/src/ConnectionIndicator.tsx:7-11`（`disconnected|connecting|recovered`）：
     服务中=`done`绿 / 连接中·握手中·重连中=`ongoing`转圈 / 其余=`error`红。
   - "点它去重连"不是我们发明的：DSH 的异常/重连指示器本身就是按钮（`ConnectionIndicator.tsx:75-81`
     的 `onClick={onReconnect}`）。手机上统一成 sheet，是为了把「重试 / 重新配对 / 断开」三个出路
     放在同一个地方，且**保住"任何状态 ≤2 步走到重新配对"**这条已被 widget 断言钉住的硬判据。
   - 颜色进 `app/lib/theme/dsh_colors.dart`（`stateSuccess` / `stateError` / `stateIdle` / `stateWarn`），
     值取 `design-platform.css` 暗色块 `:368-375`；**不许在 UI 里取色**是项目规则。
   - 映射函数只有一处：`app/lib/ui/dsh_state_dot.dart` 的 `dotStateOf`（与 `connectionLabel` 并列，
     一个状态的说法与长相都在同一层决定）。
2. `▷` **右抽屉入口**成了独立按钮（`panelLeft` 镜像 + `Transform.flip`）。
   - 理由不是"更好看"，而是 DSH 本来就是这么分的：右面板入口是 header **角落席位**里的
     `ExpandButton`（`ui-sidebar-right/src/client/index.ts:238-239`），图形是左侧栏图标镜像
     （`shell/ExpandButton.tsx:13-14`），与连接指示器没有任何关系。
   - 于是"点状态位开右抽屉"这条**临时**安排（2026-10-15 为 ≥2 步重配让路的产物）退役，
     两个入口互不抢占。
3. **标题限宽 `220px`**，数值照 DSH 的 `.crumb { max-width: 220px }`
   （`ui-conversation/src/client/skeleton/ConversationRoot.module.css:125-139`）。
   结构上 `Expanded`（右簇钉在右边）+ 内层 `ConstrainedBox(maxWidth: 220)`（标题吃不掉整行）。
4. 子智能体 / 后台任务计数保持**自己那一行**（`_LiveChipsRow`），并把 `Row` 改成 `Wrap`
   —— 两枚两位数 chip（"12 个子智能体，正在运行"是 190px 级）在 360px 上必然溢出。

## Alternatives considered

1. **什么都不做**（继续文字胶囊）。
   - 最强的理由：改动面最小，且"已连接"文字最直白。
   - 为何被否：用户点名；而且**Web 在连接正常时根本不显示指示器**（`ConnectionIndicator` 只有异常
     / 重连 / 刚恢复三态）—— 文字胶囊是我们自己长出来的一层，占了 42vw。
2. **完全照 Web：正常时不显示连接指示**。
   - 最强的理由：与 Web 逐字同源，顶栏最省地方。
   - 为何被否：与用户"显示个绿点"的明确要求冲突；且手机上除了顶栏没有第二个地方能一眼确认连线，
     而"不显示"与"没实现"在用户眼里是同一件事。
3. **把计数 chip 搬进顶栏同一行**（更贴近 Web 的 header 结构）。
   - 最强的理由：与 Web 同构，一个 band 解决。
   - 为何被否：算过宽度账 —— 360~390px 上四个控件约 164px、两枚两位数 chip 约 250px，
     标题位为负。手机上照抄不了宽屏的同一行，只能让计数另起一行（已写进设计文档的有意偏离）。
4. **点状态点时区分 serving（开右抽屉）与异常（弹 sheet）**（原有分法）。
   - 为何被否：右抽屉入口搬到自己的按钮之后，这个分叉只剩副作用 —— 一个点做两件事，
     用户点绿点时预期是"看连接"，却弹出右抽屉。

## Consequences

- 收益：顶栏不再互相挤压（标题有上限、右簇不收缩、计数不争宽度）；连接状态的**说法与长相各自只有一处**
  （`connectionLabel` / `dotStateOf`）；"≤2 步重配"继续成立且有 widget 断言；
  右抽屉回到一步可达，且入口来源与 DSH 一致。
- 代价：顶栏多了一个 38px 按钮位（总控件从 3 个变 4 个），390px 竖屏下标题最多 220px；
  连接正常时顶栏常驻一个 10px 的点（Web 没有）。
- 观测点：任务计数不再出现在顶栏 —— 若哪天 chip 行没渲染出来，"有任务在跑"就没有任何顶栏痕迹；
  chip 行"有才显示"的语义（无任务整行不占位）因此更重要，回归在
  `app/test/widget_test.dart` 的「顶栏：连接状态点只做连接的事，右抽屉有自己的按钮」与
  「顶栏标题限宽与计数 chip 的席位」两组。
- 被取代的旧安排：`.agents/notes/implemented/2026-10-15-connection-terminal-failure-goes-to-pairing.md`
  里"顶栏状态位常驻连接状态、点它弹 sheet"的部分，本篇改成"点它弹 sheet + 右抽屉独立按钮"，
  **"任何状态 ≤2 步走到重新配对"这条结论不变**。