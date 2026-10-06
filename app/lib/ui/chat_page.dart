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
import 'chat_turns.dart';
import 'dsh_app_bar.dart';
import 'dsh_composer.dart';

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

  @override
  void initState() {
    super.initState();
    // 输入框有内容才亮发送键 —— `TextField` 的 `onChanged` 不触发本层重建，
    // 所以手动挂一个监听（否则发送键永远灰着）。
    _input.addListener(_onInputChanged);
  }

  void _onInputChanged() => setState(() {});

  @override
  void dispose() {
    _input.removeListener(_onInputChanged);
    _input.dispose();
    super.dispose();
  }

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
            statusText: widget.paired ? null : '未连接',
            statusIcon: widget.paired ? 'loading' : 'warningTriangle',
            statusIsWarn: !widget.paired,
            onStatusTap: widget.onConnect,
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
              // ---- 底部：dock + 输入栏 + 统计条 ----
              Container(
                color: DshColors.sidebar,
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).padding.bottom + 6,
                ),
                child: Column(
                  children: [
                    DshComposer(
                      controller: _input,
                      attachments: _attachments,
                      // 模型名与推理等级：接上 `repo.info` 之后从真数据来，
                      // 现在给占位（界面上看得出是占位：写的是"未连接"）。
                      modelName: widget.paired ? 'claude-opus' : '未连接',
                      reasoningLabel: '高',
                      accessMode: AccessMode.workspaceWrite,
                      sending: _sending,
                      enabled: widget.paired && sid != null,
                      onSend: _send,
                      onAttach: () => setState(
                        () => _attachments.add(
                          const PendingAttachment(name: '新增文件.txt'),
                        ),
                      ),
                      onPickModel: () {},
                      onPickAccess: () {},
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
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
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
