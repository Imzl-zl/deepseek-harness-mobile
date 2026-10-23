# Agent Note: 子智能体目录是「直接子级 + 懒加载的树」，状态与指标一律来自投影

Status: implemented

> 部分被取代（2026-10-23）：本篇里「子会话标题 = `父会话 › 子级名`（`_SubagentCrumb`，放不下只留子级）」
> 那一条已由 `.agents/notes/implemented/2026-10-23-subagent-header-parent-from-data.md` 取代 ——
> 顶栏标题现在**只显示当前子级名**，父级改由会话数据（`session.list` 的 `parentSessionId`）决定。
> 其余结论（目录三态 / 指标来自投影 / 行规格）仍然成立。

## Problem

手机端子智能体面板把**两件不同的事**压成了一个字段：`SubagentRow.status` 由
`mode` 推出（`one-shot` ⇒ `completed`，其余 ⇒ `running`），`isLive` 也是
`mode != 'one-shot'`。`mode` 说的是"能不能续聊"（不随时间变），
`running` 说的是"此刻跑没跑"（子会话自己 `session.list` 行的 `running`）。
合成一个之后有三个可见后果：

1. 可续聊的子会话**跑完了仍显示「正在运行」**，分组永远停在「进行中」；
2. 一次性任务的时长用 `finishedAt ?? now` 算，而 `finishedAt` 从未被解析过
   ⇒ 秒数**一直涨**；
3. 目录只有当前会话的直接子级、平铺、无展开、无 token、无第二行标题 ——
   而 `session.list` 的行早就原样带着 `projections.values` 的
   `title` / `subagentTiming` / `tokenUsage`（`connector/src/handlers.ts:527-533`），
   手机只取了 `title`。

同时"目录读失败"与"目录读到空"在界面上是同一句「没有子智能体」，
而两者的下一步动作相反（点重试 vs 换地方找）。

## Decision

子智能体目录 = **投影直接子级 + 展开才懒加载**的树；每行的活动态、时长、token
全部来自**子会话自己的投影提示**，`mode` 只负责"能不能续聊"这一个维度。
目录本身带 `loading / ready / error` 三态，`ready 且空` 是唯一敢说"它没有下级"的证据。

准入门槛（可机械判定）：

1. **活动态不得由 `mode` 推**：`SubagentNode.activity` 只读
   `running` 与 `subagentTiming.lastTurnCompleted`。判据的样子：
   `mode == 'continuable'` 且 `running == false`、`lastTurnCompleted == true` ⇒
   `activity == completed`、`activityText == '已完成'`
   （`app/test/subagent_metrics_test.dart` 有这一条）。
2. **时长不得用本地时钟兜底**：`SubagentTiming.durationMs` 在没有 `active` 时
   返回 `settledMs`，已停时用 `active.through` 封住 —— 传再大的 `now` 都不变。
3. **空与没读到分开**：`subagentCatalogOf(sid).state` 必须是三态之一；
   `isKnownLeaf` 只在 `ready && entries.isEmpty` 时为真（照
   `SubagentHeaderLineage.tsx:196-198`）。
4. **读子级目录不写当前会话那一包投影**：`refreshSubagentCatalog(child)`
   之后 `AppModel.projections` 仍是当前会话的
   （`app/test/subagent_panel_test.dart` 的「读子级目录不污染当前会话」）。
5. **两个手势两个回调**：点行 = 进入子会话（`onOpen`），点行尾展开按钮 = 展开
   （`onLoad` + 只动展开集合）。外部任务两者都没有。
6. **没有新方法面**：读的还是 `session.projections` / `session.list`；
   `parentAvailable` 不猜（它不在 `session.list` 的字段里）。
7. **排布按触屏重排，不是把桌面那一行缩小**：展开按钮在行尾、可点区 44×44；
   不预留 disclosure 槽；右列只放 token 一个数（时长并进详情行）；缩进 12、
   只画竖线；行尾不再有"进入"箭头（整行就是进入区）。
8. **子会话的导航就在顶栏**：左侧 `☰` → `chevronLeft`（回父会话），标题 =
   `父会话 › 子级名`（放不下只留子级名，用 `TextPainter` 量），右边 `chevronDown`
   点开「切换子智能体」sheet。**不另起一条头部条**。
   系统返回键走同一条路（`PopScope.canPop` 置假；抽屉开着时不抢 ——
   `material/drawer.dart:526-546` 的 `LocalHistoryEntry` 先处理，
   `widgets/routes.dart:942-947`）。
