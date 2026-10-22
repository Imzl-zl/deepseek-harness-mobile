/// 行级 diff：把 `{oldText, newText}` 折成 [DiffLine] 列表（`ui/dsh_diff.dart` 的输入）。
///
/// ## 为什么自己写
///
/// `ui/dsh_diff.dart` 只负责**画**（行号槽 + `+`/`−`/空行），它从来没有生产者
/// （`DiffLine(` 在整个 `app/lib` 里只有那个文件自己）。DSH 的 hunk 是
/// `computeHunkDiffs(path, before, after)` 的结果（`packages/fs/tool-fs/src/diff.ts`），
/// 手机上要自己在 `{oldText,newText}` 上折一次。
///
/// ## 算法与代价
///
/// 1. **先剥公共前缀 / 后缀**：一次编辑改的通常只有中间几行，这一步就把两边压到很小；
/// 2. 中间剩下的两边都 ≤ [maxLcsLines] 时跑 **LCS**（动态规划，O(n·m)）；
/// 3. 任何一边超过上限 ⇒ **整段替换**（先把旧的都标 `−`、再新的都标 `+`）。
///    这是**如实降级**：宁可粗一点，也不为了好看去猜配对。
///
/// 行号：`DiffLine.oldLine` / `newLine` 都按**原文的 1 基行号**给，
/// 新增行没有旧行号、删除行没有新行号（与 DSH 的 `dsh-diff` 同一套语义）。
library;

import '../ui/dsh_diff.dart';

/// LCS 的规模上限（两边行数乘积超过它就整段替换）。
const int maxLcsLines = 400;

/// 把一段 `{oldText, newText}` 折成 diff 行。
List<DiffLine> diffLinesOf(String oldText, String newText) {
  final oldLines = _split(oldText);
  final newLines = _split(newText);
  return diffLineListsOf(oldLines, newLines);
}

/// 只要统计（`+N −M`）：**按折出来的 diff 行数**，不是按两段文本的总行数。
///
/// 旧实现把 `oldText` 的每一行都算删除、`newText` 的每一行都算新增
/// （`{a,b}` → `{a,c}` 会报 `+2 −2`），而真实只有 1 增 1 删。
({int added, int removed}) diffStatOfTexts(String oldText, String newText) {
  var added = 0;
  var removed = 0;
  for (final line in diffLinesOf(oldText, newText)) {
    switch (line.kind) {
      case DiffKind.add:
        added += 1;
      case DiffKind.del:
        removed += 1;
      case DiffKind.context || DiffKind.hunk:
        break;
    }
  }
  return (added: added, removed: removed);
}

/// 同上，输入已经切好行（write 的整文件对比用得上）。
List<DiffLine> diffLineListsOf(List<String> oldLines, List<String> newLines) {
  final out = <DiffLine>[];

  var prefix = 0;
  while (prefix < oldLines.length &&
      prefix < newLines.length &&
      oldLines[prefix] == newLines[prefix]) {
    prefix += 1;
  }
  var suffix = 0;
  while (suffix < oldLines.length - prefix &&
      suffix < newLines.length - prefix &&
      oldLines[oldLines.length - 1 - suffix] ==
          newLines[newLines.length - 1 - suffix]) {
    suffix += 1;
  }

  // 公共前缀与后缀：上下文行（都带行号）。
  for (var i = 0; i < prefix; i += 1) {
    out.add(
      DiffLine(
        kind: DiffKind.context,
        text: oldLines[i],
        oldLine: i + 1,
        newLine: i + 1,
      ),
    );
  }

  final oldMiddle = oldLines.sublist(prefix, oldLines.length - suffix);
  final newMiddle = newLines.sublist(prefix, newLines.length - suffix);
  final oldBase = prefix; // 0 基 → 行号 = index + 1 + base
  final newBase = prefix;

  if (oldMiddle.isEmpty ||
      newMiddle.isEmpty ||
      oldMiddle.length * newMiddle.length > maxLcsLines * maxLcsLines) {
    // 纯插入 / 纯删除 / 太大：整段替换（删除在前、新增在后）。
    for (var i = 0; i < oldMiddle.length; i += 1) {
      out.add(
        DiffLine(
          kind: DiffKind.del,
          text: oldMiddle[i],
          oldLine: oldBase + i + 1,
        ),
      );
    }
    for (var i = 0; i < newMiddle.length; i += 1) {
      out.add(
        DiffLine(
          kind: DiffKind.add,
          text: newMiddle[i],
          newLine: newBase + i + 1,
        ),
      );
    }
  } else {
    out.addAll(_lcsLines(oldMiddle, newMiddle, oldBase, newBase));
  }

  // 公共后缀：上下文行（行号从各自尾部倒着数）。
  for (var i = 0; i < suffix; i += 1) {
    out.add(
      DiffLine(
        kind: DiffKind.context,
        text: oldLines[oldLines.length - suffix + i],
        oldLine: oldLines.length - suffix + i + 1,
        newLine: newLines.length - suffix + i + 1,
      ),
    );
  }
  return out;
}

/// 中间段的 LCS：输出时把"删除"排在"新增"之前（与 patch 的阅读顺序一致）。
List<DiffLine> _lcsLines(
  List<String> oldLines,
  List<String> newLines,
  int oldBase,
  int newBase,
) {
  final n = oldLines.length;
  final m = newLines.length;
  // table[i][j] = oldLines[i..] 与 newLines[j..] 的 LCS 长度。
  final table = List<List<int>>.generate(
    n + 1,
    (_) => List<int>.filled(m + 1, 0),
  );
  for (var i = n - 1; i >= 0; i -= 1) {
    for (var j = m - 1; j >= 0; j -= 1) {
      table[i][j] = oldLines[i] == newLines[j]
          ? table[i + 1][j + 1] + 1
          : (table[i + 1][j] >= table[i][j + 1]
                ? table[i + 1][j]
                : table[i][j + 1]);
    }
  }

  final out = <DiffLine>[];
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (oldLines[i] == newLines[j]) {
      out.add(
        DiffLine(
          kind: DiffKind.context,
          text: oldLines[i],
          oldLine: oldBase + i + 1,
          newLine: newBase + j + 1,
        ),
      );
      i += 1;
      j += 1;
      continue;
    }
    if (table[i + 1][j] >= table[i][j + 1]) {
      out.add(
        DiffLine(
          kind: DiffKind.del,
          text: oldLines[i],
          oldLine: oldBase + i + 1,
        ),
      );
      i += 1;
    } else {
      out.add(
        DiffLine(
          kind: DiffKind.add,
          text: newLines[j],
          newLine: newBase + j + 1,
        ),
      );
      j += 1;
    }
  }
  while (i < n) {
    out.add(
      DiffLine(kind: DiffKind.del, text: oldLines[i], oldLine: oldBase + i + 1),
    );
    i += 1;
  }
  while (j < m) {
    out.add(
      DiffLine(kind: DiffKind.add, text: newLines[j], newLine: newBase + j + 1),
    );
    j += 1;
  }
  return out;
}

/// 切行：末尾的换行不产生一个空行（`"a\nb\n"` 是两行）。
List<String> _split(String text) {
  if (text.isEmpty) return const [];
  final normalized = text.replaceAll('\r\n', '\n');
  final lines = normalized.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines;
}
