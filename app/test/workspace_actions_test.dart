/// 侧栏会话动作的跨层回归（`workspace.pin` / `workspace.unpin` /
/// `workspace.insertSessionBefore`）。
///
/// 守三件事：
///
/// 1. **载荷形状**：`sid` 反解由连接器做；手机只发 `sid` / `workspaceId` /
///    `beforeSid`，且**追加到末尾时不发 `beforeSid`**（DSH 的 `beforeSessionId?`
///    缺省即追加，塞空串会被当成一个不存在的锚点）。
/// 2. **应答是权威值**：置顶集照 `{pinnedSessionIds}` 落，组内顺序照
///    `{sessionIds}` 落 —— 不本地猜。
/// 3. **失败照实说**：形状不认识 / 调用失败时返回 `false` 且 `lastError` 有值，
///    不假装成功。
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 最小假客户端：按方法名回固定形状，并记录调用。
class _FakeWorkspaceClient extends FakeSyncClient {
  _FakeWorkspaceClient({this.onCall});

  final Object? Function(String method, Map<String, Object?> params)? onCall;

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
    return onCall?.call(method, params) as T;
  }
}

Map<String, Object?> _snapshot() => {
  'workspaces': [
    {
      'workspaceId': 'w1',
      'title': 'dsh-mobile',
      'path': '/repo',
      'sessionIds': ['s1', 's2'],
    },
  ],
  'archivedSessionIds': <String>[],
  'pinnedSessionIds': ['s2'],
};

