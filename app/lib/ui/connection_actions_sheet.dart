/// 连接操作 sheet —— 议题 3「重新配对」与电脑直切的落点。
///
/// ## 两个形态，同一份内容
///
/// [anchor] 为 `null` ⇒ 底部 sheet（空态出路、抽屉连接行 —— 触发点就在下半屏）；
/// 给了锚点 ⇒ 锚定浮层（顶栏状态点）。
library;

import 'package:flutter/material.dart';

import '../model/chat_item.dart';
import '../platform/pairing_store.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import 'connection_summary_block.dart';
import 'dsh_popover.dart';
import 'dsh_toast.dart';
import 'host_picker_sheet.dart' show lastConnectedLabelOf;

/// 连接 sheet 里"换电脑"那几行需要的缝（装配层注入，页面只转发）。
typedef HostSwitchSeam = ({
  /// 除了当前这台还有几台（0 = 不给「切换电脑」这一行）。
  int otherHostCount,
  VoidCallback? onSwitch,
  VoidCallback? onSwitchBack,
  String? switchBackLabel,
  List<PairedHost>? hosts,
  String? currentHostId,
  void Function(String hostId)? onSelectHost,
  Future<void> Function(String hostId, String name)? onRenameHost,
  Future<void> Function(String hostId)? onClearHostCache,
});

/// 弹出连接操作面板。取消（点遮罩 / 「取消」行）不触发任何动作。
Future<void> showConnectionActionsSheet(
  BuildContext context, {
  required ConnectionSummary connection,
  required VoidCallback onRePair,
  VoidCallback? onOpenSide,
  VoidCallback? onDisconnect,
  VoidCallback? onRetry,

  /// 重新拨一次（不改偏好）。
  VoidCallback? onReconnect,

  /// 换一条并直接连（弹选择框的动作由调用方实现 —— 它持有 `AppModel`）。
  VoidCallback? onPickEndpoint,

  /// 填一个新地址**只加进表**（换了网络、旧地址全拨不通时的那条出路）。
  VoidCallback? onManualEndpoint,

  /// **切换电脑**的入口与"切回上一台"（`HostSwitchSeam`）。
  HostSwitchSeam? hostSwitch,

  /// **添加一台电脑**（一台手机配多台电脑的入口）。
  VoidCallback? onAddHost,

  /// 触发点矩形。`null` = 底部 sheet。
  Rect? anchor,
}) {
  final c = context.dshColors;
  final switchBackLabel = hostSwitch?.switchBackLabel;

  Widget content(BuildContext inner) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ConnectionSummaryBlock(
        connection: connection,
      ),

      // **直切已配对电脑列表（1步直达，消灭多级嵌套弹窗）**
      if (hostSwitch?.hosts != null && hostSwitch!.hosts!.isNotEmpty) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '已配对电脑',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: c.labelSecondary,
                ),
              ),
              if (onAddHost != null)
                GestureDetector(
                  onTap: () {
                    Navigator.of(inner).pop();
                    onAddHost();
                  },
                  child: Row(
                    children: [
                      DshIcon('plus', size: 14, color: c.roleContext),
                      const SizedBox(width: 2),
                      Text(
                        '添加新电脑',
                        style: TextStyle(fontSize: 12, color: c.roleContext),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        for (final host in hostSwitch!.hosts!)
          _HostInlineTile(
            host: host,
            isCurrent: host.hostId == hostSwitch.currentHostId,
            onTap: () {
              Navigator.of(inner).pop();
              hostSwitch.onSelectHost?.call(host.hostId);
            },
            onRename: hostSwitch.onRenameHost == null
                ? null
                : () => _askRename(inner, host, hostSwitch.onRenameHost!),
            onClearCache: hostSwitch.onClearHostCache == null
                ? null
                : () => _confirmClearCache(inner, host, hostSwitch.onClearHostCache!),
          ),
      ] else if (hostSwitch != null &&
          hostSwitch.otherHostCount > 0 &&
          hostSwitch.onSwitch != null)
        ListTile(
          leading: const DshIcon(
            'workspaceTree',
            size: 18,
            color: DshColors.labelSecondary,
          ),
          title: const Text('切换电脑'),
          subtitle: Text(
            hostSwitch.otherHostCount == 1
                ? '还有 1 台已配对的电脑'
                : '还有 ${hostSwitch.otherHostCount} 台已配对的电脑',
          ),
          onTap: () {
            Navigator.of(inner).pop();
            hostSwitch.onSwitch?.call();
          },
        ),

      if (hostSwitch?.onSwitchBack != null)
        ListTile(
          leading: const DshIcon(
            'chevronLeft',
            size: 18,
            color: DshColors.labelSecondary,
          ),
          title: const Text('切回上一台'),
          subtitle: Text(
            switchBackLabel == null || switchBackLabel.isEmpty
                ? '回到刚才那台电脑'
                : '回到「$switchBackLabel」',
          ),
          onTap: () {
            Navigator.of(inner).pop();
            hostSwitch?.onSwitchBack?.call();
          },
        ),

      // 仅在未内联展示电脑列表时显示独立的「添加电脑」行
      if (onAddHost != null && (hostSwitch?.hosts == null || hostSwitch!.hosts!.isEmpty))
        ListTile(
          leading: const DshIcon(
            'plus',
            size: 18,
            color: DshColors.labelSecondary,
          ),
          title: const Text('添加电脑'),
          subtitle: const Text('扫另一台的配对码；当前这台不会被清掉'),
          onTap: () {
            Navigator.of(inner).pop();
            onAddHost();
          },
        ),

      // **手动填写电脑地址（换网或自建中转直接配 IP 出路）**
      if (onManualEndpoint != null)
        ListTile(
          leading: const DshIcon(
            'link',
            size: 18,
            color: DshColors.labelSecondary,
          ),
          title: const Text('手动填写电脑地址'),
          subtitle: const Text('填完只加进表，不会自动连'),
          onTap: () {
            Navigator.of(inner).pop();
            onManualEndpoint();
          },
        ),

      if (onReconnect != null)
        ListTile(
          leading: const DshIcon(
            'refresh',
            size: 18,
            color: DshColors.labelSecondary,
          ),
          title: const Text('重新连接'),
          onTap: () {
            Navigator.of(inner).pop();
            onReconnect();
          },
        ),

      if (onRetry != null)
        ListTile(
          leading: const DshIcon(
            'refresh',
            size: 18,
            color: DshColors.labelSecondary,
          ),
          title: const Text('重试连接'),
          onTap: () {
            Navigator.of(inner).pop();
            onRetry();
          },
        ),

      ListTile(
        title: const Center(child: Text('取消')),
        onTap: () => Navigator.of(inner).pop(),
      ),
    ],
  );

  if (anchor != null) {
    return showDshPopover<void>(
      context: context,
      anchor: anchor,
      maxHeightFactor: 0.8,
      body: Builder(builder: content),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: c.layer1,
    builder: (inner) => SafeArea(
      child: SingleChildScrollView(child: content(inner)),
    ),
  );
}

class _HostInlineTile extends StatelessWidget {
  const _HostInlineTile({
    required this.host,
    required this.isCurrent,
    required this.onTap,
    this.onRename,
    this.onClearCache,
  });

  final PairedHost host;
  final bool isCurrent;
  final VoidCallback onTap;
  final VoidCallback? onRename;
  final VoidCallback? onClearCache;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: isCurrent ? c.roleContext : c.labelTertiary,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          host.label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal,
                            color: isCurrent ? c.labelPrimary : c.labelSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (isCurrent) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: c.layer2,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '当前',
                            style: TextStyle(fontSize: 10, color: c.roleContext),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${host.shortCode} · ${lastConnectedLabelOf(host.lastConnectedAt)}',
                    style: TextStyle(fontSize: 11, color: c.labelCaption),
                  ),
                ],
              ),
            ),
            if (onRename != null)
              IconButton(
                icon: DshIcon('edit', size: 15, color: c.labelTertiary),
                tooltip: '改名',
                onPressed: onRename,
              ),
            if (onClearCache != null)
              IconButton(
                icon: DshIcon('trash', size: 15, color: c.labelTertiary),
                tooltip: '清空此电脑缓存',
                onPressed: onClearCache,
              ),
          ],
        ),
      ),
    );
  }
}

