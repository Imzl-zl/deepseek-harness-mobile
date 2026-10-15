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

import 'package:flutter/material.dart';

import '../core/job.dart';
import '../data/app_model.dart';
import '../model/chat_item.dart';
import '../model/permission.dart';
import '../model/send_mode.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';
import 'chat_turns.dart';
import 'connection_actions_sheet.dart';
import 'dsh_app_bar.dart';
import 'dsh_composer.dart';
import 'dsh_sheet.dart';
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

  /// 右抽屉是否打开（竖屏手机上它是**全屏页**，见 `side_pane.dart` 文件头）。
  bool _sideOpen = false;
  SidePanel _sidePanel = SidePanel.file;

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

  /// 打开右侧抽屉（文件 / 任务 / 子代理）。
  ///
  /// 连接操作 sheet 的「打开侧面板」经它落（那一条原来直接挂在顶栏状态位上，
  /// 现在状态位改弹连接操作 sheet，"打开侧面板"降为 sheet 里的一个选项）。
  void openSide() => setState(() => _sideOpen = true);

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
    // **没选会话就发不出去，必须说出来**：静默 `return` 会让用户以为"点了没反应"，
    // 而那正是"我发了啥也没有"最常见的成因（真机实测）。
    if (text.isEmpty || _sending) return;
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
        'content': [
          {'type': 'text', 'text': text},
        ],
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
            // 主界面（聊天页）。
            _mainScaffold(context),
            // ---- 右抽屉：一个抽屉三个面板（竖屏手机上它是全屏页）----
            if (_sideOpen)
              Positioned.fill(
                child: GestureDetector(
                  // 点遮罩关闭（原型 `.side-scrim { opacity:.45 }`）。
                  onTap: _closeSide,
                  child: Container(color: Colors.black.withValues(alpha: 0.45)),
                ),
              ),
            if (_sideOpen)
              Positioned.fill(
                child: SidePane(
                  header: _sideHeader(),
                  panel: _sidePanel,
                  onPanelChanged: (p) => setState(() => _sidePanel = p),
                  onClose: _closeSide,
                  fileBody: _fileBody(),
                  fileActions: _fileActions(),
                  jobs: _jobsFor(jobsSid),
                  subs: _subsFor(),
                  runningJobs: _jobsFor(jobsSid).where((j) => j.isLive).length,
                  runningSubs: _subsFor().where((j) => j.isLive).length,
                  onToggleJob: (job) => _toggleJob(job),
                  // 停止：任务面板里最常见的那件事。**不传它就永远没有停止按钮**
                  //（渲染条件里有 `onStop != null`）—— 第一版就漏了传，
                  // 截图里运行中的任务旁边空着。
                  onStopJob: (job) => _stopJob(job),
                  openJobIds: _openJobs,
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
  Widget _mainScaffold(BuildContext context) {
    final items = widget.app.items;
    final sid = widget.app.currentSid;
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: DshColors.bgBase,
      drawer: widget.drawer,
      // 左缘跟手拖出的宽度（原型 `.edge--open` 手势带）。
      // 用 `Drawer` 自带的边缘拖动而不是自写手势：它已经处理了
      // "拖动中遮罩透明度""松手回弹"这些细节。
      drawerEdgeDragWidth: 32,
      appBar: ChatAppBar(
        title: widget.app.currentTitle ?? 'DSH',
        onOpenDrawer: widget.onOpenDrawer,
        onNewSession: widget.onNewSession,
        // 状态位：有后台任务显任务（点它开右抽屉），否则不显示。
        // 原型：*"有任务显任务,否则显文件变更;点它开右抽屉"*。
        statusText: _statusText(),
        statusIcon: _statusIcon(),
        statusIsWarn: !widget.paired,
        onStatusTap: _onStatusTap,
      ),
      body: Column(
        children: [
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
                    onOpenDrawer: widget.onOpenDrawer,
                    onRefreshSessions: _refreshSessions,
                    onOpenSession: widget.onOpenSession ?? (_) {},
                    onConnect: widget.onConnect,
                    // 已配对时给空态一条"重新配对"的出路（议题 3，1 步直达）。
                    onRePair: widget.paired ? widget.onRePair : null,
                  )
                : _TrajectoryTab(onTapEntry: _showTraceSheet),
          ),
          // ---- 底部：接管卡 + 输入栏 + 统计条 ----
          Container(
            color: DshColors.sidebar,
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
                  onSend: _send,
                  onAttach: _showAttachSheet,
                  onPickModel: _showModelSheet,
                  onPickAccess: _showAccessSheet,
                  onPickSendMode: _showSendModeSheet,
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

  /// `第 N 轮 · M 步`；轮次为 0 或读不到就是 `null`（整条不显示）。
  ///
  /// 有解码数据时**把输出速率拼在同一格里**，照 Web 的
  /// `1 turns 1 steps · 20 tok/s`（`StatsPills.tsx:166-170,242-243`）——
  /// 手机原来只显示轮次步数，速率那一项整个丢了。
  String? get _turnText {
    final stats = widget.app.sessionStats;
    final base = stats?.turnLabel;
    if (base == null) return null;
    final tps = stats?.tokensPerSecond;
    if (tps == null) return base;
    return '$base · ${tps.round()} tok/s';
  }

  /// `302K · 缓存 42%`；读不到用量就是 `null`。
  ///
  /// **缓存率为 null 时不拼那半句**：没有计费输入时算不出命中率，
  /// 而显示 `缓存 0%` 会让用户以为"缓存坏了"，其实只是这一轮还没花 token。
  /// 分母用 `billedInput`（未缓存 + 缓存读 + 缓存写），与 Web 逐字一致 ——
  /// 手机原来把输出也算进去，同一个会话两个端显示两个命中率。
  String? get _usageText {
    final usage = widget.app.tokenUsage;
    if (usage == null) return null;
    final hit = usage.cacheHitRate;
    if (hit == null) return usage.totalLabel;
    return '${usage.totalLabel} · 缓存 ${(hit * 100).round()}%';
  }

  /// 上下文占用百分比。**算法与 Web 逐字一致**：
  /// `projectedTokens ?? pressureTokens` 除以 `contextWindow`
  /// （`packages/client/ui-conversation/src/client/context-occupancy.ts:15-25`）。
  ///
  /// 投影**本来就给窗口大小**（`contextWindow` 在 wire view 里）——
  /// 手机原来没解析它，于是这里只能返回 null，那一格整个不显示。
  int? get _contextPercent => widget.app.contextPressure?.occupancy?.percent;

  // ---------------------------------------------------------------------------
  // 右抽屉（文件 / 任务 / 子代理）
  // ---------------------------------------------------------------------------

  /// 状态位的文字。
  ///
  /// 顺序照原型 §7.8,再加一层"连接异常优先":
  /// 1. **连接不在服务态且已配对** → 连接状态（`重连中…` 等）。它是**可点的出路**，
  ///    必须常在 —— 否则议题 3 的「≤2 步走到重新配对」没有落点。
  /// 2. 有后台任务 → `N 任务运行中`（琥珀）。
  /// 3. 已配对且在服务态 → `已连接`。**不返回 null**：状态位是右抽屉（文件/任务/
  ///    子代理）的入口，基线规定它可点；返回 null 会让整个 pill 消失，右bar 就只剩
  ///    sheet 里一条路。文件变更那一档**不显示**：手机的文件面还没接
  ///    （`workspace-files`），显示"0 个文件变更"是把"没接"说成"没有"。
  String? _statusText() {
    // **看示例数据时也当"有数据"** —— 否则示例模式下一半界面是死的
    //（状态位点不开右抽屉），而示例数据存在的意义正是"看看它长什么样"。
    if (!_hasData) return '未连接';
    if (widget.paired && widget.app.connection != ConnectionStateView.serving) {
      return connectionLabel(widget.app.connection);
    }
    final live = _jobsFor(widget.app.currentSid).where((j) => j.isLive).length;
    if (live > 0) return '$live 任务运行中';
    if (widget.paired) return '已连接';
    return null;
  }

  /// 是否有"可看的数据"（真连上了，或在看示例）。
  bool get _hasData => widget.paired || widget.app.isPreview;

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
  String get _modelLabel {
    if (!_hasData) return '未连接';
    final sid = widget.app.currentSid;
    if (sid == null) return '未选择';
    final model = widget.app.sessionOf(sid)?.model;
    return model?.label ?? '未选择';
  }

  String _statusIcon() => _hasData ? 'loading' : 'warningTriangle';

  /// 推理等级的文字。
  ///
  /// 也**不写死**（原来是 `'高'`）：电脑侧给了 effort 就显示它，没给就显示"默认" ——
  /// "默认"是实话（DSH 的 `reasoning` 带 `defaultEffort`，见
  /// `packages/api/session-controller/src/catalog.ts`），编一个等级才是谎。
  String get _reasoningLabel {
    if (!_hasData) return '默认';
    final sid = widget.app.currentSid;
    if (sid == null) return '默认';
    final effort = widget.app.sessionOf(sid)?.model?.reasoningEffort;
    return effort ?? '默认';
  }

  /// 顶栏状态位的点击。
  ///
  /// - **没配对**：去配对页（空态的「连电脑（配对）」同义）。
  /// - **已配对但连接不在服务态**：弹连接操作 sheet（含「重新配对」）——
  ///   这正是用户最需要出路的时刻，也是议题 3「≤2 步」的落点。
  /// - **已配对且在服务态**：**开右抽屉**（原型基线行为：状态位本就是右抽屉的入口，
  ///   `docs/design-and-tech-plan.md` §7.8）。否则为了重配入口把状态位整个占掉，
  ///   右bar(文件/任务/子代理)就只剩 sheet 里一条路 —— 而正常使用时那里才该一步到。
  ///
  /// 这条切分写在设计文档的有意偏离里：连接态只在**异常时**占位，serving 时
  /// 把位置还给基线规定的内容。
  void _onStatusTap() {
    if (!widget.paired) {
      widget.onConnect?.call();
      return;
    }
    if (widget.app.connection == ConnectionStateView.serving) {
      openSide();
      return;
    }
    _showConnectionActionsSheet();
  }

  /// 弹连接操作 sheet（议题 3 的唯一形状，三处入口共用）。
  void _showConnectionActionsSheet() {
    unawaited(
      showConnectionActionsSheet(
        context,
        onRePair: () => widget.onRePair?.call(),
        onOpenSide: openSide,
        onDisconnect: () => widget.onDisconnect?.call(),
      ),
    );
  }

  void _closeSide() => setState(() => _sideOpen = false);

  SideHeader _sideHeader() => switch (_sidePanel) {
    SidePanel.file => const SideHeader(
      title: 'chat_page.dart',
      subtitle: 'app/lib/ui/chat_page.dart',
      added: 128,
      removed: 46,
    ),
    SidePanel.jobs => const SideHeader(title: '后台任务'),
    SidePanel.subs => const SideHeader(title: '子代理'),
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

  Widget? _fileActions() {
    if (_sidePanel != SidePanel.file) return null;
    return Row(
      children: [
        _FileAction(icon: 'copy', label: '复制路径', onTap: () => _toast('复制路径')),
        const SizedBox(width: 8),
        _FileAction(
          icon: 'rightUp',
          label: '在电脑打开',
          onTap: () => _toast('在电脑打开'),
        ),
        const SizedBox(width: 8),
        _FileAction(
          icon: 'share',
          label: '分享',
          filled: true,
          onTap: () => _toast('分享'),
        ),
      ],
    );
  }

  void _toast(String what) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('$what 还没接上数据')));
  }

  // ---------------------------------------------------------------------------
  // sheet 体系（照原型的 `sheet-*` action）
  // ---------------------------------------------------------------------------

  /// `sheet-stats`：会话统计。数值照原型。
  void _showStatsSheet() => showDshSheet<void>(
    context: context,
    title: '会话统计',
    body: const Column(
      children: [
        DshKeyValue(label: '模型用时', value: '12.4', unit: 's'),
        DshKeyValue(label: '工具用时', value: '3.8', unit: 's'),
        DshKeyValue(label: '首 token (TTFT)', value: '420', unit: 'ms'),
        DshKeyValue(label: '输出速度', value: '516', unit: 'tok/s'),
        DshKeyValue(label: '轮次 / 步数', value: '1 / 3'),
      ],
    ),
  );

  /// `sheet-usage`：Token 用量。
  void _showUsageSheet() => showDshSheet<void>(
    context: context,
    title: 'Token 用量',
    body: const Column(
      children: [
        DshKeyValue(label: '缓存命中', value: '0%'),
        DshKeyValue(label: '未缓存输入', value: '12,480'),
        DshKeyValue(label: '缓存读取', value: '289,120'),
        DshKeyValue(label: '缓存写入', value: '0'),
        DshKeyValue(label: '输出', value: '1,204'),
        DshKeyValue(label: '合计', value: '302,804'),
      ],
    ),
  );

  /// `sheet-context`：上下文已用 N% —— **三段用量条**是这一屏的重点。
  void _showContextSheet() {
    const meter = DshContextMeter(
      systemTokens: 7200,
      toolTokens: 10100,
      messageTokens: 2600,
      limitTokens: 1000000,
    );
    unawaited(
      showDshSheet<void>(
        context: context,
        title: '上下文已用 ${meter.percent}%',
        body: meter,
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

  /// 模型选择（§7.9 的行结构）。
  ///
  /// **2026-10-15 删掉四个手抄的模型名**。原来是
  /// `claude-opus` / `claude-sonnet` / `gpt-5-codex` / `deepseek-v4.1-flash`
  /// 四个写死的名字，`selected` 也写死（第一个恒为 true），点完只弹 toast
  /// **不切任何东西**。
  ///
  /// 现在的来源：
  /// - **读**：`session/modelCatalog`（连接器已接，`dsh/models.ts`）。
  ///   手机上显示的名字与电脑侧**同一份真值**，不手抄第二份。
  /// - **写**：`session/select-model` —— **与 Web 用同一个 DSH 方法**
  ///   （已核实 Web 侧调的就是它，
  ///   `packages/client/ui-model-selection/src/client/directory.ts:98`）。
  ///   语义：**当前会话**立即生效、**以后新建的**会话默认跟随、
  ///   **不改别的会话**（`packages/core/agent-default-model/src/index.ts:82-94`）。
  ///   所以"新会话默认跟随"是 Web 一直有的行为，不是副作用。
  void _showModelSheet() {
    final catalog = widget.app.modelCatalog;
    if (catalog == null || catalog.isEmpty) {
      _toast('拿不到模型目录：电脑侧没有返回 session/modelCatalog');
      return;
    }
    unawaited(
      showDshSheet<void>(
        context: context,
        title: '选择模型',
        body: Column(
          children: [
            for (final m in catalog)
              DshPickerRow(
                name: m.model,
                tags: [m.provider],
                selected: m.model == widget.app.currentModel?.model,
                onTap: () => _switchModel(m),
              ),
          ],
        ),
      ),
    );
  }

  /// 切模型。**失败要如实说** —— 静默失败会让用户以为"点了没反应"，
  /// 而那正是这一版之前的样子（点完只弹一个"切到 X"的 toast）。
  Future<void> _switchModel(ModelRef model) async {
    Navigator.of(context).pop();
    final picked = await widget.app.selectModel(
      provider: model.provider,
      model: model.model,
    );
    if (!mounted) return;
    if (picked == null) {
      _toast('切换失败：${widget.app.lastError?.message ?? '电脑侧没有给结论'}');
      return;
    }
    _toast('已切到 ${picked.model}');
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

  /// 发送模式二选一（DSH 的"繁忙时的发送行为"：排队 / 插话）。
  ///
  /// **插话那一项在会话没在跑时禁用**：DSH 的文案就是"仅运行中可插话发送"
  /// （`locales.ts:365`），而轮次已变时 DSH 回 `session/steer-unavailable`。
  /// 禁用而不是"点了再报错"—— 报错只会让用户以为发失败了。
  void _showSendModeSheet() {
    final sid = widget.app.currentSid;
    final running = sid == null
        ? false
        : widget.app.sessionOf(sid)?.running ?? false;
    unawaited(
      showDshSheet<void>(
        context: context,
        title: '繁忙时的发送行为',
        body: Column(
          children: [
            for (final mode in SendMode.values)
              DshPickerRow(
                name: mode.label,
                tags: [
                  mode == SendMode.queue ? '排到下一个轮次（默认）' : '插进当前轮次，立刻生效',
                  if (mode == SendMode.steer && !running)
                    '仅运行中可插话发送 —— 这个会话此刻没在跑',
                ],
                icon: mode.icon,
                selected: mode == widget.app.sendMode,
                enabled: mode != SendMode.steer || running,
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(widget.app.setSendMode(mode));
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 完全权限的**风险确认门**：必须勾选才生效（§7.10）。
  ///
  /// 勾选态**不跨次残留**（§7.10 表格里"关掉后重开，勾选态不残留"）——
  /// 所以开门的动作里先把它清掉，而不是依赖"新建 widget 就自然是 false"
  ///（那在 widget 被复用时就不成立了）。
  Future<void> _showRiskGate(PermissionPreset option) {
    _riskAcked = false;
    return showDshSheet<void>(
      context: context,
      title: '启用${option.name}？',
      body: StatefulBuilder(
        builder: (context, setSheetState) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '这一档下，DSH 执行越权操作时不再问你。'
              '误操作（删文件、改工作区外的东西）不会被拦。',
              style: TextStyle(
                fontSize: 13,
                height: 20 / 13,
                color: DshColors.labelSecondary,
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
                      activeColor: DshColors.roleTool,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '我已了解风险',
                      style: TextStyle(
                        fontSize: 13,
                        color: DshColors.labelPrimary,
                      ),
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
  void _showAttachSheet() {
    const items = [
      (icon: 'paperclip', label: '附件', desc: '图片、文档、PDF'),
      (icon: 'folderOpen', label: '工作区文件', desc: '桌面端 Ctrl+P'),
      (icon: 'code', label: '新建终端', desc: '桌面端 Ctrl+`'),
      (icon: 'globe', label: '浏览器', desc: '桌面端 Ctrl+T'),
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
                  switch (item.label) {
                    case '附件':
                      setState(
                        () => _attachments.add(
                          const PendingAttachment(name: '新增文件.txt'),
                        ),
                      );
                    case '演示：接管输入栏':
                      _enqueueDemoTakeovers();
                    default:
                      _toast(item.label);
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
  /// **2026-10-15 删掉假数据**。原来是两条写死的示例子代理
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

/// 文件面板底部的动作按钮（`.btn--out` / `.btn--fill`）。
class _FileAction extends StatelessWidget {
  const _FileAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.filled = false,
  });

  final String icon;
  final String label;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Material(
        color: filled ? DshColors.layer3 : Colors.transparent,
        borderRadius: BorderRadius.circular(DshRadius.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: 38,
            alignment: Alignment.center,
            decoration: filled
                ? null
                : BoxDecoration(
                    borderRadius: BorderRadius.circular(DshRadius.md),
                    border: Border.all(color: DshColors.layer3),
                  ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                DshIcon(icon, size: 14, color: DshColors.labelSecondary),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: DshColors.labelSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
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
    this.onConnect,
    this.onRePair,
  });

  final AppModel app;
  final List<ChatItem> items;
  final bool paired;
  final VoidCallback onOpenDrawer;

  /// 重新拉会话列表（由**有状态**的页面层实现：它能在 await 之后安全用 `context`）。
  final VoidCallback onRefreshSessions;

  /// 打开某个会话（主界面上的内联列表与抽屉共用同一条通路）。
  final void Function(SessionSummary session) onOpenSession;
  final VoidCallback? onConnect;

  /// 已配对时空态的"重新配对（换一台电脑）"出路（议题 3）。未配对为 `null`。
  final VoidCallback? onRePair;

  @override
  Widget build(BuildContext context) {
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
          onRefresh: paired ? onRefreshSessions : null,
        );
      }
      return _EmptyChat(
        paired: paired,
        hasSessions: app.sessions.isNotEmpty,
        // **已经选中了会话**（只是它还没有条目）——必须与"还没选"分开说。
        // 少了这一支，点进一个空会话会看到"选一个会话"，而用户**刚刚才选过**，
        // 那句话会让人以为点击没生效（真机实测）。
        selectedSid: app.currentSid,
        onOpenDrawer: onOpenDrawer,
        onConnect: onConnect,
        onRePair: onRePair,
        onPreview: app.loadPreview,
        onRefresh: paired ? onRefreshSessions : null,
        // 失败原因带进空态：**空列表 + 有错** 与 **空列表 + 真没有** 必须看得出区别。
        // 连接诊断也带上：真机"列表恒空 + 反复重连"而两端日志无原因，
        // 就是因为原因只躺在客户端的诊断字段里（详见 `AppModel.connectionDiagnosis`）。
        errorText: app.lastError?.message ?? app.connectionDiagnosis,
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: items.length,
      itemBuilder: (context, index) => _TurnView(item: items[index]),
    );
  }
}

/// 主界面上的会话列表（**不必先开抽屉**）。
///
/// 与抽屉里的那份是**同一批数据**（`AppModel.sessions`），只是摆的位置不同：
/// 抽屉是"历史入口"，这里是"首页就该看得见的东西"。
class _SessionListInline extends StatelessWidget {
  const _SessionListInline({
    required this.sessions,
    required this.onOpen,
    this.onRefresh,
  });

  final List<SessionSummary> sessions;
  final void Function(SessionSummary session) onOpen;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: [
              const Text(
                '会话',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: DshColors.labelCaption,
                ),
              ),
              const Spacer(),
              if (onRefresh != null)
                IconButton(
                  onPressed: onRefresh,
                  tooltip: '重新拉取会话',
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                  color: DshColors.labelTertiary,
                  icon: const DshIcon(
                    'refresh',
                    size: 16,
                    color: DshColors.labelTertiary,
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: sessions.length,
            itemBuilder: (context, index) {
              final session = sessions[index];
              return ListTile(
                dense: true,
                title: Text(
                  // 标题链照 DSH：持久标题 → 项目目录名 → 会话 id
                  // （`SessionSummary.displayTitle`，service.ts:116-127）。
                  session.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    color: DshColors.labelPrimary,
                  ),
                ),
                subtitle: () {
                  // 副标题显示**模型**，不再显示 sid：标题按 DSH 的链会退到 sid
                  // （`displayTitle`），再显示一遍 sid 就是同一行里同一个字符串。
                  // Web 的列表行同样不显示原始会话 id。
                  final model = session.model?.label;
                  return model == null ? null : Text(model);
                }(),
                onTap: () => onOpen(session),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 一条条目 → 对应的渲染组件（**按类型分派**）。
class _TurnView extends StatelessWidget {
  const _TurnView({required this.item});

  final ChatItem item;

  @override
  Widget build(BuildContext context) {
    // sealed class ⇒ 这个 switch 是穷尽的：加一种条目时编译器会在**这里**报错，
    // 而不是让新类型静默渲染成空白。
    return switch (item) {
      MessageItem(:final role, :final text) => switch (role) {
        MessageRole.user => UserTurn(text),
        MessageRole.assistant => AssistantTurn(text: text),
        MessageRole.system => SystemTurn(text),
      },
      ToolCallItem(:final name, :final status, :final summary) => ToolCard(
        name: name,
        status: status,
        argument: summary,
      ),
      ApprovalItem(:final title, :final decided) => TakeoverHint(
        icon: decided ? 'check' : 'shield',
        name: decided ? 'approval' : 'approval',
        argument: title,
        statusText: decided ? '已决定' : '等待审批',
      ),
      OtherItem() => const SizedBox.shrink(),
    };
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
    this.onRefresh,
    this.onConnect,
    this.onRePair,
    this.errorText,
  });

  final bool paired;
  final bool hasSessions;

  /// 当前选中的会话（`null` = 还没选）。**用来把"选了但还没内容"与"还没选"分开**。
  final String? selectedSid;
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

  @override
  Widget build(BuildContext context) {
    // **"拉取失败"必须与"真没有会话"分开说**（`app_model.dart` 的 `lastError`）。
    // 两者在界面上一模一样（都是空列表），而下一步动作完全不同：
    // 一个去电脑上开会话，一个查连接/协议错误。
    // 少了这一支，"连上了却永远没有会话"就只能靠猜 —— 实测就是这么被卡住的。
    final error = errorText;
    final (icon, title, detail) = !paired
        ? ('globe', '还没连电脑', '界面可以先看。要看到真实会话，得先配对（在电脑上出码）。')
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
                DshIcon(icon, size: 48, color: DshColors.labelTertiary),
                const SizedBox(height: 16),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    color: DshColors.labelSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    color: DshColors.labelTertiary,
                  ),
                ),
                const SizedBox(height: 24),
                // 两个入口都不需要连电脑。
                if (hasSessions || paired)
                  FilledButton.icon(
                    onPressed: onOpenDrawer,
                    icon: const DshIcon(
                      'panelLeft',
                      size: 14,
                      color: DshColors.onAccent,
                    ),
                    label: const Text('打开会话抽屉'),
                  ),
                // 已配对但列表是空的：给一条"重新拉一次"的出路。
                // 会话由电脑侧新建，而自动拉只在连上那一刻发生一次 ——
                // 没有它，用户只能杀 App 重进。
                if (paired && !hasSessions && onRefresh != null) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: onRefresh,
                    icon: const DshIcon(
                      'refresh',
                      size: 14,
                      color: DshColors.labelSecondary,
                    ),
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
                    icon: const DshIcon(
                      'refresh',
                      size: 14,
                      color: DshColors.labelSecondary,
                    ),
                    label: const Text('重新配对（换一台电脑）'),
                  ),
                ],
                if (!paired) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: onPreview,
                    icon: const DshIcon(
                      'sparkle',
                      size: 14,
                      color: DshColors.labelSecondary,
                    ),
                    label: const Text('看示例数据'),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: onConnect,
                    style: FilledButton.styleFrom(
                      backgroundColor: DshColors.accentBlue,
                      foregroundColor: DshColors.onAccent,
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
              color: DshColors.labelTertiary,
            ),
            const SizedBox(height: 16),
            Text(
              isDiff ? '还没有改动' : '还没有文件内容',
              style: const TextStyle(
                fontSize: 15,
                color: DshColors.labelSecondary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              isDiff
                  ? '电脑侧这一轮改了什么，会在这里列成差异。\n'
                        '数据来自会话投影 deliverables。'
                  : '在电脑上选中一个文件，这里显示它的内容。\n'
                        '数据来自 workspace-files 的 read / list。',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                color: DshColors.labelTertiary,
              ),
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
/// 这里只留接线：点账本条目弹 `sheet-traj`。
class _TrajectoryTab extends StatelessWidget {
  const _TrajectoryTab({required this.onTapEntry});

  final void Function(TraceEntry entry) onTapEntry;

  @override
  Widget build(BuildContext context) {
    return TrajectoryTab(onTapEntry: onTapEntry);
  }
}
