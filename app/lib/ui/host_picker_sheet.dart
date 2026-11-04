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
import 'dsh_sheet.dart';

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
}) {
  return showDshSheet<String>(
    context: context,
    title: '切换电脑',
    body: _HostList(
      hosts: hosts,
      currentHostId: currentHostId,
      onRename: onRename,
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
  });

  final List<PairedHost> hosts;
  final String? currentHostId;
  final Future<void> Function(String hostId, String name)? onRename;

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

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final host in _hosts)
          DshPickerRow(
            name: host.label,
            // 第二行：短码（同名靠它分）+ 状态。名字可改可重名，短码不会。
            //
            // **非当前那台显示"上次连接多久之前"**：这一屏唯一的用途是挑一台切过去，
            // 而"配过但从没连上"与"十分钟前还在用"是两种完全不同的预期 ——
            // 只写"已配对"时两者长得一模一样。
            tags: [
              host.shortCode,
              host.hostId == widget.currentHostId
                  ? '当前'
                  : lastConnectedLabelOf(host.lastConnectedAt),
            ],
            selected: host.hostId == widget.currentHostId,
            onTap: () => Navigator.of(context).pop(host.hostId),
            trailing: widget.onRename == null
                ? null
                : IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    color: context.dshColors.labelSecondary,
                    tooltip: '给这台电脑改名',
                    onPressed: () => _rename(host),
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
