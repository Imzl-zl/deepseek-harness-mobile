/// 工作区行的三个动作（`workspace.rename` / `workspace.delete` +
/// 「在这一组里新建会话」）的跨层回归。
///
/// 守四件事：
///
/// 1. **载荷形状**：改名只发 `{workspaceId, title}`，标题**原样发**
///    （`trim` 与判空是宿主的责任，`workspace-controller/src/commands.ts:74-77`）；
///    删除只发 `{workspaceId}`。
/// 2. **应答是权威值**：改名照应答里的那一行替换（标题与 `sessionIds` 都来自宿主），
///    删除只在宿主回 `{deleted: true}` 时才摘掉分组。
/// 3. **失败照实说**：错误码原样留在 `lastError`（重名是 `workspace/name-conflict`
///    而不是被归一成 `internal`），返回 `false`，**本地表不动**。
/// 4. **删除只删注册**：会话列表不受影响（宿主 `commands.ts:94` 的原注释）。
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 按方法名回固定形状，并记录调用（与 `workspace_actions_test.dart` 同一族）。
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
      'createdAt': '2026-10-01T00:00:00.000Z',
      'sessionIds': ['s1', 's2'],
    },
    {
      'workspaceId': 'w2',
      'title': 'another',
      'path': '/repo2',
      'createdAt': '2026-10-02T00:00:00.000Z',
      'sessionIds': ['s3'],
    },
  ],
  'archivedSessionIds': <String>[],
  'pinnedSessionIds': <String>[],
};

/// 一个改好名的行（形状与 `workspace.list` 的行同构）。
Map<String, Object?> _renamedRow(String title) => {
  'workspace': {
    'workspaceId': 'w1',
    'title': title,
    'path': '/repo',
    'createdAt': '2026-10-01T00:00:00.000Z',
    'sessionIds': ['s1', 's2'],
  },
};

