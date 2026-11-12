/// 会话条目表（内存态）+ 变更通知。
///
/// ## 它解决什么
///
/// `core/` 交出的是**一次变更**（`SessionDelta`：这一批到了哪几条），
/// 而 UI 要的是**当前完整列表**（并据此重建最小子树）。
/// 本类就是这两者之间的那一层：把增量**归并**成"当前状态"，并在变的时候通知。
///
/// ## 三条纪律
///
/// 1. **upsert-only**（契约 §5.2）：同一个 `itemId` 再出现是**覆盖**，不是追加。
///    追加会让"工具调用 + 它的结果"显示成两条，而它们本该是一条的两个状态。
/// 2. **顺序按 `seq` 升序**：`seq` 是 DSH 的会话修订号（会话内单调）。
///    按插入顺序排会让快照收口时的合并顺序影响显示（那正是"UI 闪回旧内容"的成因）。
/// 3. **通知合并到下一帧**：一次恢复可能带来几十条 `upsert`，
///    每条都通知会让 UI 在一帧里重建几十次。用"脏标记 + 微任务"合并（见 [flush]）。
///
/// ## 为什么不是直接给 UI 一个 `List`
///
/// 因为可变列表会让"谁改了它"无从追溯，而 Flutter 的重建判断依赖
/// "引用变了没有"。这里给的是**不可变副本**（[items]），
/// 每次变更产出**新列表** —— 于是 `identical(old, new)` 就是"变了没有"。
library;

import 'dart:async';

import '../model/chat_item.dart';

/// 一个会话的条目表。
class SessionStore {
  SessionStore(this.sid);

  /// 会话别名。
  final String sid;

  /// `itemId → 条目`。用 Map 做 upsert，用 `_order` 记顺序。
  final Map<String, ChatItem> _byId = {};

  /// 按 `seq` 升序的缓存列表（[items] 直接返回它，避免每次调用都重排）。
  List<ChatItem> _sorted = const <ChatItem>[];

  bool _dirty = false;
  final StreamController<List<ChatItem>> _changes =
      StreamController<List<ChatItem>>.broadcast();

  /// 当前条目（**不可变快照**，可直接用于 `ListView.builder`）。
  ///
  /// 返回的是同一个 List 实例直到下次变更 —— 于是 UI 可以用 `identical` 判断
  /// "要不要重建"，而不必做深比较。
  List<ChatItem> get items => _sorted;

  /// 条目数（**含已放掉的那些**）：[compact] 之后仍然是同一个数。
  ///
  /// 抽屉行与 `_touchSummary` 读它；少了这一条，压缩一下就会把"N 条"变成 0。
  int get length => _droppedCount + _sorted.length;

  /// 手里有没有**可见**条目（口径与 `ui/chat_page.dart` 的 hero 判据一致：
  /// `OtherItem` 不算）。
  ///
  /// **必须是事实，不能等于 `items.isNotEmpty`**：`sessionBlankOf` 靠它判定
  /// "宿主说 blank、但我手里有东西"，而正文可以被 [compact] 放掉 ——
  /// 那时事实还在（[_droppedVisible]），只是正文不在内存里。
  bool get hasVisibleItems =>
      _droppedVisible || _sorted.any((item) => item is! OtherItem);

  /// 已经放掉过正文（`_restoreLocalHistory` 据此允许从本地库重新回填）。
  bool get isCompacted => _droppedCount > 0;

  /// 变更流（每次归并后发一次，**已合并到微任务**）。
  Stream<List<ChatItem>> get changes => _changes.stream;

  /// 取一条。
  ChatItem? byId(String itemId) => _byId[itemId];

