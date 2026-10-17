/// 排队条（DSH Web 的 `conversation.input.dock` 槽里的 `QueueDock`）。
///
/// ## 它是什么
///
/// 会话正在跑时发出去的消息会**排进下一个轮次**（选"排队发送"时）。
/// 这条 dock 把这些排队中的消息列出来，并给每项三个动作：
/// **编辑 / 删除 / 插话**（插话 = 立刻插进当前轮次）。
///
/// 与 DSH Web 逐字对应的部分：
/// - 数据是 `inbox` 投影的 `next-turn` 段（`QueueDock.tsx:113`）；
/// - 计数文案 `{n} 条排队消息`（`locales.ts:355` 的 `queue.count`）；
/// - 一条时直接展示、多条时折叠成计数头（`listVisible` 判据，`:144`）；
/// - 插话只在**运行中**可点（`:300-306`，禁用态带"仅运行中可插话发送"）；
/// - 编辑只对**纯文本**项可点（`textOf`，`:29-32`）—— DSH 的
///   `updateQueue` 编辑只收纯文本（`commands.ts:433-441`）；
/// - 三个动作都走 `session.updateQueue`（`:404`）。
///
/// ## 与 Web 的形态差异（有意偏离）
///
/// Web 的行内编辑器（`InlineEditor`）在手机上换成底部 sheet：
/// 触屏上没有"行内展开一个输入框"的可靠高度。语义不变 ——
/// 保存发的还是 `{kind:'edit', content:[{type:'text',text}]}`。
library;

import 'package:flutter/material.dart';

import '../data/app_model.dart';
import '../model/queue_item.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';

/// 排队条。**空队列时整条不占位**（返回 `SizedBox.shrink()`）——
/// 没有排队消息时摆一条空dock 是把"没有"说成"有一个空的"。
class QueueDock extends StatefulWidget {
  const QueueDock({
    super.key,
    required this.app,
    required this.sid,
    required this.running,
  });

  final AppModel app;

  /// 当前会话（队列按它取）。
  final String sid;

  /// 会话是否正在跑（插话动作的门）。
  final bool running;

  @override
  State<QueueDock> createState() => _QueueDockState();
}

class _QueueDockState extends State<QueueDock> {
  /// 折叠态。**默认折叠**（Web 同）：排队消息多是"发了就等着"，
  /// 不需要每条都占着输入栏上方。
  bool _collapsed = true;

  /// 正在操作的那一项（进行中时禁用其它按钮，照 Web 的 `busy`）。
  String? _busyItemId;

  @override
  Widget build(BuildContext context) {
    final items = widget.app.queueOf(widget.sid);
    if (items.isEmpty) return const SizedBox.shrink();
    // 只有一条时**永远展开**（Web 的 `listVisible = rowCount === 1 || expanded`）——
    // 一条还折叠，用户要多点一下才能看见自己发了什么。
    final single = items.length == 1;
    final expanded = single || !_collapsed;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Container(
        decoration: BoxDecoration(
          color: DshColors.layer1,
          borderRadius: BorderRadius.circular(DshRadius.md),
          border: Border.all(color: DshColors.layer2),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!single)
              InkWell(
                onTap: () => setState(() => _collapsed = !_collapsed),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    children: [
                      const DshIcon(
                        'queue',
                        size: 14,
                        color: DshColors.labelSecondary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${items.length} 条排队消息',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: DshColors.labelSecondary,
                        ),
                      ),
                      const Spacer(),
                      DshIcon(
                        expanded ? 'chevronDown' : 'chevronRight',
                        size: 14,
                        color: DshColors.labelTertiary,
                      ),
                    ],
                  ),
                ),
              ),
            if (expanded)
              for (final item in items)
                _QueueRow(
                  item: item,
                  single: single,
                  running: widget.running,
                  busy: _busyItemId == item.itemId,
                  onEdit: () => _edit(item),
                  onRemove: () => _remove(item),
                  onSteer: () => _steer(item),
                ),
          ],
        ),
      ),
    );
  }

  /// 编辑：底部 sheet 里改文本（纯文本项才可点，见 [QueueItem] 与 DSH 约束）。
  Future<void> _edit(QueueItem item) async {
    final edited = await showDialog<String>(
      context: context,
      builder: (context) => _EditQueueDialog(initial: item.previewText),
    );
    if (edited == null || edited.trim().isEmpty) return;
    await _apply(
      item,
      () => widget.app.updateQueue(
        widget.sid,
        item.itemId,
        QueueActionKind.edit,
        text: edited.trim(),
      ),
      what: '编辑',
    );
  }

  Future<void> _remove(QueueItem item) => _apply(
    item,
    () =>
        widget.app.updateQueue(widget.sid, item.itemId, QueueActionKind.remove),
    what: '删除',
  );

  Future<void> _steer(QueueItem item) => _apply(
    item,
    () =>
        widget.app.updateQueue(widget.sid, item.itemId, QueueActionKind.steer),
    what: '插话',
  );

  /// 共性：置忙 → 调 → 报告。**失败必须说出来** ——
  /// 静默失败会让用户以为"点了没反应"，而那正是这个 dock 最容易犯的错。
  Future<void> _apply(
    QueueItem item,
    Future<bool> Function() call, {
    required String what,
  }) async {
    setState(() => _busyItemId = item.itemId);
    final ok = await call();
    if (!mounted) return;
    setState(() => _busyItemId = null);
    final error = widget.app.lastError;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? '$what成功' : '$what失败：${error?.message ?? '电脑侧没有给结论'}',
        ),
      ),
    );
  }
}

