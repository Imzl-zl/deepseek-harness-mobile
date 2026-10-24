/// `@` 候选：触发判据、插入文本、线上形状（契约 §5.7 的 `refs.files` / `refs.sessions`）。
///
/// ## 触发判据与宿主一致
///
/// DSH 把 `@` 当**普通文本 token** 扫（`packages/client/ui-conversation/src/client/input/decorations.ts:24-26`）：
///
/// ```text
/// TEXT_REF_RE  = /(^|\s)([/@])([\w-]+)/g
/// FOLDER_REF_RE = /(^|\s)(@(?:"[^"\n]*\/|[^\s"]+\/))/g
/// ```
///
/// 两条正则说的是同一件事：**触发符在草稿开头或空白之后**（"行首或空白之后"），
/// 名字段里**不含空白**（`[\w-]+` 与 `[^\s"]+/`），**不跨行**（`[^"\n]`）。
/// 所以本文件的判据只有这三条 —— 手机不发明"正文中间的 `@` 也算"这种更宽松的规则：
/// 那样选中的候选插进去以后整个 token 还是普通文本（宿主不认），用户会以为引用没生效。
///
/// ## 插入的是什么
///
/// 三条，全是**纯文本**（没有结构化编码，宿主就是这么读的）：
///
/// - 文件 `@path`
/// - 目录 `@path/`（补一个斜杠 —— 与宿主的目录 token 同形，用户接着往里打字）
/// - 会话 **宿主给的 `mention` 原样**（`@[label](dsh-session:<base64url>)`）
///
/// 会话那条**不改一个字符**：URI 是宿主的引用语法，宿主的前置步骤按它解析
/// （`packages/context/session-reference/src/index.ts:143-150`）。自己拼一个
/// `@标题` 只是一个长得像引用的普通文本。
library;

/// 一条候选的种类。
enum AtCandidateKind { file, directory, session }

/// 一条 `@` 候选（文件 / 目录 / 会话）。
class AtCandidate {
  const AtCandidate._({
    required this.kind,
    this.path = '',
    this.sid = '',
    this.title = '',
    this.mention = '',
  });

  /// 解析一行文件候选（`{path, kind}`）；形状认不出给 `null`（**不猜第三种 kind**）。
  static AtCandidate? fromFileRow(Object? row) {
    if (row is! Map) return null;
    final path = row['path'];
    final kind = row['kind'];
    if (path is! String || path.isEmpty) return null;
    if (kind == 'file') {
      return AtCandidate._(kind: AtCandidateKind.file, path: path);
    }
    if (kind == 'directory') {
      return AtCandidate._(kind: AtCandidateKind.directory, path: path);
    }
    return null;
  }

  /// 解析一行会话候选（`{sid, title, mention}`）；`mention` 缺席就整行不要 ——
  /// 没有它可以插的文本，那一行点下去什么也不会发生。
  static AtCandidate? fromSessionRow(Object? row) {
    if (row is! Map) return null;
    final mention = row['mention'];
    if (mention is! String || mention.isEmpty) return null;
    final sid = row['sid'];
    final title = row['title'];
    return AtCandidate._(
      kind: AtCandidateKind.session,
      sid: sid is String ? sid : '',
      title: title is String ? title : '',
      mention: mention,
    );
  }

  final AtCandidateKind kind;

  /// 文件 / 目录的路径（会话行为空）。
  final String path;

  /// 会话别名（文件行为空）。
  final String sid;

  /// 会话标题（文件行为空）。
  final String title;

  /// 宿主编好的引用文本（文件行为空）。
  final String mention;

  /// 面板上显示的那一行。
  String get label => switch (kind) {
    AtCandidateKind.file || AtCandidateKind.directory => path,
    AtCandidateKind.session => title.isEmpty ? sid : title,
  };

