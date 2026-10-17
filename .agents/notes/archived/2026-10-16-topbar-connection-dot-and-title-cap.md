# Agent Note: 顶栏状态位缩成「圆点 + 独立右抽屉按钮」，标题限宽 220px

Status: archived

Superseded by: `.agents/notes/implemented/2026-10-17-topbar-single-row-and-stats-scroll.md`

取代范围：**决定 3（标题限宽 220px / 字号 14px）、决定 4（子智能体与后台任务计数另起一行）
与备选 3（"把计数 chip 搬进顶栏同一行"被否）** 这三处已被取代 —— 新篇把计数 chip 做成
「图标 + 计数」放进顶栏同一行，标题随之收窄到 140px / 13px，那一整行撤销。
当年否掉"同一行"的前提是**全文本** chip（两枚 250dp 级）；换成图标 + 计数后前提不成立。
本篇**其余结论仍然有效**：连接状态点的形状/颜色/三档语义（照 DSH 的 `StateDot` +
`ConnectionIndicator`）、点它弹「连接操作」sheet、"任何状态 ≤2 步走到重新配对"，
以及"与系统返回手势的冲突用官方 `setSystemGestureExclusionRects`（上半屏 192dp）"那一段
连同它的真机实测表。**下面的结论原文不改** —— 它记录了当时为什么那么想。

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
3. **标题限宽 `220px` + 字号 `14px` / `w500`**，两个数都照 DSH 的 `.crumb`
   （`ui-conversation/src/client/skeleton/ConversationRoot.module.css:125-139`：`max-width: 220px;
   font-size: 14px; line-height: 20px`，当前那条 `crumbCurrent` 是 `w500`）。
   结构上 `Expanded`（右簇钉在右边）+ 内层 `ConstrainedBox(maxWidth: 220)`（标题吃不掉整行）。
   - 字号是**用户追问后补的**（原话"会话名字不能小点"）：手机原来写 16 / w600，
     比 Web 大一档也更重 —— 直接回到 Web 的 14 / w500，不自己取中间值。
4. 子智能体 / 后台任务计数保持**自己那一行**（`_LiveChipsRow`），并把 `Row` 改成 `Wrap`
   —— 两枚两位数 chip（"12 个子智能体，正在运行"是 190px 级）在 360px 上必然溢出。
   **常态是一行**：口径改回 DSH 之后文案变短（"3 个子智能体" + "1 个后台任务运行中" ≈ 240px），
   390/360px 下都排得下，`Wrap` 只是放不下时的兜底 —— 由 `app/test/live_chips_row_test.dart` 钉住
   （390/360 一行、12+12 时才换行、任何一档都不溢出）。

## 追加（同日，用户第二轮反馈）

用户原话："左侧有个侧栏标志也不好看，去掉，左侧上半部分侧滑进入（进入就是和 web 端的左侧的
那个按钮一样，有很多东西在这显示，你自己看源码）会话标题字体小点，大小设置好，超过就省略"。

- **顶栏的 `☰` 去掉**：顶栏只剩 `标题 / ● / ▷ / ⊕`。左抽屉的入口改成**左缘侧滑** ——
  这不是新发明：原型基线本来就有 `.edge--open` 手势带（`left:0; top:56px+safe; width:20px`，
  拖过 40% 或快速甩才开，`mock/proto/app.js:244-257`），App 侧对应
  `Scaffold.drawerEdgeDragWidth`（20 → 40：指针能精确停在 20px 里，拇指不行）。
  - 顺带核对过用户在括号里说的那件事：Web 左侧栏（`ui-sidebar/src/client/SidebarRoot.tsx:199-313`）
    从上到下 = 品牌行（展开时点它=新建会话）+ **新建会话**按钮 + **全局面板行**
    （`sidebar.panellist`）+ **工作区/会话浏览区**（`sidebar.workspaces`：section 头 + 搜索 +
    分组列表 + 工作区对话框）+ 底部（`sidebar.footer.action` + `sidebar.settings`）。
    手机抽屉已经有搜索 / 工作区分组列表 / 连接行 / 底栏五项 / 新建会话；缺的是品牌行（手机不需要）
    与全局面板行（终端 / 插件那类，方案 §13 的 C 类不做）。
