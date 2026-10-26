/// 一个改动文件的**逐行比对**（`file.diff`，契约 §5.7）的值解析 + 折行。
///
/// 形状出处 `connector/src/dsh/changes.ts`，源头是宿主的 `WorkspaceFileDiff`
///（`packages/deliverables/workspace-changes/src/types.ts:56-76`）：
///
/// - `text`：`before` / `after` / `coarse` + `hunks`（每行带 `+` / `-` / 空格前缀）+ 可选的
///   `truncated:{shownLines,totalLines}`；
/// - `binary` / `oversized`：只有 `path` 与 `display`，**没有行**。
///
/// ## 行号怎么来（照桌面 `FileDiff.tsx:66-77` 的 `hunkRows`）
///
/// 上下文行两侧各进一格；`-` 只进旧行号、`+` 只进新行号。行号起点是 hunk 的
/// `oldStart` / `newStart`。这里不猜、也不按序号重排 —— 顺序就是宿主给的顺序。
library;

import '../ui/dsh_diff.dart';

/// 一个 hunk（宿主 `WorkspaceDiffHunk` 的过线字段）。
class DiffHunk {
  const DiffHunk({
    required this.oldStart,
    required this.oldLines,
    required this.newStart,
    required this.newLines,
    required this.lines,
  });

  final int oldStart;
  final int oldLines;
  final int newStart;
  final int newLines;

  /// 每行带 `+` / `-` / 空格前缀（宿主的约定，`types.ts:42-54`）。
  final List<String> lines;

  static DiffHunk? fromWire(Object? raw) {
    if (raw is! Map) return null;
    final oldStart = raw['oldStart'];
    final oldLines = raw['oldLines'];
    final newStart = raw['newStart'];
    final newLines = raw['newLines'];
    final lines = raw['lines'];
    if (oldStart is! int ||
        oldLines is! int ||
        newStart is! int ||
        newLines is! int ||
        lines is! List) {
      return null;
    }
    final body = <String>[];
    for (final line in lines) {
      if (line is! String || line.isEmpty) return null;
      body.add(line);
    }
    return DiffHunk(
      oldStart: oldStart,
      oldLines: oldLines,
      newStart: newStart,
      newLines: newLines,
      lines: List<String>.unmodifiable(body),
    );
  }
}

/// 截断标记：只给了前 [shownLines] 行（宿主的切法见连接器 `changes.ts`）。
class DiffTruncation {
  const DiffTruncation({required this.shownLines, required this.totalLines});

  final int shownLines;
  final int totalLines;

  static DiffTruncation? fromWire(Object? raw) {
    if (raw is! Map) return null;
    final shown = raw['shownLines'];
    final total = raw['totalLines'];
    if (shown is! int || total is! int) return null;
    return DiffTruncation(shownLines: shown, totalLines: total);
  }
}

/// 单文件比对。
class FileDiff {
  const FileDiff({
    required this.kind,
    required this.path,
    required this.display,
    this.before = false,
    this.after = false,
    this.coarse = false,
    this.hunks = const <DiffHunk>[],
    this.truncated,
  });

  /// `text` / `binary` / `oversized`。
  final String kind;

  final String path;
  final String display;

  /// 轮次起点 / 终点文件存在吗（`text` 才有意义）。
  final bool before;
  final bool after;

  /// 逐行对比超时，宿主按整文件替换给出。
  final bool coarse;

  final List<DiffHunk> hunks;

  /// 只给了前一部分（连接器按行数 / 字节封顶）。`null` = 全给了。
  final DiffTruncation? truncated;

  bool get isText => kind == 'text';
  bool get isBinary => kind == 'binary';
  bool get isOversized => kind == 'oversized';

  /// 解析 `{diff}` 里那一层；认不出给 `null`。
  static FileDiff? fromWire(Object? raw) {
    if (raw is! Map) return null;
    final kind = raw['kind'];
    final path = raw['path'];
    final display = raw['display'];
    if (kind is! String || path is! String || display is! String) return null;
    if (path.isEmpty || display.isEmpty) return null;
    if (kind == 'binary' || kind == 'oversized') {
      return FileDiff(kind: kind, path: path, display: display);
    }
    if (kind != 'text') return null;
    final before = raw['before'];
    final after = raw['after'];
    final coarse = raw['coarse'];
    final hunks = raw['hunks'];
    if (before is! bool ||
        after is! bool ||
        coarse is! bool ||
        hunks is! List) {
      return null;
    }
    final parsed = <DiffHunk>[];
    for (final hunk in hunks) {
      final one = DiffHunk.fromWire(hunk);
      if (one == null) return null;
      parsed.add(one);
    }
    return FileDiff(
      kind: kind,
      path: path,
      display: display,
      before: before,
      after: after,
      coarse: coarse,
      hunks: List<DiffHunk>.unmodifiable(parsed),
      truncated: DiffTruncation.fromWire(raw['truncated']),
    );
  }
}

/// 把 hunks 折成 `DshDiff` 吃的行（行号照桌面 `hunkRows` 推）。
List<DiffLine> diffLinesOfHunks(List<DiffHunk> hunks) {
  final out = <DiffLine>[];
  for (final hunk in hunks) {
    var oldNo = hunk.oldStart;
    var newNo = hunk.newStart;
    for (final line in hunk.lines) {
      if (line.isEmpty) continue;
      final text = line.substring(1);
      switch (line[0]) {
        case '+':
          out.add(DiffLine(kind: DiffKind.add, text: text, newLine: newNo));
          newNo += 1;
        case '-':
          out.add(DiffLine(kind: DiffKind.del, text: text, oldLine: oldNo));
          oldNo += 1;
        default:
          out.add(
            DiffLine(
              kind: DiffKind.context,
              text: text,
              oldLine: oldNo,
              newLine: newNo,
            ),
          );
          oldNo += 1;
          newNo += 1;
      }
    }
  }
  return out;
}
