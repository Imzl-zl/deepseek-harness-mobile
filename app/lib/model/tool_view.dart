/// 一次工具结果的**结构化视图** —— 三个高频工具各一张专用卡。
///
/// ## 数据从哪儿来（真日志实测）
///
/// `tool/result` 的 `data.meta` 是 DSH 的 `presentationMeta`
/// （`packages/fs/tool-fs/src/read.ts:124-132`、`edit.ts:113-117`、`write.ts:103-110`），
/// 真机落盘的一帧长这样（`app/test/fixtures/real-session-events.json`）：
///
/// ```json
/// {"type":"tool/result","seq":71,"data":{"turn":2,"step":1,"message":{…},
///   "meta":{"path":"…memory.md","offset":1,"lines":[{"number":1,"text":"# …"}],"totalLines":149}}}
/// ```
///
/// 三个工具的 meta 形状（逐个读过 DSH 源码）：
///
/// | 工具 | meta |
/// |---|---|
/// | `bash` / `pwsh` | 只有 `{cwd}` —— **状态在文本里**：`[exit code: N]` / `[killed by signal: X]` / `[timed out …]`（`packages/shell/tool-bash/src/render.ts:52-61`） |
/// | `read` | `{path, offset, lines:[{number,text}], totalLines, lang?}` |
/// | `edit` | `{path, diffs:[{path, oldText, newText}]}` |
/// | `write` | `{operation, path, diffs:[…]}` |
///
/// 其余工具（`grep` / `glob` / `web_*` / `todo_write` / `subagent` / …）这一版**不专门做**：
/// 它们继续走通用卡（IN/OUT 文本），见 `docs/subsystems/tool-views.md` §3 的"有意偏离"。
///
/// **键名与类型只在 `wire/event_fields.dart` 的 `toolMeta` 里断言**：本文件收
/// [ToolResultMeta]（解好的值），自己不按线上字段名取。
library;

import 'diff.dart';

/// 工具结果的专用视图（`null` = 走通用卡）。
sealed class ToolResultView {
  const ToolResultView();
}

/// 命令行结果：`bash` / `pwsh`。
final class BashResultView extends ToolResultView {
  const BashResultView({
    required this.output,
    this.stderr,
    this.exitCode,
    this.signal,
    this.marker,
  });

  /// stdout（已剥掉尾部的状态标记）。
  final String output;

  /// `[stderr]` 之后的文本；没有就是 `null`。
  final String? stderr;

  /// 退出码。**没有标记时按 0**（DSH 的 `parseExitStatus` 同一条：
  /// `terminal-card-model.ts:298` 的 `return { output: text, exitCode: 0 }`）。
  final int? exitCode;

  /// `[killed by signal: X]` 里的信号名。
  final String? signal;

  /// `[timed out …]` / `[stopped: …]` 的原文（有就显示，不翻译成别的说法）。
  final String? marker;

  /// 0 = 成功；非 0 或被杀 = 失败态（图标与 pill 都按它上色）。
  bool get ok => exitCode == 0 && signal == null && marker == null;
}

/// 读文件结果：`read`。
final class ReadResultView extends ToolResultView {
  const ReadResultView({
    required this.path,
    required this.offset,
    required this.lines,
    this.totalLines,
    this.lang,
  });

  final String path;

  /// 第一行的行号（1 基）。
  final int offset;

  /// 返回的行（已带行号）。
  final List<FileTextLine> lines;

  /// 文件总行数（`null` = 电脑侧没给）。
  final int? totalLines;

  final String? lang;
}

/// 一行带行号的文本（与 DSH 的 `FileTextLine` 同形）。
final class FileTextLine {
  const FileTextLine(this.number, this.text);

  final int number;
  final String text;
}

/// 改文件结果：`edit` / `write`。
final class DiffResultView extends ToolResultView {
  const DiffResultView({
    required this.path,
    required this.hunks,
    required this.added,
    required this.removed,
    this.operation,
  });

  final String path;

  /// `{path, oldText, newText}`（DSH 的 `computeHunkDiffs` 产物）。
  final List<DiffHunk> hunks;

  /// `+N`
  final int added;

  /// `−M`
  final int removed;

  /// `write` 的 `operation`（`create` / `update` …）；`edit` 没有。
  final String? operation;
}

/// 一段 hunk：旧文本 → 新文本。
final class DiffHunk {
  const DiffHunk({
    required this.path,
    required this.oldText,
    required this.newText,
  });

  final String path;
  final String oldText;
  final String newText;
}

/// `true` = 这个工具名有一张专用卡（`bash` / `pwsh` / `read` / `edit` / `write`）。
bool hasDedicatedView(String name) => switch (name) {
  'bash' || 'pwsh' || 'read' || 'edit' || 'write' => true,
  _ => false,
};

/// `tool/result.data.meta`（DSH 的 `presentationMeta`）**解好的值**。
///
/// 键名与类型只在 `wire/event_fields.dart` 断言（`EventFields.toolMeta`），这里只有字段。
/// 三个专用卡各取其中几项，见 [toolResultViewOf]。
final class ToolResultMeta {
  const ToolResultMeta({
    this.path,
    this.operation,
    this.offset,
    this.totalLines,
    this.lang,
    this.lines,
    this.diffs = const [],
  });

