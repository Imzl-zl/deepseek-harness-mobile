/// **打开一个文件**这件事的形状：一个请求 + 一份已读到的内容。
///
/// ## 为什么要有它（而不是每处各自 `readFile`）
///
/// 四个入口最后都是"看某个文件"：正文提及、收口改动卡的行、侧栏差异行、文件页。
/// 每个入口各写一遍"先判断能力位、再读、失败怎么报"，就会长出四份会漂的规则
/// （2026-10-20 那一轮就是"表头说改了 128 行、面板说还没有改动"）。
/// 所以请求与状态收在这里，读写只有 `AppModel.openFile` 一条路。
///
/// ## 路径**原样**过线，手机不做归属解析
///
/// `file.read` 的 scope 由宿主 `workspaceFileScope` lookup 按会话解析
/// （`packages/api/workspace-files/src/index.ts:203-221`；连接器
/// `connector/src/dsh/files.ts:136-154`），与桌面 `openFile` 的兜底是同一个 cwd
/// （`packages/client/ui-chat/src/client/apply.ts:271-278`）。
/// 手机自己拼 cwd 就是第二份真值（会话中途 `cd` 之后两边会漂）。
library;

/// 路径的最后一段（`/` 与 `\` 都认，照 DSH 的 `basename`，
/// `packages/client/ui-deliverables/src/presented.ts:84-87`）。
///
/// 侧栏标题用它（文件面板的标题是文件名，副标题才是完整路径）。
String fileNameOf(String path) {
  final slash = path.lastIndexOf('/');
  final backslash = path.lastIndexOf(r'\');
  final cut = slash > backslash ? slash : backslash;
  return cut == -1 ? path : path.substring(cut + 1);
}

/// 打开这个文件想看到什么。
enum FileOpenMode {
  /// 文件内容（`file.read`，当前已接）。
  preview,

  /// 逐行差异（需要协议方法 `file.diff`，见
  /// `.agents/notes/proposed/2026-10-26-desktop-alignment-plan.md` 的批 C）。
  diff,
}

/// 一次"打开文件"的请求。
///
/// **值相等**：同一个路径连点两次要能各自触发一次动作（所以还有一个请求序号，
/// 见 `AppModel.fileOpenTicket`），而 `==` 只用来表达"这是同一个请求"。
class FileOpenRequest {
  const FileOpenRequest({required this.path, this.mode = FileOpenMode.preview});

  /// 路径**原样**（相对工作区的路径，或宿主认得的绝对路径）。
  final String path;

  final FileOpenMode mode;

  @override
  bool operator ==(Object other) =>
      other is FileOpenRequest && other.path == path && other.mode == mode;

  @override
  int get hashCode => Object.hash(path, mode);

  @override
  String toString() => 'FileOpenRequest($path, ${mode.name})';
}

/// 已经读到的那个文件（首屏 + 后续"加载更多"累计）。
///
/// 字段语义与 `model/workspace_files.dart` 的 [FilePage] 一致 —— 这里只是把
/// 多页拼成一份：`text` 是已读行的正文（`\n` 连接）、`lines` 是已读行数、
/// `nextOffset` 是下一页从第几行起、`eof` 是"已到文件末尾"。
class OpenedFile {
  const OpenedFile({
    required this.request,
    required this.text,
    required this.lines,
    required this.eof,
    required this.nextOffset,
    this.bytes = 0,
  });

  /// 打开它时的那个请求（路径 + 模式）。
  final FileOpenRequest request;

  /// 已读正文。
  final String text;

  /// 已读行数。
  final int lines;

  /// 是否已到末尾（`true` = 没有"加载更多"）。
  final bool eof;

  /// 下一页起点（1 基）。
  final int nextOffset;

  /// 文件总字节（宿主报得出才有；`0` = 没报）。
  final int bytes;

  /// 接上下一页的正文。**空页也要落一处**：一页空行（`lines > 0` 但 `text` 为空）
  /// 与"越过末行"（`lines == 0`）是两件事，前者有内容、后者没有。
  OpenedFile appended({
    required String text,
    required int lines,
    required bool eof,
    required int nextOffset,
    int bytes = 0,
  }) => OpenedFile(
    request: request,
    text: this.text.isEmpty
        ? text
        : (text.isEmpty ? this.text : '${this.text}\n$text'),
    lines: this.lines + lines,
    eof: eof,
    nextOffset: nextOffset,
    bytes: bytes > 0 ? bytes : this.bytes,
  );
}
