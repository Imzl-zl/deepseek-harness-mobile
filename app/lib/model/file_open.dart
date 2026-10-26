/// **打开一个文件**这件事的形状：一个请求 + 一份已读到的内容。
///
/// ## 为什么要有它（而不是每处各自 `readFile`）
///
/// 四个入口最后都是"看某个文件"：正文提及、收口改动卡的行、侧栏差异行、文件页。
/// 每个入口各写一遍"先判断能力位、再读、失败怎么报"，就会长出四份会漂的规则
/// （2026-10-20 那一轮就是"表头说改了 128 行、面板说还没有改动"）。
/// 所以请求与状态收在这里，读写只有 `AppModel.openFile` 一条路。
///
/// ## 路径是**桌面侧的值**，手机只做映射
///
/// 真实文件、工作区归属、`cd`、存在性、二进制判定、这一轮改了什么 —— 全在电脑上。
/// 手机这一侧只做一件事：把**桌面已经给出（或桌面将要解析）的那一串路径**原样转交。
/// 所以下面这些在 `app/lib` 里**故意都不做**：
///
/// - 不拼会话 cwd：scope 由宿主 `workspaceFileScope` lookup 按 sessionId 解析
///   （`packages/api/workspace-files/src/index.ts:203-221`；连接器
///   `connector/src/dsh/files.ts:136-154`），与桌面 `openFile` 的兜底是同一个 cwd
///   （`packages/client/ui-chat/src/client/apply.ts:271-278`）；
/// - 不规范化分隔符 / 大小写：宿主按自己的文件系统判（连接器只是原样转交，
///   `connector/src/handlers.ts:1296-1309`）；
/// - 不判断是否在工作区内：绝对路径与 `..` 由宿主 `locateFile` 接手
///   （`packages/api/workspace-files/src/index.ts:228,241` 的注释原话
///   "absolute path or path relative to the workspace root; files outside it are allowed"）；
/// - 不查本地文件、不算 diff、不判断二进制：结论由宿主的 `workspaceFiles` /
///   `workspace-changes` 给（`workspace-changes/src/types.ts:56-76`）。
///
/// 于是 [FileOpenRequest.path] 的语义是"**照桌面看到的那一串**"，
/// 不是"手机算出来的路径"。手机自己拼一份，等于在电脑之外又长出一套文件语义。
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

  /// 逐行差异（`file.diff`）。坐标是 [FileOpenRequest.seq] + [FileOpenRequest.index]。
  diff,
}

/// 一次"打开文件"的请求。
///
/// **值相等**：同一个路径连点两次要能各自触发一次动作（所以还有一个请求序号，
/// 见 `AppModel.fileOpenTicket`），而 `==` 只用来表达"这是同一个请求"。
class FileOpenRequest {
  const FileOpenRequest({
    required this.path,
    this.mode = FileOpenMode.preview,
    this.seq,
    this.index,
  });

  /// 逐行差异的坐标：`workspace/changes` 的事件序号 + 文件在记录里的下标。
  ///
  /// **不是路径**（宿主只认这两个，`workspace-changes/src/types.ts:88-96`）。
  /// `preview` 模式用不到；`diff` 模式缺一就是一次不完整的请求。
  final int? seq;
  final int? index;

  /// **桌面侧的那一串路径，原样**（相对工作区的路径，或宿主认得的绝对路径）。
  ///
  /// 手机不解释它：不拼 cwd、不规范化、不判断归属（见文件头那五条"不做"）。
  final String path;

  final FileOpenMode mode;

  @override
  bool operator ==(Object other) =>
      other is FileOpenRequest &&
      other.path == path &&
      other.mode == mode &&
      other.seq == seq &&
      other.index == index;

  @override
  int get hashCode => Object.hash(path, mode, seq, index);

  @override
  String toString() => 'FileOpenRequest($path, ${mode.name}, $seq/$index)';
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
