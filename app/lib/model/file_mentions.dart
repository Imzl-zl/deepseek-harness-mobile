/// 正文里的文件提及：**唯一一处解析器**（纯函数，无 UI、无网络）。
///
/// ## 判据从哪来（不是我们发明的规则）
///
/// DSH 的解析器 `producedFileMentions`
/// （`packages/client/ui-deliverables/src/client/turn-deliverables.ts:269-296`）：
///
/// - 词表是**这一轮产出/交付的路径**，不是工作区文件清单
///   （README 原话 "inline-code matching remains limited to produced or delivered files"）；
/// - 命中的条件只有两条：`path === value` 或 `basename(path) === value`；
/// - **命中恰好一条**才 resolve；歧义（同名 basename）与未知都保持惰性；
/// - 只有**行内代码**是候选 —— 围栏代码块里是用户要读的源码
///   （渲染层只对 `inlineCode` 节点查词表，`ui-primitives/src/markdown/render.tsx:335-366`）。
///
/// Note: 词表为什么限在"这一轮"、为什么不让我们自己拼 cwd —— 见
/// `.agents/notes/implemented/2026-10-26-file-mentions-and-open-file.md`
///
/// ## 这一层在复刻什么、不在复刻什么
///
/// 复刻的是**桌面前端的展示规则**（`producedFileMentions` 也在浏览器/客户端里跑）：
/// "哪一串 token 看起来指向一个已知文件"是读法问题，不是文件语义。
/// **不在手机复刻的**是文件本身那一半：真实性（在不在、是不是二进制）、
/// 工作区归属、这一轮到底改了什么 —— 那些是电脑的结论，手机照收
/// （打开走宿主的 `workspaceFiles.read`，改动以 `workspace/changes` 的记录为准）。
///
/// 所以这里做三件事：找出行内代码 span、归一它的值、按词表做**唯一命中**判定。
/// 词表从哪来（`AppModel.changedFiles` 按轮过滤）是调用方的事，本文件不认识数据源。
///
/// ## 为什么自己扫行内代码，而不是复用 Markdown 渲染器
///
/// `flutter_markdown_plus` 在 `builders` 里只给到**元素**（`md.Element`），
/// 不给"这个元素在原文里的位置"，也不给"哪些 token 该是链接"的判断。
/// 判断集中在渲染回调里会变成"每个 widget 一套正则"（这正是要避免的）——
/// 所以位置与词表判定在这一层，渲染层只按 `token → path` 查表。
///
/// 扫描规则照 CommonMark 的 code span（`markdown-7.3.1` 的
/// `code_span_syntax`）：开闭反引号串**长度必须相等**，内容换行归一成空格、
/// 首尾各剥一层空格。围栏判据与 `ui/dsh_markdown.dart` 的 `normalizeInlineHtml`
/// 同一套（3 个及以上的 `` ` `` 或 `~`，最多 3 个前导空格）。
library;

import 'file_open.dart' show fileNameOf;

/// 一处命中：命中的路径 + 它在原文里的位置。
class FileMentionSpan {
  const FileMentionSpan({
    required this.start,
    required this.end,
    required this.token,
    required this.path,
  });

  /// 行内代码**内容**在原文里的起点（开反引号串之后）。
  final int start;

  /// 内容在原文里的终点（闭反引号串之前）。
  final int end;

  /// 归一后的 token（换行 → 空格、首尾各剥一层空格）。
  final String token;

  /// 词表里被命中的那一条（原样，不规范化）。
  final String path;

  @override
  String toString() => 'FileMentionSpan($token → $path @$start-$end)';
}

/// 在 [text] 里找出行内代码中**唯一命中** [knownPaths] 的 token。
///
/// - [knownPaths] 是"这一轮产出/交付的路径"（调用方给）；
/// - 歧义与未知**不进结果**（认不出就保持惰性，与 DSH 同一条）；
/// - 顺序按出现位置（先出现的在前）。
List<FileMentionSpan> resolveFileMentions(
  String text, {
  required Iterable<String> knownPaths,
}) {
  final paths = knownPaths
      .where((path) => path.isNotEmpty)
      .toList(growable: false);
  if (text.isEmpty || paths.isEmpty) return const <FileMentionSpan>[];

  // 围栏内的字符先标出来：行内代码扫描跳过它们，跨围栏的配对也一律不成立。
  final fenced = _fencedMask(text);
  final out = <FileMentionSpan>[];
  var i = 0;
  while (i < text.length) {
    if (fenced[i]) {
      i += 1;
      continue;
    }
    if (text[i] != '`') {
      i += 1;
      continue;
    }
    // 开串长度。
    var open = i;
    while (open < text.length && text[open] == '`') {
      open += 1;
    }
    final runLength = open - i;
    final close = _closingRun(
      text,
      from: open,
      runLength: runLength,
      fenced: fenced,
    );
    if (close == null) {
      // 没有等长的闭串 ⇒ 这串反引号是普通字符（CommonMark 的行为）。
      i = open;
      continue;
    }
    final token = _normalizeCodeSpan(text.substring(open, close));
    final path = _uniqueMatch(token, paths);
    if (path != null) {
      out.add(
        FileMentionSpan(start: open, end: close, token: token, path: path),
      );
    }
    i = close + runLength;
  }
  return out;
}

