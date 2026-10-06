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

import '../data/app_model.dart';
import '../model/chat_item.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';
import 'chat_turns.dart';
import 'dsh_app_bar.dart';
import 'dsh_composer.dart';
import 'dsh_diff.dart';
import 'dsh_sheet.dart';
import 'side_pane.dart';
import 'takeover.dart';

/// 聊天页。
class ChatPage extends StatefulWidget {
  const ChatPage({
    super.key,
    required this.app,
    required this.onOpenDrawer,
    required this.onNewSession,
    required this.drawer,
    this.paired = true,
    this.onConnect,
  });

  final AppModel app;

  /// 顶栏 `☰`（由外层打开抽屉 —— 抽屉要盖住整个 Scaffold，所以归外层管）。
  final VoidCallback onOpenDrawer;

  final VoidCallback onNewSession;

  /// 抽屉本体（外层 `Scaffold.drawer`）。
  final Widget drawer;

  /// 是否已配对（没配对时输入栏置灰、状态胶囊说"未连接"）。
  final bool paired;

  final VoidCallback? onConnect;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
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
  final Set<String> _openJobs = {'j1'};

  /// 当前访问模式（原型默认"工作区内可改"）。
  AccessMode _accessMode = AccessMode.workspaceWrite;

  /// 风险门里的勾选态。
  ///
  /// **不跨次残留**（§7.10 表格："关掉后重开，勾选态不残留"）——
  /// 每次开风险门都从 `false` 起（`_showRiskGate` 里重置）。
  bool _riskAcked = false;

  /// 输入栏接管（审批 / 提问 / 计划）。
  final TakeoverController _takeover = TakeoverController();

  @override
  void initState() {
    super.initState();
    // 输入框有内容才亮发送键 —— `TextField` 的 `onChanged` 不触发本层重建，
    // 所以手动挂一个监听（否则发送键永远灰着）。
    _input.addListener(_onInputChanged);
    // 权限档与接管队列联动：**完全权限下审批不入队**（原型 `enqueue` 的
    // 同一条逻辑 —— 那是"已授权"的结果，不是绕过）。
    _takeover.addListener(_onTakeoverChanged);
  }

  /// 切权限档（**唯一的入口**）。
  ///
  /// ## 为什么要收成一个方法
  ///
  /// 原先两处 `setState(() => _accessMode = …)` 各自赋值，而**接管队列的
  /// `fullAccess` 只在接管自己 notify 时才同步** —— 于是"切到完全权限"之后，
  /// 审批**照样入队**（那个标志还是旧的）。
  ///
  /// 这条 bug 不会崩、不会报错，只会让"完全权限下不再逐次确认"这句话变成假的。
  /// 收成一个方法之后，"改权限"与"同步给接管"必然一起发生。
  void _setAccessMode(AccessMode mode) {
    setState(() {
      _accessMode = mode;
      _takeover.fullAccess = mode == AccessMode.fullAccess;
    });
  }

