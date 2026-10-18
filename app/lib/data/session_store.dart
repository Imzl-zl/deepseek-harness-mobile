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

  /// 条目数。
  int get length => _sorted.length;

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
  void replaceAll(Iterable<ChatItem> incoming) {
    _byId
      ..clear()
      ..addEntries(incoming.map((item) => MapEntry(item.itemId, item)));
    _resort();
    _markDirty();
  }

  /// 清空（退订时调）。
  void clear() {
    if (_byId.isEmpty) return;
    _byId.clear();
    _sorted = const <ChatItem>[];
    _markDirty();
  }

  /// 释放（**幂等**）。
  Future<void> dispose() async {
    if (_changes.isClosed) return;
    await _changes.close();
  }

  /// 待处理（审批未决定）计数，UI 角标用。
  int get pendingCount =>
      _sorted.whereType<ApprovalItem>().where((a) => !a.decided).length;

  /// 最后更新时刻（取最大 `updatedAt`；空表返回 0）。
  int get updatedAt {
    var newest = 0;
    for (final item in _sorted) {
      if (item.updatedAt > newest) newest = item.updatedAt;
    }
    return newest;
  }

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
            x.systemLabel == y.systemLabel,
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
