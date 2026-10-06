/// 应用级状态（`ChangeNotifier`），UI 的唯一数据入口。
///
/// ## 为什么是 `ChangeNotifier` 而不是引第三方状态管理
///
/// Flutter 官方就带 `ChangeNotifier` + `ListenableBuilder`，而它满足这里的全部需求：
/// **一个 owner、若干只读投影、变更时通知**。引 Riverpod / Bloc 会多一层概念，
/// 而本项目的状态形状很简单（会话列表 + 一个当前会话 + 连接状态）。
/// 换状态管理库是"以后真需要时再换"的决定，不是开工前必须定的事。
///
/// 先例：Flutter 官方的 `provider` 包就是 `ChangeNotifier` 的薄包装，
/// 而它的 README 明说"`ChangeNotifier` 可访问性高、易于理解与实现"。
///
/// ## 它做三件事
///
/// 1. **持有 `SyncClient`**（连接、订阅、写操作全走它）；
/// 2. **把 `SessionDelta` 归并进 `SessionStore`**（UI 读 store 的不可变快照）；
/// 3. **暴露连接状态与错误**，供界面显示。
///
/// 它**不做**：不认识帧、不解析事件（那是 `data/projection.dart` 的事）、
/// 不做重连（那是 `core/` 的事）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/connection.dart';
import '../core/errors.dart';
import '../core/sync_client.dart';
import '../model/chat_item.dart';
import 'projection.dart';
import 'session_store.dart';

/// 应用级状态。
///
/// ## 名字为什么是 `AppModel` 而不是 `AppState`
///
/// `core/sync_client.dart` 已经有一个 `AppState` —— 那是**前后台状态**
/// （`foreground` / `background`，决定要不要维持连接与发心跳，契约 §2.2）。
/// 两者同名会让 `import` 冲突（实测编译报 `ambiguous_import`），
/// 而更糟的是**读代码时分不清哪个是哪个**：一个是协议层的输入，一个是数据层的 owner。
///
/// 所以按职责命名：`AppState` 留给协议层（契约里已经这么叫），
/// 这里叫 `AppModel`（"界面要读的那份应用模型"）。
class AppModel extends ChangeNotifier {
  AppModel({required this.client});

  /// 通道客户端（连接 / 订阅 / 写操作的唯一 owner）。
  final SyncClient client;

  final Map<String, SessionStore> _stores = {};

  /// 会话列表（**电脑侧不返回标题**，标题由本地从条目推导 —— 见 `SessionSummary.title`）。
  List<SessionSummary> _sessions = const [];

  /// 当前打开的会话（`null` = 在列表页）。
  String? _currentSid;

  ConnectionStateView _connection = ConnectionStateView.idle;

  /// 最近一次错误（界面显示用；`null` = 没有）。
  ProtocolException? _lastError;

  StreamSubscription<ConnectionState>? _stateSub;
  final Map<String, StreamSubscription<SessionDelta>> _deltaSubs = {};

  bool _disposed = false;

  /// 会话列表（只读快照）。
  List<SessionSummary> get sessions => _sessions;

  /// 当前会话的条目（只读快照；没打开会话时是空表）。
  List<ChatItem> get items =>
      _currentSid == null ? const [] : _storeOf(_currentSid!).items;

  /// 当前会话 id。
  String? get currentSid => _currentSid;

  /// 连接状态（界面视图）。
  ConnectionStateView get connection => _connection;

  /// 最近一次错误。
  ProtocolException? get lastError => _lastError;

  /// 当前会话的变更流（UI 用它做**区块级**重建，而不是整页 setState）。
  Stream<List<ChatItem>> changesOf(String sid) => _storeOf(sid).changes;

  /// 启动：连通道。
  Future<void> start() async {
    _stateSub = client.connection.listen(_onConnectionChanged);
    _connection = _viewOf(client.state);
    notifyListeners();
    await client.start();
  }

  void _onConnectionChanged(ConnectionState state) {
    if (_disposed) return;
    _connection = _viewOf(state);
    notifyListeners();
  }

  /// 把 `ConnectionState`（协议状态机）翻成界面视图。
  static ConnectionStateView _viewOf(ConnectionState state) => switch (state) {
    ConnectionState.idle => ConnectionStateView.idle,
    ConnectionState.connecting => ConnectionStateView.connecting,
    ConnectionState.handshake => ConnectionStateView.handshaking,
    ConnectionState.serving => ConnectionStateView.serving,
    ConnectionState.backoff => ConnectionStateView.backoff,
    ConnectionState.closed => ConnectionStateView.closed,
  };

