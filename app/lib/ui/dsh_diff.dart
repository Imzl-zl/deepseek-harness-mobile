/// 差异渲染（照 `mock/proto/styles.css` 的 `.diff` / `.dl` / `.codeline`）。
///
/// ## 几何是固定的（数值取自原型）
///
/// ```text
/// 行号槽 .gut  40px 宽、右对齐、11.5px、sticky 左（横滑时行号不动）
/// 标记槽 .mk   16px 宽、居中
/// 正文   .tx   padding 0 16px 0 6px、white-space: pre
/// ```
///
/// ## 三种行各有底色（`.dl.add` / `.dl.del` / `.dl.hunk`）
///
/// | 行 | 正文底 | 行号槽底 | 标记色 |
/// |---|---|---|---|
/// | 新增 | `fileDiffAddBg` | `fileDiffAddGutter` | `fileDiffAddMarker` |
/// | 删除 | `fileDiffDelBg` | `fileDiffDelGutter` | `fileDiffDelMarker` |
/// | hunk 头 | `fhunk`（蓝 8%） | 同左 | 蓝 |
///
/// **行号槽底色比正文深**：这是 diff 的读法 —— 眼睛沿左边缘扫就能定位增删，
/// 而不必逐行读正文。少了这一列，长 diff 会变成一片同色的墙。
///
/// ## 横滑时行号要**粘住**左边
///
/// 原型用 `position: sticky; left: 0`。Flutter 里对应"固定左列 + 右侧横滑"，
/// 所以这一层拆成两个：左边一个不动的槽，右边一个横滑区。
library;

import 'package:flutter/material.dart';

import '../theme/dsh_colors.dart';

/// 一行差异。
class DiffLine {
  const DiffLine({
    required this.kind,
    required this.text,
    this.oldLine,
    this.newLine,
  });

  /// hunk 头（`@@ -112,9 +112,14 @@`）。
  const DiffLine.hunk(this.text)
    : kind = DiffKind.hunk,
      oldLine = null,
      newLine = null;

  final DiffKind kind;
  final String text;

  /// 旧行号（新增行为 `null`）。
  final int? oldLine;

  /// 新行号（删除行为 `null`）。
  final int? newLine;
}

/// 行的种类。
enum DiffKind {
  /// 上下文（两边都有）。
  context,

  /// 新增。
  add,

  /// 删除。
  del,

  /// hunk 头。
  hunk,
}

/// 一个 diff（若干行）。
class DshDiff extends StatelessWidget {
  const DshDiff(this.lines, {super.key});

  final List<DiffLine> lines;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    if (lines.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            '没有可显示的差异',
            style: TextStyle(fontSize: 13, color: c.labelTertiary),
          ),
        ),
      );
    }
    return SingleChildScrollView(
      // 纵向滚动在这里（**不外包横向**）：下面那个 `Row` 的右列是
      // `Expanded`，再套一层横向滚动会让它拿到无限宽约束而断言失败。
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---- 固定左列：两个行号（**横滑时不动**）----
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final line in lines) _Gutter(line: line)],
          ),
          // ---- 右侧横滑区：标记 + 正文 ----
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [for (final line in lines) _Body(line: line)],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 行号槽（`.gut`：两个 40px 的格子）。
class _Gutter extends StatelessWidget {
  const _Gutter({required this.line});

  final DiffLine line;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final (bg, fg) = switch (line.kind) {
      DiffKind.add => (c.fileDiffAddGutter, c.labelCaption),
      DiffKind.del => (c.fileDiffDelGutter, c.labelCaption),
      DiffKind.hunk => (c.codeDiffAdd, c.businessBlue),
      DiffKind.context => (c.bgBase, c.labelCaption),
    };
    return Container(
      color: bg,
      height: _lineHeight,
      child: Row(
        children: [
          _Num(line.oldLine, color: fg),
          _Num(line.newLine, color: fg),
        ],
      ),
    );
  }
}

class _Num extends StatelessWidget {
  const _Num(this.value, {required this.color});

  final int? value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // `.dl .gut span { width:40px; padding-right:8px; text-align:right }`
      width: 40,
      child: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Text(
          value?.toString() ?? '',
          textAlign: TextAlign.right,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 11.5,
            height: _lineHeight / 11.5,
            color: color,
          ),
        ),
      ),
    );
  }
}

/// 标记 + 正文。
class _Body extends StatelessWidget {
  const _Body({required this.line});

  final DiffLine line;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final (bg, marker, markerColor) = switch (line.kind) {
      DiffKind.add => (c.fileDiffAddBg, '+', c.fileDiffAddMarker),
      DiffKind.del => (c.fileDiffDelBg, '−', c.fileDiffDelMarker),
      DiffKind.hunk => (c.codeDiffAdd, '', c.businessBlue),
      DiffKind.context => (c.bgBase, ' ', c.labelTertiary),
    };
    final textColor = switch (line.kind) {
      DiffKind.hunk => c.businessBlue,
      DiffKind.context => c.labelSecondary,
      _ => c.labelSecondary,
    };
    return Container(
      color: bg,
      height: _lineHeight,
      child: Row(
        children: [
          // `.dl .mk { width:16px; text-align:center }`
          SizedBox(
            width: 16,
            child: Text(
              marker,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                height: _lineHeight / 12.5,
                color: markerColor,
              ),
            ),
          ),
          Padding(
            // `.dl .tx { padding: 0 16px 0 6px; white-space: pre }`
            padding: const EdgeInsets.only(left: 6, right: 16),
            child: Text(
              line.text,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                height: _lineHeight / 12.5,
                color: textColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 文件内容（`.codeline`：只有**一个**行号槽）。
class DshCodeLines extends StatelessWidget {
  const DshCodeLines(this.lines, {super.key});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    if (lines.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            '没有内容',
            style: TextStyle(fontSize: 13, color: c.labelTertiary),
          ),
        ),
      );
    }
    return SingleChildScrollView(
      // 纵向滚动在这里（同 `DshDiff`：外包横向会让 `Expanded` 拿到无限宽）。
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < lines.length; i += 1)
                Container(
                  color: c.bgBase,
                  height: _lineHeight,
                  child: _Num(i + 1, color: c.labelCaption),
                ),
            ],
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final line in lines)
                    Container(
                      color: c.bgBase,
                      height: _lineHeight,
                      child: Padding(
                        // `.codeline .tx { padding: 0 16px 0 10px }`
                        padding: const EdgeInsets.only(left: 10, right: 16),
                        child: Text(
                          line,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12.5,
                            height: _lineHeight / 12.5,
                            color: c.labelSecondary,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `.diff { line-height: 20px }` —— 行高是 diff 的基准单位。
const double _lineHeight = 20;
