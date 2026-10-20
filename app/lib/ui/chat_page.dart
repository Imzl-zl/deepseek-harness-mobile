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

import '../core/errors.dart';
import '../core/job.dart';
import '../data/app_model.dart';
import '../model/agent_preset.dart';
import '../model/chat_item.dart';
import '../model/model_catalog.dart';
import '../model/permission.dart';
import '../model/preferences.dart';
import '../model/session_stats.dart';
import '../model/workspace.dart';
import '../platform/photo_picker.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';
import 'chat_jumper.dart';
import 'chat_turns.dart';
import 'collapsible_group.dart';
import 'connection_actions_sheet.dart';
import 'connection_summary_block.dart';
import 'conversation_hero.dart';
import 'dsh_app_bar.dart';
import 'dsh_composer.dart';
import 'dsh_markdown.dart';
import 'dsh_sheet.dart';
import 'dsh_state_dot.dart';
import 'edge_stick.dart';
import 'load_older_trigger.dart';
import 'queue_dock.dart';
import 'side_pane.dart';
import 'takeover.dart';
import 'trajectory_page.dart';

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

  /// 进入子会话之前的那个会话（顶栏"返回"用）。
  ///
  /// **不是数据依赖，是导航记忆**：catalog 的 view 不带 `parentId`
  ///（`subagent/src/catalog.ts:77-94`），所以父会话只能"我来的时候记一下"。
  /// 子会话在抽屉里是藏起来的（`sessionVisible` 第 1 条），
  /// 没有这枚返回用户就找不回来。
  String? _subagentReturnFrom;

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
    // 权限档与接管队列联动：**完全权限下审批不入队**（原型 `enqueue` 的
    // 同一条逻辑 —— 那是"已授权"的结果，不是绕过）。
    _takeover.addListener(_onTakeoverChanged);
    // **真实交互接进接管队列**：待处理项是会话事件的投影（契约 §6.3），
    // 于是"对话流里有一条审批"与"输入栏上有一张审批卡"不可能对不上。
    _interactionSub = widget.app.interactions.listen(_onInteractionSignal);
    // 答复出口：控制器不认识 `AppModel`，所以在这一层把"答一次"接到
    // `interaction.respond` 上（装配点才知道用哪个实现）。
    // **没配对时不接**：那意味着没有电脑可答，而接一个必然失败的出口只会
    // 让演示入口（`＋` → 演示接管）每次都被报成"已过期"。
    _syncAnswerOutlet();
  }

  @override
  void didUpdateWidget(ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 配对状态是构造参数：配对上之后出口才该出现（见 `initState` 里同一句）。
    if (oldWidget.paired != widget.paired) _syncAnswerOutlet();
  }

  void _syncAnswerOutlet() {
    _takeover.onAnswer = widget.paired ? _onTakeoverAnswer : null;
  }

  /// 交互信号 → 接管队列。
  void _onInteractionSignal(InteractionSignal signal) {
    if (!mounted) return;
    switch (signal) {
      case InteractionOpened(:final item):
        if (!_takeover.enqueue(item)) {
          // 完全权限下审批不入队（原型同一条逻辑）—— 如实提示，不静默丢弃。
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('完全权限下不再逐步确认：${item.toolName} 直接执行')),
          );
        }
      case InteractionSettled(:final itemId):
        // **不带 sid**：收束要全桶找。迟到的 `approval/decided` 可能属于
        // **另一个**会话（用户在 A 里的时候 B 的审批在电脑上被答了）——
        // 限定当前桶会让 B 的卡片永远挂着。
        _takeover.settle(itemId);
    }
  }

  /// 把一次答复发给电脑（契约 §5.7 的 `interaction.respond`）。
  ///
  /// **失败不吞**：`interaction/not-pending` 说明这一项已经不在待处理集合里
  /// （电脑侧答过了、或会话被替换），用户该看到"已过期"而不是以为答成功了。
  Future<void> _onTakeoverAnswer(InteractionAnswer answer) async {
    try {
      await widget.app.respondInteraction(answer);
    } on Exception catch (error) {
      // 结构化错误（`ProtocolException`）与其它异常都走这条：它们对用户是同一件事 ——
      // "这一项没能答上去"。而 `interaction/not-pending` 的客户端动作正是
      // "刷新待处理列表"，所以顺手把那一项从队列里撤掉。
      if (!mounted) return;
      _takeover.settle(answer.itemId);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('这一项已过期：$error')));
    }
  }

  /// 把电脑侧的真值同步给接管队列（**每次 build 调，幂等**）。
  ///
  /// ## 为什么放在 build 里
  ///
  /// 权限档的真值在电脑侧（`permissions` 投影），手机不再持有本地副本 ——
  /// 于是"改权限"与"同步给接管"必须是同一件事的两面，而不是两个各自赋值的地方。
  /// 历史上正是两处 `setState(() => _accessMode = …)` 各自赋值，
  /// 而接管队列的 `fullAccess` 只在接管自己 notify 时才同步，于是"切到完全权限"
  /// 之后审批**照样入队**（那个标志还是旧的）—— 不崩、不报错，
  /// 只会让"完全权限下不再逐次确认"这句话变成假的。
  ///
  /// 与 `_takeover.setCurrentSid` 同一个口径：控制器内部重复设不通知。
  ///
  /// **取不到当前值时按"不是完全权限"算**：那是保守侧 —— 宁可多问一次，
  /// 也不要因为"不知道"就跳过审批。
  void _syncTakeoverAccess() {
    _takeover.fullAccess = widget.app.permissionValue == fullAccessPreset;
  }

  void _onTakeoverChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('拉取会话失败：${error.message}')));
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('先在列表里选一个会话，再发消息')));
      return;
    }
    setState(() => _sending = true);
    try {
      final requestId = 'p-${DateTime.now().microsecondsSinceEpoch}';
      // **带上发送模式**（排队 / 插话）：DSH 原生二选一，我们这边一个方法
      // 带 `mode` 参数（`connector/src/handlers.ts` 的 `session.prompt`）。
      // 不给这个字段时电脑侧按默认的 queue 走 —— 与本文默认值一致。
      await widget.app.client.call<void>('session.prompt', {
        'sid': sid,
        // 载荷形状由 `promptContentOf` 一处决定（纯函数，可单测）——
        // 图片随 `{type:'image', mediaType, data}` 一起发出去。
        'content': promptContentOf(text: text, attachments: _attachments),
        'mode': widget.app.sendMode.wire,
      }, requestId: requestId);
      _input.clear();
      if (mounted) setState(() => _attachments.clear());
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('发送失败：$error')));
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
    _syncTakeoverAccess();
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
            _mainScaffold(context, jobsSid: jobsSid),
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
    final items = widget.app.items;
    final sid = widget.app.currentSid;
    // **各算一次**：`_subsFor()` / `_jobsFor()` 要走投影映射，而顶栏那两枚计数
    // chip 与右抽屉三个面板读的是**同一份**。原来 drawer 与 chip 行各调两遍
    // （每帧四遍），chip 行还用 `_jobsSid`（`currentSid ?? ''`）而 drawer 用参数 ——
    // 两者虽然等价（`_jobsFor` 里 `sid ?? ''`），但没有理由留两个来源。
    final subs = _subsFor();
    final jobs = _jobsFor(jobsSid);
    final runningSubs = subs.where((j) => j.isLive).length;
    final runningJobs = jobs.where((j) => j.isLive).length;
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: c.bgBase,
      drawer: widget.drawer,
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
        title: widget.app.currentTitle ?? 'DSH',
        onOpenDrawer: openDrawer,
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
          onPanelChanged: (p) => setState(() => _sidePanel = p),
          onClose: _closeSide,
          fileBody: _fileBody(),
          jobs: jobs,
          subs: subs,
          runningJobs: runningJobs,
          runningSubs: runningSubs,
          onToggleJob: (job) => _toggleJob(job),
          // 停止：任务面板里最常见的那件事。**不传它就永远没有停止按钮**
          //（渲染条件里有 `onStop != null`）—— 第一版就漏了传，
          // 截图里运行中的任务旁边空着。
          onStopJob: (job) => _stopJob(job),
          // 子智能体行：点它**进入那个子会话**（不是展开输出）。
          // 会话 id 已是别名（连接器在 `session.projections` 里换过，见
          // `connector/src/handlers.ts` 的 `aliasSubagentCatalog`），
          // 所以直接 `openSession` 就通。
          onOpenSub: (job) => _openSubagentSession(job),
          openJobIds: _openJobs,
          fullscreen: _sideFullscreen,
          onToggleFullscreen: () =>
              setState(() => _sideFullscreen = !_sideFullscreen),
        ),
      ),
      onEndDrawerChanged: (open) {
        // 右缘那条棒棒的显隐跟着它走（开着就收起来）。
        if (_sideOpen == open) return;
        setState(() => _sideOpen = open);
      },
      body: Column(
        children: [
          // **子会话的面包屑**（只在"从子智能体进来"时出现）。
          //
          // DSH 桌面靠会话头部的 lineage 回父会话
          // （`SubagentHeaderLineage.tsx`）；我们拿不到 `parentId`
          //（catalog 的 view 只有 `{id, createdAt, mode, label?}`，
          // `subagent/src/catalog.ts:77-94`），所以用**导航记忆**
          //（`_subagentReturnFrom`）—— 没有它用户找不回来：
          // 子会话在抽屉里是藏起来的（`sessionVisible` 第 1 条）。
          //
          // 放在内容区上方而不是顶栏：那行已有五个位置
          //（☰ / 标题 / 状态点 / 两枚计数 / ＋），挤不下。
          if (_subagentReturnFrom != null)
            _SubagentBreadcrumb(onBack: _returnFromSubagent),
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
                : _TrajectoryTab(app: widget.app, onTapEntry: _showTraceSheet),
          ),
          // ---- 底部：接管卡 + 输入栏 + 统计条 ----
          Container(
            color: c.sidebar,
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).padding.bottom + 6,
            ),
            child: Column(
              children: [
                // **接管卡在输入栏上方**：它接管的是"下一步做什么"，
                // 而输入栏仍然是最后一行（用户随时能看到自己在哪打字）。
                // 原型是把输入栏整块换掉 —— 手机上并排更省高度，
                // 且不会让用户以为"输入框不见了"。
                TakeoverPanel(controller: _takeover),
                // **排队条**（DSH Web 的 `conversation.input.dock` 槽里的
                // QueueDock）：会话正在跑时发出去的消息排进下一个轮次，
                // 这里列出来并可编辑 / 删除 / 插话。空队列整条不占位。
                if (sid != null)
                  QueueDock(app: widget.app, sid: sid, running: _running),
                DshComposer(
                  controller: _input,
                  attachments: _attachments,
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
        ],
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

  /// 是否有"可看的数据"（真连上了，或在看示例）。
  bool get _hasData => widget.paired || widget.app.isPreview;

  /// 当前会话是否正在跑（排队条的插话门 + 发送模式 sheet 的禁用判据）。
  ///
  /// **从电脑侧来**（`session.list` 的 `running`，`connector/src/dsh/sessions.ts`）——
  /// 手机不自己猜"应该在跑吧"。
  bool get _running {
    final sid = widget.app.currentSid;
    if (sid == null) return false;
    return widget.app.sessionOf(sid)?.running ?? false;
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
    final sid = widget.app.currentSid;
    if (sid == null) return '未选择';
    final model = widget.app.sessionOf(sid)?.model;
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
    final sid = widget.app.currentSid;
    if (sid == null) return null;
    final model = widget.app.sessionOf(sid)?.model;
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
  void _onStatusTap() {
    if (!widget.paired) {
      widget.onConnect?.call();
      return;
    }
    _showConnectionActionsSheet();
  }

  /// 弹连接操作 sheet（议题 3 的唯一形状，三处入口共用）。
  void _showConnectionActionsSheet() {
    unawaited(
      showConnectionActionsSheet(
        context,
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
  /// ## 为什么要记住"从哪来"
  ///
  /// DSH 的目录项点开是 `openChild` → `openSession(address)`
  ///（`ui-subagent/src/client/index.ts:61-63`）—— 子会话**替换主对话区**。
  /// 桌面靠会话头部的 lineage 面包屑回得去
  ///（`SubagentHeaderLineage.tsx`），而**我们拿不到父会话 id**：
  /// catalog 的 view 只有 `{id, createdAt, mode, label?}`
  ///（`subagent/src/catalog.ts:77-94`，`parentId` 只在
  /// `listDescendants` 的行上有，那是另一个方法）。
  ///
  /// 所以退路用**导航记忆**而不是数据依赖：进来时记下当前会话，
  /// 顶栏据此给一枚"返回"。这比"让用户自己去抽屉里找父会话"好得多 ——
  /// 子会话在抽屉里是**藏起来的**（`sessionVisible` 的第 1 条：
  /// `subagent` 不列），用户根本找不回来。
  Future<void> _openSubagentSession(SideJob job) async {
    final from = widget.app.currentSid;
    _closeSide();
    // **先记后退**：`_subagentReturnFrom` 是"进子会话之前的那个会话"。
    setState(() => _subagentReturnFrom = from);
    await widget.app.openSession(job.id);
  }

  /// 从子会话回到来处（顶栏那枚"返回"）。
  Future<void> _returnFromSubagent() async {
    final from = _subagentReturnFrom;
    if (from == null) return;
    setState(() => _subagentReturnFrom = null);
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
    // **不再写死一个文件名与 diff 统计**（2026-10-20）：这里原来恒返回
    // `chat_page.dart` / `app/lib/ui/chat_page.dart` / `+128 −46`，
    // 而面板体（`_fileBody`）显示的是「还没有改动」——
    // **表头声称某个文件有 128 行改动，面板体说根本没有改动**。
    // 那不是"示例"，是在生产路径上摆假数据（与会静默丢弃的假附件同类）。
    //
    // 等文件面板接上真的 `deliverables` 投影再从数据里取标题与统计；
    // 在那之前表头只说实话（与面板体的空态同一口径）。
    SidePanel.file => const SideHeader(title: '文件'),
    SidePanel.jobs => const SideHeader(title: '后台任务'),
    SidePanel.subs => const SideHeader(title: '子智能体'),
  };

  Widget? _fileBody() {
    if (_sidePanel != SidePanel.file) return null;
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
        _fileTab == 0
            ? const _EmptyFilePane(kind: 'diff')
            : const _EmptyFilePane(kind: 'file'),
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
  void _toast(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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

  /// `sheet-traj`：点账本条目弹的详情。
  ///
  /// **点得动是刻意的**：账本给"形状"（时间花在哪），
  /// 而这个 sheet 给"这一条到底是什么" —— 只有账本会让人问"那 84 毫秒干了啥"。
  void _showTraceSheet(TraceEntry entry) => unawaited(
    showDshSheet<void>(
      context: context,
      title: '轨迹条目',
      body: Column(
        children: [
          DshKeyValue(label: '角色', value: entry.name),
          DshKeyValue(label: '耗时', value: entry.took),
          DshKeyValue(label: '结果', value: entry.summary),
        ],
      ),
      actions: [
        DshSheetAction(
          label: '查看完整调用',
          filled: true,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    ),
  );

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
      _toast('切换失败：${widget.app.lastError?.message ?? '电脑侧没有给结论'}');
      return;
    }
    final effortLabel = widget.app.modelCatalog?.effortNameOf(
      provider: picked.provider,
      model: picked.model,
      effort: picked.reasoningEffort,
    );
    _toast(
      effortLabel == null || effortLabel.isEmpty
          ? '已切到 $name'
          : '已切到 $name · $effortLabel',
    );
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
      case PhotoPicked(:final mediaType, :final data, :final name):
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
      // 原型底栏有一个「演示」入口（`data-act="demo"`）。这里照做：
      // 接管卡**只有真的有待办才出现**，而"看看它长什么样"需要一个入口。
      (icon: 'shield', label: '演示：接管输入栏', desc: '审批 / 提问 / 计划长什么样'),
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
                  } else {
                    _enqueueDemoTakeovers();
                  }
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 装三个演示接管（审批 / 提问 / 计划），让"接管长什么样"可见。
  ///
  /// 队列是**瀑布**（一次只处理队首），所以三个会依次出现。
  void _enqueueDemoTakeovers() {
    setState(() {
      _takeover.enqueue(
        const InteractionItem(
          itemId: 'demo-approval',
          sid: 'preview-1',
          callId: 'demo-call-approval',
          kind: InteractionKind.approval,
          toolName: 'bash',
          title: '工具 bash 请求越权执行',
          detail:
              'rm -rf build/ && flutter clean\n\n'
              '只读 / 工作区内修改模式下，越权操作要你确认；\n'
              '完全权限模式下这一步不会出现（那是"已授权"的结果）。',
        ),
      );
      _takeover.enqueue(
        const InteractionItem(
          itemId: 'demo-question',
          sid: 'preview-1',
          callId: 'demo-call-question',
          kind: InteractionKind.question,
          header: 'DSH 想确认一件事',
          title: '拆连接层的资源束时，要不要顺手把「在途请求」也一起拆出去？',
          questions: [
            InteractionQuestion(
              id: 'demo-q1',
              header: 'DSH 想确认一件事',
              question: '拆连接层的资源束时，要不要顺手把「在途请求」也一起拆出去？',
              options: [
                InteractionOption(
                  // **标签里不写"（推荐）"**：原型会把它剥出来单独渲染成徽标
                  //（`label.replace(/[（(]推荐[)）]/g, '')`）。
                  // 我第一版把"（推荐）"写进了标签，于是界面上同时出现
                  // 标签里的括号与独立徽标 —— 重复了。
                  label: '一起拆',
                  description: '它俩生命周期不同：资源束每连接换一份，在途请求要跨重连保留',
                  recommended: true,
                ),
                InteractionOption(
                  label: '先只拆资源束',
                  description: '改动更小，但在途请求那个缺口会留着',
                ),
              ],
            ),
          ],
        ),
      );
      _takeover.enqueue(
        const InteractionItem(
          itemId: 'demo-plan',
          sid: 'preview-1',
          callId: 'demo-call-plan',
          kind: InteractionKind.plan,
          title: '把侧抽屉的「任务」面板接上 job 帧',
          approveLabel: '同意执行',
          questions: [
            InteractionQuestion(
              id: 'demo-call-plan',
              question: '把侧抽屉的「任务」面板接上 job 帧',
              detail:
                  '1. 展开时 `job.follow`，收起时 `job.unfollow`\n'
                  '2. 把三帧映射成 SideJob\n'
                  '3. 停止走 `job.stop`，两步确认',
              options: [
                InteractionOption(label: '同意执行'),
                InteractionOption(label: '要求修改'),
              ],
            ),
          ],
        ),
      );
    });
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

  /// 子智能体列表（`core/job.dart` 的 `SubagentRow` → 侧抽屉的 `SideJob`）。
  ///
  /// 映射只在这里发生一次：UI 不认识 `subagentCatalog` 投影的 JSON。
  List<SideJob> _subsFor() {
    final rows = widget.app.subagentsOf(widget.app.currentSid ?? '');
    return [
      for (final row in rows)
        SideJob(
          id: row.id,
          kind: 'agent',
          label: row.displayLabel,
          state: row.status,
          statusText: row.statusText,
          durationText: _subDuration(row),
          output: '',
        ),
    ];
  }

  /// 子智能体时长。与 `_jobDuration` 同一条纪律：**从电脑侧时间戳算**，
  /// 不从手机本地计时（锁屏/后台时手机会停）。
  String _subDuration(SubagentRow row) {
    final end = row.finishedAt ?? DateTime.now().millisecondsSinceEpoch;
    final seconds = ((end - row.startedAt) / 1000).floor();
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// 子智能体面板的内容。
  ///
  /// **2026-10-15 删掉假数据**。原来是两条写死的示例子智能体
  /// （`Extract DSH icon paths` / `Research rikkahub standalone mode`），
  /// 状态文字带「· 示例」—— 标记是有，但它**无条件**出现在面板里，
  /// 真连上了也照显示。
  ///
  /// 真数据通路**已经找到了**（上一轮我判成"阻塞"是找错了门）：
  /// `subagentCatalog` 投影（`packages/subagent/subagent/src/catalog.ts:122`）
  /// 经 `session.projections` 读；写面有 `SubagentRuntime` 的
  /// `@Remote('prompt')` 与 `@Remote('interruptByParent')`
  /// （`packages/subagent/subagent/src/index.ts:445,512`）。
  /// 接线见 `.agents/notes/proposed/2026-10-15-phone-surface-inventory.md`。
  ///
  /// 面板内容由 `SidePane` 的 `subs` 参数给（`_subsFor()`），空列表由
  /// `SidePane` 的 `emptyText` 渲染 —— 不另造一份空态，那会让
  /// "没有子智能体"有两个说法。
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
        onPreview: app.loadPreview,
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
      liveText: app.liveText,
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
class _ConversationFlow extends StatefulWidget {
  const _ConversationFlow({
    required this.items,
    required this.autoOpenDetail,
    this.liveText,
    this.app,
  });

  final List<ChatItem> items;
  final bool autoOpenDetail;

  /// 流式文本；`null` = 没有正在生成的流。
  ///
  /// 它是**虚拟尾条目**：没有稳定 itemId（不进 store），所以列表数是
  /// `items.length + (liveText == null ? 0 : 1)`。持久的 `assistant/message`
  /// 到达后它自动消失（`AppModel` 不再给值）—— 那条消息整体替换它。
  final String? liveText;

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
  List<GlobalKey> _keys = const [];

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
    _syncKeys();
  }

  @override
  void didUpdateWidget(_ConversationFlow old) {
    super.didUpdateWidget(old);
    if (!identical(widget.items, old.items)) _syncKeys();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _syncKeys() {
    _keys = List.generate(widget.items.length, (_) => GlobalKey());
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
    for (var i = 0; i < _keys.length; i += 1) {
      final box = _keys[i].currentContext?.findRenderObject() as RenderBox?;
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
    if (index < 0 || index >= _keys.length) return;
    final context = _keys[index].currentContext;
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
    _ensureVisible((_firstVisibleIndex + delta).clamp(0, _keys.length - 1));
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
            // **+1 是流式尾条目**（虚拟，没有 itemId）。
            itemCount: widget.items.length + (widget.liveText == null ? 0 : 1),
            itemBuilder: (context, index) {
              // `reverse: true` 下 index 0 是**最新**一端，所以流式条目在 index 0，
              // 持久条目从 1 开始（`widget.items[index - 1]`）。
              if (widget.liveText != null && index == 0) {
                return KeyedSubtree(
                  key: const ValueKey('live'),
                  child: _LiveTurn(widget.liveText!),
                );
              }
              final itemIndex = widget.liveText == null ? index : index - 1;
              return KeyedSubtree(
                key: itemIndex < _keys.length ? _keys[itemIndex] : null,
                child: _TurnView(
                  item: widget.items[itemIndex],
                  autoOpenDetail: widget.autoOpenDetail,
                ),
              );
            },
          ),
        ),
        // 跳转钮：浮在右侧，滚动停下 1.5 秒后自己淡出。
        // `itemCount` 含流式尾条目 —— 它与持久条目一样"可跳"。
        Positioned.fill(
          child: ChatJumper(
            itemCount: widget.items.length + (widget.liveText == null ? 0 : 1),
            onStep: _step,
            onEdge: _edge,
            onCreated: (controller) => _jumper = controller,
          ),
        ),
      ],
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
  const _LiveTurn(this.text);

  /// 正在生成的文本（`AppModel.liveText`）。
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头像 + 「助手」—— 与 `AssistantTurn` 同一套（照原型 `.a-head`）。
          Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [DshColors.accentBlue, DshColors.roleAssistant],
                  ),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Center(
                  child: DshIcon('sparkle', size: 14, color: Colors.white),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '助手',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: c.labelPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // **正在生成的正文**（Markdown，与持久消息同一套渲染）。
          // 空文本时给一行占位 —— 那表示"这一步开始了但还没有文本"
          // （可能在等工具结果），说"正在生成"比一片白诚实。
          if (text.isEmpty)
            Text(
              '正在生成…',
              style: TextStyle(fontSize: 13, color: c.labelTertiary),
            )
          else
            DshMarkdown(text),
        ],
      ),
    );
  }
}

class _TurnView extends StatelessWidget {
  const _TurnView({required this.item, this.autoOpenDetail = false});

  final ChatItem item;

  /// 工具明细默认展开（"工作步骤展示"偏好）。
  final bool autoOpenDetail;

  @override
  Widget build(BuildContext context) {
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
      ) =>
        switch (role) {
          MessageRole.user => UserTurn(
            text,
            attachmentCount: attachmentCount,
            steering: steering,
          ),
          MessageRole.assistant => AssistantTurn(
            text: text,
            reasoning: reasoning,
          ),
          MessageRole.system => SystemTurn(text, label: systemLabel),
        },
      ToolCallItem(
        :final name,
        :final status,
        :final summary,
        :final detail,
        :final diffStat,
      ) =>
        ToolCard(
          name: name,
          status: status,
          argument: summary,
          detail: detail,
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
      TurnProcessItem(
        :final title,
        :final stats,
        :final failed,
        :final usage,
        :final copyText,
      ) =>
        TurnProcessRow(
          title: title,
          stats: stats,
          failed: failed,
          usage: usage,
          copyText: copyText,
        ),
      // 一次上下文压缩（`compaction/*` 三条事件）。
      CompactionItem(:final summary, :final stats) => CompactionRow(
        summary: summary,
        stats: stats,
      ),
    };
  }
}

/// 子会话的面包屑：`← 返回上一个会话`。
///
/// ## 为什么需要它
///
/// 点右抽屉「子智能体」的某一行会**进入那个子会话**（`openSession`）——
/// 与 DSH 的 `openChild` 同一条（`ui-subagent/src/client/index.ts:61-63`）。
/// 但子会话在会话列表里是**藏起来的**（`sessionVisible` 第 1 条：
/// `subagent` 不列），所以用户没有别的路回到父会话。
///
/// DSH 靠会话头部的 lineage 面包屑（`SubagentHeaderLineage.tsx`）；
/// 我们拿不到 `parentId`（catalog 的 view 只有
/// `{id, createdAt, mode, label?}`，`subagent/src/catalog.ts:77-94`），
/// 所以用**导航记忆**：进来时把来处记在 `_subagentReturnFrom`。
///
/// 放在内容区上方而不是顶栏：那一行已有五个位置
///（☰ / 标题 / 状态点 / 两枚计数 / ＋），挤不下。
class _SubagentBreadcrumb extends StatelessWidget {
  const _SubagentBreadcrumb({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Material(
      color: c.layer1,
      child: InkWell(
        onTap: onBack,
        child: Container(
          // 一行高一点，便于点（触摸目标 ≥ 32）。
          constraints: const BoxConstraints(minHeight: 34),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            children: [
              DshIcon('chevronLeft', size: 14, color: c.accentBlue),
              const SizedBox(width: 4),
              Text(
                '返回上一个会话',
                style: TextStyle(fontSize: 12.5, color: c.accentBlue),
              ),
              const SizedBox(width: 8),
              // 说清"你在看的是子智能体" —— 否则标题突然变了会莫名其妙。
              Expanded(
                child: Text(
                  '正在查看子智能体',
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: c.labelCaption),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
    required this.onPreview,
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
  final VoidCallback onPreview;

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
                  OutlinedButton.icon(
                    onPressed: onPreview,
                    icon: DshIcon('sparkle', size: 14, color: c.labelSecondary),
                    label: const Text('看示例数据'),
                  ),
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
/// 实现已搬到 `ui/trajectory_page.dart`（甘特条 + 账本列表）——
/// 它有 300 行，留在本文件里会让"聊天页"这个文件同时装两个页面的规格。
/// 这里只留接线：**把 `turnOutline` 投影喂成账本**，点条目弹 `sheet-traj`。
///
/// ## 为什么之前轨迹页常驻空态
///
/// `TrajectoryTab` 一直接收 `rows` / `entries` 两个参数，而这一层**只传了
/// `onTapEntry`** —— 于是两个表恒为空、轨迹页永远显示"电脑侧跑完一轮后…"。
/// 契约里 `turnOutline` 投影一直都在（`session.projections`，§5.7），
/// 手机也早就解析了别的投影，只是从没把它接进来。
class _TrajectoryTab extends StatelessWidget {
  const _TrajectoryTab({required this.app, required this.onTapEntry});

  final AppModel app;
  final void Function(TraceEntry entry) onTapEntry;

  @override
  Widget build(BuildContext context) {
    // **一轮一行**：`turnOutline` 的 wire view 是 `[{turn, seq, prompt, response}]`
    // （DSH `session-turn-outline/src/projection.ts:61-75`）。
    // 空表时 `TrajectoryTab` 自己显示空态，不在这里兜假数据。
    final entries = [
      for (final turn in app.turnOutline)
        TraceEntry(
          kind: TraceKind.assistant,
          name: '第 ${turn.turn} 轮',
          // `turnOutline` 不带耗时（只有 turn/seq/prompt/response）——
          // 空着比编一个数字诚实。
          took: '',
          prompt: turn.promptLabel,
          summary: turn.responseLabel,
          mono: false,
        ),
    ];
    return TrajectoryTab(entries: entries, onTapEntry: onTapEntry);
  }
}
