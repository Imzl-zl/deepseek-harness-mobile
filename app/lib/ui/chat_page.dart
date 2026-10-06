/// 会话详情 · 对话页（`design-and-tech-plan.md` §7 的"对话"）。
///
/// ## 接线（`app-channel-client.md` §6 的接线表）
///
/// - 条目：`AppState.items`（本地条目表的只读快照）
/// - 流式：`AppState.liveText`（正在生成的这段）
/// - 输入栏：走 `outbox`（写操作先落盘再发，幂等键保证重发安全）
///
/// ## 两条渲染纪律
///
/// 1. **UI 永不闪空**：快照恢复期间保留旧 items（`stale → recovering` 时不清表）。
///    这一页的做法是**只读 store 的当前快照**，而 store 在快照分页收口前不替换内容
///    （`data/session_store.dart`）—— 所以"不闪空"是数据层的性质，不是这一页的特判。
/// 2. **不整页 setState**：列表用 `StreamBuilder` 绑 store 的变更流，
///    于是只有列表子树重建。整页 `setState` 会让输入栏也跟着重建 —— 而那正是
///    "打字打到一半被重建"这类毛病的来源。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/app_model.dart';
import '../../model/chat_item.dart';
import '../../theme/dsh_colors.dart';
import '../../theme/dsh_theme.dart';

/// 对话页。
class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.app, required this.sid});

  final AppModel app;

  /// 会话别名。
  final String sid;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    // 打开会话：订阅它（`since: 0` = 本地没有水位，电脑侧会给快照）。
    // `unawaited`：`initState` 不能是 async，而打开会话的失败由 `AppModel`
    // 记进 `lastError`（界面从那里显示），不需要在这里等。
    unawaited(widget.app.openSession(widget.sid));
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 发一句。
  ///
  /// **幂等键在入队时生成**（契约 §5.6）：重发复用同一个 —— 换键等于换了一次新消息。
  /// 这就是"点了发送但没反应，又点一次"不会变成两条的原因。
  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final requestId = 'p-${DateTime.now().microsecondsSinceEpoch}';
      await widget.app.client.call<void>('session.prompt', {
        'sid': widget.sid,
        'text': text,
      }, requestId: requestId);
      _input.clear();
    } catch (error) {
      if (!mounted) return;
      // **如实报错**：吞掉会让用户以为发出去了。
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('发送失败：$error')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DshColors.bgBase,
      appBar: AppBar(
        backgroundColor: DshColors.sidebar,
        foregroundColor: DshColors.labelPrimary,
        title: Text(
          widget.app.sessions
                  .where((s) => s.sid == widget.sid)
                  .firstOrNull
                  ?.title ??
              '会话',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Column(
        children: [
          Expanded(
            // 只绑 store 的变更流：列表重建不影响输入栏。
            child: StreamBuilder<List<ChatItem>>(
              stream: widget.app.changesOf(widget.sid),
              initialData: widget.app.items,
              builder: (context, snapshot) {
                final items = snapshot.data ?? const <ChatItem>[];
                if (items.isEmpty) {
                  return const _WaitingBody();
                }
                return ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  itemCount: items.length,
                  itemBuilder: (context, index) =>
                      _ItemView(item: items[index]),
                );
              },
            ),
          ),
          // 流式文本单独一行显示在输入栏上方（它没有稳定 itemId，不进列表）。
          if (widget.app.liveText != null && widget.app.liveText!.isNotEmpty)
            _LiveBar(text: widget.app.liveText!),
          _Composer(controller: _input, sending: _sending, onSend: _send),
        ],
      ),
    );
  }
}

/// 还没收到任何条目时的提示。
class _WaitingBody extends StatelessWidget {
  const _WaitingBody();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(height: 12),
          Text(
            '正在同步…',
            style: TextStyle(fontSize: 13, color: DshColors.labelTertiary),
          ),
        ],
      ),
    );
  }
}

/// 一条条目的渲染（**按类型分派**，这是 UI 层唯一需要识别类型的地方）。
class _ItemView extends StatelessWidget {
  const _ItemView({required this.item});

