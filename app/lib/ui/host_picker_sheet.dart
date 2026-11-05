/// 切换电脑（一台手机配多台电脑）的唯一入口形状。
///
/// ## 它回答什么
///
/// "我还能连哪几台、现在连的是哪台、该切哪台"。列表来自凭据层按 `hostId` 分槽的
/// **派生读**（`PairingStore.hosts()`）—— 不另存一份"已配对电脑清单"，那是同一个
/// 事实的第二处表达。
///
/// ## 四条约束
///
/// 1. **行 = `[名称 / 其下标签组] [勾位(恒占位)]`**（根 `AGENTS.md` 的选择类列表规则）：
///    名称是**用户改的名 > 电脑自报的名 > `hostId` 短码**，短码与"上次连接"放第二行
///    标签组，**不做与名称同行的第三列**。
/// 2. **点一行 = 切过去**：切换是用户动作（方案决策 6 / 9），这里不自动挑、不预选。
/// 3. **"当前"那一行照常可点**（点了等于重连一次），不做"点了没反应"的假交互 ——
///    用户想重连时最自然的动作就是点自己那台。
/// 4. **每行可改名**（尾部铅笔）：多机之后"这台是谁"只能由用户回答 ——
///    电脑自报的名字常常是同款机器的默认名（"我的笔记本" ×3），靠它分不出人。
///    改名**立刻落盘**（`PairingStore.saveCustomName`），不等下次连接。
library;

import 'package:flutter/material.dart';

import '../platform/pairing_store.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import 'dsh_sheet.dart';
import 'dsh_toast.dart';

/// 弹出电脑列表；返回被选中的 `hostId`（取消返回 `null`）。
///
/// [currentHostId] 只用于标出"当前"那一行（`null` = 还没配对）。
/// [onRename] 非空时每行多一枚铅笔：改名落盘由装配层做（它持有 `PairingStore`），
/// 这里只负责问名字并把结果交出去。
Future<String?> pickPairedHost(
  BuildContext context, {
  required List<PairedHost> hosts,
  required String? currentHostId,
  Future<void> Function(String hostId, String name)? onRename,
  Future<void> Function(String hostId)? onClearCache,
}) {
  return showDshSheet<String>(
    context: context,
    title: '切换电脑',
    body: _HostList(
      hosts: hosts,
      currentHostId: currentHostId,
      onRename: onRename,
      onClearCache: onClearCache,
    ),
  );
}

/// 列表本体（有状态那一层）：改名之后要**当场**看见新名字，所以自己持一份列表，
/// 不去等下一次 `hosts()` 重读 —— 那要等用户关掉再打开面板。
class _HostList extends StatefulWidget {
  const _HostList({
    required this.hosts,
    required this.currentHostId,
    required this.onRename,
    this.onClearCache,
  });

  final List<PairedHost> hosts;
  final String? currentHostId;
  final Future<void> Function(String hostId, String name)? onRename;
  final Future<void> Function(String hostId)? onClearCache;

  @override
  State<_HostList> createState() => _HostListState();
}

class _HostListState extends State<_HostList> {
  late List<PairedHost> _hosts = List<PairedHost>.of(widget.hosts);

  Future<void> _rename(PairedHost host) async {
    final onRename = widget.onRename;
    if (onRename == null) return;
    final name = await _askHostName(context, host.renameInitial);
    if (name == null) return; // 取消
    await onRename(host.hostId, name);
    if (!mounted) return;
    setState(() {
      _hosts = [
        for (final h in _hosts)
          // 空串 = 改回电脑自报的名字（`label` 会依次回退）。
          h.hostId == host.hostId ? h.copyWith(customName: name) : h,
      ];
    });
  }

  Future<void> _confirmClearCache(PairedHost host) async {
    final onClearCache = widget.onClearCache;
    if (onClearCache == null) return;
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
    if (confirmed == true && mounted) {
      await onClearCache(host.hostId);
      if (mounted) {
        DshToast.show(context, '已清空「${host.label}」的本地缓存');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final host in _hosts)
          DshPickerRow(
            name: host.label,
            // 第二行：短码（同名靠它分）+ 状态。名字可改可重名，短码不会。
            tags: [
              host.shortCode,
              host.hostId == widget.currentHostId
                  ? '当前'
                  : lastConnectedLabelOf(host.lastConnectedAt),
            ],
            selected: host.hostId == widget.currentHostId,
            onTap: () => Navigator.of(context).pop(host.hostId),
            trailing: (widget.onRename == null && widget.onClearCache == null)
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.onRename != null)
                        IconButton(
                          icon: DshIcon('edit', size: 16, color: context.dshColors.labelSecondary),
                          tooltip: '给这台电脑改名',
                          onPressed: () => _rename(host),
                        ),
                      if (widget.onClearCache != null)
                        IconButton(
                          icon: DshIcon('trash', size: 16, color: context.dshColors.labelSecondary),
                          tooltip: '清空此电脑缓存',
                          onPressed: () => _confirmClearCache(host),
                        ),
                    ],
                  ),
          ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            // 只留**后果**（会断开当前那台）；"界面只显示新的那台"是它能自己看见的。
            '切换会立刻断开当前那台。点右侧铅笔可以给电脑改名，名字只存在这台手机上。',
            style: TextStyle(
              fontSize: 12,
              height: 1.45,
              color: context.dshColors.labelSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

/// 问一个名字。返回 `null` = 取消；返回空串 = **清掉自定义名**（改回电脑自报的名字）。
Future<String?> _askHostName(BuildContext context, String initial) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
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
}

/// "上次连接"那一格的说法。[at] 为空 = 配过但一次都没连上。
///
/// 分档的粒度按"人怎么判断该切哪台"来定：一天之内说相对时间（"3 小时前"有直觉），
/// 超过一天说日期 —— "37 天前"人算不出是哪天，给了也没用。
String lastConnectedLabelOf(DateTime? at) {
  if (at == null) return '从未连接';
  final diff = DateTime.now().difference(at);
  if (diff.isNegative || diff.inMinutes < 1) return '刚刚连过';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${at.year}-${two(at.month)}-${two(at.day)}';
}