9. **只读框文字两行**：框的形状照 Web（54 / l4 发丝边 / layer-1），但标题与正文
   上下排 —— 390dp 上并排会交错换行。

## Alternatives considered

1. **保留 `SubagentRow` 的 `status`，只把它改成"外部传入"**
   - 最强的理由：改动面最小，目录行仍是同一个类型，面板不用拆。
   - 为何被否：目录行是**父会话看到的事实**（有哪些子级、什么 mode），
     活动态是**另一个会话的运行时状态**。把运行时状态塞进目录行，
     就得给目录行配一份"谁来填它"的约定 —— 那正是会漂的第二真值源。
     拆成 `SubagentRow`（目录事实，`core/job.dart`）+ `SubagentNode`（运行态视图，
     `model/subagent.dart`）之后，视图每帧现算，没有可漂的副本。
2. **把 `subagentTiming` / `tokenUsage` 存进一张 `Map<sid, metrics>`，不碰 `SessionSummary`**
   - 最强的理由：`SessionSummary` 是列表行类型，加字段会让它越来越胖。
   - 为何被否：这两个值是**同一行 `session.list` 的投影提示**，与 `title` 同一个来源、
     同一次解析（`_projectionValueOf`）。另起一张表就有两个"会话行的解析器"，
     而它们迟早对不上（列表刷新时一份新、一份旧）。
3. **进入子会话时把 `parentAvailable` 一起判**（照 Web 的第三档只读）
   - 最强的理由：这样能完整复刻 `selectReadOnlySubagent` 的三档。
   - 为何被否：`parentAvailable` 是 client session 的快照字段
     （`packages/api/session-controller/src/client/sessions/session.ts:75`），
     不在 `SessionSummary` / `session.list` 里；要判得先扩 Host 契约与连接器。
     当前没有证据表明这一档在手机上出现过，先不为此扩大方法面，写进已知差异。
4. **目录仍用任务面板那一套行（`SideJob` + `_JobPanel`）**
   - 最强的理由：一个面板复用一份行组件，代码最少。
   - 为何被否：任务行点击是"展开输出"，子智能体行点击是"进入另一个会话"，
     再加一个 disclosure 就是三种手势挤在一个组件里；而且任务行没有"当前行加粗"
     这件事（子会话头部要它高亮自己）。树自带展开态与 1 秒时钟，
     塞进无状态的 `_JobPanel` 只能把状态提到页面层，反而更分散。
5. **照 Web 用 336px 浮层下拉承载目录**
   - 最强的理由：与 Web 逐像素对齐，点开的落点也不遮标题。
   - 为何被否：设计 §7.8 已定右抽屉三面板（文件 / 任务 / 子代理）；
     手机没有 hover，浮层在触屏上既难点中也难关。要补的是**抽屉里的树**，不是换容器。
     子会话头部的"切换"用底部 sheet 复用同一棵树（体量与落点都更适合手指）。
6. **行排布照抄桌面**（左侧 14px disclosure + 右列两行小字 + 行尾进入箭头）
   - 最强的理由：代码与 Web 一一对应，评审时逐条能对得上；
     第一次实现就是这么做的（可点击区只放大到 24×34）。
   - 为何被否：那一行成立的三个前提在手机上都不成立 —— 鼠标精度（14px）、
     336~600px 宽（右抽屉 300dp）、10px 字号可读（390dp 高 DPI）。
     实际后果是：左侧小箭头与"进入"的整行点击区挨着，两种误触都会发生；
     右列两行吃掉 23% 宽度，label 与详情行被挤到只剩 200dp 出头。
     改成"行尾 44×44 展开 + 右列一个数 + 时长进详情行"之后，
     label 拿到全部剩余宽度，两个动作分处行的两端。
