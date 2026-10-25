/// 通知与后台保活的**语义**（端口替身 `MemoryNotify`，不碰平台通道）。
///
/// ## 这一组守什么
///
/// 1. 保活的三条判据：**退到后台 + 有通知权限 + 连接在服务态**。
///    缺任何一条都不起服务（没权限还起服务 = 一条看不见的通知 + 白耗电）。
/// 2. 提醒**只从既有事实派生**：审批（本地 `ApprovalItem` 未决）、提问
///    （`ask_user_question` 的 `tool/call` 还没结果）、以及"你没看着时跑完了一轮"
///    （`completionUnread`）。**没有第四份状态机、不落盘**。
/// 3. 前台且正看着那个会话 ⇒ **不提醒**。
/// 4. 通知上的「允许一次 / 拒绝」走既有唯一出口 `interaction.respond`，
///    载荷是 DSH 的 outcome 值（`allowed-once` / 空 `selected`）——
///    **没有"总是允许"**。
/// 5. 待处理消失（有人答了 / decided）⇒ 撤掉那条通知。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/notify.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/platform/notify_memory.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 每个 sid 一条独立的 delta 流（真客户端就是每会话一条）。
class _Client extends FakeSyncClient {
  _Client({required this.rows});

  List<Map<String, Object?>> rows;

  /// 连接态（保活的第三条判据读它）。本组一律在服务态。
  @override
  conn.ConnectionState get state => conn.ConnectionState.serving;

  final _sessions = <String, StreamController<SessionDelta>>{};
  final _status = StreamController<SessionStatus>.broadcast();
  final calls =
      <({String method, Map<String, Object?> params, String? requestId})>[];

  void emitDelta(String sid, SessionEvent event) {
    _sessions
        .putIfAbsent(sid, () => StreamController<SessionDelta>.broadcast())
        .add(SessionDelta(sid: sid, events: [event], transient: const {}));
  }

  void emitStatus(String sid, bool running) =>
      _status.add(SessionStatus(sid: sid, running: running));

  Future<void> closeAll() async {
    await _status.close();
    for (final controller in _sessions.values) {
      await controller.close();
    }
  }

  @override
  Stream<conn.ConnectionState> get connection => const Stream.empty();
  @override
  Stream<JobFrame> get jobUpdates => const Stream.empty();
  @override
  Stream<SessionStatus> get sessionStatus => _status.stream;
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => _sessions
      .putIfAbsent(sid, () => StreamController<SessionDelta>.broadcast())
      .stream;
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
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    calls.add((method: method, params: params, requestId: requestId));
    if (method == 'session.list') return {'sessions': rows} as T;
    return <String, Object?>{} as T;
  }
}

Map<String, Object?> _row(String sid) => {
  'sid': sid,
  'updatedAt': 0,
  'running': false,
  // 恒发键（`connector/src/handlers.ts:740-744`）：假行必须是线上形状。
  'blank': false,
  'subagent': false,
};

/// 让异步链（`_syncKeepAlive` 的 `await`、`_syncNotices` 的 `unawaited`）跑完。
Future<void> pump() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

// 身份来自 `data.id`（`core/items.dart:121-125`：`i:<approvalId>`），
// 不是事件里自带的 —— 手写 fixture 少这个键就整条被丢掉。
SessionEvent _approvalAsked() => const SessionEvent(
  itemId: 'i:a1',
  type: 'approval/asked',
  seq: 1,
  time: 1,
  data: <String, Object?>{
    'id': 'a1',
    'toolName': 'Bash',
    'reason': '要写工作区外的文件',
  },
);

SessionEvent _approvalDecided() => const SessionEvent(
  itemId: 'i:a1',
  type: 'approval/decided',
  seq: 2,
  time: 2,
  data: <String, Object?>{'id': 'a1', 'decision': 'allowed-once'},
);

