/// **设备本地 UI 状态的唯一缝**：键、序列化、恢复点、清理与失效都在这里。
///
/// ## 为什么是"一个缝"而不是每个页面各存各的
///
/// 本轮审计（`proposed/2026-10-27-state-semantics-audit.md`）的结论是：状态丢失的根因
/// 不是"忘了写盘"，而是**没有"UI 状态该住哪"的归属模型** —— 于是每个页面各自发明键名、
/// 各自 `read`、各自猜默认值，下一次加功能再漏一遍。
///
/// 所以这里只做一件事：把"属于这台手机的 UI 状态"收成一组**带作用域的键**，
/// 由一处读写、一处迁移、一处清理。UI 层不许再拼键名（`verify-platform-boundary` 的精神）。
///
/// ## 两类键（换电脑时行为不同，这是它们唯一的分界）
///
/// | 前缀 | 例子 | 换电脑（重新配对）时 |
/// |---|---|---|
/// | `device.` | 主题、界面字号、工作步骤密度、收起时机、性能用量 | **保留**（与某台电脑无关） |
/// | `host.` | 上次看的会话、抽屉折叠、每会话页签、每会话草稿 | **整段清空** |
///
/// 判据：一个键如果它的值离开这台电脑就没有意义（会话 id / 工作区 id），它必须是 `host.`。
///
/// ## 读写时机（移动端约束）
///
/// - **读**：`open()` 在**首帧前**跑（`main.dart` 的 `_assemble`），只做固定几次读，
///   不随会话数增长；会话级的值（页签/草稿）在 `openSession(sid)` 时懒读一次。
/// - **写**：非高频值改了立刻写（串行链保证顺序，不在 UI 回调里 `await`）；
///   草稿另有一个防抖口（批 C 接线），因为 sqflite 是异步事务，不能每击键一次。
/// - 语义与取舍见 `proposed/2026-10-27-ui-state-design.md` §2。
library;

import 'dart:async';
import 'dart:convert';

import 'store.dart';

/// 键名**唯一拼写处**。改动等于作废用户的偏好，必须配一次数据迁移。
abstract final class UiKey {
  /// `device.*` 与某台电脑无关。
  static const String devicePrefix = 'device.';

  /// `host.*` 属于某台电脑（重新配对时整段清空）。
  static const String hostPrefix = 'host.';

  static const String themeMode = '${devicePrefix}theme_mode';
  static const String uiScaleIndex = '${devicePrefix}ui_scale_index';
  static const String transcriptView = '${devicePrefix}transcript_view';
  static const String performanceView = '${devicePrefix}performance_view';
  static const String collapseTiming = '${devicePrefix}collapse_timing';

  static const String lastSession = '${hostPrefix}last_session';
  static const String drawerExpansion = '${hostPrefix}drawer_expansion';

  /// 每会话页签：存的是**注册项 id**（`chat` / `trajectory`），不是下标 ——
  /// 桌面存的也是 id（`ui-conversation/src/client/stores.ts:8,23-25`），
  /// 存下标会在页签集合变化时指错。
  static const String sessionViewPrefix = '${hostPrefix}session_view.';

  /// 每会话草稿（形状照桌面的 `DraftSnapshot`，今天只有 `text`）。
  static const String sessionDraftPrefix = '${hostPrefix}session_draft.';

  /// 每会话的**提问作答进度**（哪些题勾了什么、答到第几题）。
  /// 形状与桌面 `draft-store.ts` 的 `progressByRequest` 同构，键用 itemId + questionId。
  static const String questionDraftPrefix = '${hostPrefix}question_draft.';

  static String sessionView(String sid) => '$sessionViewPrefix$sid';

  static String sessionDraft(String sid) => '$sessionDraftPrefix$sid';

  static String questionDraft(String sid) => '$questionDraftPrefix$sid';
}

/// 设备本地 UI 状态。**不是 `ChangeNotifier`**：它的读者是 `AppModel` 与页面，
/// 而"草稿"这类高频值绝不能借通知把整页带起来（见设计 §3）。
class UiStateStore {
  UiStateStore({
    required PreferenceStore prefs,
    Duration draftDebounce = const Duration(milliseconds: 300),
  }) : _prefs = prefs,
       _draftDebounce = draftDebounce;

