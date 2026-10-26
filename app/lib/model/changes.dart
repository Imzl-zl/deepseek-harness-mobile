/// 一轮的改动记录（`file.changes`，契约 §5.7）的**值解析**。
///
/// 形状出处 `connector/src/dsh/changes.ts`（给手机的那一层），源头是宿主的
/// `WorkspaceChangesSummary`（`packages/deliverables/workspace-changes/src/types.ts:25-40`）：
///
/// ```text
/// {turn, files:[{path, display, added, deleted, binary?, oversized?}], total, added, deleted}
/// ```
///
/// ## 这些数字**不是手机上算的**
///
/// 真实文件、行数、二进制 / 超大判定都在电脑上（`types.ts:14-21` 的两个标记就是宿主给的）。
/// 手机只解析与显示 —— 自己从工具调用推一份 `+N −M` 会与桌面**不同源**，
/// 而用户看到的应该是同一份记录（方案笔记批 B）。
///
/// ## `display` 与 `path` 的分工
///
/// - `display`：界面上该显示的那一串（相对 cwd、`../`、`~` 或绝对路径，`types.ts:9-13`）；
/// - `path`：打开文件时**原样交回**的那一串（`file.read` 按会话 scope 解析，见
///   `model/file_open.dart` 的文件头）。
library;

/// 一个改动文件（宿主 `WorkspaceChangedFile` 的过线字段）。
class ChangedFile {
  const ChangedFile({
    required this.path,
    required this.display,
    required this.added,
    required this.deleted,
    this.binary = false,
    this.oversized = false,
  });

  /// 打开文件用（原样交给 `file.read`）。
  final String path;

  /// 显示用（宿主排好的那串）。
  final String display;

  final int added;
  final int deleted;

  /// 宿主说它是二进制（没有行数可比）。
  final bool binary;

  /// 宿主说它超过插件上限（没有行数、也没有比对）。
  final bool oversized;

  /// 解析一行；`path` / `display` 缺一就整行不要（点不动也叫不出路径）。
  static ChangedFile? fromWire(Object? raw) {
    if (raw is! Map) return null;
    final path = raw['path'];
    final display = raw['display'];
    final added = raw['added'];
    final deleted = raw['deleted'];
    if (path is! String ||
        path.isEmpty ||
        display is! String ||
        display.isEmpty ||
        added is! int ||
        deleted is! int) {
      return null;
    }
    return ChangedFile(
      path: path,
      display: display,
      added: added,
      deleted: deleted,
      binary: raw['binary'] == true,
      oversized: raw['oversized'] == true,
    );
  }
}

/// 一轮的改动记录。
class ChangesSummary {
  const ChangesSummary({
    required this.turn,
    required this.files,
    required this.total,
    required this.added,
    required this.deleted,
  });

  final int turn;

  /// 宿主给的清单（按 `display` 排序、已被插件 `maxFiles` 截过）。
  final List<ChangedFile> files;

  /// **完整**的改动文件数（含被上限截掉的）。
  final int total;

  final int added;
  final int deleted;

  /// 宿主的文件上限截掉了一些行（`total` 比 `files` 多）。
  ///
  /// **照报不假装列全**（与 `file.list` 的 `truncated` 同一条纪律）。
  bool get truncated => files.length < total;

  /// 解析 `{summary}` 里的那一层；认不出给 `null`（调用方按形状错处理）。
  static ChangesSummary? fromWire(Object? raw) {
    if (raw is! Map) return null;
    final turn = raw['turn'];
    final total = raw['total'];
    final added = raw['added'];
    final deleted = raw['deleted'];
    final files = raw['files'];
    if (turn is! int || total is! int || added is! int || deleted is! int) {
      return null;
    }
    if (files is! List) return null;
    return ChangesSummary(
      turn: turn,
      files: List<ChangedFile>.unmodifiable(
        files.map(ChangedFile.fromWire).whereType<ChangedFile>(),
      ),
      total: total,
      added: added,
      deleted: deleted,
    );
  }
}
