/// 一行差异的形状（`DiffLine` / `DiffKind`）：**生产者与渲染者之间的那份数据**。
///
/// ## 为什么在 `model/` 而不是 `ui/`
///
/// 生产者是 `model/diff.dart`（`{oldText,newText}` 折行）与 `model/file_diff.dart`
/// （宿主的 hunk 过线），渲染者是 `ui/dsh_diff.dart`（行号槽 + `+`/`−`/空行）。
/// 形状跟着**生产者**走：放在 `ui/` 会让 `model/` 反向 import 界面层，把
/// `package:flutter/material.dart` 一路带进纯 Dart 的模型里（`app-platform-boundaries.md`
/// 的分层规则就是为这类边写的）。
///
/// 渲染侧的几何（40px 行号槽、16px 标记槽、sticky 左侧）留在 `ui/dsh_diff.dart` ——
/// 那是画法，不是数据。
library;

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