7. **另起一条 40dp 的头部条放"返回会话 + 子级名"**（第一版就是这样）
   - 最强的理由：完全不动顶栏 —— `☰` 还在、顶栏那五个位置一个不动，
     几何断言一行都不用改。
   - 为何被否：竖屏上 40dp 是实打实的对话高度；而"进入下一层就在导航栏左侧返回"
     是手机自己的惯例（也顺带把系统返回键接上了）。顶栏原有五个位置里，
     `☰` 在子会话里本来就该让位给返回 —— 留着它反而多一个矛盾入口
     （左抽屉打开的是父会话列表，用户此刻在子会话里）。
     代价是子会话里左抽屉只能从左缘拖出；那条手势本来就是主路径。

## Consequences

- 收益：三个假象消失 —— 跑完的子会话进「已结束」、一次性时长定格、空目录不再冒充
  "没有子智能体"；顶栏那枚「N 个子智能体，正在运行」的 N 也跟着变成真数
  （`running` 而不是 `mode`）。目录能展开到孙级，token 与真实耗时按 Web 的格式出现。
- 收益：`SidePane` 少了一份"子智能体也走任务面板"的隐含约定（`enterable` 参数与
  它的 chevron 一并删掉）；空态只有树这一个出处。
- 代价：每次展开都会多一个 `session.projections` 往返；`SubagentTree` 是**有状态**
  组件（展开集合 + 1 秒时钟），比原来的纯展示面板多两处内部状态。
- 代价：`SubagentTree.clock` 是为了让"每秒走一格"可单测而开的注入缝 ——
  生产默认 `DateTime.now()`；这类缝每加一个都得多想一次"它会不会被误用"。
- 代价：树的递归要多带一个祖先集合（`_visibleNodes` 与 `_Level` 各一处）——
  健康宿主的 catalog 不会成环，但畸形投影一旦成环就是不可捕获的
  `StackOverflowError`。这条防线是写测试时自己撞出来的
  （替身一开始对任何 sid 都回同一条目录 ⇒ 立即栈溢出）。
- 代价：token 全零时**不显示** `0 tok`（Web 会显示），与统计条那条
  「全零当作没给」同一条纪律（`memory.md` 八条教训 4）。属于有意偏离。
- 代价：`mode` 的中文词从「可续聊」改成 DSH 词典的「可继续」
  （`ui-subagent/src/client/locales.ts:28`）—— 用户会看到一次词变。
- 代价：触屏排布与 Web 的行**不再逐像素对应**，核对源码时要走
  `docs/subsystems/subagent-page.md` §3.1 那张对照表；新手直接比对两边会以为抄错了。
- 收益：系统返回键在子会话里回父会话 —— 这是移动端独有的一条路，
  Web 靠浏览器 history，手机没有它就只剩"退出聊天页"一种结果。
- 收益：子会话省掉一条 40dp 的头部条（导航进了顶栏），竖屏对话高度多 40dp。
- 代价：子会话里顶栏左侧的 `☰` 被 `←` 顶掉，左抽屉只能从左缘跟手拖出
  （那条手势本来就是主路径，但"点一下开抽屉"在子会话里没有了）。
- 代价：标题里"父级名"是**机会性**的 —— 两个名字量不下时它整段消失。
  也就是说同一套代码在不同标题长度下会长得不一样；核对截图时别以为是 bug
  （规则在 `ui/dsh_app_bar.dart` 的 `_SubagentCrumb`，判据是 `TextPainter` 的实测宽度）。
- 仍未做（已知差异）：`parentAvailable` 那一档、右侧栏子智能体聊天
  （`openChildAside`，`ui-subagent/src/client/index.ts:64-69`）、以及
  **`mock/proto` 的子代理面板仍是平的演示列表**（`mock/proto/app.js` 的 `renderSubs`）。
  前两条的判据见 `docs/subsystems/subagent-page.md` §6；第三条是**已知的原型/落地端差异**：
  本期只改 Flutter 端，同步原型要连 disclosure 交互、三态演示数据、token 与第二行指标、
  一个新验证脚本一起做，否则原型会变成一个"看起来能点、其实没有断言"的半成品。
  在那之前，面板结构以 `docs/subsystems/subagent-page.md` 与
  `app/lib/ui/subagent_tree.dart` 为准。
- 验证：`app/test/subagent_metrics_test.dart`（26）、`subagent_panel_test.dart`（13）、
  `subagent_tree_test.dart`（17，含环保护与 44×44 触控目标）、
  `subagent_enter_test.dart`（6，含系统返回键）；全量 `flutter test` **989 项**全绿。
