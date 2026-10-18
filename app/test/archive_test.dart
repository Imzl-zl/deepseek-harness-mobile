/// 归档链的回归（契约 §5.7 的 `workspace.archive` / `workspace.unarchive`）。
///
/// 守三件事：
///
/// 1. **归档集只有一个来源**：它随 `workspace.list` 的 `archivedSessionIds` 来，
///    归档/取消归档的应答里也是同一个字段（宿主的权威值）—— 不本地猜、不自己维护副本。
/// 2. **`stopActivity` 只在真要停时才进请求体**：DSH 判的是 `=== true`，
///    塞一个 `false` 是另一种语义（见 `connector/src/dsh/workspaces.ts` 的注释）。
/// 3. **"还在跑"是信息不是故障**：宿主回 `workspace/session-active` 时，
///    错误码必须**原样透传**（被归一成 `internal` 的话，界面就没法弹「停止并归档」，
///    用户只会看到一个永远重试也不好的操作 —— 2026-10-09 踩过的那一类）。
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/archive_sheet.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

/// 会记住归档方法的调用、并且可以注入失败码的假客户端。
class _FakeArchiveClient implements SyncClient {
  _FakeArchiveClient({this.archived = const [], this.failWith});

  /// `workspace.list` 报的归档集（手机见的 sid）。
  final List<String> archived;

  /// 归档/取消归档要抛的错（`null` = 成功）。
  final ProtocolException? failWith;

  final List<({String method, Map<String, Object?> params, String? requestId})>
  calls = [];

  @override
  ConnectionState get state => ConnectionState.idle;

  @override
  Stream<ConnectionState> get connection => const Stream.empty();

  @override
  Future<void> start() async {}

  @override
  Future<void> reconnect() => start();

  @override
  Future<void> setAppState(AppState state) async {}

  @override
  Future<void> close() async {}

  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();

  @override
  Future<void> subscribe(String sid, {required int since}) async {}

  @override
  Future<void> unsubscribe(String sid) async {}

  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    calls.add((method: method, params: params, requestId: requestId));
    switch (method) {
      case 'session.list':
        return {
              'sessions': [
                {
                  'sid': 's1',
                  'updatedAt': 30,
                  'projections': {
                    'kind': 'cached',
                    'asOfSeq': 1,
                    'values': {'title': '第一个会话'},
                  },
                },
                {
                  'sid': 's2',
                  'updatedAt': 20,
                  'projections': {
                    'kind': 'cached',
                    'asOfSeq': 1,
                    'values': {'title': '第二个会话'},
                  },
                },
              ],
            }
            as T;
      case 'workspace.list':
        return {
              'workspaces': [
                {
                  'workspaceId': 'ws-1',
                  'title': 'dsh-mobile',
                  'path': 'D:/repo',
                  'sessionIds': ['s1', 's2'],
                },
              ],
              'archivedSessionIds': archived,
            }
            as T;
      case 'workspace.archive':
      case 'workspace.unarchive':
        final failure = failWith;
        if (failure != null) throw failure;
        // 宿主的应答就是权威值：这里模拟"归档之后 s1 进了归档集"。
        return {
              'archivedSessionIds': method == 'workspace.archive'
                  ? ['s1']
                  : <String>[],
            }
            as T;
      default:
        return null as T;
    }
  }
}

Future<AppModel> _loaded(_FakeArchiveClient client) async {
  final app = AppModel(client: client);
  await app.refreshSessions();
  await app.refreshWorkspaces();
  return app;
}

void main() {
  test('归档集随 workspace.list 来；已归档的会话从可见列表里去掉', () async {
    final client = _FakeArchiveClient(archived: ['s2']);
    final app = await _loaded(client);

    expect(app.archivedSids, {'s2'});
    expect(app.archivedSessions.map((s) => s.sid), ['s2']);
    // 上一条断言用的是**同一份 sessions**：归档行不能被"顺手从 sessions 里删掉"，
    // 否则取消归档就没有行可回（DSH 的原注释：记账槽位保留，取消归档回原位）。
    expect(app.sessions.map((s) => s.sid), ['s1', 's2']);
  });

  test('归档：带 requestId；应答里的归档全集落进 archivedSids', () async {
    final client = _FakeArchiveClient();
    final app = await _loaded(client);

    expect(await app.archiveSession('s1'), isTrue);
    final call = client.calls.last;
    expect(call.method, 'workspace.archive');
    expect(call.params, {'sid': 's1'});
    expect(call.requestId, isNotNull, reason: '写方法必须带幂等键');
    expect(app.archivedSids, {'s1'});
  });

  test('stopActivity 只在真要停时才进请求体', () async {
    final client = _FakeArchiveClient();
    final app = await _loaded(client);

    await app.archiveSession('s1');
    expect(client.calls.last.params.containsKey('stopActivity'), isFalse);

    await app.archiveSession('s1', stopActivity: true);
    expect(client.calls.last.params['stopActivity'], true);
  });

  test('取消归档：同样带幂等键，并把归档全集更新掉', () async {
    final client = _FakeArchiveClient(archived: ['s1']);
    final app = await _loaded(client);
    expect(app.archivedSids, {'s1'});

    expect(await app.unarchiveSession('s1'), isTrue);
    expect(client.calls.last.method, 'workspace.unarchive');
    expect(client.calls.last.requestId, isNotNull);
    expect(app.archivedSids, isEmpty);
  });

  test('归档被拒（会话还在跑）：错误码原样透传，不当成 internal', () async {
    final client = _FakeArchiveClient(
      failWith: const ProtocolException(
        ErrorCode.workspaceSessionActive,
        '会话有在跑的活动',
      ),
    );
    final app = await _loaded(client);

    expect(await app.archiveSession('s1'), isFalse);
    expect(
      app.lastError?.code,
      ErrorCode.workspaceSessionActive,
      reason: '被归一成 internal 的话，界面就没法弹「停止并归档」',
    );
    expect(app.archivedSids, isEmpty, reason: '失败不该动归档集');
  });

  testWidgets('归档列表：列已归档的、点「取消归档」真的发方法、空态照 DSH 文案', (tester) async {
    final client = _FakeArchiveClient(archived: ['s2']);
    final app = await _loaded(client);

    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showArchiveSheet(
                context,
                app: app,
                onUnarchive: app.unarchiveSession,
              ),
              child: const Text('开归档'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开归档'));
    await tester.pumpAndSettle();

    // 顶部那句是 DSH 的原话（`toast.archivedNotOpenable`）。
    expect(find.text('已归档对话暂时无法查看，请取消归档后查看'), findsOneWidget);
    expect(find.text('第二个会话'), findsOneWidget);
    expect(find.text('第一个会话'), findsNothing, reason: '没归档的不该出现在这张列表里');

    await tester.tap(find.text('取消归档'));
    await tester.pumpAndSettle();

    expect(client.calls.last.method, 'workspace.unarchive');
    expect(client.calls.last.params, {'sid': 's2'});
    expect(
      find.text('第二个会话'),
      findsNothing,
      reason: '取消归档之后那一行当场消失（列表跟着 AppModel 变，不自己存副本）',
    );
  });

  testWidgets('归档列表：一条都没有时说「暂无已归档会话」', (tester) async {
    final client = _FakeArchiveClient();
    final app = await _loaded(client);

    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showArchiveSheet(
                context,
                app: app,
                onUnarchive: app.unarchiveSession,
              ),
              child: const Text('开归档'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开归档'));
    await tester.pumpAndSettle();

    expect(find.text('暂无已归档会话'), findsOneWidget);
  });
}