  /// 行首那枚图标（宿主 `ReferenceIconRegular` 的三档，`ui-primitives/src/ReferenceIcon.tsx:25-30`）。
  ///
  /// 三个字形**逐字对应**宿主的三种 artwork，不是"最接近的一个"：
  /// 目录 = `FolderCloseArtwork`（`folderClose`）、文件 = `BrowseOutlineArtwork`
  /// （`browse`）、会话 = `ChatLinesOutlineArtwork`（同文件 `:13-19`，
  /// 注释原话 "matches the `queue-outline` product glyph" ⇒ 我们图标集里的 `queue`）。
  String get icon => switch (kind) {
    AtCandidateKind.directory => 'folderClose',
    AtCandidateKind.file => 'browse',
    AtCandidateKind.session => 'queue',
  };

  /// 分组标题（宿主的行内 `section`，`ui-reference/src/client/index.ts:258,288`）。
  ///
  /// 用宿主 zh 词典的原话（`ui-reference/src/client/locales.ts` 的
  /// `section.files` / `section.sessions`），不另起一套中文。
  String get section => switch (kind) {
    AtCandidateKind.file || AtCandidateKind.directory => kSectionFiles,
    AtCandidateKind.session => kSectionSessions,
  };

  /// 行上显示的名字：路径最后一段，**目录带一个尾斜杠**
  /// （宿主 `fileCandidate` 的 `name`，`ui-reference/src/client/index.ts:253`）。
  String get displayName {
    if (kind == AtCandidateKind.session) return label;
    final trimmed = _trimSlash(path);
    final slash = trimmed.lastIndexOf('/');
    final name = slash < 0 ? trimmed : trimmed.substring(slash + 1);
    return kind == AtCandidateKind.directory ? '$name/' : name;
  }

  /// 行右侧的说明 = **父目录**（宿主同一条：`:242-256`，
  /// "The location is the parent alone"）。
  ///
  /// 根目录下的候选没有父目录 ⇒ 空串（那一行不摆说明，不是摆一个空串占位）。
  /// 会话行没有位置信息（`refs.sessions` 只回 `{sid,title,mention}`）⇒ 空串。
  String get parent {
    if (kind == AtCandidateKind.session) return '';
    final trimmed = _trimSlash(path);
    final slash = trimmed.lastIndexOf('/');
    return slash < 0 ? '' : trimmed.substring(0, slash);
  }

  /// 选中后**插进输入框的纯文本**。这是唯一一处决定"目录补斜杠、文件不补、
  /// 会话用宿主原样"的地方。
  String get insertion => switch (kind) {
    AtCandidateKind.file => '@$path',
    AtCandidateKind.directory => path.endsWith('/') ? '@$path' : '@$path/',
    AtCandidateKind.session => mention,
  };
}

/// 分组标题：文件与文件夹（宿主 zh 词典 `section.files` 的原话）。
const String kSectionFiles = '文件与文件夹';

/// 分组标题：对话（宿主 zh 词典 `section.sessions` 的原话）。
const String kSectionSessions = '对话';

/// 面包屑最左那一段的文案（宿主 zh 词典 `crumb.root` 的原话）。
const String kCrumbRoot = '工作区';

/// 一截面包屑的一段。
///
/// 宿主把 crumb 的 `value` 当"候选的 drill 载荷"原样还给 `onPick`
/// （`ui-input-trigger/src/types.ts:169-180`），所以这里只存**插回输入框的文本**：
/// 根 = `@`，第 n 段 = `@a/b/`（与目录 mention 同形，`file-reference/grammar.ts` 的
/// `formatFileMention`）。
class AtCrumb {
  const AtCrumb({
    required this.label,
    required this.insertion,
    this.current = false,
  });

  final String label;

  /// 点它之后替换掉 `@…` 那一段 token 的文本。
  final String insertion;

  /// 列表此刻就停在这一层 ⇒ 它是一段标签，不是可点的入口（宿主 `crumbCurrent`）。
  final bool current;
}