  /// 归并一批条目（upsert-only）。
  ///
  /// 返回**是否有实际变化**：同一个 `itemId` 内容完全相同时不算变化 ——
  /// 少了这一条，重放同一批事件会让 UI 白重建一次（而重放是常态：
  /// §5.1 明写"同一个 `seq` 会经两条读路径各出现一次"）。
  bool upsertAll(Iterable<ChatItem> incoming) {
    var changed = false;
    for (final item in incoming) {
      final existing = _byId[item.itemId];
      if (existing != null && _sameContent(existing, item)) continue;
      _byId[item.itemId] = item;
      changed = true;
    }
    if (!changed) return false;
    _resort();
    _markDirty();
    return true;
  }

  /// 整体替换（快照收口用，契约 §5.4 规则 4：分页期间不渲染，收口时整体换）。
  ///
  /// **"整份换掉"包括标量**：`compact()` 攒下的计数与"有可见条目"标记必须归零，
  /// 否则这批条目数会翻倍（`length` = 旧计数 + 新条目）。
  void replaceAll(Iterable<ChatItem> incoming) {
    _droppedCount = 0;
    _droppedVisible = false;
    _droppedUpdatedAt = 0;
    _byId
      ..clear()
      ..addEntries(incoming.map((item) => MapEntry(item.itemId, item)));
    _resort();
    _markDirty();
  }

  /// 放掉**正文**，只留三个事实：条目数、有没有过可见条目、最新时刻。
  ///
  /// ## 为什么是"放正文"而不是"把整张表删掉"
  ///
  /// `_stores` 不只是渲染缓存：抽屉的 `itemCount` / `pendingCount`、
  /// `sessionBlankOf` 的判据、通知里"谁在等我"都从它读。整表删掉等于把
  /// **事实**也删了，症状是"抽屉全归零"与"新建会话点了没反应"复发。
  /// 所以只丢正文（几十上百 KB），事实留成三个标量（几十字节）。
  ///
  /// ## 调用方必须保证的前提
  ///
  /// **不在看、不在跑、没有待处理、且本地库读得回来**（见
  /// `AppModel._compactIdleSessions` 的三个条件）。
  /// 放掉的正文靠 `_restoreLocalHistory` 下次打开时从 sqflite 回填。
  ///
  /// ## 为什么**不发**变更通知
  ///
  /// 压缩只发生在非当前会话上，而 `changes` 的消费者是"正在渲染的那一屏"。
  /// 发一次空列表只会在切换的那一帧里让旧屏幕闪一下空白 —— 没有收益。
  void compact() {
    if (_sorted.isEmpty) return;
    _droppedCount += _sorted.length;
    for (final item in _sorted) {
      if (item is! OtherItem) {
        _droppedVisible = true;
      }
      if (item.updatedAt > _droppedUpdatedAt) {
        _droppedUpdatedAt = item.updatedAt;
      }
    }
    _byId.clear();
    _sorted = const <ChatItem>[];
    _pendingCacheSource = null;
    _updatedCacheSource = null;
  }

  int _droppedCount = 0;
  bool _droppedVisible = false;
  int _droppedUpdatedAt = 0;

  /// 清空（退订时调）。
  ///
  /// 同 [replaceAll]：标量也归零（`clear` 的语义是"这个会话在这里什么都没有了"）。
  void clear() {
    if (_byId.isEmpty && _droppedCount == 0) return;
    _byId.clear();
    _droppedCount = 0;
    _droppedVisible = false;
    _droppedUpdatedAt = 0;
    _sorted = const <ChatItem>[];
    _pendingCacheSource = null;
    _updatedCacheSource = null;
    _markDirty();
  }

  /// 释放（**幂等**）。
  Future<void> dispose() async {
    if (_changes.isClosed) return;
    await _changes.close();
  }

  /// 待处理（审批未决定）计数，UI 角标用。
  ///
  /// ## 为什么要缓存（2026-10-20）
  ///
  /// 它要扫**全部条目**，而 `AppModel` 在**每次刷新会话列表**时对**每个会话**
  /// 各问一次（`app_model.dart:1473`）—— 流式输出期间每帧都会刷新，
  /// 于是每帧把已加载的条目全扫一遍。
  ///
  /// 失效判据用 `_sorted` 的**同一性**：`_resort()` 每次都换成新的
  /// `List.unmodifiable`（`:118`），所以 `identical` 为假就等于条目真的变了。
  /// **不加修订计数** —— 那会多一个可能与真实状态漂移的真值。
  int get pendingCount {
    if (identical(_pendingCacheSource, _sorted)) return _pendingCache;
    var count = 0;
    for (final item in _sorted) {
      if (item is ApprovalItem && !item.decided) count += 1;
    }
    _pendingCacheSource = _sorted;
    _pendingCache = count;
    return count;
  }

