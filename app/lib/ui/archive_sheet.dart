/// 归档列表（抽屉底栏「归档」的落点）。
///
/// ## 为什么是「自己的一个列表」，而不是照 Web 做成筛选项
///
/// DSH Web 把归档做成**列表的过滤档**（隐藏 / 混显 / 只看归档 —— `ArchivedFilter`，
/// `packages/client/ui-workspace/src/client/tree.ts:225-230`），因为桌面侧栏宽、
/// 行上有悬浮按钮。手机抽屉是 390px 的一列、**没有悬浮态**：三态过滤会占掉一整行，
/// 而且看不出"里面到底有没有东西"。所以手机给它一个**自己的落点**（抽屉底栏「归档」，
/// 原型基线里这一项本来就有），语义照 DSH 一字不改：
///
/// - **已归档的不能直接打开**（`toast.archivedNotOpenable` 那句原话就写在列表顶部）；
/// - 取消归档即**回原位**（Web 的原注释：归档只是不显示，记账槽位还在，
///   `tree.ts:234-236`）；
/// - 文案逐字照 DSH 的 zh 词典（`ui-workspace/src/client/locales.ts:37,63,68`）。
library;

import 'package:flutter/material.dart';

import '../data/app_model.dart';
import '../model/chat_item.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import 'dsh_sheet.dart';
import 'dsh_toast.dart';

/// 「取消归档」的动作（失败原因在 `app.lastError`）。
typedef UnarchiveAction = Future<bool> Function(String sid);

/// 打开归档列表。列表内容跟着 [app] 变 —— 取消归档之后那一行当场消失
/// （不自己维护一份副本：副本与真相册就是两份真值）。
Future<void> showArchiveSheet(
  BuildContext context, {
  required AppModel app,
  required UnarchiveAction onUnarchive,
}) {
  return showDshSheet<void>(
    context: context,
    title: '归档',
    body: ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        final c = context.dshColors;
        final rows = app.archivedSessions;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '已归档对话暂时无法查看，请取消归档后查看',
              style: TextStyle(fontSize: 12, color: c.labelCaption),
            ),
            const SizedBox(height: 10),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Text(
                  '暂无已归档会话',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: c.labelTertiary),
                ),
              ),
            for (final row in rows)
              _ArchiveRow(
                key: ValueKey(row.sid),
                session: row,
                onUnarchive: () => onUnarchive(row.sid),
              ),
          ],
        );
      },
    ),
  );
}

/// 一行：`[图标] 标题 / 已归档 … [取消归档]`。
///
/// **行本身不可点**：已归档的会话打不开（DSH 的同一条规则），
/// 所以"点行"这件事在这里不存在 —— 只有右边那一个动作。
class _ArchiveRow extends StatelessWidget {
  const _ArchiveRow({
    super.key,
    required this.session,
    required this.onUnarchive,
  });

  final SessionSummary session;
  final Future<bool> Function() onUnarchive;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          DshIcon('archiveOff', size: 18, color: c.labelTertiary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session.displayTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: c.labelPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  '已归档',
                  style: TextStyle(fontSize: 11, color: c.labelCaption),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _UnarchiveButton(onPressed: onUnarchive),
        ],
      ),
    );
  }
}

/// 「取消归档」按钮。请求在飞时按不动（避免双击发两次）。
class _UnarchiveButton extends StatefulWidget {
  const _UnarchiveButton({required this.onPressed});

  final Future<bool> Function() onPressed;

  @override
  State<_UnarchiveButton> createState() => _UnarchiveButtonState();
}

class _UnarchiveButtonState extends State<_UnarchiveButton> {
  bool _busy = false;

  Future<void> _run() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await widget.onPressed();
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      // 失败要留声：这一行还在原地，用户得知道"刚才那一下没生效"。
      DshToast.show(context, '取消归档失败，稍后再试', kind: DshToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return TextButton(
      onPressed: _busy ? null : () => _run(),
      style: TextButton.styleFrom(
        foregroundColor: c.accentBlue,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(0, 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: const Text('取消归档'),
    );
  }
}

/// 归档一个**还在跑**的会话前的确认（DSH 的 `archive.confirm.*` 那一组文案）。
///
/// 触发条件是宿主回 `workspace/session-active` —— 那是**信息**不是故障：
/// 会话的轮次 / 子智能体 / 后台任务还在跑，归档会先把它们停掉。
/// Web 的同一道门见 `ui-workspace/src/client/index.ts:190-208`。
/// @returns 用户是否选择了「停止并归档」。
Future<bool> confirmStopAndArchive(
  BuildContext context, {
  required String title,
}) async {
  final c = context.dshColors;
  final result = await showDshSheet<bool>(
    context: context,
    title: '停止并归档此会话？',
    body: Text(
      '“$title”仍有正在进行的工作。归档会先停止这些工作；'
      '之后可在「归档」列表里取消归档恢复会话，被停止的工作不会自动继续。',
      style: TextStyle(fontSize: 13, height: 1.6, color: c.labelSecondary),
    ),
    actions: [
      DshSheetAction(
        label: '取消',
        onPressed: () => Navigator.of(context).pop(false),
      ),
      DshSheetAction(
        label: '停止并归档',
        filled: true,
        onPressed: () => Navigator.of(context).pop(true),
      ),
    ],
  );
  return result ?? false;
}
