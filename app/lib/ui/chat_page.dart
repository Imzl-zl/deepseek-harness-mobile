/// 聊天页 —— **主页**（照 `mock/proto/index.html` 的 `section.page--chat`）。
///
/// ## 这是主页，不是"会话详情"
///
/// `design-and-tech-plan.md` §6：**主屏 = 当前会话**（聊天页），
/// 会话历史在左侧抽屉。我第一版做成了"会话列表当主页"，
/// 那是文档明确否掉的"列表优先 + 底部导航"结构。
///
/// ## 结构（自上而下，照原型）
///
/// ```
/// ┌──────────────────────────────────────┐
/// │ ☰  标题(超长省略)  ⑵任务运行中  ⊕   │  ChatAppBar
/// │ [对话]      轨迹                     │  DshSegmented
/// │──────────────────────────────────────│
/// │  用户气泡(右)                        │  UserTurn
/// │  助手:头像 + 名字 + Markdown          │  AssistantTurn
/// │  ▸ 工具卡片(可展开)                   │  ToolCard
/// │──────────────────────────────────────│
/// │ ┌──────────────────────────────────┐ │  DshComposer
/// │ │ 附件轨(有才出现)                  │ │
/// │ │ 输入消息…                        │ │
/// │ │ ＋ 模型·等级 权限            ↑   │ │
/// │ └──────────────────────────────────┘ │
/// │ ⏱1轮·3步 🗄302K ◔3%                 │  DshStatsBar
/// └──────────────────────────────────────┘
/// ```
///
/// ## 空态
///
/// 没会话时显示空态 + "打开抽屉"提示（用户选的方案）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/errors.dart';
import '../core/job.dart';
import '../data/app_model.dart';
import '../model/agent_preset.dart';
import '../model/changes.dart';
import '../model/chat_item.dart';
import '../model/command.dart';
import '../model/file_diff.dart';
import '../model/file_open.dart';
import '../model/image_limits.dart';
import '../model/model_catalog.dart';
import '../model/permission.dart';
import '../model/preferences.dart';
import '../model/session_stats.dart';
import '../model/subagent.dart';
import '../model/trajectory.dart';
import '../model/turn_groups.dart';
import '../model/workspace.dart';
import '../platform/photo_picker.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';
import '../theme/dsh_type.dart';
import '../wire/rpc/session.dart' show sendPrompt;
import '../wire/rpc/subagent.dart' show sendSubagentPrompt;
import 'chat_jumper.dart';
import 'chat_turns.dart';
import 'collapsible_group.dart';
import 'connection_actions_sheet.dart';
import 'connection_summary_block.dart';
import 'conversation_hero.dart';
import 'dsh_app_bar.dart';
import 'dsh_brand.dart';
import 'dsh_composer.dart';
import 'dsh_diff.dart';
import 'dsh_markdown.dart';
import 'dsh_popover.dart';
import 'dsh_sheet.dart';
import 'dsh_shimmer.dart';
import 'dsh_state_dot.dart';
import 'dsh_toast.dart';
import 'edge_stick.dart';
import 'input_focus.dart';
import 'load_older_trigger.dart';
import 'queue_dock.dart';
import 'side_pane.dart';
import 'subagent_readonly_band.dart';
import 'subagent_tree.dart';
import 'takeover.dart';
import 'trajectory_page.dart';

/// 会话至少露出来的高度：底部那一块（接管卡 + 输入栏 + 统计条）不许把它吃掉。
///
/// 布局参数，不是业务规则 —— 它只决定"卡片最多能长多高"，不决定任何行为。
const double kMinConversationVisible = 72;

/// 输入栏**固定件**的高度：文字行 + 控制行 + 内外边距（候选面板不在里面）。
///
/// 实测上界，由 `app/test/composer_layout_test.dart` 的一条用例守着
/// （空输入栏的实测高度必须 ≤ 这个常量）：常量只能大于等于实测，
/// 低了就会让候选面板把接管卡挤爆。
const double kComposerFixedHeight = 104;

/// 统计条 + 它的上边距（一行 chip，见 `DshStatsBar` 的 `padding.top`）。
///
/// 实测 32（`composer_layout_test.dart` 的棘轮用例），留 4px 余量。
const double kStatsBarHeight = 36;

/// 底部这一块的**一份预算**（接管卡与候选面板从同一个数里分空间）。
///
/// 为什么要有它：接管卡、队列条、输入栏、统计条同在一个 `Column` 里，而手机键盘
/// 弹起后可用高度只剩一小半。各算各的"屏幕高度比例"会叠出溢出 ——
/// 真机 2026-10-24 抓到的那次是 `BOTTOM OVERFLOWED BY 204 PIXELS`，
/// 接管卡的「跳过 / 提交」被顶出屏幕（`shots-2026-10-24-mentions/h1-typed.png`）。
///
/// 现在只有这里算：
/// - [blockMax]：底部这一块最多占多高（可用高度减掉至少要露出来的会话）；
/// - 接管卡拿 `Flexible` 的**剩余空间**（结构约束，不必猜它有多高）；
/// - 候选面板拿 [panelMax]（同一个数再减掉输入栏固定件、统计条，接管卡在场时
///   还要扣掉它不可压缩的那两行）—— 两者因此不可能相加超过 [blockMax]。
///
/// Note: 为什么是"一份预算 + `Flexible`"而不是调小那个窗口比例 ——
/// 见 `.agents/notes/implemented/2026-10-25-bottom-budget-and-takeover-card.md`
@immutable
class _BottomBudget {
  const _BottomBudget({required this.blockMax, required this.panelMax});

  /// [viewportHeight] 是**页面 body 自己的**高度（已经扣掉顶栏与键盘 ——
  /// 这正是 `Scaffold` 按 `viewInsets` 压缩 body 的结果，别再用屏幕高度算一遍）。
  factory _BottomBudget.of(double viewportHeight, {required bool cardActive}) {
    final blockMax = math.max(0.0, viewportHeight - kMinConversationVisible);
    final reserved =
        kComposerFixedHeight +
        kStatsBarHeight +
        (cardActive ? kTakeoverFixedHeight : 0);
    return _BottomBudget(
      blockMax: blockMax,
      // 设计上限仍然照宿主（400）：空间够时不画一个比桌面还高的菜单。
      panelMax: math.min(
        kSuggestionPanelMax,
        math.max(0.0, blockMax - reserved),
      ),
    );
  }

  /// 底部这一块的硬上限（`ConstrainedBox` 用它）。
  final double blockMax;

  /// 候选面板的高度上限（传给 `DshComposer`）。
  final double panelMax;
}

/// 聊天页。
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.app,
    required this.onOpenDrawer,
    required this.onNewSession,
    required this.drawer,
    this.onOpenSession,
    this.paired = true,
    this.onConnect,
    this.onRePair,
    this.onDisconnect,
  });

  final AppModel app;

  /// 顶栏 `☰`（由外层打开抽屉 —— 抽屉要盖住整个 Scaffold，所以归外层管）。
  final VoidCallback onOpenDrawer;

  final VoidCallback onNewSession;

  /// 打开某个会话（**主界面上的内联会话列表**用它；抽屉有自己的一条同名回调）。
  ///
  /// 可选：不给时内联列表点了没反应 —— 那只该出现在"只画界面"的测试里，
  /// 真实装配点（`main.dart`）必须给。
  final void Function(SessionSummary session)? onOpenSession;

  /// 抽屉本体（外层 `Scaffold.drawer`）。
  final Widget drawer;

  /// 是否已配对（没配对时输入栏置灰、状态胶囊说"未连接"）。
  final bool paired;

  final VoidCallback? onConnect;

  /// 「重新配对（换一台电脑）」：清掉本机凭据 + 回配对页（装配层注入）。
  ///
  /// 议题 3 的落点：顶栏连接状态位、空态出路两处点它都经连接操作 sheet 确认。
  final VoidCallback? onRePair;

  /// 「断开并清掉凭据」但**不**进配对页（装配层注入；聊天页自己不给这个入口）。
  final VoidCallback? onDisconnect;

  @override
  State<ChatPage> createState() => ChatPageState();
}