  List<ChatItem>? _pendingCacheSource;
  int _pendingCache = 0;

  /// 最后更新时刻（取最大 `updatedAt`；空表返回 0）。
  ///
  /// 缓存的理由与 [pendingCount] 一样（它也被逐会话问）。
  int get updatedAt {
    if (identical(_updatedCacheSource, _sorted)) return _updatedCache;
    var newest = _droppedUpdatedAt;
    for (final item in _sorted) {
      if (item.updatedAt > newest) newest = item.updatedAt;
    }
    _updatedCacheSource = _sorted;
    _updatedCache = newest;
    return newest;
  }

  List<ChatItem>? _updatedCacheSource;
  int _updatedCache = 0;

  void _resort() {
    final next = _byId.values.toList()..sort((a, b) => a.seq.compareTo(b.seq));
    _sorted = List<ChatItem>.unmodifiable(next);
  }

  /// 内容相同吗（**不比 `seq` 与 `updatedAt`**）。
  ///
  /// 只比"看得见的部分"：重放同一条事件时 `seq` 相同但 `updatedAt` 可能不同
  /// （DSH 的两个读路径给的时间戳可以差一点），而界面上没有任何区别 ——
  /// 比时间戳会让 UI 白白重建。
  ///
  /// **新字段必须进这里**（`detail` / `diffStat` / `attachmentCount` /
  /// `steering` / `reasoning`）：漏一个的症状是"结果到了但展开区是空的"——
  /// upsert 认为内容没变，于是不更新。
  static bool _sameContent(ChatItem a, ChatItem b) {
    if (a.runtimeType != b.runtimeType) return false;
    return switch ((a, b)) {
      (final MessageItem x, final MessageItem y) =>
        x.role == y.role &&
            x.text == y.text &&
            x.attachmentCount == y.attachmentCount &&
            x.steering == y.steering &&
            x.reasoning == y.reasoning &&
            x.systemLabel == y.systemLabel &&
            x.systemHint == y.systemHint &&
            x.trigger == y.trigger &&
            x.systemIcon == y.systemIcon,
      (final ToolCallItem x, final ToolCallItem y) =>
        x.name == y.name &&
            x.status == y.status &&
            x.summary == y.summary &&
            x.detail == y.detail &&
            _sameDiffStat(x.diffStat, y.diffStat),
      (final ApprovalItem x, final ApprovalItem y) =>
        x.title == y.title &&
            x.decided == y.decided &&
            x.decision == y.decision,
      (final OtherItem x, final OtherItem y) => x.eventType == y.eventType,
      _ => false,
    };
  }

  static bool _sameDiffStat(
    ({int added, int removed})? a,
    ({int added, int removed})? b,
  ) =>
      (a == null && b == null) ||
      (a != null && b != null && a.added == b.added && a.removed == b.removed);

  /// 打脏标记，并把通知**合并到微任务**。
  ///
  /// 合并的理由：一次恢复可能带几十条事件，逐条通知会让 UI 在一帧里重建几十次
  /// （Flutter 会把它们都排进同一个 frame，但那几十次 `setState` 的开销还在）。
  void _markDirty() {
    if (_dirty) return;
    _dirty = true;
    scheduleMicrotask(flush);
  }

  /// 立即发出当前快照（测试与"必须立刻看到"的场景用）。
  void flush() {
    if (!_dirty) return;
    _dirty = false;
    if (_changes.isClosed) return;
    _changes.add(_sorted);
  }
}