  void _onTakeoverChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _takeover.removeListener(_onTakeoverChanged);
    _takeover.dispose();
    _input.removeListener(_onInputChanged);
    _input.dispose();
    super.dispose();
  }

  void _onInputChanged() => setState(() {});

  /// 发一句。
  ///
  /// **幂等键在入队时生成**（契约 §5.6）：重发复用同一个 —— 换键等于换了一次新消息。
  Future<void> _send() async {
    final text = _input.text.trim();
    final sid = widget.app.currentSid;
    if (text.isEmpty || _sending || sid == null) return;
    setState(() => _sending = true);
    try {
      final requestId = 'p-${DateTime.now().microsecondsSinceEpoch}';
      await widget.app.client.call<void>('session.prompt', {
        'sid': sid,
        'text': text,
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
                  jobs: _previewJobs(),
                  subs: _previewSubs(),
                  runningJobs: _previewJobs().where((j) => j.isLive).length,
                  runningSubs: _previewSubs().where((j) => j.isLive).length,
                  onToggleJob: (job) => setState(() {
                    if (!_openJobs.remove(job.id)) _openJobs.add(job.id);
                  }),
                  // 停止：任务面板里最常见的那件事。**不传它就永远没有停止按钮**
                  //（渲染条件里有 `onStop != null`）—— 第一版就漏了传，
                  // 截图里运行中的任务旁边空着。
                  onStopJob: (job) => _toast('停止 ${job.label}'),
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
        onStatusTap: _openSide,
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
                    onConnect: widget.onConnect,
                  )
                : const _TrajectoryTab(),
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
                  // 模型名与推理等级：接上 `repo.info` 之后从真数据来，
                  // 现在给占位（界面上看得出是占位：写的是"未连接"）。
                  modelName: _hasData ? 'claude-opus' : '未连接',
                  reasoningLabel: '高',
                  accessMode: _accessMode,
                  sending: _sending,
                  enabled: _hasData && sid != null,
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
                    turnText: items.isEmpty
                        ? null
                        : '第 1 轮 · ${items.length} 步',
                    usageText: items.isEmpty ? null : '302K · 缓存 0%',
                    contextPercent: items.isEmpty ? null : 3,
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
  // 右抽屉（文件 / 任务 / 子代理）
  // ---------------------------------------------------------------------------

  /// 状态位的文字：有后台任务显任务，否则显文件变更（原型注释）。
  String? _statusText() {
    // **看示例数据时也当"有数据"** —— 否则示例模式下一半界面是死的
    //（状态位点不开右抽屉），而示例数据存在的意义正是"看看它长什么样"。
    if (!_hasData) return '未连接';
    final live = _previewJobs().where((j) => j.isLive).length;
    if (live > 0) return '$live 任务运行中';
    return null;
  }

  /// 是否有"可看的数据"（真连上了，或在看示例）。
  bool get _hasData => widget.paired || widget.app.isPreview;

  String _statusIcon() => _hasData ? 'loading' : 'warningTriangle';

  void _openSide() {
    if (!_hasData) {
      widget.onConnect?.call();
      return;
    }
    setState(() => _sideOpen = true);
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
            ? const DshDiff(sampleDiff)
            : const DshCodeLines(sampleFileLines),
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

  /// 模型选择（§7.9 的行结构）。
  void _showModelSheet() {
    const models = [
      (name: 'claude-opus', tags: ['图片', '工具', '推理'], selected: true),
      (name: 'claude-sonnet', tags: ['图片', '工具'], selected: false),
      (name: 'gpt-5-codex', tags: ['工具'], selected: false),
      (name: 'deepseek-v4.1-flash', tags: ['纯文本', '工具'], selected: false),
    ];
    unawaited(
      showDshSheet<void>(
        context: context,
        title: '选择模型',
        body: Column(
          children: [
            for (final m in models)
              DshPickerRow(
                name: m.name,
                tags: m.tags,
                selected: m.selected,
                onTap: () {
                  Navigator.of(context).pop();
                  _toast('切到 ${m.name}');
                },
              ),
          ],
        ),
      ),
    );
  }

  /// 权限选择（三档 + 完全权限的**风险确认门**，§7.10）。
  ///
  /// §7.10 的硬规则："未授权 → 绝不生效"。
  /// 所以完全权限那一档**不是直接切**，而是先弹风险门、要勾选
  /// "我已了解风险"才能启用。
  void _showAccessSheet() {
    const modes = [
      (mode: AccessMode.readOnly, desc: '只能看，不能改任何文件'),
      (mode: AccessMode.workspaceWrite, desc: '可在工作区内改文件，越权要审批'),
      (mode: AccessMode.fullAccess, desc: '不再逐次审批 —— 危险'),
    ];
    unawaited(
      showDshSheet<void>(
        context: context,
        title: '访问模式',
        body: Column(
          children: [
            for (final m in modes)
              DshPickerRow(
                name: m.mode.label,
                tags: [m.desc],
                icon: m.mode.icon,
                selected: m.mode == _accessMode,
                onTap: () {
                  Navigator.of(context).pop();
                  if (m.mode.isWarn) {
                    unawaited(_showRiskGate(m.mode));
                  } else {
                    _setAccessMode(m.mode);
                  }
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
  Future<void> _showRiskGate(AccessMode mode) {
    _riskAcked = false;
    return showDshSheet<void>(
      context: context,
      title: '启用${mode.label}？',
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
            _setAccessMode(mode);
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
        const TakeoverItem(
          key: 'demo-approval',
          kind: TakeoverKind.approval,
          toolName: 'bash',
          title: '工具 bash 请求越权执行',
          detail:
              'rm -rf build/ && flutter clean\n\n'
              '只读 / 工作区内修改模式下，越权操作要你确认；\n'
              '完全权限模式下这一步不会出现（那是"已授权"的结果）。',
        ),
      );
      _takeover.enqueue(
        const TakeoverItem(
          key: 'demo-question',
          kind: TakeoverKind.question,
          header: 'DSH 想确认一件事',
          title: '拆连接层的资源束时，要不要顺手把「在途请求」也一起拆出去？',
          options: [
            TakeoverOption(
              // **标签里不写"（推荐）"**：原型会把它剥出来单独渲染成徽标
              //（`label.replace(/[（(]推荐[)）]/g, '')`）。
              // 我第一版把"（推荐）"写进了标签，于是界面上同时出现
              // 标签里的括号与独立徽标 —— 重复了。
              label: '一起拆',
              description: '它俩生命周期不同：资源束每连接换一份，在途请求要跨重连保留',
              recommended: true,
            ),
            TakeoverOption(label: '先只拆资源束', description: '改动更小，但在途请求那个缺口会留着'),
          ],
        ),
      );
      _takeover.enqueue(
        const TakeoverItem(
          key: 'demo-plan',
          kind: TakeoverKind.plan,
          title: '把侧抽屉的「任务」面板接上 job 帧',
          detail:
              '1. 展开时 `job.follow`，收起时 `job.unfollow`\n'
              '2. 把三帧映射成 SideJob\n'
              '3. 停止走 `job.stop`，两步确认',
        ),
      );
    });
  }

  /// **示例任务**（数据照 `mock/proto/app.js` 的 `JOBS`）。
  ///
  /// 占位：真的任务要等 `job.follow` / `job` 帧那条通路接上。
  /// 有它是一个**可见的接口契约**：这一屏该显示什么，看这里就够。
  static List<SideJob> _previewJobs() => const [
    SideJob(
      id: 'j1',
      kind: 'pwsh',
      label: 'flutter build apk --debug',
      state: 'running',
      statusText: '构建中 · 电脑端执行',
      durationText: '02:14',
      output:
          "Running Gradle task 'assembleDebug'...\n"
          'Resolving dependencies...\n'
          '> Task :app:compileFlutterBuildDebug\n'
          '(构建在电脑端进行，手机只看进度)',
    ),
    SideJob(
      id: 'j5',
      kind: 'pwsh',
      label: 'node protocol/verify-fixtures.mjs',
      state: 'completed',
      statusText: '已完成',
      durationText: '00:03',
      output: 'ALL CHECKS PASSED — 486 项断言，16 条 fixture',
    ),
    SideJob(
      id: 'j7',
      kind: 'bash',
      label: 'rm -rf build/ && flutter clean',
      state: 'running',
      statusText: '等待审批',
      durationText: '00:41',
    ),
  ];

  /// **示例子代理**（数据照 `mock/proto/app.js` 的 `SUBS`）。
  static List<SideJob> _previewSubs() => const [
    SideJob(
      id: 's1',
      kind: 'agent',
      label: 'Extract DSH icon paths',
      state: 'completed',
      statusText: '已完成',
      durationText: '08:57',
      output: '98 个图标 · 验证脚本全 PASS',
    ),
    SideJob(
      id: 's2',
      kind: 'agent',
      label: 'Research rikkahub standalone mode',
      state: 'completed',
      statusText: '已完成',
      durationText: '12:20',
      output: '本机运行模式调研：三条路径，见 docs/standalone-mode-notes.md',
    ),
  ];
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
    this.onConnect,
  });

  final AppModel app;
  final List<ChatItem> items;
  final bool paired;
  final VoidCallback onOpenDrawer;
  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return _EmptyChat(
        paired: paired,
        hasSessions: app.sessions.isNotEmpty,
        onOpenDrawer: onOpenDrawer,
        onConnect: onConnect,
        onPreview: app.loadPreview,
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: items.length,
      itemBuilder: (context, index) => _TurnView(item: items[index]),
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
/// 三句话分开说（**这是本页最有价值的一段文案**）：
/// 没配对 / 真没有会话 / 有会话但没选中。
class _EmptyChat extends StatelessWidget {
  const _EmptyChat({
    required this.paired,
    required this.hasSessions,
    required this.onOpenDrawer,
    required this.onPreview,
    this.onConnect,
  });

  final bool paired;
  final bool hasSessions;
  final VoidCallback onOpenDrawer;
  final VoidCallback onPreview;
  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) {
    final (icon, title, detail) = !paired
        ? ('globe', '还没连电脑', '界面可以先看。要看到真实会话，得先配对（在电脑上出码）。')
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

/// **示例 diff**（数据照 `mock/proto/app.js` 的 `FILES["app/lib/ui/chat_page.dart"]`）。
///
/// 它是**占位**：真的 diff 要等 `session.diff` 那条数据通路接上。
/// 放在这里而不是 `preview_data.dart`：它是"这一屏长什么样"的样例，
/// 与"会话里有哪些消息"不是一类。
const List<DiffLine> sampleDiff = [
  DiffLine.hunk(
    '@@ -112,9 +112,14 @@ class _ChatPageState extends State<ChatPage> {',
  ),
  DiffLine(
    kind: DiffKind.context,
    oldLine: 112,
    newLine: 112,
    text: '  @override',
  ),
  DiffLine(
    kind: DiffKind.context,
    oldLine: 113,
    newLine: 113,
    text: '  Widget build(BuildContext context) {',
  ),
  DiffLine(kind: DiffKind.del, oldLine: 114, text: '    return Scaffold('),
  DiffLine(
    kind: DiffKind.del,
    oldLine: 115,
    text: '      body: SessionListView(active: _active),',
  ),
  DiffLine(
    kind: DiffKind.del,
    oldLine: 116,
    text: '      bottomNavigationBar: const DshNavBar(),',
  ),
  DiffLine(kind: DiffKind.del, oldLine: 117, text: '    );'),
  DiffLine(
    kind: DiffKind.add,
    newLine: 114,
    text: '    return ModalNavigationDrawer(',
  ),
  DiffLine(
    kind: DiffKind.add,
    newLine: 115,
    text: '      drawer: const SessionDrawer(),',
  ),
  DiffLine(kind: DiffKind.add, newLine: 116, text: '      child: Scaffold('),
  DiffLine(
    kind: DiffKind.add,
    newLine: 117,
    text: '        appBar: DshAppBar(',
  ),
  DiffLine(
    kind: DiffKind.add,
    newLine: 118,
    text: '          leading: const DrawerButton(),',
  ),
  DiffLine(
    kind: DiffKind.add,
    newLine: 119,
    text: '          title: Text(_session.title),',
  ),
  DiffLine(kind: DiffKind.add, newLine: 120, text: '        ),'),
  DiffLine(
    kind: DiffKind.add,
    newLine: 121,
    text: '        body: ChatView(turns: _turns),',
  ),
  DiffLine(kind: DiffKind.add, newLine: 122, text: '      ),'),
  DiffLine(kind: DiffKind.add, newLine: 123, text: '    );'),
  DiffLine(kind: DiffKind.context, oldLine: 118, newLine: 124, text: '  }'),
];

/// **示例文件内容**（"文件"那个 tab）。
const List<String> sampleFileLines = [
  'class _ChatPageState extends State<ChatPage> {',
  '  final _input = TextEditingController();',
  '  int _tab = 0;',
  '',
  '  @override',
  '  Widget build(BuildContext context) {',
  '    return ModalNavigationDrawer(',
  '      drawer: const SessionDrawer(),',
  '      child: Scaffold(',
  '        appBar: DshAppBar(',
  '          leading: const DrawerButton(),',
  '          title: Text(_session.title),',
  '        ),',
  '        body: ChatView(turns: _turns),',
  '      ),',
  '    );',
  '  }',
  '}',
];

/// 轨迹页签 —— **占位**（照原型是甘特图 + 账本列表，那是独立一块）。
///
/// 如实做成占位而不是假装有：写"还没做"比画一张假图好 ——
/// 后者会被当成"已经能用了"。
class _TrajectoryTab extends StatelessWidget {
  const _TrajectoryTab();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            DshIcon('gauge', size: 40, color: DshColors.labelTertiary),
            SizedBox(height: 12),
            Text(
              '轨迹还没做',
              style: TextStyle(fontSize: 14, color: DshColors.labelSecondary),
            ),
            SizedBox(height: 6),
            Text(
              '原型里是甘特图 + 按时间排的账本列表（上下文/助手/工具/错误）。\n'
              '它依赖 `session.trajectory` 的数据，那是独立一块。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: DshColors.labelTertiary),
            ),
          ],
        ),
      ),
    );
  }
}