  /// 文件路径（`read` / `edit` / `write`）。
  final String? path;

  /// `write` 的操作名（`create` / `update` …）；`edit` 没有。
  final String? operation;

  /// `read` 的起始行号（1 基）。
  final int? offset;

  /// `read` 的文件总行数（`null` = 电脑侧没给）。
  final int? totalLines;

  /// `read` 的语言标记。
  final String? lang;

  /// `read` 的结构化窗口；**没有（或空）就是 `null`** —— 那时退回通用卡，
  /// 不装作有行号（老结果 / 第三方适配器）。
  final List<FileTextLine>? lines;

  /// `edit` / `write` 的 hunks（缺就是空表）。
  final List<DiffHunk> diffs;
}

/// 从 `tool/result` 的**解好的 meta** 与正文文本解析出专用视图；`null` = 走通用卡。
///
/// [meta] 由 `EventFields.toolMeta` 解（`data.meta` 的键名只在那里断言）；[text] 是结果
/// 消息的文本块拼接 —— 调用方已经有解好的消息块，别在这里再解一次。
ToolResultView? toolResultViewOf({
  required String name,
  required ToolResultMeta meta,
  required String text,
}) {
  switch (name) {
    case 'bash' || 'pwsh':
      // 状态在文本末尾的标记里，meta 只有 cwd —— 所以这一支不要求 meta。
      final parsed = _parseExitStatus(text);
      return BashResultView(
        output: parsed.output,
        stderr: parsed.stderr,
        exitCode: parsed.exitCode,
        signal: parsed.signal,
        marker: parsed.marker,
      );
    case 'read':
      final lines = meta.lines;
      if (lines == null || lines.isEmpty) {
        // 没有结构化窗口（老结果 / 第三方适配器）：退回通用卡，别装作有行号。
        return null;
      }
      return ReadResultView(
        path: meta.path ?? '',
        offset: meta.offset ?? 1,
        lines: lines,
        totalLines: meta.totalLines,
        lang: meta.lang,
      );
    case 'edit' || 'write':
      final hunks = meta.diffs;
      final path = meta.path ?? '';
      if (hunks.isEmpty && path.isEmpty) return null;
      // 统计**按折出来的 diff** 算（`{a,b}`→`{a,c}` 是 +1 −1，不是 +2 −2）。
      var added = 0;
      var removed = 0;
      for (final hunk in hunks) {
        final stat = diffStatOfTexts(hunk.oldText, hunk.newText);
        added += stat.added;
        removed += stat.removed;
      }
      return DiffResultView(
        path: path,
        hunks: hunks,
        added: added,
        removed: removed,
        operation: meta.operation,
      );
    default:
      return null;
  }
}

/// 剥掉文本末尾的状态标记并按 DSH 的 `parseExitStatus` 分类
/// （`ui-tool/src/client/tool/models/terminal-card-model.ts:293-299`）。
///
/// 顺序照它：**先看信号**，再看 exit code，都没有就是 0。
/// 我们多看两种（timeout / stopped），因为 `render.ts:53-56` 会写它们，
/// 而 DSH 的 shell 卡片对那两种走"通用路径"—— 手机上给它们一句话更诚实。
({String output, String? stderr, int? exitCode, String? signal, String? marker})
_parseExitStatus(String raw) {
  var text = raw;
  String? signal;
  int? exitCode;
  String? marker;

  final signalMatch = RegExp(
    r'\n\[killed by signal: ([^\]\n]+)\]$',
  ).firstMatch(text);
  if (signalMatch != null) {
    signal = signalMatch.group(1);
    text = text.substring(0, signalMatch.start);
  } else {
    final exitMatch = RegExp(
      r'\n\[exit code: (-?\d+|null)\]$',
    ).firstMatch(text);
    if (exitMatch != null) {
      final raw = exitMatch.group(1);
      exitCode = raw == 'null' ? null : int.tryParse(raw ?? '');
      text = text.substring(0, exitMatch.start);
    } else {
      // 没有标记 = 正常退出（`render.ts:59` 只为非 0 写标记）。
      exitCode = 0;
    }
  }

  // timeout / stopped 可能排在 exit 标记**之前**（`render.ts:53-56` 的顺序）。
  final tail = RegExp(
    r'\n\[((?:timed out|stopped)[^\]\n]*)\]$',
  ).firstMatch(text);
  if (tail != null) {
    marker = '[${tail.group(1)}]';
    text = text.substring(0, tail.start);
  }

  // `[stderr]` 段单独拿出来（DSH 的 `render.ts:36-40` 用这一行分隔）。
  String? stderr;
  final sep = text.indexOf('\n[stderr]\n');
  if (sep >= 0) {
    stderr = text.substring(sep + '\n[stderr]\n'.length);
    text = text.substring(0, sep);
  }
  return (
    output: text,
    stderr: stderr,
    exitCode: exitCode,
    signal: signal,
    marker: marker,
  );
}