/// drill 之后的面包屑；`null` = 这一屏不该有面包屑。
///
/// 与宿主 `crumbsFor` 逐条对齐（`ui-reference/src/client/index.ts:199-226`）：
///
/// 1. **没 drill 就整条不出现**（`if (!drilled) return undefined`）—— 手打的路径
///    自带上下文（就在草稿里），而 drill 把用户正在读的文本换成了更深的一段，
///    欠他一条回去的路；
/// 2. 查询串里**没有 `/`** 也不出现（还在工作区根挑东西，没有"上一层"）；
/// 3. 根 + 各段，最后一段是 `current`（不可点）。
List<AtCrumb>? atCrumbsOf(String query, {required bool drilled}) {
  if (!drilled) return null;
  final slash = query.lastIndexOf('/');
  if (slash < 0) return null;
  final segments = query
      .substring(0, slash)
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
  return [
    const AtCrumb(label: kCrumbRoot, insertion: '@'),
    for (var index = 0; index < segments.length; index += 1)
      AtCrumb(
        label: segments[index],
        insertion: '@${segments.take(index + 1).join('/')}/',
        current: index == segments.length - 1,
      ),
  ];
}

/// 去掉尾部斜杠（宿主的目录候选**不带**尾斜杠，`file-reference-local/src/search.ts:248`；
/// 而手机侧的测试替身里两种都出现过 —— 显示前统一一次，别让 `/` 与 `//` 两种形状各算一遍）。
String _trimSlash(String path) {
  var end = path.length;
  while (end > 0 && path[end - 1] == '/') {
    end -= 1;
  }
  return path.substring(0, end);
}

/// 一次查询的两半（文件/目录 + 会话）。
class AtCandidates {
  const AtCandidates({this.files = const [], this.sessions = const []});

  final List<AtCandidate> files;
  final List<AtCandidate> sessions;

  /// 面板要画的行：文件在前（它们是 `@` 最常见的用法），会话在后。
  List<AtCandidate> get all => [...files, ...sessions];

  bool get isEmpty => files.isEmpty && sessions.isEmpty;
}

/// 一次候选查询的结论。
///
/// **两种"没有"不是一回事**：`candidates.isEmpty` = 电脑侧说"没有匹配"（空态），
/// `error != null` = 这次没查成（失败态，显示电脑侧给的原因）。
/// 把失败画成空列表，用户会以为自己路径打错了。
class MentionQueryResult {
  const MentionQueryResult({this.candidates, this.error});

  /// 查到的候选；`null` = 这次没查成。
  final AtCandidates? candidates;

  /// 失败原因（电脑侧的原话）。
  final String? error;
}

bool _isSpace(String unit) => RegExp(r'\s').hasMatch(unit);

/// `input` 里正在输入的 `@` token：返回它的起点与该 token 的查询串；
/// `null` = 此刻不该出候选。
///
/// 判据三条（与宿主 `decorations.ts:24-26` 的两条正则同一件事）：
/// 触发符在**草稿开头或空白之后**、token 里**不含空白**（于是也不跨行）、
/// 取的是**最后一个** `@`（正在打的那个）。
({int at, String query})? atTriggerOf(String input) {
  final at = input.lastIndexOf('@');
  if (at < 0) return null;
  if (at > 0 && !_isSpace(input.substring(at - 1, at))) return null;
  final query = input.substring(at + 1);
  if (query.isNotEmpty && query.split('').any(_isSpace)) return null;
  return (at: at, query: query);
}

/// 只取查询串（面板的输入）；`null` = 此刻不该出候选。
String? atQueryOf(String input) => atTriggerOf(input)?.query;

/// 把选中的候选插进草稿：**只替换那一个 token**，前面的文字原样留着。
///
/// 认不出触发位置时**原样返回**（不猜一个位置去改用户的文本）。
String insertAtMention(String input, AtCandidate candidate) =>
    insertAtToken(input, candidate.insertion);

/// 把 `@…` 那一段 token 换成 [text]。
///
/// 只有两处会用它：落定（[insertAtMention]）与 drill / 面包屑（宿主把 drill 的载荷
/// 也叫 "text"，`ui-reference/src/client/index.ts:138-140`）—— 两者都是"换掉那一段"，
/// 所以替换规则只有这一份。认不出触发位置时**原样返回**。
String insertAtToken(String input, String text) {
  final trigger = atTriggerOf(input);
  if (trigger == null) return input;
  return input.substring(0, trigger.at) + text;
}
