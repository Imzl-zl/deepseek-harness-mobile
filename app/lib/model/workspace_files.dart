/// 工作区文件的线上形状（契约 §5.7 的 `file.list` / `file.read`）。
///
/// 字段以宿主的 `WorkspaceDirectoryListing` / `WorkspaceFileText` 为准
/// （`packages/api/workspace-files/src/types.ts:94-123`、`:48-62`），这里只做解析 ——
/// **手机不自己解析路径归属**：`path` 是"相对工作区的路径、根是空串"，子项的路径是
/// `父路径 + '/' + name`（宿主 `list` 的注释同一句）；越界（`..`、绝对路径）的判定在宿主，
/// 手机照它给的清单走。
library;

/// 一个目录项的类型（宿主的第三档 `other` = 既不是普通文件也不是目录）。
enum FileEntryType {
  file,
  directory,
  other;

  static FileEntryType fromWire(Object? value) => switch (value) {
    'file' => FileEntryType.file,
    'directory' => FileEntryType.directory,
    _ => FileEntryType.other,
  };
}

/// 目录里的一行。
class FileEntryRow {
  const FileEntryRow({required this.name, required this.type, this.size = 0});

  /// 解析宿主的一行；没有 `name` 就整行不要（点不动也叫不出路径）。
  static FileEntryRow? fromWire(Object? row) {
    if (row is! Map) return null;
    final name = row['name'];
    if (name is! String || name.isEmpty) return null;
    final size = row['size'];
    return FileEntryRow(
      name: name,
      type: FileEntryType.fromWire(row['type']),
      size: size is int && size >= 0 ? size : 0,
    );
  }

  /// 目录内的名字（不是路径）。
  final String name;
  final FileEntryType type;

  /// 字节大小（宿主只在普通文件且后端报得出时给；`0` = 没报）。
  final int size;

  bool get isDirectory => type == FileEntryType.directory;
}

/// 一份目录清单。
class FileListing {
  const FileListing({
    this.path = '',
    this.entries = const <FileEntryRow>[],
    this.truncated = false,
  });

  /// 解析 `file.list` 的应答；认不出给 `null`（调用方按失败处理，不摆空目录）。
  static FileListing? fromWire(Object? value) {
    if (value is! Map) return null;
    final rows = value['entries'];
    if (rows is! List) return null;
    final path = value['path'];
    return FileListing(
      path: path is String ? path : '',
      entries: rows
          .map(FileEntryRow.fromWire)
          .whereType<FileEntryRow>()
          .toList(growable: false),
      truncated: value['truncated'] == true,
    );
  }

  /// 被列的目录（相对工作区，根是空串）。
  final String path;
  final List<FileEntryRow> entries;

  /// 宿主的条目上限截掉了后面的项 —— **照报，不假装列全**。
  final bool truncated;

  /// 子项的路径（`父路径 + '/' + name`；根目录时就是 name）。
  String pathOf(FileEntryRow entry) =>
      path.isEmpty ? entry.name : '$path/${entry.name}';
}

/// 一页文本。
class FilePage {
  const FilePage({
    this.text = '',
    this.offset = 1,
    this.lines = 0,
    this.eof = true,
    this.bytes = 0,
  });

  /// 解析 `file.read` 的应答；认不出给 `null`。
  static FilePage? fromWire(Object? value) {
    if (value is! Map) return null;
    final text = value['text'];
    final offset = value['offset'];
    final lines = value['lines'];
    if (text is! String || offset is! int || lines is! int) return null;
    final bytes = value['bytes'];
    return FilePage(
      text: text,
      offset: offset,
      lines: lines,
      eof: value['eof'] == true,
      bytes: bytes is int && bytes >= 0 ? bytes : 0,
    );
  }

  /// 这一页的行（`\n` 连接、末尾不带换行；空串 = 越过末行 **或** 一页空行 —— 看 [lines]）。
  final String text;

  /// 这一页从第几行起（1 基）。
  final int offset;

  /// 这一页有几行。
  final int lines;

  /// 这一页是否含文件最后一行。
  final bool eof;

  /// 文件总字节（后端报得出才有；`0` = 没报）。
  final int bytes;

  /// 下一页从第几行起（`eof` 之后调用方不该再要）。
  int get nextOffset => offset + lines;
}
