/// 收口处的「在新会话中分支」（`session.fork`）。
///
/// ## 这一组守什么
///
/// 1. **坐标是收口事件的 seq**（桌面 `forkAt(turn.end.seq)`，`apply.ts:299-305`），
///    不是轮号、不是路径；
/// 2. **子会话是别名**：`{sid}` 直接拿来打开，不出现 DSH id；
/// 3. 成功后会话列表被重拉（子会话进抽屉），失败**如实弹**（不假装成功）；
/// 4. 按钮在途置灰（宿主 fork 没有幂等键，重复点击只能由界面兜）。
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/data/projection.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:dsh_mobile/wire/rpc/session.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

const String _src = 'sid_src';
const String _child = 'sid_child';

/// 一台假电脑：一行源会话 + fork 回 `{sid: sid_child}`；列表在 fork 后多出子会话。
class _ForkClient extends FakeSyncClient {
  _ForkClient({this.forkThrows});

  /// 让 `session.fork` 抛（宿主 writer-held 之类）。
  final Exception? forkThrows;

  final sent = <(String, Map<String, Object?>)>[];
  final subscribed = <String>[];
  bool forked = false;

  @override
  ConnectionState get state => ConnectionState.serving;
  @override
  Stream<ConnectionState> get connection => const Stream.empty();
  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();
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
  Future<SessionAnchor> subscribe(String sid, {required int since}) async {
    subscribed.add(sid);
    return const SessionAnchor(since: 0, hasMore: false);
  }

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    sent.add((method, params));
    switch (method) {
      case 'repo.info':
        return <String, Object?>{'protocol': 1, 'caps': <String, Object?>{}}
            as T;
      case 'session.fork':
        final thrown = forkThrows;
        if (thrown != null) throw thrown;
        forked = true;
        return <String, Object?>{'sid': _child} as T;
      case 'session.list':
        return <String, Object?>{
              'sessions': [
                {
                  'sid': _src,
                  'updatedAt': 2,
                  'running': false,
                  'blank': false,
                  'subagent': false,
                },
                if (forked)
                  {
                    'sid': _child,
                    'updatedAt': 3,
                    'running': false,
                    'blank': false,
                    'subagent': false,
                  },
              ],
            }
            as T;
    }
    return <String, Object?>{} as T;
  }
}

/// 一条收口（`turn/end`）—— 分支按钮就在这一行上。
ChatItem _turnEnd({required int seq, required int turn}) => projectEvent(
  type: 'turn/end',
  seq: seq,
  turn: turn,
  data: <String, Object?>{
    'turn': turn,
    'reason': <String, Object?>{'kind': 'completed'},
  },
).item!;

ChatItem _assistant({required int seq, required int turn}) => projectEvent(
  type: 'assistant/message',
  seq: seq,
  turn: turn,
  data: <String, Object?>{
    'turn': turn,
    'step': 1,
    'message': <String, Object?>{
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': '改好了。'},
      ],
      'source': {'kind': 'model'},
      'id': 'm1',
    },
  },
).item!;

Future<AppModel> _seeded(_ForkClient client) async {
  final app = AppModel(client: client);
  app.seedForTest(
    sid: _src,
    title: '源会话',
    updatedAt: 1,
    items: [_assistant(seq: 2, turn: 1), _turnEnd(seq: 5, turn: 1)],
  );
  await app.refreshRepoInfo();
  await app.openSession(_src);
  return app;
}

void main() {
  test('wire：只认非空 sid（子会话的别名）', () {
    expect(valueOrNull(readForkedSid({'sid': _child})), _child);
    final bad = readForkedSid({'sid': ''});
    expect(bad, isA<WireBad<String>>());
    expect(valueOrReport(bad, 'session.fork'), isNull);
    expect(WireDiagnostics.badCount, 1);
  });

  test('AppModel：atSeq 原样进请求，回子会话并重拉列表', () async {
    final client = _ForkClient();
    final app = await _seeded(client);
    addTearDown(app.dispose);

    final child = await app.forkSession(_src, atSeq: 9);

    expect(child, _child);
    expect(client.sent.where((c) => c.$1 == 'session.fork').map((c) => c.$2), [
      {'sid': _src, 'atSeq': 9},
    ]);
    // 重拉列表：子会话进抽屉（列表里出现它才算数）。
    expect(app.sessionOf(_child), isNotNull);
  });

  test('AppModel：fork 失败回 null，原因留在 lastError', () async {
    final client = _ForkClient(
      forkThrows: const ProtocolException(
        ErrorCode.internal,
        'session/writer-held: busy',
      ),
    );
    final app = await _seeded(client);
    addTearDown(app.dispose);

    final child = await app.forkSession(_src, atSeq: 5);

    expect(child, isNull);
    expect(app.lastError?.message, contains('session/writer-held'));
  });

  testWidgets('收口行有「分支」钮：点它发出 atSeq = 收口 seq，并打开子会话', (tester) async {
    final client = _ForkClient();
    final app = await _seeded(client);
    addTearDown(app.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: ChatPage(
          app: app,
          paired: true,
          onOpenDrawer: () {},
          onNewSession: () {},
          drawer: const Drawer(child: SizedBox(height: 200)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final fork = find.byKey(const Key('turn-fork'));
    expect(fork, findsOneWidget, reason: '收口行上要有分支钮');

    await tester.tap(fork);
    await tester.pumpAndSettle();

    expect(
      client.sent.where((c) => c.$1 == 'session.fork').map((c) => c.$2),
      [
        {'sid': _src, 'atSeq': 5},
      ],
      reason: 'atSeq 必须是这一轮收口（turn/end seq=5）的事件序号',
    );
    expect(app.currentSid, _child, reason: '成功后要打开子会话');
    expect(client.subscribed, contains(_child));
  });
}