/// **公开的**（不是 `_ChatPageState`）：外层要靠 `GlobalKey<ChatPageState>`
/// 调 [ChatPageState.openDrawer] 打开抽屉 —— 抽屉归本页的 `Scaffold` 管，外层只能通过 key 够到它。
///
/// **这条是踩出来的**：先前它是私有的、且**没有 `openDrawer` 这个方法**，
/// 而外层写的是 `_chatKey.currentState?.openDrawer()` —— 私有的 `State` 类型
/// 让 `currentState` 的静态类型是 `State<ChatPage>`，那个 `?.` 于是**永远静默失效**：
/// 点 `☰`、点空态里的"打开会话抽屉"都毫无反应，**且不报任何错**（真机实测）。
///
/// Note: 为什么这类"静默失效"要专门留一篇 —— 见
/// `.agents/notes/implemented/2026-10-07-three-wire-shape-mismatches.md`
class ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();

  /// 本页 `Scaffold` 的 key —— [openDrawer] 靠它开抽屉。
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  int _tab = 0;
  bool _sending = false;
  final List<PendingAttachment> _attachments = [];

  /// 右抽屉是否打开。**不驱动渲染**（抽屉本体是 `Scaffold.endDrawer`，
  /// 由 Flutter 自己管开合）——它只决定右缘那条"棒棒"要不要显示，
  /// 由 `onEndDrawerChanged` 同步过来。
  bool _sideOpen = false;
  SidePanel _sidePanel = SidePanel.file;

  /// 右抽屉铺满整屏（用户点头部那枚全屏钮切的）。
  ///
  /// **不落盘**：它是"这一眼想看多一点"的临时状态，不是偏好
  /// （DSH 的 manual mode 同样只在会话期内有效，`SidebarRight.tsx:310`）。
  /// 关掉抽屉再开就回到抽屉态 —— 那才是默认该有的形态。
  bool _sideFullscreen = false;

  /// 进入子会话之前的那个会话（**老连接器**的返回兜底，见 [_subagentParentSid] 第 3 档）。
  ///
  /// 父级本身来自数据（`session.list` 行的 `parentSessionId`，或画出那一行的那一层），
  /// 记忆只在"新手机连老连接器"时兜底。子会话在抽屉里是藏起来的
  ///（`sessionVisible` 第 1 条），没有返回入口用户就找不回来。
  String? _subagentReturnFrom;

  /// 当前打开的子会话 sid（用来判断导航是否已经离开它）。
  ///
  /// 只记 `_subagentReturnFrom` 不够：用户从抽屉再打开别的会话时，父会话
  /// 记忆不会自动消失，子会话头部（`←` + 标题）会挂在无关会话上。
  String? _subagentChildSid;

  /// 当前子会话的 catalog 模式（`one-shot` / `continuable` / `unknown`）。
  ///
  /// 与 Web 的 `selectReadOnlySubagent` 同一个判据
  /// （`ui-subagent/src/client/index.ts:37-49`）：一次性 / 模式未知的子会话
  /// 不接受后续消息，输入栏要换成只读说明。
  String? _subagentMode;

  /// 文件面板的分段（差异 / 文件）。
  ///
  /// **不是 `final`**：`dart fix` 曾因为"只有读、没有写"把它改成 `final`，
  /// 而那时还没有分段控件。现在要切换 tab，必须可变。
  int _fileTab = 0;

  /// 展开了哪些任务行。
  /// 展开着的任务（UI 的展开态；订阅状态以电脑侧为准）。
  ///
  /// **不预展开任何一个**：早先写死 `{'j1'}` 会让第一屏就显示一个
  /// 不存在任务的输出 —— 而那是示例数据时代的遗留。
  final Set<String> _openJobs = <String>{};

  /// 风险门里的勾选态。
  ///
  /// **不跨次残留**（§7.10 表格："关掉后重开，勾选态不残留"）——
  /// 每次开风险门都从 `false` 起（`_showRiskGate` 里重置）。
  bool _riskAcked = false;

  /// 输入栏接管（审批 / 提问 / 计划）。
  final TakeoverController _takeover = TakeoverController();

  /// 交互信号订阅（会话事件 → 接管队列）。
  StreamSubscription<InteractionSignal>? _interactionSub;

  /// 打开左侧会话抽屉。
  ///
  /// 外层用 `GlobalKey<ChatPageState>` 调它（顶栏 `☰`、空态里的"打开会话抽屉"）。
  /// **抽屉归本页的 `Scaffold`**，所以只有这里能开它 —— 外层拿不到那个 `Scaffold`。
  void openDrawer() => _scaffoldKey.currentState?.openDrawer();

  /// 收起左侧会话抽屉（**同步**）。
  ///
  /// 抽屉不是一条路由，它给当前路由挂一个 `LocalHistoryEntry`
  /// （`packages/flutter/lib/src/material/drawer.dart:529-541`）；因此"收抽屉"
  /// 曾经写成 `Navigator.maybePop()`。那是**错的**：`maybePop` 是 async，
  /// `await route.willPop()` 之后要重新取一次栈顶，栈顶变了就直接放弃
  /// （`packages/flutter/lib/src/widgets/navigator.dart:5539,5547-5551`）——
  /// 抽屉里"先收抽屉、紧接 push 全屏页"正好是这个形状，于是那一句静默失效，
  /// 抽屉原样开着（真机三次、`app/test/drawer_close_before_push_test.dart`）。
  /// `ScaffoldState.closeDrawer()` 没有这一步：它自己会摘掉那个 history entry
  /// （`drawer.dart:543-549` → `routes.dart:950-967`）。
  ///
  /// 因果见 `.agents/notes/implemented/2026-10-22-drawer-close-before-push.md`。
  void closeDrawer() => _scaffoldKey.currentState?.closeDrawer();

  /// 从抽屉里打开一个全屏页：**先收抽屉，再 push**，开 / 关各收一次输入法。
  ///
  /// 两支都由本页负责，因为它们用的是本页的 `Scaffold`（抽屉）与本页的焦点树；
  /// 外层（`main.dart`）只给 route。[closeDrawer] 是同步的，所以 push 与"收抽屉"
  /// 不会抢同一个栈顶（见它的注释）。
  Future<void> openFromDrawer(Route<void> route) =>
      dismissInputFocusAround(() async {
        closeDrawer();
        await Navigator.of(context).push(route);
      });

  /// 打开右侧抽屉（文件 / 任务 / 子智能体）。
  ///
  /// 连接操作 sheet 的「打开侧面板」与 chip 行都经它落。
  /// **它就是 `Scaffold.openEndDrawer()`** —— 原生抽屉自带跟手拖出与遮罩关闭，
  /// 自己维护一个 `_sideOpen` 布尔值只会多出一套会跟原生状态漂移的真值。
  /// （`_sideOpen` 现在**只用来决定右缘那条棒棒的显隐**，由
  /// `onEndDrawerChanged` 同步，不再驱动渲染。）
  void openSide() => _scaffoldKey.currentState?.openEndDrawer();

  /// 打开右抽屉并**直接落在指定面板**（chip 行用：点子智能体就开到子智能体）。
  ///
  /// 面板状态在抽屉**之外**（它决定抽屉里显示哪一页），所以先设面板再开抽屉。
  void _openSidePanel(SidePanel panel) {
    setState(() => _sidePanel = panel);
    openSide();
  }

  /// 子智能体面板的指标要**现拉一次** `session.list`（见
  /// `AppModel.refreshSessionMetrics` 的注释：子会话是在回合里才出现的，
  /// 而行只在连上 / 建会话时读过）。
  ///
  /// 挂在"面板真的会被看见"的三个入口：抽屉打开、抽屉内切到子智能体页、
  /// 「切换子智能体」sheet 打开。**不是定时器** —— 这一层没有推送面。
  void _refreshSubsMetrics() {
    if (widget.app.currentSid == null) return;
    unawaited(widget.app.refreshSessionMetrics());
  }

  /// 右抽屉的宽度。
  ///
  /// **不铺满整屏**：留出左侧一条让下层会话露出来，这才读作"抽屉"而不是
  /// "翻到另一页"（2026-10-19 用户原话"右侧的我感觉做成抽屉好看点"）。
  ///
  /// 右抽屉的宽度。**三个面板同一个宽度**，且可由用户切成全屏。
  ///
  /// ## 为什么不再按面板分两个宽度（2026-10-19 用户反馈）
  ///
  /// 原话：「你这个文件切换到任务（是后台任务吧），子智能体还变化大小
  /// 多割裂啊」。原来文件面板 92%、任务/子智能体 78%，**切换面板时整块
  /// 面板横向跳一下** —— 那是纯视觉噪音，没有任何信息量。
  ///
  /// ## 为什么默认不是 DSH 的 45%
  ///
  /// DSH 的 `RIGHTBAR_DEFAULT_RATIO = 0.45`
  /// （`packages/client/ui-layout/src/client/columns.ts:29`）是**桌面比例**：
  /// 1400px 的桌面窗口上它是 630px。手机 390dp 的 45% = **175dp**，
  /// 而 DSH 自己规定 `RIGHTBAR_MIN = 300px`（同文件 `:25`）——
  /// **照抄 45% 会低于 DSH 自己的最小可用宽**。
  ///
  /// 所以取 **300dp**（DSH 的最小可用宽，有出处的数），并用 `× 0.86`
  /// 兜住窄屏（沿用本项目抽屉已有的约定：`session_drawer.dart` 的
  /// `min(86%, 360px)`）—— 保证右侧永远露着一条下层会话，
  /// 读作抽屉而不是换页。
  ///
  /// ## 全屏是用户切的，不是宽度派生的
  ///
  /// DSH 的 `autoFullscreen = viewportWidth < 768`
  /// （`ui-sidebar-right/.../SidebarRight.tsx:360-361`）会让**手机永远全屏**；
  /// 但触屏上"浮在会话上的抽屉"更好用（用户 2026-10-19 原话：
  /// "这个滑动也就看下现在这样直接换页了感觉怪怪的"）。
  /// 所以默认抽屉态、**给一枚全屏钮**（DSH 也有这枚钮，在 tab 条末端，
  /// 同文件 `:263-296`）—— 读长文件 / 看任务输出时点它。
  ///
  /// 算术在 `side_pane.dart` 的 `sidePaneWidth`（纯函数，可单测）。
  double _sideDrawerWidth(BuildContext context) => sidePaneWidth(
    screenWidth: MediaQuery.sizeOf(context).width,
    fullscreen: _sideFullscreen,
  );

  @override
  void initState() {
    super.initState();
    // 输入框有内容才亮发送键 —— `TextField` 的 `onChanged` 不触发本层重建，
    // 所以手动挂一个监听（否则发送键永远灰着）。
    _input.addListener(_onInputChanged);
    _takeover.addListener(_onTakeoverChanged);
    // **真实交互接进接管队列**：待处理项是会话事件的投影（契约 §6.3），
    // 于是"对话流里有一条审批"与"输入栏上有一张审批卡"不可能对不上。
    _interactionSub = widget.app.interactions.listen(_onInteractionSignal);
    // 答复出口：控制器不认识 `AppModel`，所以在这一层把"答一次"接到
    // `interaction.respond` 上（装配点才知道用哪个实现）。
    // **没配对时不接**：那意味着没有电脑可答，而接一个必然失败的出口只会
    // 让每次答复都被报成"已过期"。
    _syncAnswerOutlet();
    // **打开文件是一次"动作"，不是一份"状态"**：`openFile` 只改模型，
    // 而"把右抽屉拉出来、落到文件面板"是本页的事（抽屉归本页的 Scaffold 管）。
    // 先用当前序号对账，免得挂载时把上一次的请求再开一遍。
    _seenFileOpenTicket = widget.app.fileOpenTicket;
    widget.app.addListener(_onAppFileOpen);
  }

  @override
  void didUpdateWidget(ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 配对状态是构造参数：配对上之后出口才该出现（见 `initState` 里同一句）。
    if (oldWidget.paired != widget.paired) _syncAnswerOutlet();
    // 用户从抽屉/内联列表打开了别的会话：父会话记忆必须跟着失效，
    // 否则子会话头部会挂在一个与它无关的会话上。这里直接改字段而不
    // `setState` —— `didUpdateWidget` 之后本来就会 build。
    if (_subagentChildSid != null &&
        widget.app.currentSid != _subagentChildSid) {
      _subagentReturnFrom = null;
      _subagentChildSid = null;
      _subagentMode = null;
    }
  }

  void _syncAnswerOutlet() {
    _takeover.onAnswer = widget.paired ? _onTakeoverAnswer : null;
  }

  /// 交互信号 → 接管队列。
  void _onInteractionSignal(InteractionSignal signal) {
    if (!mounted) return;
    switch (signal) {
      case InteractionOpened(:final item):
        _takeover.enqueue(item);
      case InteractionSettled(:final itemId):
        // **不带 sid**：收束要全桶找。迟到的 `approval/decided` 可能属于
        // **另一个**会话（用户在 A 里的时候 B 的审批在电脑上被答了）——
        // 限定当前桶会让 B 的卡片永远挂着。
        _takeover.settle(itemId);
    }
  }

  /// 把一次答复发给电脑（契约 §5.7 的 `interaction.respond`）。
  ///
  /// **失败不吞**，而且**按错误码分两类**：
  ///
  /// - `interaction/not-pending`：这一项真的没了（电脑侧答过了 / 会话被替换 / 已过期）。
  ///   客户端动作正是"刷新待处理列表"（§3.1），所以撤卡并说"已过期"。
  /// - 其余（传输 / 超时 / 未知）：这一项**很可能还在** —— 留卡，让用户重试。
  ///   把它当成"已过期"撤掉，等于让一次网络抖动变成"永远答不了"。
  ///
  /// 处理完**照原样抛**：控制器（`takeover.dart` 的 `_send`）据此知道"没发出去"，
  /// 从而不写成功回执、不撤卡。
  Future<void> _onTakeoverAnswer(InteractionAnswer answer) async {
    try {
      await widget.app.respondInteraction(answer);
    } on Exception catch (error) {
      final expired =
          error is ProtocolException &&
          error.code == ErrorCode.interactionNotPending;
      if (expired) _takeover.settle(answer.itemId);
      if (mounted) {
        DshToast.show(
          context,
          expired ? '这一项已过期：$error' : '没发出去，再试一次：$error',
          kind: DshToastKind.error,
        );
      }
      rethrow;
    }
  }

  void _onTakeoverChanged() {
    if (mounted) setState(() {});
  }

  /// 已经处理过的那次"打开文件"（见 `initState`）。
  int _seenFileOpenTicket = 0;

  /// `AppModel.openFile` 之后：切到文件面板并拉开右抽屉。
  ///
  /// **只认序号**：`AppModel` 的通知里绝大多数与打开文件无关（流式输出每秒几十条），
  /// 每次都拉抽屉会把用户正在做的事打断。同一个路径连点两次也会再开一次（序号递增）。
  void _onAppFileOpen() {
    final ticket = widget.app.fileOpenTicket;
    if (ticket == _seenFileOpenTicket) return;
    _seenFileOpenTicket = ticket;
    if (!mounted) return;
    if (widget.app.fileOpenRequest == null) return; // closeFile：什么都不用做
    setState(() => _sidePanel = SidePanel.file);
    openSide();
  }

  @override
  void dispose() {
    widget.app.removeListener(_onAppFileOpen);
    _takeover.removeListener(_onTakeoverChanged);
    _takeover.dispose();
    unawaited(_interactionSub?.cancel());
    _input.removeListener(_onInputChanged);
    _input.dispose();
    super.dispose();
  }

  void _onInputChanged() => setState(() {});

  /// 重新拉一次会话列表，失败**要说出来**。
  ///
  /// 失败必须可见：空态下那几行字是用户唯一的线索来源，
  /// "拉取失败却什么都不显示"会让人以为"电脑上真的没有会话"——
  /// 而两者的下一步动作完全不同（一个是去电脑上开会话，一个是查连接）。
  Future<void> _refreshSessions() async {
    await widget.app.refreshSessions();
    if (!mounted) return;
    final error = widget.app.lastError;
    if (error == null) return;
    DshToast.show(context, '拉取会话失败：${error.message}', kind: DshToastKind.error);
  }

  /// 发一句。
  ///
  /// **幂等键在入队时生成**（契约 §5.6）：重发复用同一个 —— 换键等于换了一次新消息。
  ///
  /// ## 参数形状（踩过）
  ///
  /// 电脑侧要的是 `{ sid, content }`，而 `content` 是**非空数组、每项带 `type`**
  /// （照 DSH 的 `PromptContentPart`：文本是 `{type:'text', text}`）。
  /// 早先这里发的是 `{ sid, text }` —— 电脑侧回 `content 必须是非空数组`，
  /// 而那个错误只在一闪而过的 SnackBar 里，看起来就是"发了啥也没有"（真机实测）。
  ///
  /// ## 分流只有一处
  ///
  /// 判据在 [sendRouteOf]（纯函数、可单测）：命令 → `command.execute`；
  /// 普通消息 → `session.prompt`；子会话 → `subagent.prompt`。
  /// **这里不重写判据** —— 两处判据必然有一天对不上，而对不上的症状是
  /// "同样一句话在某个会话里发不出去"。
  Future<void> _send() async {
    final text = _input.text.trim();
    final sid = widget.app.currentSid;
    // **"只发一张图"是合法的**（2026-10-20 修）：原来这里只看 `text.isEmpty`
    // 就 return，于是选了照片却没打字时点发送**什么都不发生** ——
    // 而 DSH 的 `content` 本来就是 part 数组，可以没有文本 part。
    final hasImage = _attachments.any((item) => !item.isInert);
    if ((text.isEmpty && !hasImage) || _sending) return;
    // **没选会话就发不出去，必须说出来**：静默 `return` 会让用户以为"点了没反应"，
    // 而那正是"我发了啥也没有"最常见的成因（真机实测）。
    if (sid == null) {
      DshToast.show(context, '先在列表里选一个会话，再发消息');
      return;
    }
    setState(() => _sending = true);
    try {
      // 判据与顶栏同一个（[_subagentParentSid]）：它比"我是不是从面板走进来的"宽一档
      // —— 恢复出来的子会话（重启后直接落在子会话上）也该走这条路，
      // 而那条按记忆判会走 `session.prompt`，必然被宿主拒。
      final route = sendRouteOf(
        text: text,
        isSubagent: _subagentParentSid != null,
      );

      if (route == SendRoute.command) {
        // **命令不随附件走**（契约 §5.7：这一版 `command.execute` 恒传 `[]`）。
        // 悄悄把图片丢掉比拒绝更坏 —— 用户会以为目标设上了、图也一起发了。
        if (hasImage) {
          _toast('命令暂不随附件发送：先移除图片再发');
          return;
        }
        final outcome = await widget.app.executeCommand(text);
        if (!mounted) return;
        if (outcome == null) {
          // 失败如实报，**文本留在输入框**（改一改就能再发）。
          _toast('命令没有执行：${widget.app.lastError?.message ?? '电脑侧没有给结论'}');
          return;
        }
        if (outcome.matched) {
          // 跑过了：结果落在命令卡上（`command/run` + `command/done` 是 DSH 的
          // 生命周期事件，随会话流到手机），所以输入框可以清。
          // **附件不清**：命令没带它们走。
          _input.clear();
          return;
        }
        // 电脑侧没有这条命令（DSH 的 `execute` 回 `undefined`）⇒ 与 Web 的输入
        // 流水线同一条：**当普通消息发出去**（`machine.ts:170-175`），并说一句。
        // 不说的话，用户会以为命令跑过了 —— 那正是本轮要消灭的形状。
        _toast('电脑上没有这条命令，按普通消息发送');
      }

      final requestId = 'p-${DateTime.now().microsecondsSinceEpoch}';
      // **带上发送模式**（排队 / 插话）：DSH 原生二选一，我们这边一个方法
      // 带 `mode` 参数（`connector/src/handlers.ts` 的 `session.prompt`）。
      // 不给这个字段时电脑侧按默认的 queue 走 —— 与本文默认值一致。
      //
      // **子会话走另一个方法**：对子会话直接 `session.prompt` 会被宿主拒成
      // `internal: session "…" is owned by subagent routing`（2026-10-21 真机实测，
      // 手机上就是一句「发送失败」）。子会话唯一的写入口是 `subagent.prompt`
      // （契约 §5.7），参数形状与这里逐字相同。
      //
      // 两个方法名与参数形状都在 `app/lib/wire/rpc/` 里（`session.dart` /
      // `subagent.dart`）——界面层不再知道线上方法的形状。
      final content = promptContentOf(text: text, attachments: _attachments);
      final mode = widget.app.sendMode.wire;
      if (route == SendRoute.subagentPrompt) {
        await sendSubagentPrompt(
          widget.app.client,
          sid: sid,
          content: content,
          mode: mode,
          requestId: requestId,
        );
      } else {
        await sendPrompt(
          widget.app.client,
          sid: sid,
          content: content,
          mode: mode,
          requestId: requestId,
        );
      }
      _input.clear();
      if (mounted) setState(() => _attachments.clear());
    } catch (error) {
      if (!mounted) return;
      DshToast.show(context, '发送失败：$error', kind: DshToastKind.error);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // **切会话 = 换待处理桶**（DSH 的待处理是 per-session 的）。
    // 放在 build 里而不是某个点击回调：切会话的路径有两条（抽屉、内联列表），
    // 漏一条就会"切过去了但卡片没换"。控制器内部幂等，重复设不通知。
    _takeover.setCurrentSid(widget.app.currentSid);
    // 任务清单按会话取；`sid` 为 null（列表页）时给空表。
    final jobsSid = widget.app.currentSid;
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        return Stack(
          children: [
            // 主界面（聊天页）。两个抽屉都是**原生 Drawer**（在 Scaffold 里）：
            // 左 = `drawer`、右 = `endDrawer`，两条边都能**跟手**拖出
            //（`Scaffold.drawerEdgeDragWidth` + `endDrawerEnableOpenDragGesture`），
            // 遮罩、回弹、拖拽关闭全由 Flutter 管 —— 不自己画第二套。
            // **系统返回 = 回父会话**（移动端专有的那条路；Web 靠浏览器 history）。
            //
            // 判据用 `PopScope.canPop`（`packages/flutter/lib/src/widgets/pop_scope.dart:83-96`）：
            // 在子会话里置假 ⇒ 系统返回不弹路由，改由回调回父会话；其余情况照常。
            // **抽屉开着时不抢**：`DrawerController` 会给自己挂一个
            // `LocalHistoryEntry`（`material/drawer.dart:526-546`），而
            // `ModalRoute.popDisposition` 先看它（`routes.dart:942-947`）——
            // 但回调仍可能被叫到，所以这里再按抽屉状态让一次。
            PopScope<void>(
              // 与 `←` 同一个判据（数据里的父级），否则"恢复出来的子会话"会被
              // 顶栏认成子会话、而返回键直接退出 App —— 同一件事两套答案。
              canPop: _subagentParentSid == null,
              onPopInvokedWithResult: (didPop, _) {
                if (didPop) return;
                final scaffold = _scaffoldKey.currentState;
                if (scaffold != null &&
                    (scaffold.isDrawerOpen || scaffold.isEndDrawerOpen)) {
                  return;
                }
                unawaited(_returnFromSubagent());
              },
              child: _mainScaffold(context, jobsSid: jobsSid),
            ),
            // ---- 右缘那条"棒棒"：右抽屉的标识（能侧滑的提示）----
            // **抽屉开着时它消失**（用户原话："侧滑之后棒要消失"）：
            // 那时右侧抽屉已经在眼前，再留一条标识只会挡着它。
            if (!_sideOpen)
              Positioned.fill(
                child: DshRightEdgeStick(
                  topInset: 56 + MediaQuery.of(context).padding.top,
                ),
              ),
          ],
        );
      },
    );
  }

  /// 主界面（聊天页本体）。
  ///
  /// 单独成方法而不是嵌在 `build` 里：嵌着时那个 `Stack` 会深到
  /// **括号数不清**（实测改出过语法错误）。一层一个方法，
  /// 读代码时也不必同时记住"我在 Stack 的第几个孩子里"。
  Widget _mainScaffold(BuildContext context, {required String? jobsSid}) {
    final c = context.dshColors;
    final sid = widget.app.currentSid;
    // **轮组**：先按轮切开，再把"收起"那些轮里的过程条目去掉
    // （工具 / 命令 / 重试 / 压缩），只留用户那句话、正文与收口行。
    // 运行中的一轮不可折叠 —— 组头只在轮次收口后出现
    // （DSH 同一条：`TurnProcessNodeView.tsx:18` 在未 closed 时整行不渲染）。
    final groups = buildTurnGroups(widget.app.items);
    final collapsible = collapsibleTurns(groups);
    final items = applyTurnCollapse(
      groups,
      isExpanded: (turn) => _turnExpanded(sid, turn, groups),
    );
    // 「助手」头画在每组第一条助手侧条目上方（用户 2026-10-23：
    // 「助手不应该是开始的时候显示吗」）。流式尾条目同理：本轮还没有任何
    // 助手侧条目时才由它自己带头。
    // 头按**折叠后可见的条目**算：被藏掉的那条不能是头像落点
    // （否则收起一轮时头像跟着过程一起消失）。
    final headAt = assistantHeadItemIds(items);
    final liveShowHead = groups.isEmpty
        ? true
        : !groups.last.items.any(isAssistantSide);
    // **各算一次**：顶栏那两枚计数 chip 与右抽屉三个面板读的是**同一份**。
    //
    // 子智能体那枚 chip 的数是**目录直接子级**（Web 的 `directCount`，
    // `SubagentHeaderLineage.tsx:496-500`），"正在跑"是其中 `running` 的行
    // （`:498` 用 `activity === 'running'`，而 `activity` 就是会话的 `running`，
    // `:471-475`）。**不是 `mode`** —— 那是"能不能续聊"。
    final subsCatalog = widget.app.subagentCatalogOf(sid ?? '');
    final subs = [for (final row in subsCatalog.entries) _nodeOf(row)];
    final jobs = _jobsFor(jobsSid);
    final runningSubs = subs.where((n) => n.running).length;
    final runningJobs = jobs.where((j) => j.isLive).length;
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: c.bgBase,
      drawer: widget.drawer,
      // **输入法不许自己弹出来**：抽屉开、关两个方向都失焦。
      //
      // 打开时 `DrawerController` 把焦点搬进抽屉（`material/drawer.dart:538`）；
      // 关闭时框架又把焦点还给页面里**上一次的焦点节点**
      //（`widgets/focus_manager.dart:1444-1461` 的 `setFirstFocus` → `focusedChild`），
      // 那通常就是输入栏 —— 而 `EditableText._handleFocusChanged` 一拿回焦点
      // 就开输入连接（`widgets/editable_text.dart:4752-4753`）。
      // 真机复现与取舍见 `input_focus.dart` 文件头。
      onDrawerChanged: (_) => dismissInputFocus(),
      // **跟手**：两条边都用 Flutter 自带的边缘拖动（左 `drawer`、右 `endDrawer`）——
      // 手指拖多少抽屉走多少，松手按位置/速度决定开还是回弹，全由 `DrawerController` 管
      // （`material/drawer.dart` 的 `_move` / `_settle`）。自己写第二套只会更差。
      //
      // **拖出区是 `min(屏宽 28%, 64px)`，不是默认的 20px + 安全区**
      // （2026-10-19 用户原话：「rikkahub 也是 APP 端 agent，人家是整个页面
      // 侧滑都可以，我觉得他这个是好啊，体验很好」）。`Drawer` 的判定是
      // **水平**拖拽，与消息列表的**垂直**滚动不冲突
      // （`material/drawer.dart:657-665` 的 `dragAreaWidth` 可由
      // `edgeDragWidth` 指定；默认只有 20px + padding）。
      //
      // **两条上限，都是实测撞出来的**：
      // - **64px 硬顶**：320px 窄屏上 28% = 89.6px，会把底部**统计条的横滑**
      //   抢走（`16 轮 650 步 · 338M tok · 缓存命中 97%` 那一行四枚 chip，
      //   横滑是为"四位数也滑得到"专门做的 ——
      //   `app/test/widget_test.dart` 的"统计条横滚不裁切"）。窄屏上
      //   64px 已经是从左缘起手的全部空间。
      // - **28% 比例顶**：宽屏上 64px 太窄，仍是"从最边缘起手"。
      //   两者取小，于是窄屏 64px、宽屏 28%。
      drawerEdgeDragWidth: math.min(
        MediaQuery.of(context).size.width * 0.28,
        64,
      ),
      appBar: ChatAppBar(
        // **子会话里顶栏就是那一层导航**：左侧 `←` 回父会话，标题 = 当前子智能体的
        // 名字（点它开「切换子智能体」）。这样不再需要内容区上方那条 40dp 头部条 ——
        // 手机上"进入下一层"的惯例就是导航栏左侧返回 + 标题即位置。
        //
        // **"在不在子会话里"看的是数据里的父级**（[_subagentParentSid]），不是
        // 导航记忆：记忆只有一层，往深处再走一层就错了（2026-10-23 的 bug：
        // 孙级头部显示的仍是祖父）。
        title: _subagentParentSid != null
            ? _subagentLabel
            // 没有会话标题时显示 App 名（与启动器 / 抽屉头部同一处口径）。
            : (widget.app.currentTitle ?? kAppName),
        onOpenDrawer: openDrawer,
        onBack: _subagentParentSid == null
            ? null
            : () => unawaited(_returnFromSubagent()),
        onTitleTap: _subagentParentSid == null ? null : _showSubagentSwitcher,
        onNewSession: widget.onNewSession,
        // **连接状态点**（原来是文字胶囊）：绿=服务中 / 转圈=连接中·握手中·重连中 /
        // 红=其余。形状与颜色照 DSH 的 `StateDot`（出处见 `dsh_state_dot.dart`），
        // 文字退进 tooltip —— 顶栏一行五个位置，文字状态位会把标题挤没。
        connectionState: dotStateOf(widget.app.connection),
        connectionTooltip: _connectionTooltip(),
        onConnectionTap: _onStatusTap,
        // **计数 chip 与标题同一行**（照 DSH Web header 的 actions band，
        // `ConversationSession.tsx:127-129`）—— **有才显示，没有就整枚不占位**。
        // 点它开右抽屉对应面板：手机上不放下拉菜单（手指点不中小目标），
        // 而右抽屉本来就是这三个面板的家，且能原路关回来。
        subagentCount: subs.length,
        subagentRunning: runningSubs,
        // 目录读失败时这枚 chip 是**唯一**能进面板重试的入口（DSH 的 `visible`
        // 同样把 `state === 'error'` 算作要渲染，`SubagentHeaderLineage.tsx:617-631`）。
        subagentCatalogFailed: subsCatalog.state == SubagentCatalogState.error,
        jobCount: jobs.length,
        jobRunning: runningJobs,
        onTapSubagents: () => _openSidePanel(SidePanel.subs),
        onTapJobs: () => _openSidePanel(SidePanel.jobs),
      ),
      // ---- 右抽屉：一个抽屉三个面板 ----
      // 用 `endDrawer` 而不是自绘遮罩：右缘**跟手**拖出、拖拽/点遮罩关闭、
      // 以及"开着时棒棒消失"的开关（`onEndDrawerChanged`）全都是原生行为。
      //
      // **宽度不再铺满整屏**（2026-10-19，用户原话"右侧的我感觉做成抽屉好看点，
      // 因为现在这样直接换页了感觉怪怪的"）：留出左侧一条让下层会话露出来，
      // 这才读作"抽屉"而不是"翻到另一页"。
      //
      // DSH 的对应规则是 `fullscreen ? 100vw : width`，且"Below 768px fullscreen
      // is derived from viewport width"（`ui-sidebar-right/.../SidebarRight.tsx:5-7,310`）
      // —— 手机上走全屏是它的**派生默认**，而它同时保留 manual mode。
      // 触屏上用户要的是抽屉感，所以这里按面板给两个宽度：
      // 文件面板（diff 预览）要宽度，任务 / 子智能体一行能放下，可以窄一些。
      endDrawer: Drawer(
        width: _sideDrawerWidth(context),
        backgroundColor: c.bgBase,
        // 抽屉的"浮层感"：圆角 + 左边框。**全屏时不画** ——
        // 铺满整屏还留圆角会露出底下的会话，读作"没收干净"。
        // 判据就是 `_sideFullscreen` 本身（宽度与 chrome 同一个来源，
        // 不设第二个开关）。
        shape: _sideFullscreen
            ? null
            : const RoundedRectangleBorder(
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(DshRadius.lg),
                  bottomLeft: Radius.circular(DshRadius.lg),
                ),
              ),
        child: SidePane(
          header: _sideHeader(),
          panel: _sidePanel,
          onPanelChanged: (p) {
            setState(() => _sidePanel = p);
            // 抽屉内切到子智能体页：同样是一次"面板被看见"。
            if (p == SidePanel.subs) _refreshSubsMetrics();
          },
          onClose: _closeSide,
          fileBody: _fileBody(),
          jobs: jobs,
          // 子智能体：**目录树**（直接子级 + 展开才懒加载孙级）。
          // 点行进入那个子会话；点行左侧的 disclosure 只展开。
          // 会话 id 已是别名（连接器在 `session.projections` 里换过，见
          // `connector/src/handlers.ts` 的 `aliasSubagentCatalog`），
          // 所以直接 `openSession` 就通。
          subsBody: SubagentTree(
            rootSid: sid ?? '',
            catalogOf: widget.app.subagentCatalogOf,
            nodeOf: _nodeOf,
            onOpen: _openSubagent,
            onLoad: (target) =>
                unawaited(widget.app.refreshSubagentCatalog(target)),
          ),
          runningJobs: runningJobs,
          runningSubs: runningSubs,
          onToggleJob: (job) => _toggleJob(job),
          // 停止：任务面板里最常见的那件事。**不传它就永远没有停止按钮**
          //（渲染条件里有 `onStop != null`）—— 第一版就漏了传，
          // 截图里运行中的任务旁边空着。
          onStopJob: (job) => _stopJob(job),
          openJobIds: _openJobs,
          fullscreen: _sideFullscreen,
          onToggleFullscreen: () =>
              setState(() => _sideFullscreen = !_sideFullscreen),
        ),
      ),
      onEndDrawerChanged: (open) {
        // 输入法不许自己弹出来：右抽屉开、关都收一次
        //（与左抽屉 `onDrawerChanged` 同一条，见 `input_focus.dart`）。
        dismissInputFocus();
        // 落在子智能体页就是"面板被看见了"的那一刻：那一页的指标（running /
        // 时长 / token）来自 `session.list` 的行，现拉一次才不会停在旧值。
        if (open && _sidePanel == SidePanel.subs) _refreshSubsMetrics();
        // 右缘那条棒棒的显隐跟着它走（开着就收起来）。
        if (_sideOpen == open) return;
        setState(() => _sideOpen = open);
      },
      body: LayoutBuilder(
        builder: (context, viewport) {
          // **底部这一块的预算只算一次**（接管卡与候选面板从同一个数里分空间）。
          // 键盘弹起后可用高度只剩一小半，各算各的"屏幕比例"就会叠出溢出 ——
          // 真机 2026-10-24 抓到的那次是 `BOTTOM OVERFLOWED BY 204 PIXELS`，
          // 接管卡的「跳过 / 提交」被顶出屏幕。
          final budget = _BottomBudget.of(
            viewport.maxHeight,
            cardActive: _takeover.active != null,
          );
          return Column(
            children: [
              // **没选中会话时只有「对话」一个 tab**（2026-10-19 用户原话：
              // 「没有会话的时候对话，轨迹不用显示吧，没会话你显示没用啊」）。
              //
              // 轨迹页读的是**当前会话**的事件流；没有会话时它是一块空屏，
              // 而那一格 tab 等于在说"这里有个你点不开的东西"。
              // **选中了但还没有条目时仍然显示两个**：那时轨迹页有话说
              // （会话刚建、事件正在来）。
              if (sid != null)
                DshSegmented(
                  labels: const ['对话', '轨迹'],
                  index: _tab,
                  onChanged: (i) => setState(() => _tab = i),
                ),
              Expanded(
                child: _tab == 0
                    ? _ChatTab(
                        app: widget.app,
                        items: items,
                        // 轮组的折叠接线（见 `_mainScaffold` 里那段注释）。
                        collapsibleTurns: collapsible,
                        isTurnExpanded: (turn) =>
                            _turnExpanded(sid, turn, groups),
                        onToggleTurn: (turn, expanded) =>
                            _toggleTurn(sid, turn, expanded),
                        headAt: headAt,
                        liveShowHead: liveShowHead,
                        paired: widget.paired,
                        autoOpenToolDetail: _autoOpenToolDetail,
                        isBlank: widget.app.currentIsBlank,
                        // hero 的两枚 chip 都要开 sheet / 建会话，所以**由页面层建**
                        // （`_ChatTab` 是纯展示的，拿不到那些方法）。
                        hero: _buildHero(),
                        onOpenDrawer: widget.onOpenDrawer,
                        onRefreshSessions: _refreshSessions,
                        onOpenSession: widget.onOpenSession ?? (_) {},
                        onConnect: widget.onConnect,
                        // 已配对时给空态一条"重新配对"的出路（议题 3，1 步直达）。
                        onRePair: widget.paired ? widget.onRePair : null,
                      )
                    : _TrajectoryTab(
                        app: widget.app,
                        onTapTurn: _showTraceSheet,
                        onTapSegment: _showSegmentSheet,
                      ),
              ),
              // ---- 底部：接管卡 + 输入栏 + 统计条 ----
              Container(
                // **`bgBase`，不是 `sidebar`**（2026-10-20 修）。
                //
                // 用户反馈："下面有一块都没覆盖"。实测（深色，`x=30` 竖向）：
                // 页面 `#151517` 到 `y=2341`，**`y=2343` 起到底边是 `#1B1B1C`**
                // —— 正好是 `c.sidebar` 的暗色值，高度 ≈ 系统导航条 + 6。
                //
                // 根因：输入栏内部（`DshComposer`）为了去掉灰带已改用 `bgBase`，
                // 但**外面这层包裹仍是 `sidebar`**，而它下面有一条
                // `padding.bottom + 6` —— 输入栏盖不到那块，就露出一条 sidebar 色。
                // 也就是说灰带没被"去掉"，而是被挤到了最底部一条缝里。
                color: c.bgBase,
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).padding.bottom + 6,
                ),
                // **底部这一块有硬上限**（`_BottomBudget` 的 `blockMax`）：
                // 它和消息列表在同一个 `Column` 里，而消息列表是 `Expanded` ——
                // 不设上限时键盘一弹就会溢出（真机 `h1-typed.png`）。
                // 上限之内**接管卡先让位**：它是 `Flexible`，主体自己滚、动作行恒可见；
                // 队列条 / 输入栏 / 统计条是固定件，永远整块可见。
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: budget.blockMax),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // **接管卡在输入栏上方**：它接管的是"下一步做什么"，
                      // 而输入栏仍然是最后一行（用户随时能看到自己在哪打字）。
                      // 原型是把输入栏整块换掉 —— 手机上并排更省高度，
                      // 且不会让用户以为"输入框不见了"。
                      Flexible(
                        child: TakeoverPanel(controller: _takeover),
                      ), // **排队条**（DSH Web 的 `conversation.input.dock` 槽里的
                      // QueueDock）：会话正在跑时发出去的消息排进下一个轮次，
                      // 这里列出来并可编辑 / 删除 / 插话。空队列整条不占位。
                      if (_subagentReadOnlyReason == null && sid != null)
                        QueueDock(app: widget.app, sid: sid, running: _running),
                      // 一次性 / 模式未知的子会话：**整条输入栏换成只读状态框**
                      // （DSH 的 `SubagentReadOnlyComposer`，同一个判据）。
                      if (_subagentReadOnlyReason != null)
                        SubagentReadOnlyBand(reason: _subagentReadOnlyReason!)
                      else
                        DshComposer(
                          controller: _input,
                          attachments: _attachments,
                          // 候选菜单的名单来自电脑侧（`repo.info.commands`）——
                          // 手机侧不抄第二份（契约 §5.7 的 `repo.info` 行）。
                          slashCommands: widget.app.slashCommands,
                          // **面板的高度上限来自底部预算**：不是屏幕的一个比例，
                          // 而是"输入卡上方真正剩下的空间"（扣除输入栏固定件、
                          // 统计条，接管卡在场时再扣它那两行）。
                          panelMaxHeight: budget.panelMax,
                          // `@` 候选：能力位与处理器都来自电脑侧（`repo.info.caps.references`
                          // 与 `refs.files` / `refs.sessions`）。老连接器 ⇒ 能力位 false ⇒
                          // 面板整块不出现（不是显示一个永远空的列表）。
                          mentionsEnabled: widget.app.mentionsAvailable,
                          onQueryMentions: widget.app.mentionsAvailable
                              ? widget.app.queryMentions
                              : null,
                          // 模型名与推理等级：**从真投影来**（见 `_modelLabel`）。
                          // 推理等级同样不写死：模型自带 effort 时显示它，否则显示"默认"。
                          modelName: _modelLabel,
                          reasoningLabel: _reasoningLabel,
                          access: permissionChipOf(
                            value: widget.app.permissionValue,
                            catalog: widget.app.permissionCatalog,
                          ),
                          sendMode: widget.app.sendMode,
                          sending: _sending,
                          enabled: _hasData && sid != null,
                          // **hero 上换一套占位文案**（DSH 的 `placeholder.hero`，
                          // `locales.ts:23`）：那一屏的动作是"开一个新任务"。
                          // 只在真的显示了 hero 时才换 —— 与 `_ChatTab` 用同一个判据，
                          // 免得出现"文案说开新任务、屏幕却是空态"。
                          hintText: _heroVisible
                              ? kComposerHintHero
                              : kComposerHintDefault,
                          // 运行中且没有草稿时，主键是"停止"（照 Web 的 primaryStops）。
                          running: _running,
                          onStop: _stop,
                          onSend: _send,
                          onAttach: _showAttachSheet,
                          onPickModel: _showModelSheet,
                          onPickAccess: _showAccessSheet,
                          onRemoveAttachment: (item) =>
                              setState(() => _attachments.remove(item)),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: DshStatsBar(
                          // **三条都从真投影来**（`session.projections` 的
                          // `sessionStats` / `tokenUsage` / `contextPressure`）。
                          // 2026-10-15 之前这里是写死的 `第 1 轮 · N 步` /
                          // `302K · 缓存 0%` / `3%` —— 与电脑侧毫无关系，
                          // 而用户无法分辨哪个是真的。**拿不到就整条不显示**，
                          // 不猜一个数字把"看起来连着"当成"连着"。
                          turnText: _turnText,
                          usageText: _usageText,
                          contextPercent: _contextPercent,
                          // 三个统计各自弹一个 sheet（原型 `sheet-stats` /
                          // `sheet-usage` / `sheet-context`）。
                          onTapTurn: _showStatsSheet,
                          onTapUsage: _showUsageSheet,
                          onTapContext: _showContextSheet,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 统计条（三条都从 `session.projections` 来）
  // ---------------------------------------------------------------------------

  /// `第 N 轮 · M 步 · X tok/s`；轮次为 0 或读不到就是 `null`（整条不显示）。
  ///
  /// 有解码数据时**把输出速率拼在同一格里**，照 Web 的
  /// `1 turns 1 steps · 20 tok/s`（`StatsPills.tsx:244-245`）——
  /// 手机原来只显示轮次步数，速率那一项整个丢了。速率数字用 Web 的
  /// `formatTokensPerSecond`（`message-chrome.ts:71-74`：≥10 取整，<10 一位小数）。
  ///
  /// **简洁档只留速率**（Web 的 `usePerformanceUsage === 'compact'`：
  /// `ActivityPill` 在 compact 下只渲染速度读数，`StatsPills.tsx:242`）。
  String? get _turnText {
    final stats = widget.app.sessionStats;
    final tps = stats?.tokensPerSecond;
    if (widget.app.performanceUsage == PerformanceUsage.compact) {
      return tps == null ? null : '${formatTokensPerSecond(tps)} tok/s';
    }
    final base = stats?.turnLabel;
    if (base == null) return null;
    if (tps == null) return base;
    return '$base · ${formatTokensPerSecond(tps)} tok/s';
  }

  /// `302K tok · 缓存命中 96%`；读不到用量就是 `null`。
  ///
  /// **与 Web 逐字一致**（`StatsPills.tsx:288-302` 的 `UsagePill`）：
  /// 合计 = `billedInput + output` 走 `{count} tok`，命中文字是
  /// `t('stats.cacheHit', {percent})` = `缓存命中 {percent}%`
  /// （`locale.ts:78`）。2026-10-17 前这里是 `302K · 缓存 96%` ——
  /// 少一个 ` tok`、多一个"中"字之差，真机对比截图就能看出来。
  ///
  /// **简洁档只留缓存命中**（Web compact：`UsagePill` 只渲染命中读数，
  /// `StatsPills.tsx:291-293`）。
  ///
  /// **缓存率为 null 时不拼那半句**：没有计费输入时算不出命中率，
  /// 而显示 `缓存命中 0%` 会让用户以为"缓存坏了"，其实只是这一轮还没花 token。
  String? get _usageText {
    final usage = widget.app.tokenUsage;
    if (usage == null) return null;
    // **全零也算"没有数据"**：刚建的 blank 会话，投影里 `tokenUsage` 是一个
    // 字段齐全但全为 0 的对象（不是 `null`），于是这一格会渲染出 `0 tok` ——
    // 用户看到"用量 0"会以为在统计，其实一个字都没花。与上面"拿不到就整条
    // 不显示"同一条纪律：**没数据就不要显示一个像数据的数字**。
    if (usage.grandTotal == 0) return null;
    final hit = usage.cacheHitText;
    if (widget.app.performanceUsage == PerformanceUsage.compact) {
      return hit == null ? null : '缓存命中 $hit%';
    }
    if (hit == null) return '${usage.totalLabel} tok';
    return '${usage.totalLabel} tok · 缓存命中 $hit%';
  }

  /// 上下文占用百分比。**算法与 Web 逐字一致**：
  /// `projectedTokens ?? pressureTokens` 除以 `contextWindow`
  /// （`packages/client/ui-conversation/src/client/context-occupancy.ts:15-25`）。
  ///
  /// 投影**本来就给窗口大小**（`contextWindow` 在 wire view 里）——
  /// 手机原来没解析它，于是这里只能返回 null，那一格整个不显示。
  int? get _contextPercent => widget.app.contextPressure?.occupancy?.percent;

  // ---------------------------------------------------------------------------
  // 右抽屉（文件 / 任务 / 子智能体）
  // ---------------------------------------------------------------------------

  /// 顶栏状态点画成哪一档，**由 `dotStateOf` 一处决定**
  /// （`ui/dsh_state_dot.dart`，与 DSH 的 `ConnectionIndicator` 三态同义）。
  ///
  /// 这里原来返回的是**文字**（`已连接` / `N 任务运行中`）：文字状态位在 390px
  /// 顶栏上把标题挤到 `max-width: 42vw`；而任务计数在 chip 行里本来就另算了一遍 ——
  /// 同一件事两处各算一次就是第二个真值源，所以这一条改成"只表连接、不管任务"。

  /// 状态点的说法。文案来自 [connectionLabel] —— **同一个状态只有一套说法**
  /// （抽屉连接行、设置页、顶栏共用），不在这里另写一套。
  String _connectionTooltip() =>
      '连接状态：${connectionLabel(widget.app.connection)}（点按查看连接操作）';

  /// 是否有"可看的数据"（已配对）。
  bool get _hasData => widget.paired;

  /// 用户手动展开 / 收起的轮：`sid → turn → 是否展开`。
  ///
  /// **按轮号存，不按列表下标**：新来一条消息会让下标整体挪位，展开态就落到
  /// 别的一轮上（`widget_test` 有一条"展开后换一份 items 仍然展开"钉的是同一件事）。
  final Map<String, Map<int, bool>> _turnOpen = <String, Map<int, bool>>{};

  /// 这一轮此刻要不要展开。
  ///
  /// 三档优先：用户手动点过 → 听用户的；否则看「工作步骤收起时机」
  /// （`CollapseTiming.nextInput` 只让**最新那一轮**保持展开，其余收起；
  /// `completion` 一律收起）。
  bool _turnExpanded(String? sid, int turn, List<TurnGroup> groups) {
    final key = sid ?? '';
    final manual = _turnOpen[key]?[turn];
    if (manual != null) return manual;
    if (widget.app.collapseTiming != CollapseTiming.nextInput) return false;
    // 「下次有新消息时」：只有**最新那一轮**保持展开。用 groups.last 而不是
    // "最后一个可折的轮" —— 用户一发出下一句，上一轮就该收起来，
    // 而那时新一轮还不可折（还没收口）。
    return groups.isNotEmpty && turn == groups.last.turn;
  }

  void _toggleTurn(String? sid, int turn, bool expanded) {
    setState(() => (_turnOpen[sid ?? ''] ??= <int, bool>{})[turn] = expanded);
  }

  /// 当前会话是否正在跑（排队条的插话门 + 发送模式 sheet 的禁用判据）。
  ///
  /// 走 `AppModel.runningOf` —— **单一真值**（事件流说了算，`session.list` 只补初值）。
  /// 这里曾经直读 `sessionOf(sid)?.running`（那张快照），于是它旧地停在一个
  /// 已经结束的轮次上：输入栏一直显示「排队发送」，运行条一直转
  /// （2026-10-22 真机，见 `app_model.dart` 的 `runningOf`）。
  bool get _running {
    final sid = widget.app.currentSid;
    if (sid == null) return false;
    return widget.app.runningOf(sid);
  }

  /// 工具明细是否默认展开（"工作步骤展示"偏好）。
  ///
  /// 口径照 Web 的 `transcriptView`（`ui-chat/src/client/locale.ts:103-108` 四档）：
  /// **完全展开**一律展开；**详细**在会话运行时展开（Web 的"运行中直接显示
  /// 组正文"，完成后仍保留组头）；其余两档折叠、可手动展开。
  bool get _autoOpenToolDetail {
    final view = widget.app.transcriptView;
    if (view == TranscriptView.fullyOpen) return true;
    return view == TranscriptView.detailed && _running;
  }

  /// 输入栏上显示的模型名。
  ///
  /// **从真投影来**（`SessionSummary.model`，源头是 DSH 的 `modelSelection` 投影，
  /// 见 `connector/src/dsh/models.ts`）。这里曾经写死 `'claude-opus'`，
  /// 于是手机上显示的模型与电脑侧真实状态毫无关系 —— 用户看到的"模型"是个谎言。
  ///
  /// 三个档次，按证据从强到弱：
  /// ① 电脑侧说了 → 显示那个模型 id；
  /// ② 电脑侧没说（`null`）但连着 → "未选择"（**不猜**）；
  /// ③ 没连着 → "未连接"。
  ///
  /// 目录里有这一项时用它的**展示名**（`DeepSeek-V41-Flash`），与 Web 的
  /// trigger 同一条链（`ModelSelect.tsx:419` 的 `model.name`）；目录里没有
  /// （刚拉到手、模型已下线）才退到 id。
  String get _modelLabel {
    if (!_hasData) return '未连接';
    if (widget.app.currentSid == null) return '未选择';
    // 走 `AppModel.currentModel`（唯一出口）：它先看**本会话的投影提示**
    // `modelSelection`，再退到清单行 —— 只读清单行的话，子智能体页面上
    // 永远显示「未选择」（子会话不在连接器那张活 agent 表里）。
    final model = widget.app.currentModel;
    if (model == null) return '未选择';
    return widget.app.modelCatalog?.displayNameOf(
          provider: model.provider,
          model: model.model,
        ) ??
        model.label;
  }

  /// 推理等级的文字；**`null` = 不显示那一截**。
  ///
  /// 也**不写死**（原来是 `'高'`）：电脑侧给了 effort 就显示它。
  /// 目录里有这一项时把 effort id 翻成展示名（照 Web 的 `effortLabel`，
  /// `ModelSelect.tsx:130-136`）。
  ///
  /// **为什么从"默认"改成 null**（2026-10-19）：DSH Web 的 `effortLabel`
  /// 是**条件渲染**的（`ModelSelect.tsx:488` 的
  /// `{effortLabel !== undefined && <span …>}`），而它 `undefined` 的条件是
  /// `currentChoice === undefined`（没选模型）。我们原来在"没选模型"时显示
  /// "默认"—— 那一截在 390px 屏上占约 40px，而"默认"说的是"没有信息"。
  /// **没有信息就不占位**（与"拿不到就整条不显示"同一条纪律）。
  String? get _reasoningLabel {
    if (!_hasData) return null;
    if (widget.app.currentSid == null) return null;
    // 与 [_modelLabel] 同一个出口（`AppModel.currentModel`）：
    // 推理等级是模型选择的一部分，两个来源就会"模型有、等级没有"。
    final model = widget.app.currentModel;
    if (model == null) return null;
    final name = widget.app.modelCatalog?.effortNameOf(
      provider: model.provider,
      model: model.model,
      effort: model.reasoningEffort,
    );
    return name != null && name.isNotEmpty ? name : null;
  }

  /// 顶栏状态点的点击。
  ///
  /// **统一弹连接操作 sheet**（重试连接 / 重新配对 / 打开侧面板 / 断开）：

  /// - **没配对** → 去配对页（与空态的「连电脑（配对）」同义）；
  /// - **已配对** → sheet。**不再按"serving 时开右抽屉"分叉**：右抽屉入口已经搬到
  ///   自己那个按钮上（`ChatAppBar.onOpenSide`），一个点只做一件事；
  ///   而"任何状态 ≤2 步走到重新配对"的硬判据照旧成立（点 1 → sheet 里选 1）。
  void _onStatusTap(Rect anchor) {
    if (!widget.paired) {
      widget.onConnect?.call();
      return;
    }
    _showConnectionActionsSheet(anchor);
  }

  /// 弹连接操作面板（议题 3 的唯一形状，三处入口共用）。
  ///
  /// [anchor] 是那枚状态点的矩形 —— 面板长在它下面（锚定浮层），
  /// 不是从屏幕底部升起来。另外两个入口（空态出路 / 抽屉连接行）
  /// 仍走底部 sheet：它们的触发点本来就在下半屏。
  void _showConnectionActionsSheet(Rect anchor) {
    unawaited(
      showConnectionActionsSheet(
        context,
        anchor: anchor,
        // 「当前连接」块（连接方式选择器第 1 步）：与设置页顶部同一块、
        // 同一套说法（`connectionSummary`）。
        connection: connectionSummary(
          state: widget.app.connection,
          active: widget.app.activeEndpoint,
          endpoints: widget.app.endpoints,
          attemptOf: widget.app.attemptOf,
        ),
        onRePair: () => widget.onRePair?.call(),
        onOpenSide: openSide,
        onDisconnect: () => widget.onDisconnect?.call(),
        // **右上角那个点也管"换方式"与"重连"**（用户原话："页面的右上角的点
        // 最好也可以点击切换方式重连"）。两个动作与设置页顶部块**同一份实现**：
        // `pickEndpointToConnect` / `reconnectNow` 住在 `connection_summary_block.dart`。
        //
        // **必须等这个 sheet 关完再开下一个**（`pop` 之后 `await` 一拍）：
        // 两层面板同时做退出/进入动画时，后开的那个会被前一个的 pop 带走 ——
        // 真机上表现为"点了「换个连接方式」，面板关了、选择框没出来"。
        onPickEndpoint: () => unawaited(
          _afterCurrentSheet(() => pickEndpointToConnect(context, widget.app)),
        ),
        onReconnect: () => unawaited(
          _afterCurrentSheet(() => reconnectNow(context, widget.app)),
        ),
        // **已经放弃自动重连时才给「重试连接」**：再试一轮，不清凭据。
        // `client.start()` 会清掉放弃标记并把退避表带回起点。
        onRetry: widget.app.connection == ConnectionStateView.gaveUp
            ? () => unawaited(widget.app.client.start())
            : null,
      ),
    );
  }

  void _closeSide() => _scaffoldKey.currentState?.closeEndDrawer();

  /// 进入一个子智能体的会话（点右抽屉「子智能体」那一行）。
  ///
  /// DSH 的目录项点开是 `openChild` → `openSession(address)`
  ///（`ui-subagent/src/client/index.ts:61-63`）—— 子会话**替换主对话区**。
  /// 地址里的父级与 mode **由画出这一行的那一层交出**（[SubagentTree.onOpen] 的
  /// 第二个参数）：DSH 同样在那一层构造
  /// `openChild({parentSessionId, childSessionId, mode})`
  ///（`SubagentHeaderLineage.tsx:279-287`），不查表。
  ///
  /// `_subagentReturnFrom` 只是**老连接器**的第三档兜底（见 [_subagentParentSid]）：
  /// 子会话在抽屉里是**藏起来的**（`sessionVisible` 的第 1 条：`subagent` 不列），
  /// 没有父级就没有返回入口，用户根本找不回来。
  Future<void> _openSubagent(SubagentNode node, String parentSid) async {
    _closeSide();
    // **先记后退**：`_subagentReturnFrom` 是"进子会话之前的那个会话"。
    setState(() {
      _subagentReturnFrom = parentSid;
      _subagentChildSid = node.id;
      _subagentMode = node.row.mode;
    });
    await widget.app.openSession(node.id);
  }

  /// 当前子会话是否只读，以及原因（`null` = 可以正常输入）。
  ///
  /// 照 DSH 的 `selectReadOnlySubagent`（`ui-subagent/src/client/index.ts:37-49`）：
  /// `one-shot` 与 `unknown` 的输入栏换成说明；`continuable` 保留正常输入。
  /// 我们拿不到 `parentAvailable`（它不在 `session.list` 的字段里），所以
  /// “父会话离线”那一档暂不判 —— 不猜，不把“可能能发”说成“一定能发”。
  ///
  /// Note: 为什么只判这两档、不扩 `session.list` —— 见
  /// `.agents/notes/implemented/2026-10-21-subagent-entry-readonly-composer.md`。
  SubagentReadOnlyReason? get _subagentReadOnlyReason {
    if (_subagentReturnFrom == null) return null;
    if (_subagentMode == 'one-shot') return SubagentReadOnlyReason.oneShot;
    // `null` 与 `unknown` 同一档：说不清能不能续聊就不给输入。记忆非空时 mode
    // 必有值（进入即赋值），所以这一支是**默认拒绝**的那一侧，不是活分支。
    if (_subagentMode == null || _subagentMode == 'unknown') {
      return SubagentReadOnlyReason.unknown;
    }
    return null;
  }

  /// 当前子会话在**父级目录**里的名字（子会话头部那个标题）。
  ///
  /// 判据照 Web 的 `switcherDisplayTitle`（`SubagentHeaderLineage.tsx:490-495`）：
  /// 父级 catalog 里**当前子级那一行**的 label（没有就用 id），
  /// 找不到那一行才退回会话标题。**不缓存 label**：目录重读过就以新的为准。
  ///
  /// **查不到就显示会话自己的标题，不回落成字面量「子智能体」** ——
  /// 那会把"没查到"伪装成"名字就叫子智能体"，用户看到的是"里面还是它自己"，
  /// 也正是 2026-10-23 那个 bug 在屏幕上的样子。
  ///
  /// 第二档是 `currentTitle`，再退到 App 名（冷启动、`session.list` 还没到）。
  /// **不另取 `sessionOf(current)?.displayTitle`**：它和 `currentTitle` 是同一次
  /// `_sessions` 查找，所以后者为 null 时前者必然也是 null —— 那一档永远不会给出值。
  String get _subagentLabel {
    final parent = _subagentParentSid;
    final current = widget.app.currentSid;
    if (parent != null && current != null) {
      final row = widget.app
          .subagentCatalogOf(parent)
          .entries
          .where((r) => r.id == current)
          .firstOrNull;
      if (row != null) return row.displayLabel;
    }
    return widget.app.currentTitle ?? kAppName;
  }

  /// 当前子会话的**父级** sid（`null` = 不在子会话里：根会话 / 没连上）。
  ///
  /// 三档，按可信度排（与 DSH `SubagentHeaderLineage.tsx:789-797` 同一个次序）：
  ///
  /// 1. `session.list` 行的 `parentSessionId`（电脑侧已过别名表，见
  ///    `connector/src/handlers.ts` 的 `session.list`）—— **真值**；
  /// 2. 已读目录里扫到"当前会话"的那一行（`AppModel.subagentParentOfCatalogEntry`）
  ///    —— 老连接器没有第 1 档时，只要是从面板走进来的，父级目录就已经在表里；
  /// 3. 导航记忆 `_subagentReturnFrom` —— **只在这一层确实是"走进去的那个会话"时**
  ///    才算（`_subagentChildSid` 与当前会话相同），否则从抽屉打开别的会话时
  ///    子会话头部会挂在无关会话上。
  ///
  /// 第 3 档不能删：**新手机连老连接器**时 `parentSid` 为空，删了就退回
  /// 2026-10-21 那个"进子会话出不来"的坑（返回按钮根本不出现）。
  ///
  /// 「只读 / 可续聊」那条**仍看导航记忆**（`_subagentMode` 只在走进目录那一刻
  /// 知道）：恢复出来的子会话没有 mode，按这里判只读会把输入栏凭空禁掉 ——
  /// 那是另一个方向的"说的和做的不一致"。取舍见决策笔记。
  String? get _subagentParentSid {
    final current = widget.app.currentSid;
    if (current == null) return null;
    final fromData = widget.app.sessionOf(current)?.parentSid;
    if (fromData != null) return fromData;
    final fromCatalog = widget.app.subagentParentOfCatalogEntry(current);
    if (fromCatalog != null) return fromCatalog;
    if (_subagentChildSid == current) return _subagentReturnFrom;
    return null;
  }

  /// 打开「切换子智能体」面板：父级目录的树，当前行加粗。
  ///
  /// Web 是头部那个 244px 宽的 `switcher` 下拉（`SubagentHeaderLineage.tsx:802-821`）。
  /// **形态也是下拉**：锚在标题正下方（`showDshPopover`）。第一版用的是底部
  /// sheet，用户 2026-10-21 当场否掉 —— 「点击在上面，下面弹出你不觉得不跟手吗？」
  /// 点顶栏却从屏幕底部升起来，视线要跨过大半屏去找结果。
  void _showSubagentSwitcher(Rect anchor) {
    // **root 是当前会话真正的父级**（数据里的那个），当前行加粗。
    // 以前 root 用的是导航记忆、当前行是 `_subagentChildSid` —— 两者都不跟数据走，
    // 于是孙级的面板里会列着"它自己"（`u3-switcher.png`）。
    final parent = _subagentParentSid;
    final current = widget.app.currentSid;
    if (parent == null || current == null) return;
    // 面板里同样画着指标（token / 时长），打开就现拉一次。
    _refreshSubsMetrics();
    // 父级目录可能还没读过（恢复出来的子会话、或老连接器）：现拉一次，
    // 与展开子级走同一个入口。**不拉就打开**会是一个空面板 ——
    // 用户读成"没有兄弟"，而真相是我们还没问。
    if (widget.app.subagentCatalogOf(parent).state !=
        SubagentCatalogState.ready) {
      unawaited(widget.app.refreshSubagentCatalog(parent));
    }
    unawaited(
      showDshPopover<void>(
        context: context,
        anchor: anchor,
        title: '切换子智能体',
        body: Builder(
          builder: (sheetContext) => ListenableBuilder(
            // **sheet 是独立路由**：页面层的重建到不了它，所以展开子级 /
            // 重试之后，它必须自己听 `AppModel` 的通知才画得出新目录。
            listenable: widget.app,
            builder: (context, _) => SubagentTree(
              rootSid: parent,
              catalogOf: widget.app.subagentCatalogOf,
              nodeOf: _nodeOf,
              currentSid: current,
              emptyText: '没有其他子智能体。',
              onOpen: (node, parentSid) {
                Navigator.of(sheetContext).pop();
                unawaited(_switchSibling(node, parentSid));
              },
              onLoad: (target) =>
                  unawaited(widget.app.refreshSubagentCatalog(target)),
            ),
          ),
        ),
      ),
    );
  }

  /// 切到同一个父级下的另一个子会话（父级由**画它的那一层**给出，不扫描）。
  Future<void> _switchSibling(SubagentNode node, String parentSid) async {
    // **点当前行什么都不做**（面板已经关了）：以前这里会 `openSession(自己)`，
    // 屏幕上看起来就是"又进了自己一次"。DSH 那一下是重新打开同一个会话 +
    // 关面板（`SubagentHeaderLineage.tsx:279-287`），对手机来说就是纯噪音。
    if (node.id == widget.app.currentSid) return;
    setState(() {
      // 记忆跟着更新：它是老连接器那一档的兜底，留着旧父级会让第 3 档指错。
      _subagentReturnFrom = parentSid;
      _subagentChildSid = node.id;
      // mode 是**这一行自己的**（`SubagentRow.mode`）。以前回目录里再查一次：
      // 目录可能正在重读（`loading` 保留旧 entries，界面照常画行），那一拍里回查
      // 查不到 ⇒ 可续聊的孙级被说成「暂时只读」，而且不会自愈（mode 只取一次）。
      _subagentMode = node.row.mode;
    });
    await widget.app.openSession(node.id);
  }

  /// 回到**数据里的父级**（头部条的「返回会话」/ 系统返回键）。
  ///
  /// 逐层返回靠的就是这一点：孙级回子级、子级回父级。
  /// `_subagentReturnFrom` 只当老连接器没有 `parentSid` 时的兜底（见
  /// [_subagentParentSid] 的第 3 档）。
  Future<void> _returnFromSubagent() async {
    // `PopScope` 的回调可能在路由销毁后才到（SDK 的提醒，
    // `widgets/routes.dart:2057-2059`）—— 用 `setState` 前必须先看 `mounted`。
    if (!mounted) return;
    final from = _subagentParentSid;
    if (from == null) return;
    setState(() {
      _subagentReturnFrom = null;
      _subagentChildSid = null;
      _subagentMode = null;
    });
    await widget.app.openSession(from);
  }

  /// 等当前 sheet 的退出动画走完再跑 [action]。
  ///
  /// 连接 sheet 的每一项都是"先 `pop` 再做事"；而"换个连接方式"要接着开**第二个**
  /// sheet。两层动画叠在一起时，后开的那个会被前一个的 pop 一起带走 ——
  /// 真机实测两次：面板关了、选择框没出来（看起来像点了没反应）。
  ///
  /// **等的是动画时长，不是"一帧"**：`Duration.zero` 只让出一次微任务，
  /// 那时退出动画刚开始，`pop` 仍会作用到新路由上。`ModalBottomSheetRoute`
  /// 的出场时长是 `_kMinFlingVelocity` 一档的 200ms 级别，等它走完最稳。
  Future<void> _afterCurrentSheet(Future<void> Function() action) async {
    await Future<void>.delayed(const Duration(milliseconds: 260));
    if (!mounted) return;
    await action();
  }

  SideHeader _sideHeader() => switch (_sidePanel) {
    // 表头由**真的**改动数据决定（`AppModel.changedFiles`，来自工具调用），
    // 与面板体同一个真值来源 —— 所以不会出现"表头说某个文件改了 128 行、
    // 面板体说还没有改动"那种自相矛盾（2026-10-20 修过）。
    //
    // **只取一次**：在这里连问两次（`.isEmpty` 与 `.length`）会让每次 build
    // 的成本取决于"缓存命中没有"，没必要。
    SidePanel.file => _fileHeader(widget.app),
    SidePanel.jobs => const SideHeader(title: '后台任务'),
    SidePanel.subs => const SideHeader(title: '子智能体'),
  };

  /// 文件面板的表头：**正在看某个文件时是那个文件**，否则是改动清单。
  ///
  /// 两者同一处给出，是为了"表头说 5 个文件、面板里是某个文件的内容"这种
  /// 自相矛盾不可能出现（2026-10-20 修过同类的表头/面板不一致）。
  SideHeader _fileHeader(AppModel app) {
    final request = app.fileOpenRequest;
    if (request != null) {
      return SideHeader(
        title: fileNameOf(request.path),
        subtitle: request.path,
      );
    }
    // **有改动面时表头数的是桌面记录的总数**（同一份数据源）；老连接器退回旧清单。
    if (app.changesAvailable) {
      final seq = app.latestChangesSeq;
      final total = seq == null ? null : app.changesStateOf(seq).summary?.total;
      return total == null
          ? const SideHeader(title: '文件')
          : SideHeader(title: '文件', subtitle: '$total 个文件');
    }
    final changed = app.changedFiles;
    return changed.isEmpty
        ? const SideHeader(title: '文件')
        : SideHeader(title: '文件', subtitle: '${changed.length} 个文件');
  }

  Widget? _fileBody() {
    if (_sidePanel != SidePanel.file) return null;
    // 正在看某个文件（正文提及 / 改动卡行点进来的）：面板就是那份内容。
    if (widget.app.fileOpenRequest != null) {
      return _OpenedFileBody(app: widget.app);
    }
    // **有改动面就按桌面的记录画**（一轮一条 summary，行是它的 files）；
    // 没有（老连接器 / 没装 workspace-changes）才退回旧清单。
    if (widget.app.changesAvailable) {
      final seq = widget.app.latestChangesSeq;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DshSegmented(
            labels: const ['差异', '文件'],
            index: _fileTab,
            onChanged: (i) => setState(() => _fileTab = i),
          ),
          Expanded(
            child: seq == null
                ? _EmptyFilePane(kind: _fileTab == 0 ? 'diff' : 'file')
                : _ChangesPane(app: widget.app, seq: seq, tab: _fileTab),
          ),
        ],
      );
    }
    final changed = widget.app.changedFiles;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 文件页的分段（差异 ⇄ 文件）—— 原型注释：
        // *"不做左右滑:diff 自身要横滑看长行"*。
        DshSegmented(
          labels: const ['差异', '文件'],
          index: _fileTab,
          onChanged: (i) => setState(() => _fileTab = i),
        ),
        if (changed.isEmpty) ...[
          _fileTab == 0
              ? const _EmptyFilePane(kind: 'diff')
              : const _EmptyFilePane(kind: 'file'),
        ] else
          // **两个页签同一份真数据**：`文件` = 路径，`差异` = 路径 + 行数增量。
          // 这样才不会出现"文件页列着 5 个文件、差异页说还没有改动"那种
          // 自相矛盾（那正是 2026-10-20 修掉过的那类）。
          Expanded(
            child: _ChangedFileList(rows: changed, showStat: _fileTab == 0),
          ),
      ],
    );
  }

  // **文件面板底部那三个动作已移除**（2026-10-20）：`复制路径` /
  // `在电脑打开` / `分享` 全都只弹「还没做」，而它们挂在**根本没有内容**的
  // 文件面板上（面板体是 `_EmptyFilePane`）。`settings_page.dart` 的文件头
  // 早就写下这条纪律：「一行点下去只弹"还没做"的假入口，比没有这一行更糟
  // （用户会以为功能坏了）」。等文件面板接上真的 `deliverables` 再一起做
  // —— 那时"复制路径"才有路径可复制。

  /// 一条普通提示（操作结论）。
  ///
  /// **2026-10-17 从 `_toast` 拆出来**：原来只有一个助手、且所有消息都被缀上
  /// "还没接上数据"—— 于是"已切到 deepseek-chat"在界面上变成
  /// "已切到 deepseek-chat 还没接上数据"，一句**谎话**（它确实切了）。
  void _toast(String message, {DshToastKind kind = DshToastKind.info}) {
    DshToast.show(context, message, kind: kind);
  }

  // ---------------------------------------------------------------------------
  // sheet 体系（照原型的 `sheet-*` action）
  // ---------------------------------------------------------------------------

  /// 打断当前轮次（运行中且没有草稿时，主键是它）。
  ///
  /// 走 `session.cancel`（与 Web 同一个 DSH 方法）。DSH 的语义是"取消当前
  /// 轮次但**保留待处理收件箱**"—— 排队中的消息不会被这次取消丢掉。
  /// **失败要如实说**：静默失败会让用户以为"点了没反应"。
  Future<void> _stop() async {
    final sid = widget.app.currentSid;
    if (sid == null) return;
    final ok = await widget.app.cancel(sid);
    if (!mounted) return;
    _toast(
      ok ? '已请求停止' : '停止失败：${widget.app.lastError?.message ?? '电脑侧没有给结论'}',
    );
  }

  /// `sheet-stats`：会话统计。**数值全部来自 `sessionStats` 投影**。
  ///
  /// 2026-10-17 之前这里是写死的 `12.4 / 3.8 / 420 / 516 / 1 · 3` ——
  /// 五个数一个都不来自电脑侧，而用户无法分辨。现在逐行对照 Web 的
  /// `ActivityPill` 浮层（`StatsPills.tsx:249-277`）：**哪项没有数据就
  /// 不摆那一行**（Web 的 `stats.llmMs > 0 && …` 同一个门）。
  void _showStatsSheet() {
    final stats = widget.app.sessionStats;
    final tps = stats?.tokensPerSecond;
    final ttft = stats?.averageTtftMs;
    final rows = <Widget>[
      if (stats != null && stats.llmMs > 0)
        DshKeyValue(label: '模型用时', value: formatCompactDuration(stats.llmMs)),
      if (stats != null && stats.toolMs > 0)
        DshKeyValue(label: '工具用时', value: formatCompactDuration(stats.toolMs)),
      if (ttft != null)
        DshKeyValue(
          label: '首 token (TTFT)',
          value: '${ttft.round()}',
          unit: 'ms',
        ),
      if (tps != null)
        DshKeyValue(
          label: '输出速度',
          value: formatTokensPerSecond(tps),
          unit: 'tok/s',
        ),
      if (stats != null && stats.turns > 0)
        DshKeyValue(label: '轮次 / 步数', value: '${stats.turns} / ${stats.steps}'),
    ];
    unawaited(
      showDshSheet<void>(
        context: context,
        title: '会话统计',
        body: rows.isEmpty
            ? const _SheetEmptyNote(what: '这个会话还没有计时数据')
            : Column(children: rows),
      ),
    );
  }

  /// `sheet-usage`：Token 用量。**数值全部来自 `tokenUsage` 投影**。
  ///
  /// 行与门都对照 Web 的 `UsagePill` 浮层（`StatsPills.tsx:311-330`）：
  /// 缓存写入为 0 时那一行不摆；合计 = 计费输入 + 输出。
  void _showUsageSheet() {
    final c = context.dshColors;
    final usage = widget.app.tokenUsage;
    final hit = usage?.cacheHitText;
    unawaited(
      showDshSheet<void>(
        context: context,
        title: 'Token 用量',
        body: usage == null
            ? const _SheetEmptyNote(what: '这个会话还没有 token 用量')
            : Column(
                children: [
                  if (hit != null) DshKeyValue(label: '缓存命中', value: '$hit%'),
                  DshKeyValue(
                    label: '未缓存输入',
                    value: formatExactTokens(usage.uncachedInputTokens),
                  ),
                  DshKeyValue(
                    label: '缓存读取',
                    value: formatExactTokens(usage.cacheReadTokens),
                  ),
                  if (usage.cacheWriteTokens != 0)
                    DshKeyValue(
                      label: '缓存写入',
                      value: formatExactTokens(usage.cacheWriteTokens),
                    ),
                  DshKeyValue(
                    label: '输出',
                    value: formatExactTokens(usage.outputTokens),
                  ),
                  Divider(height: 20, color: c.layer2),
                  DshKeyValue(
                    label: '合计',
                    value: formatExactTokens(usage.grandTotal),
                  ),
                ],
              ),
      ),
    );
  }

  /// `sheet-context`：上下文已用 N% —— **三段用量条**是这一屏的重点。
  ///
  /// 分子分母来自 `contextPressure` 投影（Web 的 `contextOccupancy` 同一公式），
  /// 三段分段来自 `contextBreakdown` 投影（启发式估算，Web 同样标 `~`）。
  /// 2026-10-17 之前这里四个数是写死的（7200/10100/2600/1000000）。
  void _showContextSheet() {
    final c = context.dshColors;
    final occupancy = widget.app.contextPressure?.occupancy;
    if (occupancy == null) {
      unawaited(
        showDshSheet<void>(
          context: context,
          title: '上下文',
          body: const _SheetEmptyNote(what: '电脑侧还没有报告上下文用量（需要至少一次请求）'),
        ),
      );
      return;
    }
    // 有分段就画三段条；没有就只画百分比（Web 的 ContextMeter 同样此时
    // 只有一个 total 段）。
    final breakdown = widget.app.contextBreakdown;
    final meter = breakdown == null
        ? DshContextMeter(
            systemTokens: 0,
            toolTokens: 0,
            messageTokens: occupancy.usedTokens,
            limitTokens: occupancy.contextWindow,
          )
        : DshContextMeter(
            systemTokens: breakdown.systemTokens,
            toolTokens: breakdown.toolsTokens,
            messageTokens: breakdown.messageTokens,
            limitTokens: occupancy.contextWindow,
          );
    unawaited(
      showDshSheet<void>(
        context: context,
        title: '上下文已用 ${meter.percent}%',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (breakdown == null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  '电脑侧没有给出三段分段，这里只显示总占用。',
                  style: TextStyle(fontSize: 12, color: c.labelTertiary),
                ),
              ),
            meter,
          ],
        ),
      ),
    );
  }

  /// `sheet-traj`：点轮次行弹的详情。
  ///
  /// **长文本走纵向块**（`DshKeyValue.multiline`）：`提问` / `结果` 的值可能是一整句
  /// 英文，放进 KV 的一行形态会撑破屏幕 —— 2026-10-22 真机就是
  /// `RIGHT OVERFLOWED BY 474 PIXELS`，「结果」两个字被挤成竖排
  /// （根因：`DshKeyValue` 的值是无约束 `Text`，见 `dsh_sheet.dart` 的类文档）。
  /// 短字段（用时 / 计数）仍走一行形态，读起来更省高度。
  ///
  /// **只有「关闭」一个动作**：原来那个「查看完整调用」是 `onPressed: pop()`，
  /// 点了只是关掉面板 —— 又一个假入口，按第八条教训删掉。
  void _showTraceSheet(TraceTurn turn) => unawaited(
    showDshSheet<void>(
      context: context,
      title: '第 ${turn.turn} 轮',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DshKeyValue(label: '用时', value: turn.timeLabel),
          if (turn.countsLabel.isNotEmpty)
            DshKeyValue(label: '计数', value: turn.countsLabel),
          if (turn.stepsTruncated)
            const DshKeyValue(label: '时间轴', value: '这一轮步数超过上限，只画了最近的若干步'),
          if (turn.prompt.isNotEmpty)
            DshKeyValue(label: '提问', value: turn.prompt, multiline: true),
          if (turn.response.isNotEmpty)
            DshKeyValue(label: '结果', value: turn.response, multiline: true),
          if (turn.prompt.isEmpty && turn.response.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '电脑侧还没给这一轮的预览（刚起，或没有文本输出）。',
                style: TextStyle(
                  fontSize: 12,
                  color: context.dshColors.labelTertiary,
                ),
              ),
            ),
        ],
      ),
      actions: [
        DshSheetAction(
          label: '关闭',
          filled: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    ),
  );

  /// 点一格时间轴弹的详情（与轮次详情同一个面板形态）。
  ///
  /// 一格可能是**好几段合并**来的（窄屏上过窄的相邻段会并成一格，
  /// 规则见 `trajectory_timeline.dart` 文件头），所以这里逐段列出，
  /// **一段都不省** —— 合并只是画法，不是丢数据。
  ///
  /// 时长读 `durationMs`（电脑侧算好的）；还在跑的段说"进行中"，
  /// 不补一个 0。
  void _showSegmentSheet(TraceTurn turn, List<TrajectoryStep> steps) {
    if (steps.isEmpty) return;
    final merged = steps.length > 1;
    unawaited(
      showDshSheet<void>(
        context: context,
        title: merged
            ? '第 ${turn.turn} 轮 · ${steps.length} 段'
            : '第 ${turn.turn} 轮',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (merged)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '这几段在时间轴上挨得太近，画成了一格；这里逐段列出。',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.dshColors.labelTertiary,
                  ),
                ),
              ),
            for (final step in steps)
              DshKeyValue(
                label: step.label.isEmpty
                    ? step.kindLabel
                    : '${step.kindLabel} · ${step.label}',
                value: _segmentDurationLabel(step),
              ),
          ],
        ),
        actions: [
          DshSheetAction(
            label: '关闭',
            filled: true,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  /// 一段的时长文案：电脑侧给了就照说，没给就说进行中 / 未知。
  ///
  /// **失败与用时并列**：段的粒度上"多久"与"成没成"是两件事
  /// （轮次那一级 DSH 会拿"失败"替换用时，`TurnProcessNodeView.tsx:24-30`，
  /// 但那里一轮只有一格；这里一格一段，两个信息都塞得下）。
  static String _segmentDurationLabel(TrajectoryStep step) {
    final duration = step.durationMs;
    final parts = <String>[
      if (step.isError) '失败',
      if (duration == null) '进行中' else formatElapsedMs(duration),
    ];
    return parts.join(' · ');
  }

  /// 模型选择（§7.9 的行结构 + DSH 的模型/推理等级两级的流动）。
  ///
  /// **2026-10-15 删掉四个手抄的模型名**。原来是
  /// `claude-opus` / `claude-sonnet` / `gpt-5-codex` / `deepseek-v4.1-flash`
  /// 四个写死的名字，`selected` 也写死（第一个恒为 true），点完只弹 toast
  /// **不切任何东西**。
  ///
  /// 现在的来源：
  /// - **读**：`session/modelCatalog`（连接器已接，`dsh/models.ts`）。
  ///   手机上显示的名字与电脑侧**同一份真值**，不手抄第二份。
  ///   形状是 DSH `buildModelCatalog` 的返回值（`{default, routableProviders,
  ///   groups, failures}`）——2026-10-17 修：解析器原来认的是一个臆想形状，
  ///   目录在生产里一次都没解析成功过，详见 `model/model_catalog.dart` 文件头。
  /// - **写**：`session/select-model` —— **与 Web 用同一个 DSH 方法**
  ///   （已核实 Web 侧调的就是它，
  ///   `packages/client/ui-model-selection/src/client/directory.ts:98`）。
  ///
  /// ## 与 Web 的流动差异（有意偏离，触屏合理形态）
  ///
  /// Web 的 `ModelSelect` 是"根菜单 → 模型面板 → 推理等级面板"的 drill
  /// （`ModelSelect.tsx:46` 的 `Pane`）；手机上是两个底部 sheet：
  /// 点模型行 → 有推理档的模型进第二屏选等级（默认档预选，照 Web
  /// `choices` 的构造：`reasoning.defaultEffort`），没有推理档的直接切。
  /// 语义逐字对照 Web：选模型带 `defaultEffort`、选等级带那个 id、
  /// "默认"只在 `defaultEffort` 缺省时才出现（`ModelSelect.tsx:129-140`）。
  void _showModelSheet() {
    final c = context.dshColors;
    final catalog = widget.app.modelCatalog;
    if (catalog == null || catalog.groups.isEmpty) {
      _toast('拿不到模型目录：电脑侧没有返回 session/modelCatalog');
      return;
    }
    final current = widget.app.currentModel;
    unawaited(
      showDshSheet<void>(
        context: context,
        title: '选择模型',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final group in catalog.groups) ...[
              // 分组头（provider 名）—— Web 的根菜单同样按 provider 分组。
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                child: Text(
                  group.name,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: c.labelCaption,
                  ),
                ),
              ),
              for (final entry in group.models)
                DshPickerRow(
                  name: entry.displayName,
                  tags: [
                    if (entry.description != null)
                      entry.description!
                    else
                      group.name,
                    // 有推理档的模型把档数说出来：用户据此知道点了还有下一步。
                    if (entry.reasoning != null)
                      '${entry.reasoning!.efforts.length} 档推理等级',
                  ],
                  selected:
                      current != null &&
                      current.provider == group.id &&
                      current.model == entry.id,
                  onTap: () => _pickModel(group, entry),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// 点一个模型行：有推理档的进等级二级 sheet，没有的直接切。
  Future<void> _pickModel(
    ModelProviderGroup group,
    ModelCatalogEntry entry,
  ) async {
    final reasoning = entry.reasoning;
    if (reasoning == null) {
      Navigator.of(context).pop();
      await _switchModel(
        provider: group.id,
        model: entry.id,
        effort: null,
        name: entry.displayName,
      );
      return;
    }
    // 预选：当前会话正在用这个模型时用它自己的 effort，否则退到 provider 默认
    // （Web 的 `effectiveEffort`，`ModelSelect.tsx:121`）。
    final current = widget.app.currentModel;
    final sameModel =
        current != null &&
        current.provider == group.id &&
        current.model == entry.id;
    final selected = reasoning.effectiveEffortOf(
      sameModel ? current.reasoningEffort : null,
    );
    unawaited(
      showDshSheet<void>(
        context: context,
        title: '推理等级 · ${entry.displayName}',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // "默认"只在 provider 没有指定 defaultEffort 时出现
            // （`ModelSelect.tsx:132-134`：有默认档时就只列各档）。
            if (reasoning.defaultEffort == null)
              DshPickerRow(
                name: '默认',
                tags: const ['跟随这个提供商的默认等级'],
                selected: selected == null,
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(
                    _switchModel(
                      provider: group.id,
                      model: entry.id,
                      effort: null,
                      name: entry.displayName,
                    ),
                  );
                },
              ),
            for (final effort in reasoning.efforts)
              DshPickerRow(
                name: effort.name,
                tags: [
                  if (effort.description != null) effort.description!,
                  if (effort.id == reasoning.defaultEffort) '提供商默认',
                ],
                selected: effort.id == selected,
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(
                    _switchModel(
                      provider: group.id,
                      model: entry.id,
                      effort: effort.id,
                      name: entry.displayName,
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 切模型。**失败要如实说** —— 静默失败会让用户以为"点了没反应"，
  /// 而那正是这一版之前的样子（点完只弹一个"切到 X"的 toast）。
  Future<void> _switchModel({
    required String provider,
    required String model,
    required String? effort,
    required String name,
  }) async {
    final picked = await widget.app.selectModel(
      provider: provider,
      model: model,
      reasoningEffort: effort,
    );
    if (!mounted) return;
    if (picked == null) {
      _toast(
        '切换失败：${widget.app.lastError?.message ?? '电脑侧没有给结论'}',
        kind: DshToastKind.error,
      );
      return;
    }
    // **成功不弹**：模型名与推理档就在输入栏上，弹一条"已切到 X"是噪音
    // （2026-10-26 真机原话：黑色的选择成功弹窗又丑又多余）。
  }

  /// 权限选择（**目录来自电脑侧** + 完全权限的**风险确认门**，§7.10）。
  ///
  /// ## 名单为什么不再手抄
  ///
  /// 2026-10-15 之前这里是三档写死的枚举（只读 / 工作区内可改 / 完全权限），
  /// 点完只改本地字段、与电脑侧无关。而 DSH 的预设表是**部署可配的**
  /// （`packages/bundle/base/cordis.patch.yml:262-271`）—— 电脑上加一个预设、
  /// 改一个名字，手抄的那份就对不上了。所以清单走 `permission.catalog`
  /// （连接器透传 DSH 的 `@Remote('catalog')`，
  /// `packages/interaction/permission-presets/src/index.ts:292`），
  /// **显示的名字与说明与电脑侧同一份真值**。
  ///
  /// §7.10 的硬规则："未授权 → 绝不生效"。所以带风险门的那一档
  /// **不是直接切**，而是先弹风险门、要勾选"我已了解风险"才能启用。
  /// 判据照 Web 客户端：`danger-full-access` 与 `auto`
  /// （`ui-permission-presets/src/client/presentation.ts:4,7`）。
  // ---- 新会话页（hero）：两枚 chip 的取值与写路径 ----
  //
  // 取舍（为什么选预设走 `session.create` 而不是 `agentPresets.select`）见
  // `.agents/notes/implemented/2026-10-17-blank-session-hero.md`。

  /// hero 现在真的显示着吗。**与 `_ChatTab` 必须同一条判据** ——
  /// 两处不一致就会出现"占位文案说开新任务、屏幕却是空态"。
  bool get _heroVisible {
    if (!widget.app.currentIsBlank) return false;
    return !(widget.paired &&
        widget.app.connection != ConnectionStateView.serving);
  }

  /// 建这一屏的 hero（chip 的点击要开 sheet / 建会话，只有页面层拿得到那些方法）。
  Widget _buildHero() {
    final app = widget.app;
    final sid = app.currentSid;
    final roster = app.agentPresetRoster;
    // 目录拿不到时整枚 chip 是占位态（`null` → 「选择工作区」那句同款占位）。
    final presetId = app.agentPresetValue ?? roster?.defaultId;
    return ConversationHero(
      // 标签链照 DSH（`ConversationContent.tsx:89-108`），纯函数在
      // `model/workspace.dart` 里，有单测钉住五级。
      workspaceLabel: workspaceChipLabel(
        workspacesReady: app.workspaces.isNotEmpty,
        sessionWorkspaceTitle: app.currentWorkspace?.title,
        cwd: sid == null ? null : app.sessionOf(sid)?.cwd,
      ),
      presetLabel: (roster == null || presetId == null)
          ? null
          : roster.displayNameOf(presetId),
      workspaceTooltip: app.currentWorkspace?.path,
      presetTooltip: _presetTooltip(roster, presetId),
      onPickWorkspace: _showWorkspacePicker,
      onPickPreset: _showPresetPicker,
    );
  }

  String? _presetTooltip(AgentPresetRoster? roster, String? id) {
    if (roster == null || id == null) return null;
    for (final option in roster.options) {
      if (option.id == id) {
        return option.displayDescription ?? kNoPresetDescription;
      }
    }
    return null;
  }

  /// 工作区选择器。
  ///
  /// **语义照 DSH**：切工作区 = **立刻落一个该工作区的 blank 会话**
  /// （`ConversationContent.tsx:119-131` 的 `onPick` → `navigation.ts:220-230`），
  /// 不是"只记住选择"。手机走 `session.create({workspaceId})`：
  /// 那是既有的方法（`session.create` 一直收 `workspaceId`），不需要新方法面。
  void _showWorkspacePicker() {
    final app = widget.app;
    final groups = app.workspaces;
    if (groups.isEmpty) {
      // 与权限目录同一条纪律：拿不到就**明说**，不摆一个空选择器。
      _toast('拿不到工作区清单：电脑侧没有返回 workspace.list');
      return;
    }
    final current = app.currentWorkspace?.workspaceId;
    unawaited(
      showDshSheet<void>(
        context: context,
        title: '工作区',
        body: Column(
          children: [
            for (final group in groups)
              DshPickerRow(
                name: group.title,
                tags: [if (group.path.isNotEmpty) group.path],
                selected: group.workspaceId == current,
                onTap: () {
                  Navigator.of(context).pop();
                  // 选中的就是当前那个：什么都不做（点一下不该多出一个 blank 会话）。
                  if (group.workspaceId == current) return;
                  unawaited(_startSession(workspaceId: group.workspaceId));
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 模式（Agent 预设）选择器。**只有 blank 会话上有这一屏**，
  /// 所以写路径不必碰"跑过就锁"那条限制（见 `_startSession`）。
  void _showPresetPicker() {
    final app = widget.app;
    final roster = app.agentPresetRoster;
    if (roster == null || !roster.available || roster.options.isEmpty) {
      _toast('拿不到 Agent 预设目录：电脑侧没有返回 agentPresets.list');
      return;
    }
    final current = app.agentPresetValue ?? roster.defaultId;
    unawaited(
      showDshSheet<void>(
        context: context,
        title: 'Agent 预设',
        body: Column(
          children: [
            for (final option in roster.options)
              DshPickerRow(
                name: option.displayName,
                // 说明来自电脑侧（`AgentPresetRow.description`）；没有就不给这一行 ——
                // 自己编一句会在 DSH 改词时静默分叉。
                tags: [option.displayDescription ?? kNoPresetDescription],
                icon: 'agentPreset',
                selected: option.id == current,
                onTap: () {
                  Navigator.of(context).pop();
                  if (option.id == current) return;
                  unawaited(_startSession(agentPreset: option.id));
                },
              ),
          ],
        ),
      ),
    );
  }

  /// hero 上的一次选择 = **开一个新任务**（照 DSH `AgentPresetSeat.tsx:4-9` 的立场：
  /// 这个选择只在会话开始前成立，所以它就该发生在"开新任务"这个动作上）。
  ///
  /// **为什么不用 `agentPresets.select`**：它对跑过一轮的会话会拒
  /// （`agent-preset/locked`，`agent-preset-registry/src/index.ts:351`），
  /// 而建会话时把 `agentPreset` 带上根本不会碰到那条限制；代价是每次换选择
  /// 会多一个 blank 会话（blank 的两边都不列，且 DSH 的 `reuseOrCreateBlank`
  /// 以后会复用它）。取舍见决策笔记。
  Future<void> _startSession({String? workspaceId, String? agentPreset}) async {
    try {
      await widget.app.createSession(
        workspaceId: workspaceId,
        agentPreset: agentPreset,
      );
    } catch (error) {
      if (!mounted) return;
      // **失败要如实说**：静默失败会让用户以为"点了没反应"。
      _toast('开新任务失败：${error is ProtocolException ? error.message : error}');
    }
  }

  void _showAccessSheet() {
    final catalog = widget.app.permissionCatalog;
    if (catalog == null || catalog.options.isEmpty) {
      _toast('拿不到权限预设目录：电脑侧没有返回 permission.catalog');
      return;
    }
    final current = widget.app.permissionValue;
    unawaited(
      showDshSheet<void>(
        context: context,
        title: '访问模式',
        body: Column(
          children: [
            for (final option in catalog.options)
              DshPickerRow(
                name: displayPresetName(option),
                // 说明来自 host（`PresetOption.description`）；没有就不给这一行
                // 标签 —— 自己编一句就会在 DSH 改词时静默分叉。
                tags: [if (option.description != null) option.description!],
                icon:
                    KnownPreset.of(option.value)?.icon ?? neutralPermissionIcon,
                selected: option.value == current,
                onTap: () {
                  Navigator.of(context).pop();
                  if (option.needsRiskGate) {
                    unawaited(_showRiskGate(option));
                  } else {
                    unawaited(_switchPermission(option));
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 切权限档。**失败要如实说** —— 静默失败会让用户以为"点了没反应"，
  /// 而那正是这一版之前的样子（点完只改一个本地字段）。
  ///
  /// 三种"没切上"必须分开说：电脑侧没有结论 / 电脑上没有 `/permission` 命令 /
  /// 电脑侧回了 error（预设名不对，原文照显）。
  Future<void> _switchPermission(PermissionPreset option) async {
    final result = await widget.app.switchPermission(option.value);
    if (!mounted) return;
    if (result == null) {
      _toast('切换失败：${widget.app.lastError?.message ?? '电脑侧没有给结论'}');
      return;
    }
    if (!result.matched) {
      _toast('这台电脑上没有 /permission 命令，切不了');
      return;
    }
    if (result.kind == 'error') {
      // DSH 的原文（如 `unknown preset "yolo" (available: …)`）——
      // 那是电脑侧权威的措辞，自己抄一份就会静默分叉。
      _toast(result.text ?? '电脑侧拒绝了这个预设');
      return;
    }
    _toast(result.text ?? '已切到 ${option.name}');
  }

  /// 完全权限的**风险确认门**：必须勾选才生效（§7.10）。
  ///
  /// 勾选态**不跨次残留**（§7.10 表格里"关掉后重开，勾选态不残留"）——
  /// 所以开门的动作里先把它清掉，而不是依赖"新建 widget 就自然是 false"
  ///（那在 widget 被复用时就不成立了）。
  Future<void> _showRiskGate(PermissionPreset option) {
    final c = context.dshColors;
    _riskAcked = false;
    return showDshSheet<void>(
      context: context,
      title: '启用${option.name}？',
      body: StatefulBuilder(
        builder: (context, setSheetState) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '这一档下，DSH 执行越权操作时不再问你。'
              '误操作（删文件、改工作区外的东西）不会被拦。',
              style: TextStyle(
                fontSize: 13,
                height: 20 / 13,
                color: c.labelSecondary,
              ),
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: () => setSheetState(() => _riskAcked = !_riskAcked),
              child: Row(
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: Checkbox(
                      value: _riskAcked,
                      onChanged: (v) =>
                          setSheetState(() => _riskAcked = v ?? false),
                      activeColor: c.roleTool,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '我已了解风险',
                      style: TextStyle(fontSize: 13, color: c.labelPrimary),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      // **勾选后"启用"才可点** —— 未授权绝不生效。
      actions: [
        DshSheetAction(
          label: '取消',
          onPressed: () => Navigator.of(context).pop(),
        ),
        DshSheetAction(
          label: '启用',
          filled: true,
          onPressed: () {
            if (!_riskAcked) return; // 没勾就不生效（门仍开着）
            unawaited(_switchPermission(option));
            Navigator.of(context).pop();
          },
        ),
      ],
    );
  }

  /// `＋` 菜单（对应桌面端的快捷键入口）。
  /// 选一张照片（相册或拍照）并挂到输入栏（**这条链是真的**：字节会随
  /// prompt 发出去）。
  ///
  /// 原生侧见 `platform/photo_picker.dart` 与 `MainActivity.kt`：
  /// 相册走系统照片选择器（**不申请权限**）；拍照要 CAMERA
  /// （本 App 已为扫一扫声明了它，所以必须已授予才发得了 intent）。
  ///
  /// 五种结果**分别说话**，不把它们混成"没反应"：
  /// 取消 → 什么都不做；平台没有 → 直说；类型不支持 → 说清是哪种；
  /// **权限被拒 → 说去哪里开**；失败 → 显示原生的原话。
  Future<void> _pickPhoto(PhotoSource source) async {
    final result = await pickPhoto(source: source);
    if (!mounted) return;
    switch (result) {
      case PhotoPicked(
        :final mediaType,
        :final data,
        :final name,
        :final byteCount,
      ):
        final already = _attachments
            .where((item) => !item.isInert)
            .fold<int>(0, (sum, item) => sum + (item.image?.byteCount ?? 0));
        final images = _attachments.where((item) => !item.isInert).length;
        // **先问宿主的限制**（`imageLimits` 投影，部署可配）：超张数 / 超单图 /
        // 超合计 / 类型不收，各自说清是哪一条。投影缺席（老连接器）⇒ 这里恒放行，
        // 让 DSH 自己拒并把 `IMAGES_TOO_LARGE` / `TOO_MANY_IMAGES` 写在错误里。
        final violation = imageLimitViolationOf(
          limits: widget.app.imageLimits,
          images: images,
          incomingBytes: byteCount,
          totalBytes: already,
          mediaType: mediaType,
        );
        if (violation != null) {
          _toast(violation);
          return;
        }
        // 再问**我们这条管道**的预算：整条 content 只占一帧，两张 3 MiB 的图
        // 就是 6 MiB 原始字节 ≈ 10.7 MB 的帧（撞 8 MiB 就断连接）。
        // 它与上一条是两个主人：那一条是宿主的业务上限，这一条是通道层参数。
        if (!fitsMessageBudget(already: already, incoming: byteCount)) {
          _toast(
            '这条消息的图片合计超过 '
            '${(kMaxTotalImageBytesForMessage / 1024 / 1024).round()} MB 了：'
            '先发出去，或者换小一点的图',
          );
          return;
        }
        setState(
          () => _attachments.add(
            PendingAttachment(
              // 没有文件名时用媒体类型的短名（`image/png` → `png`），
              // 不编一个假文件名。
              name: name.isNotEmpty ? name : mediaType.split('/').last,
              icon: 'paperclip',
              image: PickedImagePart(
                mediaType: mediaType,
                data: data,
                name: name,
                byteCount: byteCount,
              ),
            ),
          ),
        );
      case PhotoPickCancelled():
        // **用户取消不是错误**，一句话都不说。
        break;
      case PhotoPickUnavailable(:final reason):
        _toast(
          '这台设备上没有可用的${source == PhotoSource.camera ? '相机' : '相册选择器'}：$reason',
        );
      case PhotoPickPermissionDenied(:final reason):
        // 恢复动作是"去系统设置里开"，与"重试"不是一回事。
        _toast('$reason —— 到系统的应用设置里允许相机后，再点一次拍照');
      case PhotoPickUnsupportedType(:final mediaType):
        // 明确说出"哪种不发" —— DSH 只认 png/jpeg/webp/gif。
        _toast('这个格式发不出去（$mediaType）：只支持 PNG / JPEG / WebP / GIF');
      case PhotoPickTooLarge(:final byteCount):
        // **不能发**：撞 8 MiB 单帧上限会让整条连接被关掉。
        _toast(
          '这张图太大（${(byteCount / 1024 / 1024).toStringAsFixed(1)} MB）：'
          '换一张小一点的',
        );
      case PhotoPickFailed(:final reason):
        _toast('选图失败：$reason');
    }
  }

  void _showAttachSheet() {
    // **「照片」是真的**（2026-10-20）：它走系统照片选择器，选到的字节会随
    // `session.prompt` 的 `{type:'image', mediaType, data}` 一起发出去。
    //
    // 图标用 `paperclip`：DSH 与我们的图标集里都**没有** image/photo/camera
    // 那一枚（`ui-primitives/src/icons/index.tsx` 只有 folder 系列），
    // 而图标集是机生成的、不许手写 —— 用已有的"附件"字形 + 文案说清即可。
    //
    // **「上传文件」仍然不做**：DSH 的文件 part 要 `receiptId`
    // （`types.ts:98`），来自一次 `uploadFile` —— 那是另一个方法面，
    // 本仓未接。摆一个加假芯片的入口就是 2026-10-20 刚拔掉的那处。
    // **2026-10-20 又拔掉三项**：`工作区文件` / `新建终端` / `浏览器`
    // 的副标题全是"桌面端 Ctrl+P / Ctrl+` / Ctrl+T" —— 手机上**没有对应入口**
    // （它们是桌面快捷键的入口），点下去只能弹"还没做"。
    // 而项目规则写得很清楚（`settings_page.dart:7`）：
    // 「一行点下去只弹"还没做"的假入口，比没有这一行更糟」。
    // 我上一轮把它们留下了，理由是"它们各自说的是还没做、不是假装做了" ——
    // 那是我在替自己的实现找台阶，规则并不这么分。
    //
    // **`后台任务`留下了，而且做成了真的**：右抽屉本来就有那个面板
    // （`SidePanel.jobs`，顶栏计数 chip 也是开它），所以这里直接开过去，
    // 不再是"还没做"。
    const items = [
      (icon: 'paperclip', label: '拍照', desc: '用相机拍一张，随消息发出去'),
      (icon: 'paperclip', label: '照片', desc: '从相册选一张，随消息发出去'),
      (icon: 'checklist', label: '后台任务', desc: '看运行中的命令与输出'),
    ];
    unawaited(
      showDshSheet<void>(
        context: context,
        title: '添加',
        body: Column(
          children: [
            for (final item in items)
              DshPickerRow(
                name: item.label,
                tags: [item.desc],
                icon: item.icon,
                selected: false,
                onTap: () {
                  Navigator.of(context).pop();
                  if (item.label == '照片') {
                    unawaited(_pickPhoto(PhotoSource.gallery));
                  } else if (item.label == '拍照') {
                    unawaited(_pickPhoto(PhotoSource.camera));
                  } else if (item.label == '后台任务') {
                    // **落到真的面板**（不是"还没做"）：右抽屉的「任务」页。
                    _openSidePanel(SidePanel.jobs);
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 展开 / 收起一个任务：**展开即订阅输出，收起即退订**。
  ///
  /// 与 `job.follow` / `job.unfollow` 一对一。本地也维护 `_openJobs`
  /// （UI 的展开态），但**订阅状态以电脑侧为准** —— 本地那个只是为了让
  /// 箭头立刻转向，不等一个网络往返。
  Future<void> _toggleJob(SideJob job) async {
    final sid = widget.app.currentSid;
    if (sid == null) return;
    final opening = _openJobs.add(job.id);
    setState(() {});
    if (opening) {
      await widget.app.followJob(sid, job.id);
    } else {
      await widget.app.unfollowJob(sid, job.id);
    }
  }

  /// 停一个任务。**走 `job.kill`**（宿主的人类发起门面），
  /// 结论由电脑侧给（`requested` / `already-finished`）。
  ///
  /// 不做乐观更新：落终态要等 `status` 帧（`docs/plugin-and-jobs-notes.md` §B.4）。
  Future<void> _stopJob(SideJob job) async {
    final sid = widget.app.currentSid;
    if (sid == null) return;
    final outcome = await widget.app.killJob(sid, job.id);
    if (!mounted) return;
    _toast(switch (outcome) {
      'requested' => '已请求停止 ${job.label}',
      'already-finished' => '${job.label} 已经结束了',
      _ => '停止失败：电脑侧没有给结论',
    });
  }

  /// 当前会话的后台任务（`core/job.dart` 的 `JobRow` → 侧抽屉的 `SideJob`）。
  ///
  /// 映射只在这里发生一次：UI 不认识 `job.list` 的 JSON，
  /// `AppModel` 也不认识 `SideJob` 长什么样。
  List<SideJob> _jobsFor(String? sid) {
    final rows = widget.app.jobsOf(sid ?? '');
    return [
      for (final row in rows)
        SideJob(
          id: row.id,
          kind: row.kind,
          label: row.label,
          state: row.status,
          statusText: row.statusText,
          durationText: _jobDuration(row),
          // 输出只在展开时才有意义，但**无脑全给**更简单：侧抽屉自己按
          // `openJobIds` 决定显不显示。少一个"什么时候该给"的判断。
          output: widget.app.jobOutput(row.id),
          gapNote: widget.app.jobError(row.id),
        ),
    ];
  }

  /// 任务时长（`02:14`）。**从电脑侧的时间戳算，不从手机本地计时** ——
  /// 手机上的计时在锁屏/后台时会停，而任务一直在电脑上跑。
  String _jobDuration(JobRow row) {
    final end = row.finishedAt ?? DateTime.now().millisecondsSinceEpoch;
    final seconds = ((end - row.startedAt) / 1000).floor();
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// 目录一行 → 运行态视图（子会话自己的 `running` / 计时 / token / 标题）。
  ///
  /// **不缓存**：每次 `build` 从 `AppModel` 现算，少一处会跟真值漂移的副本。
  /// 三样指标都来自**子会话自己**的 `session.list` 行（`projections.values`）——
  /// 拿不到就是 `null`，界面那一格整个不显示，不拿本地时钟或旧值凑。
  SubagentNode _nodeOf(SubagentRow row) {
    final summary = widget.app.sessionOf(row.id);
    return SubagentNode(
      row: row,
      // 与 `_running` 同一条真值（快照只补初值，事件流可以撤销）。
      running: widget.app.runningOf(row.id),
      timing: summary?.subagentTiming,
      tokens: summary?.tokenUsage,
      title: summary?.title,
    );
  }

  /// 子智能体面板的内容（**目录树**，见 `ui/subagent_tree.dart`）。
  ///
  /// **2026-10-15 删掉假数据**。原来是两条写死的示例子智能体
  /// （`Extract DSH icon paths` / `Research rikkahub standalone mode`），
  /// 状态文字带「· 示例」—— 标记是有，但它**无条件**出现在面板里，
  /// 真连上了也照显示。
  ///
  /// 真数据通路：`subagentCatalog` 投影（`packages/subagent/subagent/src/catalog.ts:111-131`）
  /// 经 `session.projections` 读；写面有 `SubagentRuntime` 的
  /// `@Remote('prompt')` 与 `@Remote('interruptByParent')`
  /// （`packages/subagent/subagent/src/index.ts:445,512`）。
  ///
  /// 三个状态（加载 / 就绪 / 失败）与"已知空叶"都由 `SubagentCatalog` 带着，
  /// 面板不自己判空 —— 否则"没读到"与"读到空"又会变成同一句话。
}

/// 统计 sheet 的空态（这一项没有数据时）。
///
/// **不摆零值行**：`0 秒` / `0%` 会被读成"有数据、恰好是零"，
/// 而真相是"电脑侧还没报告"。空态把这两件事分开说。
class _SheetEmptyNote extends StatelessWidget {
  const _SheetEmptyNote({required this.what});

  final String what;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Text(
        what,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 13, color: c.labelTertiary),
      ),
    );
  }
}

/// 对话页签（消息流）。
class _ChatTab extends StatelessWidget {
  const _ChatTab({
    required this.app,
    required this.items,
    this.collapsibleTurns = const <int>{},
    this.isTurnExpanded,
    this.onToggleTurn,
    this.headAt = const <String>{},
    this.liveShowHead = true,
    required this.paired,
    required this.onOpenDrawer,
    required this.onRefreshSessions,
    required this.onOpenSession,
    required this.hero,
    this.isBlank = false,
    this.onConnect,
    this.onRePair,
    this.autoOpenToolDetail = false,
  });

  final AppModel app;
  final List<ChatItem> items;
  final bool paired;
  final VoidCallback onOpenDrawer;

  /// 可折叠的轮号（有过程条目、且已收口）。
  final Set<int> collapsibleTurns;

  /// 某一轮此刻展开与否；`null` = 没有轮组接线（只看界面时）。
  final bool Function(int turn)? isTurnExpanded;

  /// 点收口行：`(轮号, 是否展开)`。
  final void Function(int turn, bool expanded)? onToggleTurn;

  /// 该在哪些条目上方画「助手」头（每组第一条助手侧条目）。
  final Set<String> headAt;

  /// 流式尾条目要不要自己带头（本轮还没有任何助手侧条目时才带）。
  final bool liveShowHead;

  /// 当前会话是不是 blank（"从没被 agent 跑过"）。
  ///
  /// 用它选那一屏：**blank 会话 = DSH 的新会话页**（见 [ConversationHero] 的文件头）。
  /// 判据来自 `session.list` 的 `blank` 字段，不是本地推导。
  final bool isBlank;

  /// blank 时显示的 hero（由**有状态**的页面层建：chip 的点击要能开 sheet / 建会话）。
  /// 显示与否由 [isBlank] 与连接状态决定 —— 所以这里没有"空 hero"这一支。
  final Widget hero;

  /// 重新拉会话列表（由**有状态**的页面层实现：它能在 await 之后安全用 `context`）。
  final VoidCallback onRefreshSessions;

  /// 打开某个会话（主界面上的内联列表与抽屉共用同一条通路）。
  final void Function(SessionSummary session) onOpenSession;
  final VoidCallback? onConnect;

  /// 已配对时空态的"重新配对（换一台电脑）"出路（议题 3）。未配对为 `null`。
  final VoidCallback? onRePair;

  /// 工具明细默认展开（"工作步骤展示"偏好，由页面层算好传下来）。
  final bool autoOpenToolDetail;

  @override
  Widget build(BuildContext context) {
    // **"画得出来"的条目**：[OtherItem] 只计数、不渲染（[_TurnView] 把它映射成
    // `SizedBox.shrink`），而电脑侧**每个**会话的头几条都是 `session` /
    // `permission/preset` / `sandbox/mode` / `approval/policy` 这些记账事件
    // （2026-10-17 真机验收，从会话日志里数出来的），投影出来全是 OtherItem ——
    // 所以 `items.isEmpty` 在真机上**永远为假**。拿它当"这个会话没有内容"的
    // 判据，hero 一次都显示不出来（占位文案却照换，于是"文案说开新任务、
    // 屏幕却是一片空白"）。判据只能是 **blank 本身**（规格
    // `docs/subsystems/blank-session-hero.md` §5）+ 没有可见内容。
    // 取舍见 `.agents/notes/implemented/2026-10-17-hero-never-rendered-other-items.md`。
    final hasVisibleItems = items.any((item) => item is! OtherItem);
    final disconnected =
        paired && app.connection != ConnectionStateView.serving;
    // **blank 会话先走 hero**（DSH 的首页就是这一屏，见 `ConversationHero` 的文件头）。
    //
    // 位置在"内联列表"之前：blank 会话本来就被 `sessionVisible` 从列表里藏掉
    // （`tree.ts:245`），所以它既不是列表的一行、也不该落到"还没有内容"那种空态上。
    // **连接断掉时不显示** —— 那时 hero 上的两枚 chip 点了都要建会话，
    // 而电脑不在线；空态的头条（"连不上"）才是那一刻该说的话。
    // 刚发出、还没起轮次的用户消息是可见条目：那时照常渲染消息流，不进 hero。
    if (isBlank && !disconnected && !hasVisibleItems) return hero;

    if (items.isEmpty) {
      // **没选中会话但电脑侧有会话：把列表直接铺在主界面上。**
      //
      // 这是被真机逼出来的：会话原先只存在于左侧抽屉里，而主界面是一块几乎空白的屏 ——
      // 数据明明已经拉到了，用户却"什么都看不见"，只能靠先发现 `☰` 才能找到会话。
      // 抽屉仍然在（它是原型的信息架构），但**主界面自己也要能选**：
      // 一个"有数据的首页"比"让人先学会点哪"重要。
      if (app.currentSid == null && app.sessions.isNotEmpty) {
        return _SessionListInline(
          sessions: app.sessions,
          onOpen: onOpenSession,
          archived: app.archivedSids,
          onRefresh: paired ? onRefreshSessions : null,
          // **同一套工作区分组**（与抽屉共用 `bucketSessionsByWorkspace`）。
          workspaces: app.workspaces,
        );
      }
      return _EmptyChat(
        paired: paired,
        hasSessions: app.sessions.isNotEmpty,
        // **已经选中了会话**（只是它还没有条目）——必须与"还没选"分开说。
        // 少了这一支，点进一个空会话会看到"选一个会话"，而用户**刚刚才选过**，
        // 那句话会让人以为点击没生效（真机实测）。
        selectedSid: app.currentSid,
        // 投影失败（逐条隔离后记下来的那一条）：少渲染的事件要说出来。
        projectionFailure: app.projectionFailureOf(app.currentSid ?? ''),
        onOpenDrawer: onOpenDrawer,
        onConnect: onConnect,
        onRePair: onRePair,
        onRefresh: paired ? onRefreshSessions : null,
        // 失败原因带进空态：**空列表 + 有错** 与 **空列表 + 真没有** 必须看得出区别。
        // 连接诊断也带上：真机"列表恒空 + 反复重连"而两端日志无原因，
        // 就是因为原因只躺在客户端的诊断字段里（详见 `AppModel.connectionDiagnosis`）。
        errorText: app.lastError?.message ?? app.connectionDiagnosis,
        // **没连上时头条说连接**（配对照常显示"还没连电脑"）：全部端点拨不通时
        // 带上"N 个端点都拨不通（电脑可能不在线，或换了网络地址）"。
        connectionState: app.connection,
        connectionNote: connectionSummary(
          state: app.connection,
          active: app.activeEndpoint,
          endpoints: app.endpoints,
          attemptOf: app.attemptOf,
        ).note,
      );
    }
    // **`reverse: true`**：进入会话时**落在最新一条**（列表底部），与 Web 一致 ——
    // 2026-10-15 真机反馈:"dsh web 你进入会话是最新的消息,就是消息最下面,
    // APP 是最上面我要滑动多少次啊?"。
    // `reverse` 而不是"打开后 scrollToEnd":前者让**首帧**就在底部,不做二次布局,
    // 也不依赖 items 是否已经落全(恢复中的分页期间同样停在最新那端)。
    //
    // **快速跳转钮浮在右侧**（rikkahub 的 `MessageJumper`）：它要一个
    // `ScrollController` 才能跳，而 `_ChatTab` 是无状态的 —— 所以包一层
    // 有状态的 `_ConversationFlow`（见下），控制器与 jumper 都住在那儿。
    // **流式文本**（`AppModel.liveText`）也喂进去：生成过程中它一直在变，
    // 而持久的 `assistant/message` 要等这一步结束才落。不显示它，用户发一句话后
    // 要盯着"什么都没有"等到整步跑完（2026-10-19 摸到的"没有输出"实时版）。
    return _ConversationFlow(
      items: items,
      autoOpenDetail: autoOpenToolDetail,
      collapsibleTurns: collapsibleTurns,
      isTurnExpanded: isTurnExpanded,
      onToggleTurn: onToggleTurn,
      headAt: headAt,
      liveShowHead: liveShowHead,
      liveText: app.liveText,
      // **这一轮还在跑吗**：运行条只在真的在跑时挂（静止的界面不许闪）。
      // 判据来自电脑侧：`turn/start` / `turn/end` 事件（实时）+ `session.list`
      // 的 `running`（打开那一刻的初值）；起点是 `turn/start` 的 `time`。
      running: app.runningOf(app.currentSid ?? ''),
      turnStartedAt: app.turnStartedAtOf(app.currentSid ?? ''),
      // 滚到顶翻页要它（`hasOlderHistory` + `loadOlderHistory`）。
      app: app,
    );
  }
}

/// 对话流 + 右侧快速跳转钮。
///
/// ## 为什么要单独一层
///
/// 跳转钮需要 `ScrollController` 与每条条目的 `GlobalKey` 才能跳，而
/// `_ChatTab` 是无状态的纯展示层。把这一层拆出来，`_ChatTab` 仍然只管"显示什么"。
///
/// ## `reverse: true` 下的方向
///
/// `reverse` 列表里 **offset 0 是最新一端**，`maxScrollExtent` 是最早一端
/// （与直觉相反）。所以：
/// - "最新" → `animateTo(0)`；
/// - "最早" → `animateTo(maxScrollExtent)`。
///
/// ## "上一条 / 下一条"按条目，且**不猜高度**
///
/// 一条可以占满一屏（长 diff / 长输出），按像素挪只会在这条内部滑。
/// 而"跳到一个 index"在 Flutter 里**没有直接 API**（SDK 只有
/// `animateTo(offset)`）。正道是官方自己的做法：
/// `material/popup_menu.dart:997` 的
/// `Scrollable.ensureVisible(itemKeys[selectedIndex].currentContext!)` ——
/// **每条目一个 key，用 element 的 context 让它滚进视口**。
/// 用"平均高度 × index"估算是猜（条目高度不定，差一点就偏出半屏），这里不用。
///
/// ## 列表下标与 `items` 下标是**反的**
///
/// [chatItemIndexFor] 把 `reverse: true` 的列表下标换算成 `items` 下标
/// （`items` 是 seq 升序，列表 index 0 在最下面 ⇒ 最下面是最新那条）。
int chatItemIndexFor(
  int index, {
  required int itemCount,
  required bool hasLive,
  bool hasRunning = false,
}) => itemCount - 1 - (index - (hasLive ? 1 : 0) - (hasRunning ? 1 : 0));

class _ConversationFlow extends StatefulWidget {
  const _ConversationFlow({
    required this.items,
    required this.autoOpenDetail,
    this.collapsibleTurns = const <int>{},
    this.isTurnExpanded,
    this.onToggleTurn,
    this.headAt = const <String>{},
    this.liveShowHead = true,
    this.liveText,
    this.running = false,
    this.turnStartedAt,
    this.app,
  });

  final List<ChatItem> items;
  final bool autoOpenDetail;

  /// 可折叠的轮号与"这一轮展开吗"（见 `_ChatTab` 的同名字段）。
  final Set<int> collapsibleTurns;
  final bool Function(int turn)? isTurnExpanded;
  final void Function(int turn, bool expanded)? onToggleTurn;

  /// 该在哪些条目上方画「助手」头。
  final Set<String> headAt;

  /// 流式尾条目要不要自己带头。
  final bool liveShowHead;

  /// 流式文本；`null` = 没有正在生成的流。
  ///
  /// 它是**虚拟尾条目**：没有稳定 itemId（不进 store），所以列表数是
  /// `items.length + (liveText == null ? 0 : 1)`。持久的 `assistant/message`
  /// 到达后它自动消失（`AppModel` 不再给值）—— 那条消息整体替换它。
  final String? liveText;

  /// 电脑侧说这一轮还在跑（`session.list` 的 `running`）—— 决定流末尾有没有运行条。
  ///
  /// **它是虚拟尾条目**（与 [liveText] 同一种东西）：两个工具之间没有正文可显示，
  /// 那条"深度求索中，用时 N 秒"就是屏幕上唯一在动的东西。
  final bool running;

  /// 本轮起点（毫秒 epoch，来自 `trajectory` 投影）；`null` = 不知道起点。
  final int? turnStartedAt;

  /// 会话模型（滚到顶翻页要用它的 `hasOlderHistory` 与 `loadOlderHistory`）。
  ///
  /// `null` = 不翻页（预览 / 测试里没有真模型时）。
  final AppModel? app;

  @override
  State<_ConversationFlow> createState() => _ConversationFlowState();
}

class _ConversationFlowState extends State<_ConversationFlow> {
  final ScrollController _scroll = ScrollController();

  /// 列表自身的 key（`_firstVisibleIndex` 要拿视口顶在哪）。
  final GlobalKey _listKey = GlobalKey();

  /// 每条目的 key（`ensureVisible` 要 element，见类文档）。
  ///
  /// **条目数变化就重建**：留着旧的会漏掉新增条目（跳不过去），
  /// 而 key 数量与 `items` 不一致时 `ensureVisible` 拿到 null context。

  /// 跳转钮的控制器（滚动监听要把"滚过了"告诉它）。
  ///
  /// 用回调拿而不是 `GlobalKey`：这一个实例在整棵树里唯一，而回调不必
  /// 让父层知道私有 `State` 类型（拿到的是公开的 [ChatJumperController]）。
  ChatJumperController? _jumper;

  /// 正在翻页（滚到顶会**连续**触发，不去重就会一次滚到发好几页）。
  bool _paging = false;

  /// 滚到顶就翻一页更早的历史（DSH Web 的 `loadOlder`，`session.ts:406`）。
  ///
  /// ## 为什么在 `ScrollNotification` 里判，而不是照抄 DSH 的 viewport
  ///
  /// DSH 有一套 virtualizer + viewport + reading 状态机（`use-chat-viewport.ts`）
  /// 来同时管"跟随尾部 / 保持阅读位置 / 翻页锚点"。手机这一版没有虚拟列表，
  /// `ScrollController` 一行就能判"到没到顶"—— **有意偏离**：照抄那套会把
  /// 一个 `pixels >= maxScrollExtent` 的判断变成三百行状态机。
  ///
  /// ## `reverse: true` 下"顶"是 `maxScrollExtent`
  ///
  /// 列表倒序，offset 0 是最新一端，`maxScrollExtent` 是最早一端。
  /// 所以滚到**历史**的那一端 = `pixels` 接近 `maxScrollExtent`。
  /// 一轮的用时文案（`trajectory` 投影里那一轮的 `durationMs`）。
  ///
  /// 只对过程摘要那一行有意义（`TurnProcessItem` 是轮次收口），其余条目返回
  /// `null`。**这一层只查不算**：`formatElapsedMs` 只是把电脑侧给的毫秒数
  /// 说成人话，没有任何时间相减（判据见 `model/trajectory.dart` 文件头）。
  String? _durationLabelOf(ChatItem item) {
    if (item is! TurnProcessItem) return null;
    final app = widget.app;
    final turn = item.turn;
    if (app == null || turn == null) return null;
    final duration = app.trajectoryTurnOf(turn)?.durationMs;
    return duration == null ? null : formatElapsedMs(duration);
  }

  void _maybeLoadOlder() {
    final app = widget.app;
    if (app == null || _paging) return;
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    // 判据在 `ui/load_older_trigger.dart`（纯函数，可单测）——
    // 这里只负责"把滚动位置喂进去"。
    if (!shouldLoadOlder(
      pixels: position.pixels,
      maxScrollExtent: position.maxScrollExtent,
      hasMore: app.hasOlderHistory,
    )) {
      return;
    }
    final sid = app.currentSid;
    if (sid == null) return;
    _paging = true;
    // **翻完再解锁**：`loadOlderHistory` 内部还有一道并发锁（同一 sid），
    // 这里是 UI 侧的去重 —— 少了它，一次快速滚动会排好几页。
    unawaited(app.loadOlderHistory(sid).whenComplete(() => _paging = false));
  }

  @override
  void initState() {
    super.initState();
  }

  @override
  void didUpdateWidget(_ConversationFlow old) {
    super.didUpdateWidget(old);
    if (!identical(widget.items, old.items)) _pruneStaleKeys();
  }

  /// **按 `itemId` 复用 `GlobalKey`，不重建。**
  ///
  /// ## 为什么必须这样（2026-10-20 修一个真 bug）
  ///
  /// 这里原来是 `_syncKeys() = List.generate(items.length, (_) => GlobalKey())`
  /// —— 只要条目变了就**换成一批全新的 key**。而换 key 在 Flutter 里等于
  /// **让每一行重新挂载**：
  ///
  /// - `ToolCard` / `CommandCard` / `CompactionRow` / `TurnProcessRow` 都是
  ///   `StatefulWidget`，`_ToolCardState._open` 那种展开状态存在 `State` 里
  ///   ⇒ **展开一张工具卡，只要来一条新事件（流式输出/工具结果），它就自己收起**。
  /// - 顺带的性能问题：每帧分配 N 个 `GlobalKey`（它们要注册进全局表）。
  ///
  /// 改成按 `itemId` 取（`itemId` 由 `core/items.dart` 保证唯一且稳定），
  /// 同一条目跨帧拿到**同一个** key ⇒ 元素复用、状态保住、每帧零分配。
  final Map<String, GlobalKey> _keysById = {};

  GlobalKey _keyOf(String itemId) =>
      _keysById.putIfAbsent(itemId, GlobalKey.new);

  /// 条目被移出窗口时把 key 也丢掉（**只在真的变少时才扫一遍**）。
  ///
  /// 不无条件扫描：流式输出时条目只会增/改，那时这里是 O(1) 的空操作。
  void _pruneStaleKeys() {
    if (_keysById.length <= widget.items.length) return;
    final live = {for (final item in widget.items) item.itemId};
    _keysById.removeWhere((id, _) => !live.contains(id));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 当前第一条可见条目的 index。
  ///
  /// `ScrollPosition` 不提供"第几条可见"（builder 模式没有这回事），
  /// 所以从 keys 反推：**视口上缘之下的第一条**。拿不到就退 0，不猜。
  ///
  /// 视口上缘取自觉列表自身的 `RenderBox`（`_listKey` 挂在 `ListView` 上）：
  /// 它的全局 dy 就是视口顶。条目的上缘由各自的 `RenderBox.localToGlobal`
  /// 折成同一个全局坐标系后比较。**不用 `RenderAbstractViewport`** ——
  /// 它在 `rendering` 库而 material 不重导出，引它要多一个 import，
  /// 而这里要的只是"视口顶在哪"。
  int get _firstVisibleIndex {
    if (!_scroll.hasClients) return 0;
    final listBox = _listKey.currentContext?.findRenderObject() as RenderBox?;
    if (listBox == null || !listBox.hasSize) return 0;
    final viewportTop = listBox.localToGlobal(Offset.zero).dy;
    for (var i = 0; i < widget.items.length; i += 1) {
      final box =
          _keysById[widget.items[i].itemId]?.currentContext?.findRenderObject()
              as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      if (top >= viewportTop - 1) return i;
    }
    return 0;
  }

  /// 让某一条滚进视口（不猜高度，走官方 `ensureVisible`）。
  ///
  /// 它返回 `Future`（动画完成），而这里**不 await**：跳转是"发出去就不管"
  /// 的动作，调用方（按钮回调）不等它。`unawaited` 是显式说出这件事 ——
  /// `discarded_futures` lint 要求二选一，不能默默丢。
  void _ensureVisible(int index) {
    if (index < 0 || index >= widget.items.length) return;
    final context = _keysById[widget.items[index].itemId]?.currentContext;
    if (context == null) return;
    unawaited(
      Scrollable.ensureVisible(
        context,
        alignment: 0.1,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      ),
    );
  }

  /// 挪一条。[delta] 是 -1（上一条）/ +1（下一条）。
  ///
  /// 列表是**倒序**的，所以"上一条"= index **+1**（更早），
  /// "下一条" = index **-1**（更新）。index 0 可能是**流式尾条目**
  /// （没有 key，`ensureVisible` 拿不到 element）—— 那时这一步是空操作，
  /// 不猜一个位置。
  void _step(int delta) {
    if (widget.items.isEmpty) return;
    _ensureVisible(
      (_firstVisibleIndex + delta).clamp(0, widget.items.length - 1),
    );
  }

  /// 跳到某一端。[newest] 为真 = 最新一条。
  void _edge(bool newest) {
    if (!_scroll.hasClients) return;
    final extent = _scroll.position.maxScrollExtent;
    unawaited(
      _scroll.animateTo(
        newest ? 0.0 : extent,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOut,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            // **滚动就显示跳转钮**（rikkahub 的 `isRecentScroll` 同源）。
            // 返回 false = 不吞掉这个通知，别的监听者还要用。
            _jumper?.notifyScrolled();
            // **滚到顶就翻一页更早的**（DSH Web 的 `loadOlder`）。
            // 只在"用户主动滚"与"滚动结束"两类上判：`ScrollUpdateNotification`
            // 是拖动/惯性，`ScrollEndNotification` 是停下来 —— 两者都到顶才算。
            if (notification is ScrollUpdateNotification ||
                notification is ScrollEndNotification) {
              _maybeLoadOlder();
            }
            return false;
          },
          child: ListView.builder(
            key: _listKey,
            controller: _scroll,
            reverse: true,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            // **+1 是流式尾条目，再 +1 是运行条**（两条都是虚拟的，没有 itemId）。
            itemCount:
                widget.items.length +
                (widget.liveText == null ? 0 : 1) +
                (widget.running ? 1 : 0),
            itemBuilder: (context, index) {
              // `reverse: true` 下 index 0 在**最下面**，往上递增。
              // `items` 是 **seq 升序**（`session_store.dart:146`），所以 index 要
              // **倒着取**：最下面那条 = 最新的持久条目（`items.last`）。
              //
              // 2026-10-20 真机复现：原来这里是 `items[index - 1]`（正着取），
              // 于是**最早的在上、最新的在下** —— 一整段对话是倒的，
              // 而且"进入会话落在最新一条"也落到了最早一条。
              final hasLive = widget.liveText != null;
              final hasRunning = widget.running;
              // 运行条在最下面（它是流末尾），流式文本在它上面一格。
              if (hasRunning && index == 0) {
                return KeyedSubtree(
                  key: const ValueKey('running'),
                  child: RunningBar(startTime: widget.turnStartedAt),
                );
              }
              if (hasLive && index == (hasRunning ? 1 : 0)) {
                return KeyedSubtree(
                  key: const ValueKey('live'),
                  child: _LiveTurn(
                    widget.liveText!,
                    showHead: widget.liveShowHead,
                  ),
                );
              }
              final itemIndex = chatItemIndexFor(
                index,
                itemCount: widget.items.length,
                hasLive: hasLive,
                hasRunning: hasRunning,
              );
              // **按 `itemId` 取 key**（跨帧同一个）—— 换 key 会让这一行重新
              // 挂载，工具卡的展开状态就丢了。见 `_keysById` 的说明。
              final item = widget.items[itemIndex];
              return KeyedSubtree(
                key: _keyOf(item.itemId),
                child: _TurnView(
                  item: item,
                  app: widget.app,
                  autoOpenDetail: widget.autoOpenDetail,
                  // **提及表与打开动作都从模型来**：这一层不解析路径、也不决定打开哪里
                  // （`AppModel.openFile` 是四个入口唯一的那一个动作）。
                  fileMentions: widget.app?.fileMentionsOf(item),
                  onOpenFile: widget.app == null
                      ? null
                      : (path) => unawaited(
                          widget.app!.openFile(FileOpenRequest(path: path)),
                        ),
                  turnDurationLabel: _durationLabelOf(item),
                  // 轮组：这一轮的收口行是不是折叠开关、现在展不展开。
                  collapsibleTurn:
                      item.turn != null &&
                      widget.collapsibleTurns.contains(item.turn),
                  turnExpanded:
                      item.turn != null &&
                      (widget.isTurnExpanded?.call(item.turn!) ?? true),
                  onToggleTurn: widget.onToggleTurn,
                  // 组头：这一条是该轮第一条助手侧条目时，头像画在它上方。
                  showHead: widget.headAt.contains(item.itemId),
                ),
              );
            },
          ),
        ),
        // 跳转钮：浮在右侧，滚动停下 1.5 秒后自己淡出。
        // `itemCount` 含流式尾条目 —— 它与持久条目一样"可跳"。
        Positioned.fill(
          child: ChatJumper(
            itemCount:
                widget.items.length +
                (widget.liveText == null ? 0 : 1) +
                (widget.running ? 1 : 0),
            onStep: _step,
            onEdge: _edge,
            onCreated: (controller) => _jumper = controller,
          ),
        ),
      ],
    );
  }
}

/// 流末尾那条运行条读"现在几点"的时钟。**注入的缝**：活时钟要能单测
/// （与 `subagent_tree.dart` 的 `now` 同一条纪律），用例替换后记得还原。
int Function() runningBarClock = () => DateTime.now().millisecondsSinceEpoch;

/// 流末尾的**运行条** —— 照 DSH 的 `RunningStatus`
/// （`packages/client/ui-chat/src/client/chat/RunningStatus.tsx:20-41`，挂在流末尾
/// `ChatFlow.tsx:60`）。
///
/// 用户原话：「没有这个动效还以为卡了」。两个工具之间（等结果时）屏幕上原本
/// **什么都没有** —— 现在这里有一条：转圈的加载字形 +「深度求索中，用时 N 秒 ···」。
///
/// ## 秒数从电脑侧来，手机只走秒
///
/// - 起点 = 本轮 `trajectory.startTime`（投影给的毫秒 epoch，`runningTurn`）；
/// - "在跑" = `session.list` 的 `running`（`_ConversationFlow.running`）；
/// - 每 `1000ms` 重算一次 —— 照 `message-chrome.ts:13` 的
///   `LIVE_RUN_CLOCK_INTERVAL_MS = 1000`。
///
/// **手机侧唯一允许的时间减法就是这一个活时钟**（`now - startTime`）；跑完的时长
/// 仍然只读投影给的 `durationMs`（`docs/subsystems/trajectory-page.md` §1）。
/// 拿不到起点时只说「深度求索中」—— **不编秒数**（DSH 同一条，`:28`）。
///
/// 鲸鱼尾 APNG 没有引入（用户 2026-10-22 选的是"用已有 loading 字形转圈"）：
/// 少一个 2x 资源，动效点来自转圈与活时钟。
class RunningBar extends StatefulWidget {
  const RunningBar({super.key, this.startTime});

  /// 本轮起点（毫秒 epoch）；`null` = 不知道起点。
  final int? startTime;

  @override
  State<RunningBar> createState() => _RunningBarState();
}

class _RunningBarState extends State<RunningBar>
    with SingleTickerProviderStateMixin {
  /// 1.5s 匀速转 —— 与 `StateDot.module.css:42-45` 的转圈同一个节奏。
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat();

  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _spin.dispose();
    super.dispose();
  }

  String get _label {
    final start = widget.startTime;
    if (start == null) return '深度求索中';
    // `Math.max(1000, …)`：不足 1 秒也说"1 秒"（DSH 同一条）。
    final elapsed = runningBarClock() - start;
    return '深度求索中，用时 ${formatElapsedMs(elapsed < 1000 ? 1000 : elapsed)} ···';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Padding(
      // 与持久条目同一档上下留白（它也是"流里的一行"）。
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          RotationTransition(
            turns: _spin,
            child: DshIcon('loading', size: 14, color: c.businessBlue),
          ),
          const SizedBox(width: 8),
          // 文案本身也扫光：DSH 给这条 label 套的就是 `TextShimmer active`
          // （`RunningStatus.tsx:37`）。
          DshShimmer(
            active: true,
            child: Text(
              _label,
              style: TextStyle(
                // 运行条是流程行，走 secondary 档（跟字号刻度缩放）。
                fontSize: context.dshType.secondary,
                color: c.businessBlue,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 主界面上的会话列表（**不必先开抽屉**）。
///
/// 与抽屉里的那份是**同一批数据**（`AppModel.sessions`）、**同一套分组规则**
/// （`bucketSessionsByWorkspace`）、**同一套折叠规则**（`CollapsibleGroup`）——
/// 2026-10-19 用户原话「这个侧边栏会话列表，人家的每个项目的会话可以折叠的，
/// 你没有啊」。抽屉是"历史入口"，这里是"首页就该看得见的东西"，
/// 但两边看到的必须是同一份列表。
class _SessionListInline extends StatefulWidget {
  const _SessionListInline({
    required this.sessions,
    required this.onOpen,
    required this.archived,
    this.onRefresh,
    this.workspaces = const [],
  });

  final List<SessionSummary> sessions;
  final void Function(SessionSummary session) onOpen;
  final VoidCallback? onRefresh;

  /// 已归档的 sid（`AppModel.archivedSids`）。**默认不列**，见 `sessionVisible`
  /// ——归档不是删除：它们在抽屉底栏「归档」那张列表里，取消归档即回原位。
  final Set<String> archived;

  /// 工作区分组（`AppModel.workspaces`）。**空 = 不分组**，与抽屉同一规则。
  final List<WorkspaceGroup> workspaces;

  @override
  State<_SessionListInline> createState() => _SessionListInlineState();
}

class _SessionListInlineState extends State<_SessionListInline> {
  /// 每个项目组的展开态。**缺省视为展开**（`?? true`）——
  /// 第一次看到就展开，不要"默认全折叠"让用户以为会话少了一半。
  ///
  /// 与抽屉各自一份：两边是**同一个规则**的两个实例，
  /// 但状态不该跨组件共享（抽屉开着时首页这份通常看不见）。
  final Map<String, bool> _expanded = <String, bool>{};

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    // **可见性规则逐条照 DSH Web**（`sessionVisible`）:子智能体的子会话不列、
    // blank 除当前外不列。与抽屉同一条规则 —— 两边看到的必须是同一份列表。
    final visible = widget.sessions
        .where(
          (s) => sessionVisible(
            subagent: s.subagent,
            blank: s.blank,
            isCurrent: false,
            archived: widget.archived.contains(s.sid),
          ),
        )
        .toList();
    // **分组规则只有一份**（模型层的纯函数）—— 抽屉与这里都用它。
    // 2026-10-15 只改了抽屉，主界面这份还是平的，真机上一眼看出来了。
    final buckets = bucketSessionsByWorkspace(
      visible.map((s) => s.sid).toList(),
      widget.workspaces,
    );
    final bySid = {for (final s in visible) s.sid: s};
    // 分组后是"组头 + 行"的扁平序列：给 ListView 用。
    final rows = <Widget>[];
    for (final bucket in buckets) {
      // 这一组的行。**折叠时不渲染**（与 DSH 的
      // `group.expanded ? children.map(...) : []` 同一条规则，
      // `ui-workspace/.../WorkspaceBrowser.tsx:484`）。
      final sessionRows = <Widget>[
        for (final sid in bucket.sessionIds)
          if (bySid[sid] case final session?)
            ListTile(
              dense: true,
              title: Text(
                // 标题与顶栏、抽屉同一条链：投影提示标题 → 「未命名」
                // （DSH 的 Web 侧栏规则，`ui-workspace/README.zh.md:32`；
                // 判据 `tree.ts:296` 的 `sessionTitle`）。**不再退目录名 / sid**。
                session.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, color: c.labelPrimary),
              ),
              subtitle: () {
                // 副标题显示**模型**，不再显示 sid：标题按 DSH 的链会退到 sid
                // （`displayTitle`），再显示一遍 sid 就是同一行里同一个字符串。
                // Web 的列表行同样不显示原始会话 id。
                final model = session.model?.label;
                return model == null ? null : Text(model);
              }(),
              onTap: () => widget.onOpen(session),
            ),
      ];
      rows.add(
        // **可折叠的项目组头**：与抽屉同一个 widget（`collapsible_group.dart`）。
        CollapsibleGroup(
          label: bucket.label,
          expanded: _expanded[bucket.label] ?? true,
          onToggle: () => setState(
            () => _expanded[bucket.label] = !(_expanded[bucket.label] ?? true),
          ),
          childCount: bucket.sessionIds.length,
          children: sessionRows,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              Text(
                '会话',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: c.labelCaption,
                ),
              ),
              const Spacer(),
              if (widget.onRefresh != null)
                IconButton(
                  onPressed: widget.onRefresh,
                  tooltip: '重新拉取会话',
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  color: c.labelTertiary,
                  icon: DshIcon('refresh', size: 16, color: c.labelTertiary),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: rows.length,
            itemBuilder: (context, index) => rows[index],
          ),
        ),
      ],
    );
  }
}

/// 一条条目 → 对应的渲染组件（**按类型分派**）。
/// 流式尾条目：正在生成的助手文本。
///
/// ## 它为什么是"虚拟条目"
///
/// `AppModel.liveText` 没有稳定 itemId（它是累加器的当前内容，会被随后的
/// 持久 `assistant/message` **整体替换**）—— 所以不进 store、不当 ChatItem，
/// 只在列表末尾多占一格。
///
/// ## 与 DSH Web 的对应
///
/// Web 的 `AssistantNodeView` 在流式期间就是同一条：头像 + 名字 + 正在增长的
/// Markdown（`ui-chat/src/client/chat/AssistantNodeView.tsx`）。手机同一条。
///
/// ## 为什么要显示它
///
/// 2026-10-19 摸到：`AppModel.liveText` 有 getter，而 **UI 从不读它** ——
/// 用户发一句话后要盯着"什么都没有"等到整步跑完。这正是"没有输出"的**实时版**：
/// 最终会显示，但生成过程中不显示。
class _LiveTurn extends StatelessWidget {
  const _LiveTurn(this.text, {this.showHead = true});

  /// 正在生成的文本（`AppModel.liveText`）。
  final String text;

  /// 要不要带头像。**本轮已经有过程条目时不再画** —— 那一组的头已经在开头
  /// 画过了（否则同一条回答上会出现两个头像）。
  final bool showHead;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    // **与持久条目同一个骨架**（2026-10-20 第 7 条）：`AssistantTurn` 的
    // 上下留白（18）、`AssistantHead`、`DshMarkdown` 三样都照抄它 ——
    // 原来这里自己写了一套（留白 10、手抄的头像行、写死颜色），
    // 于是流结束、条目从"虚拟尾"换成持久消息时，整行的高度与构造都变，
    // 正文会**跳一下**。DSH 的流式尾与落定条目是**同一个节点类型**
    // （`ui-chat/src/client/chat/AssistantNodeView.tsx`），所以那边没有这一跳。
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showHead) const AssistantHead(),
          // **正在生成的正文**（Markdown，与持久消息同一套渲染）。
          // 空文本时给一行占位 —— 那表示"这一步开始了但还没有文本"
          // （可能在等工具结果），说"正在生成"比一片白诚实。
          if (text.isEmpty)
            Text(
              '正在生成…',
              // 占位与正文同一档（它出现的下一帧就会被正文替换，字号跳一下更刺眼）。
              style: TextStyle(
                fontSize: context.dshType.body,
                color: c.labelTertiary,
              ),
            )
          else
            DshMarkdown(text),
        ],
      ),
    );
  }
}

class _TurnView extends StatelessWidget {
  const _TurnView({
    required this.item,
    this.autoOpenDetail = false,
    this.turnDurationLabel,
    this.collapsibleTurn = false,
    this.turnExpanded = true,
    this.onToggleTurn,
    this.showHead = false,
    this.fileMentions,
    this.onOpenFile,
    this.app,
  });

  /// 会话模型（改动卡要按事件 seq 向电脑要记录；`null` = 不画卡）。
  final AppModel? app;

  /// 这一条上方要不要画「助手」头（由所在轮组的第一条助手侧条目决定）。
  final bool showHead;

  final ChatItem item;

  /// 正文里 `行内代码 → 文件路径` 的表（这一轮产出过的文件；`null` = 不认提及）。
  final Map<String, String>? fileMentions;

  /// 点中一处提及（走 `AppModel.openFile`，这里只转达路径）。
  final void Function(String path)? onOpenFile;

  /// 这一条是**可折叠轮组的收口行**（该轮有过程条目、且已收口）。
  final bool collapsibleTurn;

  /// 这一轮此刻展开与否（只在 [collapsibleTurn] 时有意义）。
  final bool turnExpanded;

  /// 点收口行：`(轮号, 是否展开)`。
  final void Function(int turn, bool expanded)? onToggleTurn;

  /// 工具明细默认展开（"工作步骤展示"偏好）。
  final bool autoOpenDetail;

  /// 这一轮用时的文案（`trajectory` 投影的 `durationMs`，电脑侧算好）。
  ///
  /// 由持有 `AppModel` 的那一层按条目所属的轮查好传进来 —— 这一层是纯展示的，
  /// 不读模型、也不算时间（`app/lib` 里不许出现 epoch 相减）。
  /// `null` = 这一轮不在投影里（更早的轮被截掉 / 这台电脑没给时间轴）。
  final String? turnDurationLabel;

  @override
  Widget build(BuildContext context) {
    final content = _content(context);
    // 「助手」头画在**这一组的第一条助手侧条目上方**（`assistantHeadItemIds`）——
    // 于是长轮次的头像在开头，而不是贴在最终回答上（用户 2026-10-23 指出）。
    if (!showHead) return content;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [const AssistantHead(), content],
    );
  }

  /// 单条条目自己的样子（不含组头）。
  Widget _content(BuildContext context) {
    // sealed class ⇒ 这个 switch 是穷尽的：加一种条目时编译器会在**这里**报错，
    // 而不是让新类型静默渲染成空白。
    return switch (item) {
      MessageItem(
        :final role,
        :final text,
        :final attachmentCount,
        :final steering,
        :final reasoning,
        :final systemLabel,
        :final systemHint,
      ) =>
        switch (role) {
          MessageRole.user => UserTurn(
            text,
            attachmentCount: attachmentCount,
            steering: steering,
          ),
          // **只有带正文的助手消息才画助手头**。没有正文的那一步在投影层
          // 已经变成 `ReasoningItem`（过程行）或被 skip 掉，正常走不到这里；
          // 这一句是兜底：万一正文为空，宁可整条不画，也不要一个空「助手」。
          MessageRole.assistant =>
            text.isEmpty && attachmentCount == 0
                ? const SizedBox.shrink()
                : AssistantTurn(
                    text: text,
                    reasoning: reasoning,
                    // 思考属于过程：轮组收起时一并收起（不可折的轮恒为展开）。
                    showReasoning: turnExpanded,
                    // 头由所在那一组在**开头**画（`assistantHeadItemIds`），
                    // 正文这里不再画 —— 否则头像会落在轮次中间。
                    showHead: false,
                    fileMentions: fileMentions,
                    onOpenFile: onOpenFile,
                  ),
          MessageRole.system => SystemTurn(
            text,
            label: systemLabel,
            hint: systemHint,
          ),
        },
      ToolCallItem(
        :final name,
        :final status,
        :final summary,
        :final detail,
        :final view,
        :final diffStat,
      ) =>
        ToolCard(
          name: name,
          status: status,
          argument: summary,
          detail: detail,
          view: view,
          diffStat: diffStat,
          initiallyOpen: autoOpenDetail,
        ),
      ApprovalItem(:final title, :final decided) => TakeoverHint(
        icon: decided ? 'check' : 'shield',
        name: decided ? 'approval' : 'approval',
        argument: title,
        statusText: decided ? '已决定' : '等待审批',
      ),
      // 斜杠命令（`command/run` + `command/done`）：DSH 的 `GenericCommandCard`。
      // 2026-10-19 之前它落到 `OtherItem` 被丢掉，于是 `/goal` / `/compact` /
      // `/permission` 这些在 Web 上有卡片的东西，手机上一条都没有。
      CommandItem(:final name, :final status, :final summary, :final detail) =>
        CommandCard(
          name: name,
          status: status,
          summary: summary,
          detail: detail,
          initiallyOpen: autoOpenDetail,
        ),
      OtherItem() => const SizedBox.shrink(),
      // 一轮的异常结局（`turn/end` 的 reason）。**80 条"出了什么事"在
      // 2026-10-19 之前完全看不见**：error 71 + interrupted 6 +
      // max-tokens 3（真日志统计，见 `TurnOutcomeItem` 文档）。
      TurnOutcomeItem(:final kind, :final message, :final title) =>
        TurnOutcomeRow(kind: kind, message: message, title: title),
      // 一次模型重试（`llm/retry` + `llm/retry-started`）。
      ModelRetryItem(:final title, :final message, :final started) => RetryRow(
        title: title,
        message: message,
        started: started,
      ),
      // 一轮的过程摘要（`turn/end` 时的收口行）—— 同时是 DSH 的
      // `turn-tail` 操作行（复制 + 用量 pill）。
      final TurnProcessItem process => TurnProcessRow(
        title: process.title,
        // 用时**只读投影**（`statsWith` 只拼串，不做减法）。
        stats: process.statsWith(turnDurationLabel),
        failed: process.failed,
        usage: process.usage,
        copyText: process.copyText,
        // 折叠开关：只有"有过程、且已收口"的轮才给。运行中的一轮没有它
        //（组头不出现），与 DSH 的 `status !== 'closed'` 同一条。
        expanded: turnExpanded,
        onToggle:
            collapsibleTurn && onToggleTurn != null && process.turn != null
            ? () => onToggleTurn!(process.turn!, !turnExpanded)
            : null,
      ),
      // 一轮的改动记录（`workspace/changes`）：桌面在收口处那张「已编辑 N 个文件」卡。
      // **数字来自电脑**（`file.changes` → 宿主 `workspaceChanges`），手机只画。
      ChangesItem(:final seq) => _ChangedFilesCard(app: app, seq: seq),
      // 一次上下文压缩（`compaction/*` 三条事件）。
      CompactionItem(:final summary, :final stats) => CompactionRow(
        summary: summary,
        stats: stats,
      ),
      // 中间步骤的思考（没有正文的那条 `assistant/message`）：**过程行**，
      // 与工具卡同级，跟着轮组一起收起。
      ReasoningItem(:final text) => ReasoningRow(text: text),
    };
  }
}

/// 收口处的**改动卡**（桌面 `ui-deliverables/src/client/ChangedFiles.tsx`）。
///
/// ## 数据是电脑的记录，手机只画
///
/// 标题用**完整**文件数（宿主的 `total`，含被 `maxFiles` 截掉的），行用宿主给的
/// `display`，"二进制 / 过大"是宿主的两个标记（`workspace-changes/src/types.ts:14-21`）。
/// 手机不拿工具调用自己推 `+N −M` —— 那会与桌面不同源。
///
/// ## 交互
///
/// 行点击与标题点击都只走 `AppModel.openFile`（唯一打开动作）；标题点第一个文件
/// （逐行差异要等 `file.diff`，方案笔记批 C）。
///
/// ## 三态
///
/// 没读到 ⇒ **不画**（桌面也是拿到记录才出现）；电脑侧没有这条记录（`summary:null`）
/// ⇒ 不画；读失败 ⇒ 把电脑侧原话摆出来 + 重试（不静默）。
class _ChangedFilesCard extends StatefulWidget {
  const _ChangedFilesCard({required this.app, required this.seq});

  /// 会话模型；`null` = 不画（预览 / 测试里没有模型时）。
  final AppModel? app;

  /// `workspace/changes` 事件的序号 —— 向电脑要记录的唯一坐标。
  final int seq;

  @override
  State<_ChangedFilesCard> createState() => _ChangedFilesCardState();
}

class _ChangedFilesCardState extends State<_ChangedFilesCard> {
  /// 桌面默认只露四行（`ChangedFiles.tsx:18` 的 `COLLAPSED_ROWS`）。
  static const int _collapsedRows = 4;

  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    // **下一帧再拉**：`loadChangesSummary` 会同步 `notifyListeners`，而在 initState 里
    // 通知祖先（`main.dart` 的 ListenableBuilder）等于在 build 期间标脏 —— Flutter
    // 会直接断言。等这一帧过去就没有这个窗口。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureLoaded();
    });
  }

  void _ensureLoaded() {
    final app = widget.app;
    if (app == null || !app.changesAvailable) return;
    if (app.changesLoading(widget.seq)) return;
    if (app.changesStateOf(widget.seq).loaded) return;
    if (app.changesFailureOf(widget.seq) != null) return;
    unawaited(app.loadChangesSummary(widget.seq));
  }

  void _open(AppModel app, String path) {
    unawaited(app.openFile(FileOpenRequest(path: path)));
  }

  /// 打开这一轮里第 [index] 个文件的**逐行差异**（坐标 = 事件 seq + 下标）。
  void _openDiff(AppModel app, String path, int index) {
    unawaited(
      app.openFile(
        FileOpenRequest(
          path: path,
          mode: FileOpenMode.diff,
          seq: widget.seq,
          index: index,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    if (app == null || !app.changesAvailable) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final failure = app.changesFailureOf(widget.seq);
        if (failure != null) return _failure(context, app, failure);
        final state = app.changesStateOf(widget.seq);
        // 没读到 / 电脑侧没有记录：不画（不是失败）。
        if (!state.loaded || state.summary == null) {
          return const SizedBox.shrink();
        }
        return _card(context, app, state.summary!);
      },
    );
  }

  Widget _failure(BuildContext context, AppModel app, String failure) {
    final c = context.dshColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          DshIcon('warningTriangle', size: 14, color: c.stateError),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '改动记录读取失败：$failure',
              style: TextStyle(fontSize: 12, color: c.stateError),
            ),
          ),
          TextButton(
            onPressed: () => unawaited(app.loadChangesSummary(widget.seq)),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, AppModel app, ChangesSummary summary) {
    final c = context.dshColors;
    final single = summary.total == 1 && summary.files.isNotEmpty
        ? summary.files.first
        : null;
    final rows = _expanded
        ? summary.files
        : summary.files.take(_collapsedRows).toList(growable: false);
    final foldable = summary.files.length > _collapsedRows;
    final title = single == null
        ? '已编辑 ${summary.total} 个文件'
        : '已编辑 ${fileNameOf(single.path)}';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: c.layer1,
        borderRadius: BorderRadius.circular(DshRadius.md),
        border: Border.all(color: c.layer2),
      ),
      clipBehavior: Clip.antiAlias,
      // `InkWell` 要 `Material` 祖先才画水波（`SidePane` 里同一处注释）。
      child: Material(
        color: Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              // 标题点开**逐行差异**（桌面点卡头开的是本轮 review 的第一个文件）。
              onTap: summary.files.isEmpty
                  ? null
                  : () => _openDiff(app, summary.files.first.path, 0),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Row(
                  children: [
                    DshIcon('deliverDoc', size: 16, color: c.labelSecondary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: c.labelPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _countsOf(
                      context,
                      added: summary.added,
                      deleted: summary.deleted,
                      binary: single?.binary ?? false,
                      oversized: single?.oversized ?? false,
                    ),
                  ],
                ),
              ),
            ),
            for (final file in rows) _row(context, app, file),
            if (summary.truncated)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
                child: Text(
                  // **截断要说**：宿主的 `maxFiles` 砍掉了后面的文件。
                  '还有 ${summary.total - summary.files.length} 个文件没列出（超过电脑侧上限）',
                  style: TextStyle(fontSize: 11, color: c.labelCaption),
                ),
              ),
            if (foldable)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
                  child: TextButton(
                    onPressed: () => setState(() => _expanded = !_expanded),
                    child: Text(
                      _expanded ? '收起' : '全部 ${summary.files.length} 个文件',
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, AppModel app, ChangedFile file) {
    final c = context.dshColors;
    return InkWell(
      onTap: () => _open(app, file.path),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
        child: Row(
          children: [
            Expanded(
              child: Text(
                file.display,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: c.labelPrimary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            _countsOf(
              context,
              added: file.added,
              deleted: file.deleted,
              binary: file.binary,
              oversized: file.oversized,
            ),
          ],
        ),
      ),
    );
  }
}

/// `+N` / `-M`，或宿主的两个"没有行数"标记（`changes.binary` / `changes.oversized`）。
///
/// 卡片与侧栏**同一份**（两处各写一遍必然漂成"卡片说 +9、侧栏说 +0"）。
Widget _countsOf(
  BuildContext context, {
  required int added,
  required int deleted,
  required bool binary,
  required bool oversized,
}) {
  final c = context.dshColors;
  if (binary || oversized) {
    return Text(
      binary ? '二进制' : '过大',
      style: TextStyle(fontSize: 11, color: c.labelCaption),
    );
  }
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        '+$added',
        style: TextStyle(
          fontSize: 11,
          fontFamily: 'monospace',
          color: c.codeDiffAdd,
        ),
      ),
      const SizedBox(width: 4),
      Text(
        '-$deleted',
        style: TextStyle(
          fontSize: 11,
          fontFamily: 'monospace',
          color: c.codeDiffDel,
        ),
      ),
    ],
  );
}

/// 空态（原型没有这一屏 —— 因为原型永远有会话；但真实 App 第一次打开是空的）。
///
/// 四句话分开说（**这是本页最有价值的一段文案**）：
/// 没配对 / 真没有会话 / 有会话但没选中 / 刚连上还没拉到。
class _EmptyChat extends StatelessWidget {
  const _EmptyChat({
    required this.paired,
    required this.hasSessions,
    required this.onOpenDrawer,
    this.selectedSid,
    this.projectionFailure,
    this.onRefresh,
    this.onConnect,
    this.onRePair,
    this.errorText,
    this.connectionState,
    this.connectionNote,
  });

  final bool paired;
  final bool hasSessions;

  /// 当前选中的会话（`null` = 还没选）。**用来把"选了但还没内容"与"还没选"分开**。
  final String? selectedSid;

  /// 投影失败的第一条原因（`null` = 没失败）。**与"真没有内容"分开说**。
  final String? projectionFailure;
  final VoidCallback onOpenDrawer;

  /// 重新拉一次会话列表。
  ///
  /// **必须有个手动入口**：自动拉只在"进服务态"那一刻发生一次，
  /// 而会话是**电脑侧**随时可以新建的 —— 用户在看手机时电脑上开了个会话，
  /// 没有这个按钮就只能杀 App 重进（那是本页最容易被骂的一种"卡住"）。
  final VoidCallback? onRefresh;
  final VoidCallback? onConnect;

  /// 已配对时的"重新配对（换一台电脑）"出路（议题 3，1 步直达）。未配对为 `null`。
  final VoidCallback? onRePair;

  /// 最近一次拉取失败的原因（`null` = 没失败）。**显示出来**，别让它只躺在日志里。
  final String? errorText;

  /// 连接状态。**配对但没连上时，空态说"连不上"而不是"还没有会话"** ——
  /// 两者在界面上都是空屏，而下一步动作完全不同（重连/重配 vs 去电脑上开会话）。
  /// 2026-10-16 实测：电脑换地址后全部端点拨不通，空态却显示"还没有会话"，
  /// 用户被引向一个根本不存在的动作。
  ///
  /// Note: 为什么稳定锚点（Tailscale / 稳定中转主机）不给代码做分支 ——
  /// 见 `.agents/notes/implemented/2026-10-16-endpoint-failure-diagnosis-and-stable-anchor.md`。
  final ConnectionStateView? connectionState;

  /// 连接诊断（`connectionSummary` 的 note；如"N 个端点都拨不通…"）。
  final String? connectionNote;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    // **"拉取失败"必须与"真没有会话"分开说**（`app_model.dart` 的 `lastError`）。
    // 两者在界面上一模一样（都是空列表），而下一步动作完全不同：
    // 一个去电脑上开会话，一个查连接/协议错误。
    // 少了这一支，"连上了却永远没有会话"就只能靠猜 —— 实测就是这么被卡住的。
    final error = errorText;
    // **连接没通是比"拉取失败"更前面的一支**：那时的 `lastError` 往往是
    // 连接层的错（握手超时之类），说成"拉取会话失败"会把排查引向会话列表。
    // 连接状态当头条，协议错误/诊断退为详情行。
    final disconnected =
        paired &&
        connectionState != null &&
        connectionState != ConnectionStateView.serving;
    final (icon, title, detail) = !paired
        ? ('globe', '还没配对', '界面可以先看。要看到真实会话，先在电脑上出码，再扫一次。')
        : disconnected
        ? (
            'warningTriangle',
            connectionLabel(connectionState!),
            // **有凭据但连不上**：与"没配对过"分开说。2026-10-26 真机复现 ——
            // 手机带着配对凭据、电脑侧设备名册里也有这台，却显示"还没连电脑"，
            // 用户被引向"重新扫码"（要电脑重新出码），而真正该先试的是
            // 「重新连接」（电脑侧 DSH 换了网络/重启过，地址变了）。
            // 那句话读起来像"我从没配对过"，于是排查方向整个反了。
            connectionNote ?? error ?? '换过网络或电脑重启过？先试顶栏状态点里的「重新连接」。',
          )
        : error != null
        ? ('warningTriangle', '拉取会话失败', error)
        // **选中了会话但还没有条目**：这是"这个会话是空的"，不是"你还没选"。
        // 两者在界面上都是空屏，而用户刚点过会话 —— 说"选一个会话"会让人以为点击失效
        //（真机实测：点进会话后仍显示"选一个会话"，看起来像没点中）。
        : selectedSid != null
        ? ('newChat', '这个会话还没有内容', '在电脑上继续它，或直接在下面发一句。')
        : hasSessions
        ? ('panelLeft', '选一个会话', '会话历史在左侧抽屉里。')
        : ('newChat', '还没有会话', '在电脑上用 DSH 开一个，它会出现在抽屉里。');
    // **投影失败要与"真没有内容"分开说**：逐条隔离之后，坏事件不再炸掉
    // 整批，但它少渲染的那几条必须让人看见 —— 否则"事件到了却没显示"
    // 会被当成"会话里就没有这些"。
    final failureNote = projectionFailure == null
        ? null
        : '有事件没能渲染：$projectionFailure';
    return SingleChildScrollView(
      // **必须可滚**：320×640 上"图标 + 三行字 + 三个按钮"放不下，
      // 会报 `BOTTOM OVERFLOWED BY 20 PIXELS`（实测踩到）。
      // 用 `Center` + `SingleChildScrollView` 而不是纯 `Center`：
      // 内容放得下时居中，放不下时可滚 —— 两个诉求都要满足。
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: MediaQuery.of(context).size.height * 0.5,
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                DshIcon(icon, size: 48, color: c.labelTertiary),
                const SizedBox(height: 16),
                Text(
                  title,
                  style: TextStyle(fontSize: 15, color: c.labelSecondary),
                ),
                const SizedBox(height: 8),
                Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: c.labelTertiary),
                ),
                if (failureNote != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    failureNote,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: c.roleTool),
                  ),
                ],
                const SizedBox(height: 24),
                // 两个入口都不需要连电脑。
                if (hasSessions || paired)
                  FilledButton.icon(
                    onPressed: onOpenDrawer,
                    icon: DshIcon('panelLeft', size: 14, color: c.onAccent),
                    label: const Text('打开会话抽屉'),
                  ),
                // 已配对但列表是空的：给一条"重新拉一次"的出路。
                // 会话由电脑侧新建，而自动拉只在连上那一刻发生一次 ——
                // 没有它，用户只能杀 App 重进。
                if (paired && !hasSessions && onRefresh != null) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: onRefresh,
                    icon: DshIcon('refresh', size: 14, color: c.labelSecondary),
                    label: const Text('重新拉取会话'),
                  ),
                ],
                // 已配对：给一条"重新配对（换一台电脑）"的出路（议题 3 ——
                // 任何状态 ≤2 步走到重新配对）。设备被停用/要换电脑时，
                // 用户停在空态也能**一步**直达，不必先想起 ☰。
                if (paired && onRePair != null) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: onRePair,
                    icon: DshIcon('refresh', size: 14, color: c.labelSecondary),
                    label: const Text('重新配对（换一台电脑）'),
                  ),
                ],
                if (!paired) ...[
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: onConnect,
                    style: FilledButton.styleFrom(
                      backgroundColor: c.accentBlue,
                      foregroundColor: c.onAccent,
                    ),
                    child: const Text('连电脑（配对）'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 文件面板的空态（差异 / 文件两个 tab 共用）。
///
/// **2026-10-15 删掉假 diff**：原来是 `sampleDiff` / `sampleFileLines`
/// 两份写死的样例，而调用方**无条件**传给 `DshDiff` / `DshCodeLines` ——
/// 于是真连上了打开文件抽屉，也会看到一段本项目 `chat_page.dart` 的假 diff，
/// **没有任何"示例"标记**。这是假数据里最坏的一处：它冒充真数据。
///
/// 真数据通路：`deliverables` 投影（diff）+ `workspace-files` 的
/// `read` / `list`（文件树与内容）。接上之前说"还没接"，不造假的。
/// 右侧「文件」面板里**真的改动清单**。
///
/// 数据来自工具调用（`AppModel.changedFiles`，判据照 DSH 的 `mutationPath`），
/// 不是编的。两个页签同一份数据：`文件` 看路径，`差异` 看路径 + 行数增量
/// （增量来自 `tool/result` 的 `metadata.diffs`，见 `ToolCallItem.diffStat`）。
///
/// **没有行数增量的行不显示 `+0 −0`**：那会把"不知道增了多少"说成"没变"。
/// 侧栏「差异 / 文件」两份视图，数据是**桌面那一轮改动记录**（`file.changes`）。
///
/// 与改动卡同一份记录、同一套 `_countsOf`：两处数字口径不可能不同。
/// 「差异」行点开逐行差异（`file.diff`，坐标 `seq`+下标），「文件」行点开内容预览。
class _ChangesPane extends StatefulWidget {
  const _ChangesPane({required this.app, required this.seq, required this.tab});

  final AppModel app;

  /// `workspace/changes` 事件的 seq（查询坐标）。
  final int seq;

  /// `0` = 差异；`1` = 文件。
  final int tab;

  @override
  State<_ChangesPane> createState() => _ChangesPaneState();
}

class _ChangesPaneState extends State<_ChangesPane> {
  @override
  void initState() {
    super.initState();
    // 下一帧再拉：`loadChangesSummary` 会同步通知祖先（同 `_ChangedFilesCard`）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureLoaded();
    });
  }

  void _ensureLoaded() {
    final app = widget.app;
    if (app.changesStateOf(widget.seq).loaded) return;
    if (app.changesLoading(widget.seq)) return;
    if (app.changesFailureOf(widget.seq) != null) return;
    unawaited(app.loadChangesSummary(widget.seq));
  }

  void _openRow(AppModel app, ChangedFile file, int index) {
    if (widget.tab == 0) {
      unawaited(
        app.openFile(
          FileOpenRequest(
            path: file.path,
            mode: FileOpenMode.diff,
            seq: widget.seq,
            index: index,
          ),
        ),
      );
      return;
    }
    unawaited(app.openFile(FileOpenRequest(path: file.path)));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final app = widget.app;
        final failure = app.changesFailureOf(widget.seq);
        if (failure != null) {
          return ListView(
            padding: const EdgeInsets.all(14),
            children: [
              Text(
                '改动记录读取失败：$failure',
                style: TextStyle(fontSize: 12, color: c.stateError),
              ),
              TextButton(
                onPressed: () => unawaited(app.loadChangesSummary(widget.seq)),
                child: const Text('重试'),
              ),
            ],
          );
        }
        final state = app.changesStateOf(widget.seq);
        if (!state.loaded) {
          return Center(
            child: Text(
              '正在读取改动…',
              style: TextStyle(fontSize: 12, color: c.labelTertiary),
            ),
          );
        }
        final summary = state.summary;
        if (summary == null) {
          return _EmptyFilePane(kind: widget.tab == 0 ? 'diff' : 'file');
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: summary.files.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 0.5, thickness: 0.5, color: c.borderL3),
                itemBuilder: (context, index) {
                  final file = summary.files[index];
                  return InkWell(
                    onTap: () => _openRow(app, file, index),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          DshIcon(
                            'deliverDoc',
                            size: 14,
                            color: c.labelTertiary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              file.display,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.35,
                                fontFamily: 'monospace',
                                color: c.labelPrimary,
                              ),
                            ),
                          ),
                          if (widget.tab == 0) ...[
                            const SizedBox(width: 8),
                            _countsOf(
                              context,
                              added: file.added,
                              deleted: file.deleted,
                              binary: file.binary,
                              oversized: file.oversized,
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            if (summary.truncated)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Text(
                  '还有 ${summary.total - summary.files.length} 个文件没列出（超过电脑侧上限）',
                  style: TextStyle(fontSize: 11, color: c.labelCaption),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ChangedFileList extends StatelessWidget {
  const _ChangedFileList({required this.rows, required this.showStat});

  final List<({String path, ({int added, int removed})? stat})> rows;

  /// `true` = 「差异」页签（显示行数增量）。
  final bool showStat;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: rows.length,
      separatorBuilder: (_, _) =>
          Divider(height: 0.5, thickness: 0.5, color: c.borderL3),
      itemBuilder: (context, index) {
        final row = rows[index];
        final stat = row.stat;
        return InkWell(
          // **点一行复制它的路径**（2026-10-20）。
          //
          // 这个动作先前被删掉过：那时面板里根本没有路径可复制，三个按钮
          // 只会弹「还没做」。留下的话写在删它的注释里 ——
          // 「等文件面板接上真的 deliverables 再一起做 —— 那时"复制路径"
          // 才有路径可复制」。现在条件满足了：清单是真的（来自工具调用），
          // 所以这个动作也是真的。
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: row.path));
            if (!context.mounted) return;
            DshToast.show(context, '已复制 ${row.path}');
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                DshIcon('deliverDoc', size: 14, color: c.labelTertiary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    row.path,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      fontFamily: 'monospace',
                      color: c.labelPrimary,
                    ),
                  ),
                ),
                if (showStat && stat != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    '+${stat.added}',
                    style: TextStyle(fontSize: 11, color: c.codeDiffAdd),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '−${stat.removed}',
                    style: TextStyle(fontSize: 11, color: c.codeDiffDel),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 右抽屉里"正在看的那一份文件"。
///
/// 数据全部来自 `AppModel`（`openFile` 是唯一入口）：这里只画三态 ——
/// 读失败（电脑侧原话）/ 正在读 / 已读到。**没有"加载中"之外的假内容**：
/// 空正文就是空正文，不是"文件不存在"。
class _OpenedFileBody extends StatelessWidget {
  const _OpenedFileBody({required this.app});

  final AppModel app;

  @override
  Widget build(BuildContext context) {
    // **自己听模型**：抽屉是独立路由，外层重建到不了它（与子智能体 sheet 同一条），
    // 而"读完了"是一次异步到达 —— 不自己听就永远停在「正在读取…」。
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => _content(context),
    );
  }

  Widget _content(BuildContext context) {
    final c = context.dshColors;
    final request = app.fileOpenRequest;
    final isDiff = request?.mode == FileOpenMode.diff;
    final opened = app.openedFile;
    final failure = isDiff ? app.diffFailure : app.fileFailure;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 关掉这份文件的入口（回到改动清单）。面板的标题栏那枚收起钮收的是
        // 整个抽屉，与"收起这个文件"不是一件事。
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 6, 0),
            child: TextButton.icon(
              key: const ValueKey<String>('file-open-back'),
              onPressed: app.closeFile,
              icon: DshIcon('chevronLeft', size: 14, color: c.labelSecondary),
              label: const Text('返回改动'),
            ),
          ),
        ),
        Expanded(
          child: isDiff
              ? _diffBody(context, failure, request!)
              : failure != null
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    failure,
                    style: TextStyle(fontSize: 12, color: c.stateError),
                  ),
                )
              : opened == null
              ? Center(
                  child: Text(
                    '正在读取…',
                    style: TextStyle(fontSize: 12, color: c.labelTertiary),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: c.layer1,
                          borderRadius: BorderRadius.circular(DshRadius.md),
                        ),
                        child: SelectableText(
                          opened.text,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 19 / 12,
                            color: c.labelSecondary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (opened.lines > 0)
                        Text(
                          opened.eof
                              ? '共 ${opened.lines} 行（已到末尾）'
                              : '已读 ${opened.lines} 行',
                          style: TextStyle(fontSize: 11, color: c.labelCaption),
                        ),
                      if (!opened.eof && !app.fileLoading)
                        TextButton(
                          key: const ValueKey<String>('file-open-more'),
                          onPressed: () => unawaited(app.loadMoreOpenedFile()),
                          child: const Text('加载更多'),
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  /// 逐行差异（`file.diff`）的五种结局，文案与桌面同一份词典
  /// （`ui-deliverables/src/client/locales.ts:58-67`）。
  Widget _diffBody(
    BuildContext context,
    String? failure,
    FileOpenRequest request,
  ) {
    final c = context.dshColors;
    if (failure != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '无法读取改动：$failure',
              style: TextStyle(fontSize: 12, color: c.stateError),
            ),
            TextButton(
              onPressed: () => unawaited(app.openFile(request)),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (app.diffLoading) return _diffNote(context, '正在读取改动…');
    final diff = app.openedDiff;
    // 电脑侧没有这条记录（会话已释放 / 没记录过）—— 与桌面 `diff.missing` 同一句话。
    if (diff == null) return _diffNote(context, '这轮改动的内容已不可用');
    if (diff.isBinary) return _diffNote(context, '二进制文件，无法显示改动');
    if (diff.isOversized) return _diffNote(context, '文件过大，无法显示改动');
    final notes = <String>[
      if (!diff.before) '本轮新建的文件',
      if (!diff.after) '本轮删除的文件',
      if (diff.before && diff.after && diff.hunks.isEmpty) '两侧内容相同',
      if (diff.coarse) '逐行对比超时，按整个文件替换显示',
      if (diff.truncated != null)
        '只显示前 ${diff.truncated!.shownLines} 行（共 ${diff.truncated!.totalLines} 行）',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final note in notes)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Text(
              note,
              style: TextStyle(fontSize: 11, color: c.labelCaption),
            ),
          ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: DshDiff(diffLinesOfHunks(diff.hunks)),
          ),
        ),
      ],
    );
  }

  Widget _diffNote(BuildContext context, String text) {
    final c = context.dshColors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: c.labelTertiary),
        ),
      ),
    );
  }
}

class _EmptyFilePane extends StatelessWidget {
  const _EmptyFilePane({required this.kind});

  /// `diff` / `file`。
  final String kind;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final isDiff = kind == 'diff';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            DshIcon(
              isDiff ? 'deliverDoc' : 'folderClose',
              size: 40,
              color: c.labelTertiary,
            ),
            const SizedBox(height: 16),
            Text(
              isDiff ? '还没有改动' : '还没有文件内容',
              style: TextStyle(fontSize: 15, color: c.labelSecondary),
            ),
            const SizedBox(height: 8),
            Text(
              isDiff
                  ? '电脑侧这一轮改了什么，会在这里列成差异。\n'
                        '数据来自会话投影 deliverables。'
                  : '在电脑上选中一个文件，这里显示它的内容。\n'
                        '数据来自 workspace-files 的 read / list。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: c.labelTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

/// 轨迹页签。
///
/// 实现已搬到 `ui/trajectory_page.dart`（轮次行 + 用时迷你条）——
/// 它有自己的行规格，留在本文件里会让"聊天页"这个文件同时装两个页面的规格。
/// 这里只留接线：**把 `turnOutline` 与本会话的条目 join 成轮次行**，点一行弹 `sheet-traj`。
///
/// ## 为什么之前轨迹页常驻空态
///
/// `TrajectoryTab` 一直接收 `rows` / `entries` 两个参数，而这一层**只传了
/// `onTapEntry`** —— 于是两个表恒为空、轨迹页永远显示"电脑侧跑完一轮后…"。
/// 契约里 `turnOutline` 投影一直都在（`session.projections`，§5.7），
/// 手机也早就解析了别的投影，只是从没把它接进来。
class _TrajectoryTab extends StatelessWidget {
  const _TrajectoryTab({
    required this.app,
    required this.onTapTurn,
    required this.onTapSegment,
  });

  final AppModel app;
  final void Function(TraceTurn turn) onTapTurn;
  final void Function(TraceTurn turn, List<TrajectoryStep> steps) onTapSegment;

  @override
  Widget build(BuildContext context) {
    // **一轮一行**：`turnOutline` 的 wire view 是 `[{turn, seq, prompt, response}]`
    // （DSH `session-turn-outline/src/projection.ts:61-75`），用时与时间轴从
    // `trajectory` 投影 join 进来、计数从本会话的 `TurnProcessItem` join 进来
    // （join 规则只有一处：`buildTraceTurns`）。
    // 空表时 `TrajectoryTab` 自己显示空态，不在这里兜假数据。
    //
    // `trajectory == null` = 这台电脑没注册投影 —— 与"跑完一轮就有了"是
    // 两句不同的话，所以把这一位原样传下去。
    final trajectory = app.trajectory;
    return TrajectoryTab(
      turns: buildTraceTurns(
        outline: app.turnOutline,
        items: app.items,
        trajectory: trajectory,
      ),
      onTapTurn: onTapTurn,
      onTapSegment: onTapSegment,
      truncationLabel: trajectoryTruncationLabel(trajectory),
      timelineMissing: trajectory == null,
    );
  }
}