/// 一行排队消息：预览 + 三个动作。
class _QueueRow extends StatelessWidget {
  const _QueueRow({
    required this.item,
    required this.single,
    required this.running,
    required this.busy,
    required this.onEdit,
    required this.onRemove,
    required this.onSteer,
  });

  final QueueItem item;

  /// 是否"只有一条"（决定前导图标要不要——多条时计数头已经有图标了）。
  final bool single;

  final bool running;
  final bool busy;
  final VoidCallback onEdit;
  final VoidCallback onRemove;
  final VoidCallback onSteer;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: DshColors.layer2)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      child: Row(
        children: [
          if (single) ...[
            const DshIcon('queue', size: 14, color: DshColors.labelSecondary),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.previewText.isEmpty ? '（空消息）' : item.previewText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 20 / 13,
                    color: DshColors.labelPrimary,
                  ),
                ),
                if (item.attachmentCount > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '${item.attachmentCount} 个附件（不随编辑发送）',
                      style: const TextStyle(
                        fontSize: 11,
                        color: DshColors.labelTertiary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 三个动作。**编辑只对纯文本项可点**：DSH 的编辑只收纯文本，
          // 摆一个能点但必然失败的按钮是骗人（Web 同：`disabled={text === null}`）。
          _RowAction(
            icon: 'listPen',
            tooltip: '编辑排队消息',
            enabled: !busy && item.editable,
            onTap: onEdit,
          ),
          _RowAction(
            icon: 'closeFill',
            tooltip: '删除排队消息',
            enabled: !busy,
            onTap: onRemove,
          ),
          _RowAction(
            icon: 'paperPlane',
            // 插话的门：**仅运行中可插话发送**（DSH 文案原话，
            // `ui-conversation/src/client/locales.ts:365`）。
            tooltip: running ? '插话发送' : '仅运行中可插话发送',
            enabled: !busy && running,
            onTap: onSteer,
          ),
        ],
      ),
    );
  }
}

/// 行内动作钮（28×28，与工具卡同一量级）。
class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });

  final String icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 28,
        height: 28,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled ? onTap : null,
            child: Center(
              child: DshIcon(
                icon,
                size: 14,
                color: enabled
                    ? DshColors.labelSecondary
                    : DshColors.labelTertiary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 编辑排队消息的对话框（触屏上代替 Web 的行内编辑器）。
class _EditQueueDialog extends StatefulWidget {
  const _EditQueueDialog({required this.initial});

  final String initial;

  @override
  State<_EditQueueDialog> createState() => _EditQueueDialogState();
}

class _EditQueueDialogState extends State<_EditQueueDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: DshColors.layer1,
      title: const Text(
        '编辑排队消息',
        style: TextStyle(fontSize: 16, color: DshColors.labelPrimary),
      ),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: 6,
        minLines: 3,
        style: const TextStyle(fontSize: 14, color: DshColors.labelPrimary),
        decoration: const InputDecoration(
          hintText: '新的内容（只发文本）',
          hintStyle: TextStyle(fontSize: 13, color: DshColors.labelTertiary),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(
            '取消',
            style: TextStyle(color: DshColors.labelSecondary),
          ),
        ),
        TextButton(
          // 空文本不给保存：DSH 会拒（`commands.ts:442-448`），
          // 而在本地就拦掉是省一次必然失败的往返。
          onPressed: _controller.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop(_controller.text),
          child: const Text(
            '保存',
            style: TextStyle(color: DshColors.accentBlue),
          ),
        ),
      ],
    );
  }
}
