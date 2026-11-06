/// app 级服务（`lib/data/app_services.dart`）：**端口只有一份，关闭只有一处**。
///
/// ## 这一组守什么
///
/// 1. 两次装配拿到**同一个**端口实例 —— 不是"两个行为一样的实例"。
///    安卓实现构造时就向 `dsh/notifications` 注册方法处理器，而 `MethodChannel`
///    只认*最后*注册的那个；各建一个的写法会让先装配的那台**永远收不到通知上的
///    答复**，症状是"点了允许、没反应"，两端都没有异常也没有日志。
/// 2. **模型释放不关端口**（`App` 还在，另一台还要用它）；只有 `AppServices.dispose`
///    关。这就是"生命周期归 app、释放也归 app" —— 不做
///    `ownsNotifyLifecycle: false` 那种布尔标记，因为那样等于谁都不收尾。
///
/// 装配点"真的只有一处建端口"由 `assembly_invariants_test.dart` 的源码断言钉住；
/// 这里测的是**共享同一个实例**在运行时是什么样。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/notify.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/data/app_services.dart';
import 'package:dsh_mobile/platform/notify_memory.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 一台电脑一个替身（两台电脑就是两个实例，各自有自己的会话与事件流）。
class _Client extends FakeSyncClient {
  _Client({required this.rows});

  final List<Map<String, Object?>> rows;

  /// 连接态：保活的第三条判据读它。本组一律在服务态。
  @override
  conn.ConnectionState get state => conn.ConnectionState.serving;

  @override
  Stream<conn.ConnectionState> get connection => const Stream.empty();

  @override
  Stream<JobFrame> get jobUpdates => const Stream.empty();

  final _sessions = <String, StreamController<SessionDelta>>{};
  final _status = StreamController<SessionStatus>.broadcast();

  @override
  Stream<SessionStatus> get sessionStatus => _status.stream;

  @override
  Stream<SessionDelta> sessionUpdates(String sid) => _sessions
      .putIfAbsent(sid, () => StreamController<SessionDelta>.broadcast())
      .stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> setAppState(AppState state) async {}

  @override
  Future<void> unsubscribe(String sid) async {}

  @override
  Future<void> close() async {}

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'session.list') return {'sessions': rows} as T;
    return <String, Object?>{} as T;
  }

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
}

Map<String, Object?> _row(String sid) => {
  'sid': sid,
  'updatedAt': 0,
  'running': false,
  // 恒发键（`connector/src/handlers.ts:740-744`）：假行必须是线上形状。
  'blank': false,
  'subagent': false,
};

/// 让异步链（`_syncNotices` 的 `unawaited`、`_syncKeepAlive` 的 `await`）跑完。
Future<void> pump() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

// 身份来自 `data.id`（`core/items.dart:121-125`：`i:<approvalId>`），不是事件自带的。
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

void main() {
  test('两次装配拿到**同一个**端口：两台的提醒落在同一份记录里', () async {
    final port = MemoryNotify();
    final services = AppServices(notify: port);
    final clientA = _Client(rows: [_row('a'), _row('b')]);
    final clientB = _Client(rows: [_row('c')]);
    // 装配层做的事就是这个形状：同一个 `services` 分别交给两处装配。
    final a = AppModel(client: clientA, notify: services.notify);
    final b = AppModel(client: clientB, notify: services.notify);
    addTearDown(() async {
      a.dispose();
      b.dispose();
      await clientA.closeAll();
      await clientB.closeAll();
    });

    await a.start();
    await b.start();
    await a.refreshSessionRows();
    await b.refreshSessionRows();
    // A：看着 b，审批发生在 a ⇒ 贴一条审批提醒。
    await a.openSession('a');
    await a.openSession('b');
    await pump();
    clientA.emitDelta('a', _approvalAsked());
    await pump();
    // B：退到后台，它自己那个会话跑完一轮 ⇒ 贴一条完成提醒。
    b.setAppForeground(false);
    clientB.emitStatus('c', true);
    await pump();
    clientB.emitStatus('c', false);
    await pump();

    final wanted = <int>[
      noticeIdOf('approval:i:a1'),
      noticeIdOf('completed:c'),
    ];
    // 两个模型贴的都在这**一个** MemoryNotify 上：各建一个端口的话，
    // 这里只会有其中一条（另一条落在没人看的那个实例里）。
    expect(
      port.visible.keys,
      containsAll(wanted),
      reason: '两个装配必须是同一个端口实例，否则先装配的那台收不到通知上的答复',
    );
    expect(port.shown, hasLength(2), reason: '没有第二个端口在偷偷记账');
  });

  test('模型释放不关端口；关端口只有 AppServices.dispose 一处', () async {
    final port = MemoryNotify();
    final services = AppServices(notify: port);
    final client = _Client(rows: [_row('a')]);
    final app = AppModel(client: client, notify: services.notify);
    addTearDown(() async {
      await services.dispose();
      await client.closeAll();
    });

    await app.start();
    app.dispose();
    await pump();

    // 端口还活着：真端口那边等价于"原生回调还能进来、通知还能贴"。
    // 关掉的端口在这里会抛 `Bad state: Cannot add new events after calling close`。
    expect(() => port.emitApproval('i:x'), returnsNormally);

    // 只有 app 走了才收端口。
    await services.dispose();
    expect(
      () => port.emitApproval('i:y'),
      throwsStateError,
      reason: '`AppServices.dispose` 是唯一的关闭点',
    );
  });
}
