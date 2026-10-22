/// 三个高频工具的**专用正文**：命令行、读文件、改文件。
///
/// 数据来自 `model/tool_view.dart`（`tool/result` 的 `data.meta` 与收口文本里的
/// 状态标记）；这里只管画。其余工具继续走 `ToolCard` 的通用 IN/OUT 文本
/// （有意偏离，见 `docs/subsystems/tool-views.md` §3）。
library;

import 'package:flutter/material.dart';

import '../model/diff.dart';
import '../model/tool_view.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';
import '../theme/dsh_type.dart';
import 'dsh_diff.dart';

/// 按视图类型分派；不认识就返回空（调用方本来会退回通用文本）。
class ToolResultBody extends StatelessWidget {
  const ToolResultBody({super.key, required this.view});

  final ToolResultView view;

  @override
  Widget build(BuildContext context) => switch (view) {
    final BashResultView v => _TerminalBlock(view: v),
    final ReadResultView v => _ReadBlock(view: v),
    final DiffResultView v => _DiffBlock(view: v),
  };
}

/// 命令行结果 —— 照 DSH 的 `TerminalBlock`
/// （`ui-tool/src/client/tool/toolviews/TerminalBlock.tsx:151,213` 的 `runState` +
/// exit code pill；文本标记的解析同 `terminal-card-model.ts:293-299`）。
///
/// 手机上的一段命令 = 「输出正文 + `[stderr]` 段 + 底部状态行」：
/// 状态行给 `exit N` / `signal X` / `[timed out …]`，**没有就写 `exit 0`**
/// （DSH 的 `parseExitStatus` 也把"没有标记"当 0）。
class _TerminalBlock extends StatelessWidget {
  const _TerminalBlock({required this.view});

  final BashResultView view;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final mono = DshTheme.mono.copyWith(
      fontSize: 11,
      height: 16 / 11,
      color: c.labelPrimary,
    );
    final status = view.signal != null
        ? 'signal ${view.signal}'
        : view.marker ?? 'exit ${view.exitCode ?? 0}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (view.output.isNotEmpty) SelectableText(view.output, style: mono),
        if (view.stderr != null && view.stderr!.isNotEmpty) ...[
          if (view.output.isNotEmpty) const SizedBox(height: 6),
          SelectableText(view.stderr!, style: mono.copyWith(color: c.error)),
        ],
        if (view.output.isEmpty &&
            (view.stderr == null || view.stderr!.isEmpty))
          Text('（没有输出）', style: mono.copyWith(color: c.labelTertiary)),
        const SizedBox(height: 6),
        _ExitPill(ok: view.ok, label: status),
      ],
    );
  }
}

/// `exit 0` / `exit 1` / `signal …` 的小胶囊。
class _ExitPill extends StatelessWidget {
  const _ExitPill({required this.ok, required this.label});

  final bool ok;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final tone = ok ? c.stateSuccess : c.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(DshRadius.xs),
      ),
      child: Text(
        label,
        style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: tone),
      ),
    );
  }
}

/// 读文件结果 —— 照 DSH 的 `ReadBlock`（`toolviews/read-row.tsx:14-20` 的行号列）。
///
/// 行内容与行号都来自 `meta.lines`（已经是 1 基编号）；这里**只画前 [maxLines] 行**，
/// 余下的说"还有 N 行"——一份 1500 行的文件全画进一张卡片只是把页面撑长。
class _ReadBlock extends StatelessWidget {
  const _ReadBlock({required this.view});

  final ReadResultView view;

  /// 一屏够看的行数；再多就在块里滚（外层已有 150 的高度上限）。
  static const int maxLines = 200;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final type = context.dshType;
    final lines = view.lines.take(maxLines).toList();
    final hidden = view.lines.length - lines.length;
    final total = view.totalLines;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PathLine(path: view.path, tail: total == null ? '' : '共 $total 行'),
        const SizedBox(height: 6),
        for (final line in lines)
          _NumberedLine(number: line.number, text: line.text),
        if (hidden > 0)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '还有 $hidden 行未显示',
              style: TextStyle(fontSize: type.caption, color: c.labelTertiary),
            ),
          ),
      ],
    );
  }
}

/// 文件路径行（等宽、弱化），右端可带一句尾巴（`共 N 行`）。
class _PathLine extends StatelessWidget {
  const _PathLine({required this.path, this.tail = ''});

  final String path;
  final String tail;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    // 路径太长时**从中间截**：末尾的文件名比开头的盘符有用。
    return Row(
      children: [
        DshIcon('deliverDoc', size: 12, color: c.labelTertiary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: c.labelSecondary,
            ),
          ),
        ),
        if (tail.isNotEmpty) ...[
          const SizedBox(width: 8),
          Text(tail, style: TextStyle(fontSize: 11, color: c.labelTertiary)),
        ],
      ],
    );
  }
}

/// 一行 `行号 + 文本`（行号右对齐、固定宽，像 DSH 的 `.readRow` 两列）。
class _NumberedLine extends StatelessWidget {
  const _NumberedLine({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: context.dshType.body >= 18 ? 34 : 28,
          child: Text(
            '$number',
            textAlign: TextAlign.right,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              height: 16 / 11,
              color: c.labelTertiary,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SelectableText(
            text,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              height: 16 / 11,
              color: c.labelPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

/// 改文件结果 —— 照 DSH 的 `DiffBlock`（`+N −M` + 内联 diff）。
///
/// diff 行由 `model/diff.dart` 在 `{oldText,newText}` 上折（工具只给前后两段文本）。
class _DiffBlock extends StatelessWidget {
  const _DiffBlock({required this.view});

  final DiffResultView view;

  /// 一个 hunk 最多画多少行（长文件整段替换时挡住）。
  static const int maxLines = 160;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final operation = view.operation;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PathLine(
          path: view.path,
          tail: operation == null ? '' : _operationLabel(operation),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Text(
              '+${view.added}',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: c.fileDiffAddMarker,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '−${view.removed}',
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: c.fileDiffDelMarker,
              ),
            ),
          ],
        ),
        for (final hunk in view.hunks) ...[
          const SizedBox(height: 6),
          if (view.hunks.length > 1) _PathLine(path: hunk.path),
          Builder(
            builder: (context) {
              final lines = diffLinesOf(hunk.oldText, hunk.newText);
              if (lines.isEmpty) {
                return Text(
                  '（内容未变化）',
                  style: TextStyle(
                    fontSize: context.dshType.caption,
                    color: c.labelTertiary,
                  ),
                );
              }
              final shown = lines.length > maxLines
                  ? lines.sublist(0, maxLines)
                  : lines;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DshDiff(shown),
                  if (lines.length > shown.length)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        '还有 ${lines.length - shown.length} 行未显示',
                        style: TextStyle(
                          fontSize: context.dshType.caption,
                          color: c.labelTertiary,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ],
    );
  }

  /// `write` 的 `operation` 是机器值（`create` / `update`），翻成人话；
  /// 认不出就原样显示（不猜）。
  static String _operationLabel(String operation) => switch (operation) {
    'create' => '新建',
    'update' => '更新',
    _ => operation,
  };
}