void main() {
  late _Client client;
  late MemoryNotify notify;
  late AppModel app;

  setUp(() async {
    client = _Client(rows: [_row('a'), _row('b')]);
    notify = MemoryNotify();
    app = AppModel(client: client, notify: notify);
    await app.start();
    // 会话清单要先落地：通知的那份"期望集合"是按 `_sessions` 走的
    // （与抽屉/待处理计数同一个数据面）。
    await app.refreshSessions();
    await app.openSession('b');
    await pump();
  });

  tearDown(() async {
    app.dispose();
    await client.closeAll();
  });

  test('退到后台 + 有权限 + 在服务态 ⇒ 起保活；回前台 ⇒ 停', () async {
    app.setAppForeground(false);
    await pump();
    expect(notify.keepAliveCount, 1, reason: '三条判据都成立才起服务');

    app.setAppForeground(true);
    await pump();
    expect(notify.keepAliveCount, 0, reason: '回前台就不需要那条常驻了');
  });

  test('保活生效时退后台照报 foreground（连接不因退后台被断）', () async {
    app.setAppForeground(false);
    await pump();
    expect(
      app.connectionForeground(false),
      isTrue,
      reason: '有权限 + 在服务态 ⇒ 那条连接要活着（否则服务只是白保进程）',
    );

    // 权限被收回 ⇒ 回到老行为：退后台就断。
    notify.granted = false;
    app.setAppForeground(true);
    await pump();
    app.setAppForeground(false);
    await pump();
    expect(app.connectionForeground(false), isFalse);
  });

  test('没有通知权限 ⇒ 不起服务（看不见的通知只是白耗电）', () async {
    notify.granted = false;
    app.setAppForeground(false);
    await pump();
    expect(notify.keepAliveCount, 0);
  });

  test('别的会话有人等审批 ⇒ 贴一条带两个按钮的通知', () async {
    await app.openSession('a'); // 订阅它，才能收到它的条目
    await app.openSession('b'); // 再切回 b：审批发生在"我看的会话之外"
    await pump();

    client.emitDelta('a', _approvalAsked());
    await pump();

    final approvals = notify.shown
        .where((n) => n.kind == NoticeKind.approval)
        .toList();
    expect(approvals, hasLength(1));
    expect(approvals.single.itemId, 'i:a1', reason: '按钮的键就是卡的 itemId');
    expect(approvals.single.allowLabel, '允许一次');
    expect(approvals.single.denyLabel, '拒绝');
    expect(approvals.single.sid, 'a');
  });

  test('正在看着那个会话 ⇒ 不贴（结果就在眼前）', () async {
    await app.openSession('a');
    await pump();
    client.emitDelta('a', _approvalAsked());
    await pump();
    expect(notify.shown.where((n) => n.kind == NoticeKind.approval), isEmpty);
  });

  test('有人答了（decided）⇒ 撤掉那条通知', () async {
    await app.openSession('a');
    await app.openSession('b');
    await pump();
    client.emitDelta('a', _approvalAsked());
    await pump();
    final id = noticeIdOf('approval:i:a1');
    expect(notify.visible.containsKey(id), isTrue);

    client.emitDelta('a', _approvalDecided());
    await pump();
    expect(notify.visible.containsKey(id), isFalse);
    expect(notify.cancelled, contains(id));
  });

  test('通知上按「允许一次」⇒ interaction.respond，载荷是 allowed-once', () async {
    await app.openSession('a');
    await app.openSession('b');
    await pump();
    client.emitDelta('a', _approvalAsked());
    await pump();

    notify.emitApproval('i:a1');
    await pump();

    final respond = client.calls
        .where((c) => c.method == 'interaction.respond')
        .toList();
    expect(respond, hasLength(1));
    expect(respond.single.params['sid'], 'a');
    expect(respond.single.params['itemId'], 'i:a1');
    // **幂等键就是 itemId**（契约 §5.7）：连点两次不会变成两次授权。
    expect(respond.single.requestId, 'i:a1');
    final answers = respond.single.params['answers']! as List;
    expect((answers.single as Map)['id'], 'i:a1');
    expect((answers.single as Map)['selected'], ['allowed-once']);
  });

  test('通知上按「拒绝」⇒ 空 selected（不是缺字段）', () async {
    await app.openSession('a');
    await app.openSession('b');
    await pump();
    client.emitDelta('a', _approvalAsked());
    await pump();

    notify.emitApproval('i:a1', allowedOnce: false);
    await pump();

    final respond = client.calls.firstWhere(
      (c) => c.method == 'interaction.respond',
    );
    final answers = respond.params['answers']! as List;
    expect((answers.single as Map)['selected'], isEmpty);
    expect((answers.single as Map).containsKey('custom'), isFalse);
  });

  test('你没看着它跑完 ⇒ 一条完成通知；切过去就撤', () async {
    app.setAppForeground(false);
    await pump();
    client.emitStatus('a', true);
    await pump();
    client.emitStatus('a', false);
    await pump();

    final completed = notify.shown.where((n) => n.kind == NoticeKind.completed);
    expect(completed, hasLength(1));
    expect(completed.single.sid, 'a');

    app.setAppForeground(true);
    await app.openSession('a');
    await pump();
    expect(
      notify.visible.containsKey(noticeIdOf('completed:a')),
      isFalse,
      reason: '看见了就不该还挂着',
    );
  });
}