  /// 拉会话列表（`session.list`）。
  ///
  /// **失败不吞**：把错误记进 [lastError] 并让界面能显示。
  /// 吞掉的话界面只会显示"空列表"，而用户无从知道是"真没有会话"还是"请求失败了"。
  Future<void> refreshSessions() async {
    try {
      final result = await client.call<Object?>('session.list', const {});
      final list = _parseSessionList(result);
      _sessions = list;
      _lastError = null;
      if (!_disposed) notifyListeners();
    } on ProtocolException catch (error) {
      _lastError = error;
      if (!_disposed) notifyListeners();
    }
  }

  /// 打开一个会话：订阅它，并把条目喂给 store。
  ///
  /// [since] 是本地已有的水位（本地库还没做，先给 0 = 从零开始，电脑侧会给快照）。
  Future<void> openSession(String sid, {int since = 0}) async {
    _currentSid = sid;
    if (!_disposed) notifyListeners();

    // 订阅前先把这一路的事件流接上（顺序反了会丢掉开启帧 —— 那是第一帧）。
    _deltaSubs[sid] ??= client.sessionUpdates(sid).listen((delta) {
      _onDelta(sid, delta);
    });

    try {
      await client.subscribe(sid, since: since);
      _lastError = null;
    } on ProtocolException catch (error) {
      _lastError = error;
      if (!_disposed) notifyListeners();
    }
  }

  /// 关闭当前会话（退订）。
  Future<void> closeSession() async {
    final sid = _currentSid;
    _currentSid = null;
    if (!_disposed) notifyListeners();
    if (sid == null) return;
    await _deltaSubs.remove(sid)?.cancel();
    try {
      await client.unsubscribe(sid);
    } on ProtocolException {
      // 退订失败不值得打扰用户：本地已经不再显示它了。
    }
  }

  void _onDelta(String sid, SessionDelta delta) {
    if (_disposed) return;
    final store = _storeOf(sid);

    // **持久事件** → 投影成界面条目 → upsert。
    // 一次恢复可能带一批：`upsertAll` 内部把通知合并成一次。
    if (delta.events.isNotEmpty) {
      store.upsertAll(
        delta.events
            .map(
              (event) => projectEvent(
                type: event.type,
                seq: event.seq,
                data: event.data,
                time: event.time,
              ),
            )
            .where((projection) => projection.isItem)
            .map((projection) => projection.item!),
      );
    }

    // **流式文本** → 单独的槽位（UI 从它读"正在生成的这段"）。
    // 它**不进 store**：没有稳定 itemId，且会被随后的持久 `assistant/message`
    // 整体替换（`app-channel-client.md` §2.2：以持久为准）。
    if (delta.liveText != null) {
      _liveText = delta.liveText;
    }

    // 会话列表里的更新时间与计数跟着动。
    _touchSummary(sid, store);
  }

  /// 当前会话的流式文本（`null` = 没有正在生成的流）。
  ///
  /// 它在持久 `assistant/message` 到达后**不清空**（那是 `core/` 的累加器负责的）——
  /// 界面按"最后一条持久消息"渲染，流式槽位只在没有持久消息时显示。
  String? get liveText => _liveText;

  String? _liveText;

  SessionStore _storeOf(String sid) =>
      _stores.putIfAbsent(sid, () => SessionStore(sid));

  void _touchSummary(String sid, SessionStore store) {
    final index = _sessions.indexWhere((s) => s.sid == sid);
    final updated = SessionSummary(
      sid: sid,
      title: store.title,
      updatedAt: store.updatedAt,
      itemCount: store.length,
      pendingCount: store.pendingCount,
    );
    if (index < 0) {
      _sessions = [..._sessions, updated];
    } else {
      final next = [..._sessions];
      next[index] = updated;
      _sessions = next;
    }
    if (!_disposed) notifyListeners();
  }

  static List<SessionSummary> _parseSessionList(Object? result) {
    if (result is! List) return const [];
    final out = <SessionSummary>[];
    for (final entry in result) {
      if (entry is! Map) continue;
      final sid = entry['sid'];
      if (sid is! String || sid.isEmpty) continue;
      // 标题不在服务端字段里（契约 §5.7），先留空，由 store 推导后覆盖。
      out.add(
        SessionSummary(
          sid: sid,
          title: '',
          updatedAt: (entry['updatedAt'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    return out;
  }

  /// 释放（**幂等**）。
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_stateSub?.cancel());
    for (final sub in _deltaSubs.values) {
      unawaited(sub.cancel());
    }
    _deltaSubs.clear();
    for (final store in _stores.values) {
      unawaited(store.dispose());
    }
    _stores.clear();
    super.dispose();
  }
}