Future<void> _askRename(
  BuildContext context,
  PairedHost host,
  Future<void> Function(String hostId, String name) onRename,
) async {
  final controller = TextEditingController(text: host.renameInitial);
  final name = await showDialog<String>(
    context: context,
    builder: (inner) => AlertDialog(
      title: const Text('给这台电脑改名'),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 24,
        decoration: const InputDecoration(
          hintText: '比如：办公室那台、家里台式',
          helperText: '只存在这台手机上；清空则改回电脑自报的名字',
        ),
        onSubmitted: (v) => Navigator.of(inner).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(inner).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(inner).pop(controller.text.trim()),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  if (name == null) return;
  await onRename(host.hostId, name);
}

Future<void> _confirmClearCache(
  BuildContext context,
  PairedHost host,
  Future<void> Function(String hostId) onClearCache,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (inner) => AlertDialog(
      title: const Text('清空本地缓存'),
      content: Text(
        '确定清空「${host.label}」的本地缓存吗？\n\n'
        '这会清除该电脑在此手机上的会话消息历史与游标，下次连接重新同步。手机全局设置不受影响。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(inner).pop(false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(inner).pop(true),
          style: TextButton.styleFrom(
            foregroundColor: context.dshColors.stateError,
          ),
          child: const Text('清空'),
        ),
      ],
    ),
  );
  if (confirmed == true && context.mounted) {
    await onClearCache(host.hostId);
    if (context.mounted) {
      DshToast.show(context, '已清空「${host.label}」的本地缓存');
    }
  }
}