/// `token → path` 一张表：渲染层按行内代码的文本查它。
///
/// 同一 token 命中同一路径多次只留一条（同一个文件在一段正文里点几次都打开同一处）。
Map<String, String> fileMentionTargets(Iterable<FileMentionSpan> spans) {
  final out = <String, String>{};
  for (final span in spans) {
    out[span.token] = span.path;
  }
  return out;
}

/// 唯一条目（**恰好一条**才算命中；`null` = 未知或歧义）。
String? _uniqueMatch(String token, List<String> paths) {
  if (token.isEmpty) return null;
  String? found;
  for (final path in paths) {
    if (path != token && _basename(path) != token) continue;
    if (found != null && found != path) return null; // 歧义：不猜
    found = path;
  }
  return found;
}

/// 末尾那段路径（**与侧栏标题同一个实现**，见 `model/file_open.dart` 的 [fileNameOf]）。
String _basename(String path) => fileNameOf(path);

/// 归一一个 code span 的内容（CommonMark）：换行 → 空格、首尾各剥一层空格。
///
/// **公开**：渲染层拿到的 `inlineCode` 文本可能已被 Markdown 解析器归一过，
/// 也可能没有 —— 两次归一必须同一条规则，否则 `token → path` 的表会查不中。
String normalizeCodeSpan(String raw) => _normalizeCodeSpan(raw);

String _normalizeCodeSpan(String raw) {
  var content = raw
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\n', ' ');
  if (content.length >= 2 &&
      content.startsWith(' ') &&
      content.endsWith(' ') &&
      content.trim().isNotEmpty) {
    content = content.substring(1, content.length - 1);
  }
  return content;
}

/// 从 [from] 起找**长度恰为** [runLength] 的反引号串（内容里出现的长串不算闭合）。
int? _closingRun(
  String text, {
  required int from,
  required int runLength,
  required List<bool> fenced,
}) {
  var i = from;
  while (i < text.length) {
    if (fenced[i]) return null; // 跨围栏的配对不成立
    if (text[i] != '`') {
      i += 1;
      continue;
    }
    var end = i;
    while (end < text.length && text[end] == '`') {
      end += 1;
    }
    if (end - i == runLength) return i;
    i = end;
  }
  return null;
}

/// 围栏内的字符掩码（含围栏行本身）。
///
/// 判据与 `ui/dsh_markdown.dart` 的 `_fenceLine` 同一条：
/// `^ {0,3}(`{3,}|~{3,})(.*)$`；闭围栏要求同记号、不短于开围栏、记号后只有空白；
/// **未闭合的围栏一直算围栏内**（流式途中就是这样，与 CommonMark 一致）。
List<bool> _fencedMask(String text) {
  final mask = List<bool>.filled(text.length, false);
  var lineStart = 0;
  String? fenceChar;
  var fenceLength = 0;
  while (lineStart <= text.length) {
    final newline = text.indexOf('\n', lineStart);
    final lineEnd = newline == -1 ? text.length : newline;
    final line = text.substring(lineStart, lineEnd);
    final match = _fenceLine.firstMatch(line);
    final run = match?.group(1);
    final rest = match?.group(2) ?? '';
    if (fenceChar == null) {
      if (run != null) {
        fenceChar = run[0];
        fenceLength = run.length;
        _mark(mask, lineStart, lineEnd);
      }
    } else {
      _mark(mask, lineStart, lineEnd);
      if (run != null &&
          run[0] == fenceChar &&
          run.length >= fenceLength &&
          rest.trim().isEmpty) {
        fenceChar = null;
        fenceLength = 0;
      }
    }
    if (newline == -1) break;
    lineStart = newline + 1;
  }
  return mask;
}

void _mark(List<bool> mask, int start, int end) {
  for (var i = start; i < end && i < mask.length; i += 1) {
    mask[i] = true;
  }
}

final RegExp _fenceLine = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');
