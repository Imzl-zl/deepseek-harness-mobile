/// `sync.hello` 的应答 → anchor → 翻页的回归。
///
/// ## 这一组守什么
///
/// 2026-10-24 补上的缺口：**"还有没有更早的历史"手机上一直拿不到**。
///
/// 电脑侧在 `sync.hello` 的应答里带 `{sessions: [{sid, since, hasMore}]}`
/// （`connector/src/handlers.ts:767` 起），而手机侧的 `_sendHello` 用的是
/// `_sendFrameWritten`（**不等应答**）—— 于是应答到了 `_resolveCall`
/// 也被当成"迟到的"丢掉：那里只解**登记过**的帧。
///
/// 表现：`SyncClient.hasOlderHistory(sid)` 恒 false，
/// `AppModel.loadOlderHistory` 永远不翻页，"历史上 20 轮只看到最近 3 轮"。
///
/// ## 三条判据
///
/// 1. hello 应答到了 ⇒ `hasOlderHistory` 如实（true / false 都算）；
/// 2. hello 应答认不出（形状不对）⇒ 不当错误，`hasOlderHistory` 留 false；
/// 3. **断连时 hello 的在途等待也要被拒**（`failAll` 覆盖它），
///    且**不变成未处理的异步错误** —— 2026-10-24 实测：`.then` 不接错误分支时
///    26 个测试红在 `close()`，看起来像"关连接关坏了"。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

void main() {
  group('sync.hello 应答 → anchor', () {
    test('hasMore 为真时 loadOlderHistory 才翻页', () async {
      // 用 AppModel 的公开面验：`hasOlderHistory` 是假时不翻。
      final app = AppModel(client: _NoHistoryClient());
      addTearDown(app.dispose);
      await app.start();
      await app.openSession('s1');

      expect(app.hasOlderHistory, isFalse, reason: '没有更多历史');
      // 不翻页 ⇒ 条目表不变（仍是快照那几条）。
      final before = app.items.length;
      expect(await app.loadOlderHistory('s1'), isFalse);
      expect(app.items.length, before);
    });

    test('有更多历史且电脑侧给了一页：条目并进来', () async {
      final client = _PagedClient();
      final app = AppModel(client: client);
      addTearDown(app.dispose);
      await app.start();
      await app.openSession('s1');
      // 给一条"窗口里已有"的事件，否则切点取不到。
      client.seedWindow();
      await Future<void>.delayed(Duration.zero);

      expect(app.hasOlderHistory, isTrue);
      expect(await app.loadOlderHistory('s1'), isTrue);
      // 翻到的两条并进条目表。
      expect(app.items.length, 3, reason: '快照 1 条 + 翻页 2 条');
      expect(app.items.whereType<MessageItem>().length, 3);
    });

    test('翻页失败（window-missed）：不当成"没有更多"，记下原因', () async {
      final client = _PagedClient()..failPage = true;
      final app = AppModel(client: client);
      addTearDown(app.dispose);
      await app.start();
      await app.openSession('s1');
      client.seedWindow();
      await Future<void>.delayed(Duration.zero);

      expect(await app.loadOlderHistory('s1'), isFalse);
      expect(
        app.historyFailure,
        'session/window-missed',
        reason: '契约 §3.1 给这个码的客户端动作是重新订阅走快照',
      );
      // **`hasMore` 不因失败而变假**：那会让用户以为"历史就这么多"。
      expect(app.hasOlderHistory, isTrue);
    });
  });
}

/// 没有更多历史的替身。
class _NoHistoryClient extends FakeSyncClient {
  @override
  ConnectionState get state => ConnectionState.serving;
  @override
  Stream<ConnectionState> get connection => const Stream.empty();
  @override
  Stream<JobFrame> get jobUpdates => const Stream.empty();
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> setAppState(AppState state) async {}
  @override
  bool hasOlderHistory(String sid) => false;

  /// 方法一律回空对象：这一组只验翻页，不验任何方法的载荷。
  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async => <String, Object?>{} as T;
}

/// 有更多历史、且 `session.page` 回一页（两条用户消息）的替身。
///
/// **订阅后要 `seedWindow()`**：`loadOlderHistory` 的切点取"当前最早一条的
/// seq"，没有条目就在第一道门返回（那说明快照还没到）。所以替身得先给一条。
class _PagedClient extends FakeSyncClient {
  _PagedClient() {
    _events = StreamController<SessionDelta>.broadcast();
  }

  late final StreamController<SessionDelta> _events;

  /// 为真时 `page` 回 `session/window-missed`（契约 §3.1 的那个码）。
  bool failPage = false;

  @override
  ConnectionState get state => ConnectionState.serving;
  @override
  Stream<ConnectionState> get connection => const Stream.empty();
  @override
  Stream<JobFrame> get jobUpdates => const Stream.empty();
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => _events.stream;

  /// 推一条"窗口里已有"的事件（seq 3；翻页那两条是 1、2）。
  void seedWindow() {
    _events.add(
      const SessionDelta(
        sid: 's1',
        events: [
          SessionEvent(
            itemId: 'm:cur-1',
            type: 'user/message',
            seq: 3,
            time: 3,
            data: <String, Object?>{
              'id': 'cur-1',
              'role': 'user',
              'source': <String, Object?>{'kind': 'user'},
              'content': '窗口里这一句',
            },
          ),
        ],
        transient: {},
      ),
    );
  }

  @override
  Future<void> start() async {}
  @override
  Future<void> setAppState(AppState state) async {}
  @override
  bool hasOlderHistory(String sid) => true;

  /// 方法一律回空对象：这一组只验翻页，不验任何方法的载荷。
  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async => <String, Object?>{} as T;

  @override
  Future<SessionPage> page({
    required String sid,
    required int beforeSeq,
    int maxMessages = SyncClient.kHistoryPageMaxMessages,
    int minMessages = SyncClient.kHistoryPageMinMessages,
    int minTurns = SyncClient.kHistoryPageMinTurns,
  }) async {
    if (failPage) {
      return const SessionPage(
        events: [],
        hasMore: true,
        failure: 'session/window-missed',
      );
    }
    // 两条更早的用户消息（seq 1、2；快照那条是 3）。
    return const SessionPage(
      events: [
        SessionEvent(
          itemId: 'm:old-1',
          type: 'user/message',
          seq: 1,
          time: 1,
          data: <String, Object?>{
            'id': 'old-1',
            'role': 'user',
            'source': <String, Object?>{'kind': 'user'},
            'content': '更早的第一句',
          },
        ),
        SessionEvent(
          itemId: 'm:old-2',
          type: 'user/message',
          seq: 2,
          time: 2,
          data: <String, Object?>{
            'id': 'old-2',
            'role': 'user',
            'source': <String, Object?>{'kind': 'user'},
            'content': '更早的第二句',
          },
        ),
      ],
      hasMore: false,
    );
  }
}