  final ChatItem item;

  @override
  Widget build(BuildContext context) {
    // sealed class ⇒ 这个 switch 是穷尽的，加一种条目时编译器会在这里报错
    //（而不是让新类型静默渲染成空白）。
    return switch (item) {
      MessageItem(:final role, :final text) => _MessageBubble(
        role: role,
        text: text,
      ),
      ToolCallItem(:final name, :final status, :final summary) => _ToolRow(
        name: name,
        status: status,
        summary: summary,
      ),
      ApprovalItem(:final title, :final decided) => _ApprovalRow(
        title: title,
        decided: decided,
      ),
      OtherItem() => const SizedBox.shrink(),
    };
  }
}

/// 消息气泡。
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.role, required this.text});

  final MessageRole role;
  final String text;

  @override
  Widget build(BuildContext context) {
    final isUser = role == MessageRole.user;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isUser ? DshColors.accentBlue : DshColors.layer1,
                borderRadius: BorderRadius.circular(DshRadius.md),
              ),
              child: SelectableText(
                text,
                style: TextStyle(
                  fontSize: 13,
                  height: 20 / 13,
                  color: isUser ? DshColors.onAccent : DshColors.labelPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 工具调用一行。
class _ToolRow extends StatelessWidget {
  const _ToolRow({
    required this.name,
    required this.status,
    required this.summary,
  });

  final String name;
  final ToolCallStatus status;
  final String summary;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (status) {
      ToolCallStatus.running => (Icons.autorenew, DshColors.roleTool),
      ToolCallStatus.completed => (
        Icons.check_circle_outline,
        DshColors.roleContext,
      ),
      ToolCallStatus.failed => (Icons.error_outline, DshColors.error),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            name,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (summary.isNotEmpty) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                summary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: DshColors.labelTertiary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 审批一行。
class _ApprovalRow extends StatelessWidget {
  const _ApprovalRow({required this.title, required this.decided});

  final String title;
  final bool decided;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: DshColors.layer2,
        borderRadius: BorderRadius.circular(DshRadius.sm),
        border: Border.all(
          color: decided ? DshColors.layer3 : DshColors.roleTool,
        ),
      ),
      child: Row(
        children: [
          Icon(
            decided ? Icons.check : Icons.shield_outlined,
            size: 14,
            color: decided ? DshColors.labelTertiary : DshColors.roleTool,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 13,
                color: DshColors.labelPrimary,
              ),
            ),
          ),
          Text(
            decided ? '已决定' : '待审批',
            style: TextStyle(
              fontSize: 11,
              color: decided ? DshColors.labelTertiary : DshColors.roleTool,
            ),
          ),
        ],
      ),
    );
  }
}

/// 流式文本条。
class _LiveBar extends StatelessWidget {
  const _LiveBar({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: DshColors.layer1,
      child: Text(
        text,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, color: DshColors.roleAssistant),
      ),
    );
  }
}

/// 输入栏。
///
/// **三条硬规则**（`AGENTS.md` §6 / 方案 §7.2）：文字独占一行；
/// 控制行左组（这里是发送）在右。附件与模型选择属于后续增量，这里先留结构。
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: DshColors.sidebar,
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        top: 8,
        bottom: 8 + MediaQuery.of(context).padding.bottom,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              minLines: 1,
              maxLines: 5,
              style: const TextStyle(
                fontSize: 13,
                color: DshColors.labelPrimary,
              ),
              decoration: InputDecoration(
                isDense: true,
                hintText: '发消息…',
                hintStyle: const TextStyle(
                  fontSize: 13,
                  color: DshColors.labelTertiary,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                filled: true,
                fillColor: DshColors.layer1,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(DshRadius.md),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => onSend(),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: sending ? null : onSend,
            style: IconButton.styleFrom(
              backgroundColor: DshColors.accentBlue,
              foregroundColor: DshColors.onAccent,
            ),
            icon: sending
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: DshColors.onAccent,
                    ),
                  )
                : const Icon(Icons.send, size: 18),
          ),
        ],
      ),
    );
  }
}
