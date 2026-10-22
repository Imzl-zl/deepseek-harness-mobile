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

/// 从 `tool/result` 的载荷里解析出专用视图；`null` = 走通用卡。
///
/// [data] 是 `tool/result` 的 `data`（含 `message` 与 `meta`）。
ToolResultView? toolResultViewOf({
  required String name,
  required Object? data,
}) {
  final meta = _field(data, 'meta');
  final text = _contentText(_field(_field(data, 'message'), 'content'));

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
      final lines = _field(meta, 'lines');
      if (lines is! List || lines.isEmpty) {
        // 没有结构化窗口（老结果 / 第三方适配器）：退回通用卡，别装作有行号。
        return null;
      }
      return ReadResultView(
        path: _string(_field(meta, 'path')) ?? '',
        offset: _int(_field(meta, 'offset')) ?? 1,
        lines: [
          for (final line in lines)
            if (line is Map)
              FileTextLine(
                _int(line['number']) ?? 0,
                _string(line['text']) ?? '',
              ),
        ],
        totalLines: _int(_field(meta, 'totalLines')),
        lang: _string(_field(meta, 'lang')),
      );
    case 'edit' || 'write':
      final hunks = _parseHunks(_field(meta, 'diffs'));
      final path = _string(_field(meta, 'path')) ?? '';
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
        operation: _string(_field(meta, 'operation')),
      );
    default:
      return null;
  }
}

/// 解析 hunk 列表（`{path, oldText, newText}`）。
List<DiffHunk> _parseHunks(Object? raw) {
  if (raw is! List) return const [];
  final out = <DiffHunk>[];
  for (final item in raw) {
    if (item is! Map) continue;
    out.add(
      DiffHunk(
        path: _string(item['path']) ?? '',
        oldText: _string(item['oldText']) ?? '',
        newText: _string(item['newText']) ?? '',
      ),
    );
  }
  return out;
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

Object? _field(Object? value, String key) => value is Map ? value[key] : null;

String? _string(Object? value) => value is String ? value : null;

int? _int(Object? value) => switch (value) {
  int() => value,
  num() => value.toInt(),
  _ => null,
};

/// `message.content` 的文本块（与 `data/projection.dart` 的 `textOfContent` 同一条规则：
/// 只取 `type == 'text'`，不把 reasoning 混进来）。
String _contentText(Object? content) {
  if (content is String) return content;
  if (content is! List) return '';
  final buffer = StringBuffer();
  for (final block in content) {
    if (block is Map && block['type'] == 'text') {
      final text = block['text'];
      if (text is String) buffer.write(text);
    } else if (block is String) {
      buffer.write(block);
    }
  }
  return buffer.toString();
}