void main() {
  test('refreshWorkspaces 解析置顶集（与归档集同一份应答）', () async {
    final client = _FakeWorkspaceClient(
      onCall: (method, params) =>
          method == 'workspace.list' ? _snapshot() : null,
    );
    final app = AppModel(client: client);

    await app.refreshWorkspaces();

    expect(app.pinnedSids, {'s2'});
    expect(app.workspaces.single.sessionIds, ['s1', 's2']);
  });

  test('pin / unpin：发 sid，照应答落置顶全集，带幂等键', () async {
    final client = _FakeWorkspaceClient(
      onCall: (method, params) => switch (method) {
        'workspace.list' => _snapshot(),
        'workspace.pin' => {
          'pinnedSessionIds': ['s1', 's2'],
        },
        'workspace.unpin' => {
          'pinnedSessionIds': ['s2'],
        },
        _ => null,
      },
    );
    final app = AppModel(client: client);
    await app.refreshWorkspaces();

    expect(await app.pinSession('s1'), isTrue);
    expect(app.pinnedSids, {'s1', 's2'});
    expect(client.calls.last.params, {
      'sid': 's1',
    }, reason: '置顶只发 sid；workspaceId 不在这个方法里');
    expect(client.calls.last.requestId, isNotEmpty);

    expect(await app.unpinSession('s1'), isTrue);
    expect(app.pinnedSids, {'s2'});
    expect(client.calls.last.params, {'sid': 's1'});
  });

  test('moveSession：有锚点发 beforeSid，无锚点**不发这个键**', () async {
    final client = _FakeWorkspaceClient(
      onCall: (method, params) => switch (method) {
        'workspace.list' => _snapshot(),
        'workspace.insertSessionBefore' => {
          'sessionIds': ['s2', 's1'],
        },
        _ => null,
      },
    );
    final app = AppModel(client: client);
    await app.refreshWorkspaces();

    expect(await app.moveSession('s1', beforeSid: 's2'), isTrue);
    expect(client.calls.last.params, {
      'workspaceId': 'w1',
      'sid': 's1',
      'beforeSid': 's2',
    });
    expect(app.workspaces.single.sessionIds, [
      's2',
      's1',
    ], reason: '应答里的顺序就是权威值，直接替换那一组');

    // 移到末尾：不带 beforeSid。DSH 缺省即追加。
    expect(await app.moveSession('s2', beforeSid: null), isTrue);
    expect(client.calls.last.params, {'workspaceId': 'w1', 'sid': 's2'});
  });

  test('moveSession：会话不属于任何工作区 → false，不发请求', () async {
    final client = _FakeWorkspaceClient(
      onCall: (method, params) =>
          method == 'workspace.list' ? _snapshot() : null,
    );
    final app = AppModel(client: client);
    await app.refreshWorkspaces();

    expect(await app.moveSession('s9', beforeSid: null), isFalse);
    expect(
      client.calls.where((c) => c.method == 'workspace.insertSessionBefore'),
      isEmpty,
    );
    expect(app.lastError, isNotNull);
  });

  test(
    'moveWorkspace：发 workspaceId + beforeWorkspaceId，照**整份**顺序重排，不丢组',
    () async {
      Map<String, Object?> snapshot() => {
        'workspaces': [
          {
            'workspaceId': 'w1',
            'title': 'A',
            'path': '/a',
            'sessionIds': ['s1'],
          },
          {
            'workspaceId': 'w2',
            'title': 'B',
            'path': '/b',
            'sessionIds': ['s2'],
          },
          {
            'workspaceId': 'w3',
            'title': 'C',
            'path': '/c',
            'sessionIds': ['s3'],
          },
        ],
        'archivedSessionIds': <String>[],
        'pinnedSessionIds': <String>[],
      };
      final client = _FakeWorkspaceClient(
        onCall: (method, params) => switch (method) {
          'workspace.list' => snapshot(),
          'workspace.insertBefore' => {
            'workspaceIds': ['w3', 'w1', 'w2'],
          },
          _ => null,
        },
      );
      final app = AppModel(client: client);
      await app.refreshWorkspaces();

      expect(await app.moveWorkspace('w3', beforeWorkspaceId: 'w1'), isTrue);
      expect(client.calls.last.params, {
        'workspaceId': 'w3',
        'beforeWorkspaceId': 'w1',
      });
      expect(app.workspaces.map((g) => g.workspaceId), ['w3', 'w1', 'w2']);

      // 移到末尾：**不发** beforeWorkspaceId（DSH 的 `beforeWorkspaceId?` 缺省语义）。
      expect(await app.moveWorkspace('w1', beforeWorkspaceId: null), isTrue);
      expect(client.calls.last.params, {'workspaceId': 'w1'});
    },
  );

  test('moveWorkspace：应答只提到一部分组 → 其余留在末尾，不丢', () async {
    final client = _FakeWorkspaceClient(
      onCall: (method, params) => switch (method) {
        'workspace.list' => {
          'workspaces': [
            {
              'workspaceId': 'w1',
              'title': 'A',
              'path': '/a',
              'sessionIds': <String>[],
            },
            {
              'workspaceId': 'w2',
              'title': 'B',
              'path': '/b',
              'sessionIds': <String>[],
            },
          ],
          'archivedSessionIds': <String>[],
          'pinnedSessionIds': <String>[],
        },
        // 宿主只回了 w2（形状仍合法）—— 排序是增强，不能因此把 w1 从列表里抹掉。
        'workspace.insertBefore' => {
          'workspaceIds': ['w2'],
        },
        _ => null,
      },
    );
    final app = AppModel(client: client);
    await app.refreshWorkspaces();

    expect(await app.moveWorkspace('w2', beforeWorkspaceId: null), isTrue);
    expect(app.workspaces.map((g) => g.workspaceId), ['w2', 'w1']);
  });

  test('应答形状不认识：不落状态，返回 false', () async {
    final client = _FakeWorkspaceClient(
      onCall: (method, params) => switch (method) {
        'workspace.list' => _snapshot(),
        // 缺 pinnedSessionIds / sessionIds 的应答
        'workspace.pin' => <String, Object?>{},
        'workspace.insertSessionBefore' => <String, Object?>{},
        _ => null,
      },
    );
    final app = AppModel(client: client);
    await app.refreshWorkspaces();
    final before = app.workspaces.single.sessionIds;

    expect(await app.pinSession('s1'), isFalse);
    expect(app.pinnedSids, {'s2'}, reason: '认不出就不动');
    expect(await app.moveSession('s1', beforeSid: 's2'), isFalse);
    expect(app.workspaces.single.sessionIds, before);
    expect(app.lastError?.code, ErrorCode.internal);
  });
}