  final PreferenceStore _prefs;

  String? _themeMode;
  int? _uiScaleIndex;
  String? _transcriptView;
  String? _performanceView;
  String? _collapseTiming;
  String? _lastSession;
  Map<String, bool> _drawerExpansion = const <String, bool>{};

  /// 会话级值的缓存：`sid → 值`。`null` 也是有效值（"这个会话没存过"）。
  final Map<String, String?> _views = <String, String?>{};

  /// 在途草稿（`sid → 正文`）+ 防抖计时器。
  final Map<String, String> _pendingDrafts = <String, String>{};
  Timer? _draftTimer;

  /// 草稿防抖窗口。桌面是**每次变更同步写**（`client/store/src/index.ts:159-165`）——
  /// 那是 `localStorage` 的便宜；sqflite 是异步事务，不能每击键一次。
  /// 代价：进程在窗口内被杀，最多丢这一段内的输入。
  final Duration _draftDebounce;

  /// 串行写：保证"先写的先落盘"，且调用方不必 `await` 在 UI 回调里。
  Future<void> _writes = Future<void>.value();

  /// 首帧前跑一次。**只做固定几次读**（`device.*` 一次范围查 + 两个 host 键），
  /// 不随会话数增长。
  Future<void> open() async {
    final device = await _prefs.readAll(UiKey.devicePrefix);
    _themeMode = device[UiKey.themeMode];
    _uiScaleIndex = int.tryParse(device[UiKey.uiScaleIndex] ?? '');
    _transcriptView = device[UiKey.transcriptView];
    _performanceView = device[UiKey.performanceView];
    _collapseTiming = device[UiKey.collapseTiming];
    _lastSession = await _prefs.read(UiKey.lastSession);
    _drawerExpansion = _decodeExpansion(
      await _prefs.read(UiKey.drawerExpansion),
    );
  }

  // ---- device.*（换电脑保留）----

  String? get themeMode => _themeMode;
  int? get uiScaleIndex => _uiScaleIndex;
  String? get transcriptView => _transcriptView;
  String? get performanceView => _performanceView;
  String? get collapseTiming => _collapseTiming;

  Future<void> setThemeMode(String wire) async {
    if (wire == _themeMode) return;
    _themeMode = wire;
    await _write(UiKey.themeMode, wire);
  }

  Future<void> setUiScaleIndex(int index) async {
    if (index == _uiScaleIndex) return;
    _uiScaleIndex = index;
    await _write(UiKey.uiScaleIndex, '$index');
  }

  Future<void> setTranscriptView(String wire) async {
    if (wire == _transcriptView) return;
    _transcriptView = wire;
    await _write(UiKey.transcriptView, wire);
  }

  Future<void> setPerformanceView(String wire) async {
    if (wire == _performanceView) return;
    _performanceView = wire;
    await _write(UiKey.performanceView, wire);
  }

  Future<void> setCollapseTiming(String wire) async {
    if (wire == _collapseTiming) return;
    _collapseTiming = wire;
    await _write(UiKey.collapseTiming, wire);
  }

  // ---- host.*（换电脑整段清）----

  String? get lastSession => _lastSession;

  /// 记"上次看的会话"；`null` = 删掉（落点判定失败时用，照桌面 `clearMain` 写 `{}`）。
  Future<void> setLastSession(String? sid) async {
    if (sid == _lastSession) return;
    _lastSession = sid;
    if (sid == null) {
      await _enqueue(
        () => _prefs.delete(UiKey.lastSession, includePrefixed: false),
      );
      return;
    }
    await _write(UiKey.lastSession, sid);
  }

  /// 某个工作区组的展开态；`null` = 没记过（调用方按"展开"处理）。
  bool? drawerExpandedOf(String workspaceId) => _drawerExpansion[workspaceId];