void main() {
  group('renameWorkspace', () {
    test('发 {workspaceId, title}，标题原样发（不 trim），照应答替换那一行', () async {
      final client = _FakeWorkspaceClient(
        onCall: (method, params) => switch (method) {
          'workspace.list' => _snapshot(),
          'workspace.rename' => _renamedRow(params['title']! as String),
          _ => null,
        },
      );
      final app = AppModel(client: client);
      await app.refreshWorkspaces();

      // 前后都带空格：宿主会 trim，我们**原样发** —— 所以发出去的必须还是带空格的。
      expect(await app.renameWorkspace('w1', '  新名字  '), isTrue);

      final call = client.calls.firstWhere(
        (c) => c.method == 'workspace.rename',
      );
      expect(call.params, {
        'workspaceId': 'w1',
        'title': '  新名字  ',
      }, reason: 'trim 是宿主的责任（commands.ts:74-77），这一层再判一次就是两份规则');
      expect(call.requestId, isNotEmpty, reason: '改名前必须带幂等键');

      expect(app.workspaces.first.title, '  新名字  ', reason: '标题以应答为准，不在本地自己裁');
      expect(app.workspaces.first.sessionIds, [
        's1',
        's2',
      ], reason: '改归属不在这个方法里，sessionIds 照旧');
      expect(app.workspaces.length, 2, reason: '只替换那一行，别的组不动');
      expect(app.workspaces[1].workspaceId, 'w2');
    });

    test('标题与现有完全相同 ⇒ 不发请求（宿主那条路径也不落盘）', () async {
      final client = _FakeWorkspaceClient(
        onCall: (method, params) =>
            method == 'workspace.list' ? _snapshot() : null,
      );
      final app = AppModel(client: client);
      await app.refreshWorkspaces();
      final before = client.calls.length;

      expect(await app.renameWorkspace('w1', 'dsh-mobile'), isTrue);
      expect(client.calls.length, before, reason: '同值改名白跑一次往返没有意义');
    });

    test('重名 ⇒ 返回 false，lastError 是 workspace/name-conflict，本地表不动', () async {
      final client = _FakeWorkspaceClient(
        onCall: (method, params) => switch (method) {
          'workspace.list' => _snapshot(),
          'workspace.rename' => throw const ProtocolException(
            ErrorCode.workspaceNameConflict,
            'already in use',
          ),
          _ => null,
        },
      );
      final app = AppModel(client: client);
      await app.refreshWorkspaces();

      expect(await app.renameWorkspace('w1', 'another'), isFalse);
      expect(
        app.lastError?.code,
        ErrorCode.workspaceNameConflict,
        reason: '重名是信息不是故障：这个码收在 ERROR_TABLE 里，不能被归一成 internal',
      );
      expect(app.lastError?.code.wire, 'workspace/name-conflict');
      expect(app.workspaces.first.title, 'dsh-mobile', reason: '失败后标题不能变');
    });

    test('应答认不出（缺 workspace 行）⇒ false + lastError', () async {
      final client = _FakeWorkspaceClient(
        onCall: (method, params) => switch (method) {
          'workspace.list' => _snapshot(),
          'workspace.rename' => <String, Object?>{},
          _ => null,
        },
      );
      final app = AppModel(client: client);
      await app.refreshWorkspaces();

      expect(await app.renameWorkspace('w1', '新名字'), isFalse);
      expect(app.lastError, isNotNull);
      expect(app.workspaces.first.title, 'dsh-mobile');
    });

    test('没有这个工作区 ⇒ false，不打请求', () async {
      final client = _FakeWorkspaceClient(
        onCall: (method, params) =>
            method == 'workspace.list' ? _snapshot() : null,
      );
      final app = AppModel(client: client);
      await app.refreshWorkspaces();
      final before = client.calls.length;

      expect(await app.renameWorkspace('nope', 'x'), isFalse);
      expect(client.calls.length, before);
      expect(app.lastError, isNotNull);
    });
  });

  group('deleteWorkspace', () {
    test('发 {workspaceId}，回 {deleted: true} 才摘掉那一组', () async {
      final client = _FakeWorkspaceClient(
        onCall: (method, params) => switch (method) {
          'workspace.list' => _snapshot(),
          'workspace.delete' => {'deleted': true},
          _ => null,
        },
      );
      final app = AppModel(client: client);
      await app.refreshWorkspaces();

      expect(await app.deleteWorkspace('w1'), isTrue);

      final call = client.calls.firstWhere(
        (c) => c.method == 'workspace.delete',
      );
      expect(call.params, {
        'workspaceId': 'w1',
      }, reason: '删除只发 workspaceId（types.ts:88-90），没有别的开关');
      expect(call.requestId, isNotEmpty, reason: '删除必须带幂等键');

      expect(app.workspaces.length, 1);
      expect(app.workspaces.single.workspaceId, 'w2');
    });

    test('应答不是 {deleted: true} ⇒ false，本地表不动（不能凭空摘掉一组）', () async {
      final client = _FakeWorkspaceClient(
        onCall: (method, params) => switch (method) {
          'workspace.list' => _snapshot(),
          // 形状变了：没有 deleted 键。
          'workspace.delete' => <String, Object?>{},
          _ => null,
        },
      );
      final app = AppModel(client: client);
      await app.refreshWorkspaces();

      expect(await app.deleteWorkspace('w1'), isFalse);
      expect(app.workspaces.length, 2, reason: '认不出的应答不能当成删成功');
      expect(app.lastError, isNotNull);
    });

    test('宿主回 workspace/not-found ⇒ false，那个码原样留在 lastError', () async {
      final client = _FakeWorkspaceClient(
        onCall: (method, params) => switch (method) {
          'workspace.list' => _snapshot(),
          'workspace.delete' => throw const ProtocolException(
            ErrorCode.workspaceNotFound,
            'no such workspace',
          ),
          _ => null,
        },
      );
      final app = AppModel(client: client);
      await app.refreshWorkspaces();

      expect(await app.deleteWorkspace('w1'), isFalse);
      expect(app.lastError?.code, ErrorCode.workspaceNotFound);
      expect(app.workspaces.length, 2);
    });

    test('删除工作区**不碰会话列表**（宿主只删注册，目录与会话都留着）', () async {
      final client = _FakeWorkspaceClient(
        onCall: (method, params) => switch (method) {
          'workspace.list' => _snapshot(),
          'session.list' => {
            'items': [
              {'sessionId': 's1', 'title': 'a', 'updatedAt': 1},
              {'sessionId': 's2', 'title': 'b', 'updatedAt': 2},
            ],
            'hasMore': false,
          },
          'workspace.delete' => {'deleted': true},
          _ => null,
        },
      );
      final app = AppModel(client: client);
      await app.refreshWorkspaces();
      await app.refreshSessionRows();
      final sessionsBefore = app.sessions.length;

      expect(await app.deleteWorkspace('w1'), isTrue);
      expect(
        app.sessions.length,
        sessionsBefore,
        reason: '删除工作区只删注册：把会话一起抹掉就是骗用户（commands.ts:94）',
      );
    });
  });
}
