/// `turn/end` 的多条目产出不炸流监听的回归。
///
/// ## 这一组守什么
///
/// 2026-10-19 引入 `ChatProjection.skip` 时踩到的坑：`AppModel._onDelta`
/// 那里写的是 `projectEvent(...).item!`，而 **`skip` 的 `item` 是 null** ——
/// 于是每个 completed 的 `turn/end`（真日志 891 条）都会抛
/// `Null check operator used on a null value`。它是 `Error` 不是 `StateError`，
/// 下面那个 `on StateError` **接不住**，直接炸掉整个流监听。
///
/// 症状：会话打开后**一条新消息都不再进来**，且没有任何可见报错。
///
/// 同一天又加了 `turn-process`（每轮一条过程摘要），于是 `turn/end` 现在
/// **产出多条**。这一组同时守那件事：多条也要逐条落表，不能只落第一条。
///
/// 判据：喂一条 completed 的 `turn/end`，会话的条目表不炸、
/// **用户消息与过程摘要各一条**、且**没有**记进投影失败。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fake_sync_client.dart';

/// 能推任意事件的替身。
class _FeedClient extends FakeSyncClient {
  final _sessions = StreamController<SessionDelta>.broadcast();

  void emit(String sid, List<Map<String, Object?>> events) {
    _sessions.add(
      SessionDelta(
        sid: sid,
        events: [
          for (final e in events)
            SessionEvent(
              // **itemId 由客户端推导**（真实路径是 `sync_client_impl` 调
              // `itemIdOf`）。替身这里按契约 §5.2 的规则手推 —— 两条测试
              // 事件的配对键分别是 `message.id` 与 `turn`。
              itemId: e['itemId'] as String,
              type: e['type'] as String,
              seq: e['seq'] as int,
              time: e['time'] as int? ?? 0,
              data: e['data'],
            ),
        ],
        transient: const {},
      ),
    );
  }

  @override
  conn.ConnectionState get state => conn.ConnectionState.serving;
  @override
  Stream<conn.ConnectionState> get connection => const Stream.empty();
  @override
  Stream<JobFrame> get jobUpdates => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> reconnect() => start();
  @override
  Future<void> setAppState(AppState state) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> unsubscribe(String sid) async {}
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => _sessions.stream;

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async => <String, Object?>{} as T;
}

void main() {
  test('completed 的 turn/end 不炸、不多条目、不记失败', () async {
    final client = _FeedClient();
    final app = AppModel(client: client);
    addTearDown(app.dispose);
    await app.start();
    await app.openSession('s1');

    // 一条用户消息 + 一个 completed 的 turn/end（真日志：891 条那种）。
    client.emit('s1', [
      <String, Object?>{
        'type': 'user/message',
        'seq': 1,
        'itemId': 'm:m-1',
        'time': 1,
        'data': <String, Object?>{
          'id': 'm-1',
          'role': 'user',
          'source': <String, Object?>{'kind': 'user'},
          'content': '在吗',
        },
      },
      <String, Object?>{
        'type': 'turn/end',
        'seq': 2,
        'itemId': 'e:1',
        'time': 2,
        'data': <String, Object?>{
          'turn': 1,
          'reason': <String, Object?>{'kind': 'completed'},
        },
      },
    ]);
    // 让流监听跑完（`_onDelta` 是 async）。
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final items = app.items;
    // **两条**：用户消息 + 过程摘要（`turn/end` 现在产出多条，
    // `AppModel._onDelta` 逐条落表 —— 只落第一条的话这里会是 1）。
    expect(items.length, 2);
    expect(items.whereType<MessageItem>().length, 1);
    expect(items.whereType<TurnProcessItem>().length, 1);
    // **没有记进投影失败** —— 那正是 `.item!` 抛错后被 catch 写成的东西。
    expect(app.projectionFailureOf('s1'), isNull);
  });

  test('error 的 turn/end 占两条（摘要 + 失败行），且消息照常进', () async {
    final client = _FeedClient();
    final app = AppModel(client: client);
    addTearDown(app.dispose);
    await app.start();
    await app.openSession('s1');

    client.emit('s1', [
      <String, Object?>{
        'type': 'user/message',
        'seq': 1,
        'itemId': 'm:m-1',
        'time': 1,
        'data': <String, Object?>{
          'id': 'm-1',
          'role': 'user',
          'source': <String, Object?>{'kind': 'user'},
          'content': '在吗',
        },
      },
      <String, Object?>{
        'type': 'turn/end',
        'seq': 2,
        'itemId': 'e:1',
        'time': 2,
        'data': <String, Object?>{
          'turn': 1,
          'reason': <String, Object?>{
            'kind': 'error',
            'error': <String, Object?>{
              'message': 'Connection error.',
              'code': 'TRANSPORT',
            },
          },
        },
      },
    ]);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final items = app.items;
    expect(items.length, 3, reason: '用户消息 + 过程摘要 + 一条异常结局');
    expect(items.whereType<TurnOutcomeItem>().length, 1);
    expect(items.whereType<TurnProcessItem>().length, 1);
    expect(app.projectionFailureOf('s1'), isNull);
  });

  test('turn/start 与 turn/end 跨批：用时与计数仍取得到', () async {
    // **这一条守 2026-10-19 真机看到的缺陷**：`turn/start` 与 `turn/end`
    // 常常不在同一个 delta 批次里（翻页 / 快照加载时前者在更早的批次）。
    // 只在本批内记一张表的话，过程摘要的用时与计数会**永远是 0** ——
    // 症状是每条收口都只说"不到 1 秒"。
    final client = _FeedClient();
    final app = AppModel(client: client);
    addTearDown(app.dispose);
    await app.start();
    await app.openSession('s1');

    // 第一批：只有 turn/start（seq 1）。
    client.emit('s1', [
      <String, Object?>{
        'type': 'turn/start',
        'seq': 1,
        'itemId': 'turn/start:1',
        'time': 1000,
        'data': <String, Object?>{'turn': 1},
      },
    ]);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // 第二批：助手消息 + 工具调用 + turn/end（seq 5）。
    client.emit('s1', [
      <String, Object?>{
        'type': 'assistant/message',
        'seq': 2,
        'itemId': 'm:a-1',
        'time': 2000,
        'data': <String, Object?>{
          'message': <String, Object?>{
            'id': 'a-1',
            'role': 'assistant',
            'content': '在的',
          },
        },
      },
      <String, Object?>{
        'type': 'tool/call',
        'seq': 3,
        'itemId': 't:c-1',
        'time': 3000,
        'data': <String, Object?>{
          'callId': 'c-1',
          'name': 'read',
          'arguments': '{"path":"a.md"}',
        },
      },
      <String, Object?>{
        'type': 'tool/call',
        'seq': 4,
        'itemId': 't:c-2',
        'time': 3100,
        'data': <String, Object?>{
          'callId': 'c-2',
          'name': 'subagent',
          'arguments': '{}',
        },
      },
      <String, Object?>{
        'type': 'turn/end',
        'seq': 5,
        'itemId': 'e:1',
        'time': 35000,
        'data': <String, Object?>{
          'turn': 1,
          'reason': <String, Object?>{'kind': 'completed'},
        },
      },
    ]);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final process = app.items.whereType<TurnProcessItem>().single;
    // 用时 = 35000 - 1000（`turn/start` 在上一批，靠落表那条翻到）。
    expect(process.elapsedMs, 34000);
    expect(process.stats, '34 秒 · 1 条消息 · 1 次工具 · 1 个子智能体');
  });
}