  Future<void> setWorkspaceExpanded(String workspaceId, bool expanded) async {
    if (_drawerExpansion[workspaceId] == expanded) return;
    _drawerExpansion = Map<String, bool>.from(_drawerExpansion)
      ..[workspaceId] = expanded;
    await _write(UiKey.drawerExpansion, jsonEncode(_drawerExpansion));
  }

  /// 一个会话的页签 id；`null` = 没存过（调用方回 `chat`）。
  Future<String?> viewOf(String sid) async {
    if (_views.containsKey(sid)) return _views[sid];
    final raw = await _prefs.read(UiKey.sessionView(sid));
    _views[sid] = raw;
    return raw;
  }

  Future<void> setView(String sid, String viewId) async {
    final key = UiKey.sessionView(sid);
    if (_views.containsKey(sid) && _views[sid] == viewId) return;
    _views[sid] = viewId;
    await _write(key, viewId);
  }

  /// 一个会话的草稿正文；`null` = 没存过。
  ///
  /// 盘上是 **JSON**（形状照桌面的 `DraftSnapshot`：`{text, references: []}`，
  /// `ui-conversation/src/client/contract/draft-editor.ts:43-56`）—— 今天只用到 `text`，
  /// 但格式先立住：将来加 `@` chip 不必换盘上格式。
  /// 旧形态（纯字符串）也认；坏数据当"没有"（不抛）。
  Future<String?> sessionDraftOf(String sid) async {
    final pending = _pendingDrafts[sid];
    if (pending != null) return pending.isEmpty ? null : pending;
    final raw = await _prefs.read(UiKey.sessionDraft(sid));
    if (raw == null || raw.isEmpty) return null;
    if (!raw.startsWith('{')) return raw; // 旧形态
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final text = decoded['text'];
      return text is String && text.isNotEmpty ? text : null;
    } on FormatException {
      return null;
    }
  }

  /// 立刻写一个会话的草稿；**空串等于删**（别在盘上留空串）。
  Future<void> setSessionDraft(String sid, String text) async {
    _pendingDrafts.remove(sid);
    if (text.isEmpty) {
      await _enqueue(
        () => _prefs.delete(UiKey.sessionDraft(sid), includePrefixed: false),
      );
      return;
    }
    await _writeDraft(sid, text);
  }

  /// 记一次击键：进待写表并**重启**防抖计时器（同一会话的新输入覆盖旧值）。
  ///
  /// 为什么不在页面里防抖：防抖是"这条通道怎么落盘"的一部分，属于 [UiStateStore]；
  /// 页面只需在"发送成功 / 切会话 / 退后台"时调 [flushDrafts]。
  void noteDraft(String sid, String text) {
    _pendingDrafts[sid] = text;
    _draftTimer?.cancel();
    _draftTimer = Timer(_draftDebounce, () {
      _draftTimer = null;
      // 定时器回调里没有 await 的地方：写失败由 `_enqueue` 的链吞掉并留给
      // 下一次 `flushDrafts()` 的返回 Future（测试与调用方等的是那一个）。
      unawaited(flushDrafts());
    });
  }

  /// 一个会话的**提问作答进度**（JSON；`null` = 没存过）。
  ///
  /// 形状由 `ui/takeover.dart` 决定（`{item, index, questions:{qid:{selected,custom,skipped}}}`），
  /// 这里只当字符串存取 —— 存储层不认识交互语义。
  Future<String?> questionDraftOf(String sid) =>
      _prefs.read(UiKey.questionDraft(sid));

  /// 写一个会话的提问进度；`null` = 删（这一项已收束）。
  Future<void> setQuestionDraft(String sid, String? json) {
    final key = UiKey.questionDraft(sid);
    if (json == null) {
      return _enqueue(() => _prefs.delete(key, includePrefixed: false));
    }
    return _write(key, json);
  }

  /// 把在途草稿立刻写下去（发送后 / 切会话前 / `paused` 时调）。
  Future<void> flushDrafts() async {
    _draftTimer?.cancel();
    _draftTimer = null;
    if (_pendingDrafts.isEmpty) return _writes;
    final batch = Map<String, String>.of(_pendingDrafts);
    _pendingDrafts.clear();
    for (final entry in batch.entries) {
      final key = UiKey.sessionDraft(entry.key);
      if (entry.value.isEmpty) {
        await _enqueue(() => _prefs.delete(key, includePrefixed: false));
      } else {
        await _writeDraft(entry.key, entry.value);
      }
    }
  }

  Future<void> _writeDraft(String sid, String text) => _write(
    UiKey.sessionDraft(sid),
    jsonEncode(<String, Object?>{'text': text, 'references': const []}),
  );

  // ---- 清理与失效 ----

  /// 换电脑：删光 `host.*`（`device.*` 一个不动）。
  Future<void> clearHostScope() async {
    _lastSession = null;
    _drawerExpansion = const <String, bool>{};
    _views.clear();
    await _enqueue(() => _prefs.delete(UiKey.hostPrefix));
  }

  /// 会话从清单消失：删掉它的页签与草稿（别在盘上留死数据）。
  Future<void> pruneSessions(Set<String> liveSids) async {
    for (final sid in _views.keys.toList()) {
      if (liveSids.contains(sid)) continue;
      _views.remove(sid);
      await _enqueue(() async {
        // **精确删**：`sid-1` 是 `sid-10` 的字符串前缀，按前缀删会误伤。
        await _prefs.delete(UiKey.sessionView(sid), includePrefixed: false);
        await _prefs.delete(UiKey.sessionDraft(sid), includePrefixed: false);
      });
    }
    // 没进缓存的会话级键也要扫一遍（比如上次跑完页签没读过）。
    final stored = await _prefs.readAll(UiKey.sessionViewPrefix);
    for (final key in stored.keys) {
      final sid = key.substring(UiKey.sessionViewPrefix.length);
      if (liveSids.contains(sid)) continue;
      await _enqueue(() => _prefs.delete(key, includePrefixed: false));
    }
    final drafts = await _prefs.readAll(UiKey.sessionDraftPrefix);
    for (final key in drafts.keys) {
      final sid = key.substring(UiKey.sessionDraftPrefix.length);
      if (liveSids.contains(sid)) continue;
      await _enqueue(() => _prefs.delete(key, includePrefixed: false));
    }
    // 提问进度同理：会话没了，它的作答进度没有语义。
    final questions = await _prefs.readAll(UiKey.questionDraftPrefix);
    for (final key in questions.keys) {
      final sid = key.substring(UiKey.questionDraftPrefix.length);
      if (liveSids.contains(sid)) continue;
      await _enqueue(() => _prefs.delete(key, includePrefixed: false));
    }
  }

  /// 工作区被删：裁掉它的折叠记忆（照桌面 `retainAccountKeys`，
  /// `ui-workspace/src/client/stores.ts:100-109`）。
  Future<void> pruneWorkspaces(Set<String> liveWorkspaceIds) async {
    final kept = <String, bool>{
      for (final entry in _drawerExpansion.entries)
        if (liveWorkspaceIds.contains(entry.key)) entry.key: entry.value,
    };
    if (kept.length == _drawerExpansion.length) return;
    _drawerExpansion = kept;
    await _write(UiKey.drawerExpansion, jsonEncode(_drawerExpansion));
  }

  /// 等所有在途写落盘（测试与"退到后台"用）。
  Future<void> flush() => _writes;

  Future<void> _write(String key, String value) =>
      _enqueue(() => _prefs.write(key, value));

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _writes.then((_) => action());
    // 一次写失败不许把整条链卡死：错误交给调用方等到的那个 Future。
    _writes = next.catchError((Object _) {});
    return next;
  }

  static Map<String, bool> _decodeExpansion(String? raw) {
    if (raw == null || raw.isEmpty) return const <String, bool>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const <String, bool>{};
      return <String, bool>{
        for (final entry in decoded.entries)
          if (entry.key is String && entry.value is bool)
            entry.key as String: entry.value as bool,
      };
    } on FormatException {
      // 盘上是坏的（手改过 / 老版本过半截）：当没记过，调用方回默认。
      return const <String, bool>{};
    }
  }
}