- **字号回到 Web 的 14px / w500**：见上一条 Decision 3 的补充（原 16/600 是手机自己长出来的）。
- **代价与连带改动**：`@data-act="drawer-open"` 那个按钮在各处被引用（`verify-settings` /
  `verify-tasks` / `shoot*.mjs`），全部改成走**真实手势**（`PROTO.openDrawerByEdge`，
  `mock/proto/app.js` 里新加），这样"入口"这件事仍然被验证脚本覆盖，而不是从断言里消失。
  设计文档 §7.1 的顶栏描述同步改了。

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

## 追加二（同日晚）：抽屉入口定稿 —— 顶栏 ☰ + 两边跟手拖 + 右边一条棒棒

用户第三次纠正（原话）："**那个图标怎么在侧边？正常不是在顶栏左侧？** 右边的侧滑可以加一个
之前那个棒棒啊，**侧滑之后棒要消失**啊，还要**侧滑能不能跟手**？跟手移动？"

被否的是我第二轮那版：把 `☰` 挪到屏幕左缘当"把手"、两边铺透明手势带、**不跟手**（划到位才开）。
定稿：

1. **`☰` 回到顶栏左侧**（`dsh_app_bar.dart`）—— 图标就该在顶栏，这是常识，不该自创形态。
2. **两个抽屉都用原生 Drawer，两边都跟手**：左 = `Scaffold.drawer`、右 = `Scaffold.endDrawer`
   （`chat_page.dart` 直接把 `SidePane` 装进 `endDrawer`，不再自绘遮罩 + `Positioned.fill`），
   `drawerEdgeDragWidth: 32`。跟手 / 回弹 / 遮罩关闭 / 拖拽关闭全是 `DrawerController` 的
   `_move` / `_settle`（`material/drawer.dart:667-709`）—— **自己写的第二套只会更差**。
3. **右边不加图标，只有一条棒棒**（`ui/edge_stick.dart`：4×40、`IgnorePointer` 不抢触摸）；
   **右抽屉开着时整条消失**（`onEndDrawerChanged` 同步 `_sideOpen`；原型侧同样
   `#app.file-open .edge--side{display:none}`）。
4. **与系统返回的冲突用官方 API 解决**（这次查了资料，不是猜）：
   `View.setSystemGestureExclusionRects` / `Window.setSystemGestureExclusionRects`（Android 10+），
   声明"这两块边别抢"。出处：Android Developers《Gesture Navigation: handling gesture conflicts (III)》，
   <https://medium.com/androiddevelopers/gesture-navigation-handling-gesture-conflicts-8ee9c2665c69>
   （**限制**：每条边最多 200dp 总高度，超了只认最靠下的那段 ⇒ 带子高度钉 192dp）。
   实现：`app/lib/platform/gesture_exclusion.dart`（换算 + 通道）+ `MainActivity.kt`
   （`setRects` → `window.decorView.systemGestureExclusionRects`）。

**真机实测（小米 `d61cf622`，Android 16，DPR 2.625）**：

| 起手位置 | 结果 |
|---|---|
| ≈2dp（最外缘），**不报**排除 | 系统返回吃掉：**App 退回桌面**（`mCurrentFocus=com.miui.home`） |
| ≈2dp，**报了**排除（本版） | 抽屉正常开出 ✓（左缘 x=5、右缘 x=1070 都验过） |
| **下半屏**（y≈610dp） | 仍归系统返回（App 退回桌面）—— **我们没抢它的活** ✓ |
| 顶栏 `☰` 点一下 | 左抽屉打开 ✓ |
| 右缘拖出后 | 右抽屉（整屏）打开，**棒棒消失** ✓ |

**弯路（留着，别再犯）**：① 把手内缩 36dp 躲系统 —— 用户否了（"把这个标记移动到里面了"）；
② 自写"划到位才开"的手势带 —— 既不跟手，又与原生 Drawer 抢状态；
③ 用 `KEYCODE_BACK` 关抽屉来测 —— 会把 App 一起退掉，测出来的现象是假的。

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