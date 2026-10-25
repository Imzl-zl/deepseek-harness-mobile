/// 运行态（`runningOf`）的**两个写入面**：`session.list` 那一包与 `status` 帧。
///
/// ## 这一组守什么
///
/// "这个会话在不在跑"在 2026-10-24（W4）之后由**宿主推送**维护：连接器把
/// `api-session/status` 转成 `status` 帧（`connector/src/protocol/frame.ts` 的 `status`）。
/// 手机侧只剩两处写入，都走 `_setRunning`：
///
/// - `session.list` 那一包：**按原样覆盖**（与 DSH 浏览器同一条，
///   `session-controller/src/client/sessions/manager.ts:248-253`）—— 断线期间收口的那一轮
///   靠它在重连后纠正；
/// - `status` 帧：宿主 `agent/status` 的实时转发。
///
/// 原来那套"数 `turn/start` / `turn/end` + 重连按代号重建"已经删掉，
/// 它的护栏用例（"旧快照不许钉死 true / 不许关掉刚起的一轮"）随行为一起删。
///
/// 最后一条 widget 级：`ChatPage` 重连后运行条消失、输入栏主键从「停止」回到「发送」。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 能推连接状态、能换 `session.list` 应答、能推事件与**运行态帧**的替身。
///
/// `listGate` 用来把"帧先到、快照后到"排出来：重连的 `session.list` 会卡在
/// 它上面，测试先推一帧，再放行快照 —— 那正是真机上"请求已发出、应答还在路上"的窗口。
class _ReconnectClient extends FakeSyncClient {
  _ReconnectClient({required List<Map<String, Object?>> rows}) : _rows = rows;

  List<Map<String, Object?>> _rows;
  final _states = StreamController<conn.ConnectionState>.broadcast();
  final _sessions = StreamController<SessionDelta>.broadcast();
  final _status = StreamController<SessionStatus>.broadcast();
  conn.ConnectionState _state = conn.ConnectionState.serving;

  /// 非空时，`session.list` 会等它。
  Completer<void>? listGate;

  /// 非空时，`session.list` 直接抛它。
  Exception? listFailure;

  set rows(List<Map<String, Object?>> value) => _rows = value;

  void emitState(conn.ConnectionState next) {
    _state = next;
    _states.add(next);
  }

  void emit(String sid, SessionEvent event) {
    _sessions.add(SessionDelta(sid: sid, events: [event], transient: const {}));
  }

  /// 推一条运行态（宿主 `api-session/status` 的转发）。
  void emitStatus(String sid, bool running) {
    _status.add(SessionStatus(sid: sid, running: running));
  }

  @override
  conn.ConnectionState get state => _state;
  @override
  Stream<conn.ConnectionState> get connection => _states.stream;
  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();
  @override
  Stream<SessionStatus> get sessionStatus => _status.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> reconnect() => start();
  @override
  Future<void> setAppState(AppState state) async {}

  @override
  Future<void> close() async {
    await _states.close();
    await _sessions.close();
    await _status.close();
  }

  @override
  Future<void> unsubscribe(String sid) async {}

  @override
  Stream<SessionDelta> sessionUpdates(String sid) => _sessions.stream;

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'session.list') {
      final gate = listGate;
      if (gate != null) await gate.future;
      final failure = listFailure;
      if (failure != null) throw failure;
      return {'sessions': _rows} as T;
    }
    // 其余方法（投影 / 任务 / 工作区 / 设置…）回空对象：本组只关心运行态。
    return <String, Object?>{} as T;
  }
}

Map<String, Object?> _row({required bool running}) => {
  'sid': 's1',
  'updatedAt': 0,
  'running': running,
  // 恒发键（`connector/src/handlers.ts:740-744`）：假行必须是线上形状。
  'blank': false,
  'subagent': false,
};

SessionEvent _turn(String type, int seq, int time) => SessionEvent(
  itemId: '$type-$seq',
  type: type,
  seq: seq,
  time: time,
  data: const <String, Object?>{},
);

/// 一条**真形状**的用户消息（`_ChatTab` 要靠一条可见条目才会建对话流）。
SessionEvent _userMessage() => const SessionEvent(
  itemId: 'm:m-1',
  type: 'user/message',
  seq: 1,
  time: 1,
  data: <String, Object?>{
    'id': 'm-1',
    'role': 'user',
    'source': <String, Object?>{'kind': 'user'},
    'content': '在吗',
  },
);

/// 让 `_onConnectionChanged` 里 `unawaited(refreshSessions(...))` 的异步链跑完。
Future<void> _settle() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

/// 起一个已经在服务态、已读到第一包列表、已打开 `s1` 的 AppModel。
Future<AppModel> _started(_ReconnectClient client) async {
  final app = AppModel(client: client);
  addTearDown(app.dispose);
  await app.start();
  await app.refreshSessions();
  await app.openSession('s1');
  return app;
}

void main() {
  test('断线期间收口（第一包是快照页）：重连后不再显示运行中', () async {
    final client = _ReconnectClient(rows: [_row(running: true)]);
    final app = await _started(client);
    expect(app.runningOf('s1'), isTrue, reason: '第一包快照说在跑（初值）');

    // 断线。期间电脑侧收口了，但手机没收到 turn/end。
    client.emitState(conn.ConnectionState.backoff);
    client.rows = [_row(running: false)];
    client.emitState(conn.ConnectionState.serving);
    await _settle();

    expect(
      app.runningOf('s1'),
      isFalse,
      reason: '快照页没有事件类型，turn/end 不会重放；新快照说 false 就必须撤',
    );
  });

  test('断线期间没收到口、这一轮仍在跑：重连后仍是在跑', () async {
    final client = _ReconnectClient(rows: [_row(running: true)]);
    final app = await _started(client);
    expect(app.runningOf('s1'), isTrue);

    client.emitState(conn.ConnectionState.backoff);
    // 断线期间没有 turn/end，电脑侧也还在跑。
    client.emitState(conn.ConnectionState.serving);
    await _settle();

    expect(app.runningOf('s1'), isTrue, reason: '重建不能把还在跑的那一轮关掉（快照说 true）');
  });

  test('`status` 帧是实时真值：true 起、false 收，且收口清掉活时钟起点', () async {
    final client = _ReconnectClient(rows: [_row(running: false)]);
    final app = await _started(client);
    expect(app.runningOf('s1'), isFalse);

    // 宿主说开始跑了（真实路径上 `turn/start` 事件同时带来 time）。
    client.emit('s1', _turn('turn/start', 1, 1700000000000));
    client.emitStatus('s1', true);
    await _settle();
    expect(app.runningOf('s1'), isTrue);
    expect(
      app.turnStartedAtOf('s1'),
      1700000000000,
      reason: '活时钟起点仍来自 turn/start 的 time',
    );

    client.emitStatus('s1', false);
    await _settle();
    expect(app.runningOf('s1'), isFalse);
    expect(app.turnStartedAtOf('s1'), isNull, reason: '收口要把起点清掉，否则下次运行条从旧起点算');
  });

  test('重连那包 session.list 读失败：保持原值，不猜"已经收口"', () async {
    final client = _ReconnectClient(rows: [_row(running: true)]);
    final app = await _started(client);
    expect(app.runningOf('s1'), isTrue);

    client.emitState(conn.ConnectionState.backoff);
    client.listFailure = const ProtocolException(
      ErrorCode.relayOffline,
      '中转不可达',
    );
    client.emitState(conn.ConnectionState.serving);
    await _settle();

    expect(app.runningOf('s1'), isTrue, reason: '拿不到新快照就什么都不知道：撤掉等于把还在跑的一轮关掉');
  });

  testWidgets('ChatPage：重连后运行条消失、输入栏主键从停止回到发送', (tester) async {
    final client = _ReconnectClient(rows: [_row(running: true)]);
    final app = AppModel(client: client);
    addTearDown(app.dispose);
    await app.start();
    await app.refreshSessions();
    await app.openSession('s1');
    // 一条可见条目：没有它，`_ChatTab` 会走空态，运行条根本不建。
    //
    // **不要在这里 `await Future.delayed`**：`testWidgets` 跑在 fake async 区，
    // 没有 `pump` 推进时钟的话那个 Future 永远不完成（本轮踩过，整条用例挂住）。
    client.emit('s1', _userMessage());
    await tester.pumpWidget(_chatPage(app));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('running')), findsOneWidget);
    expect(_primaryTooltip(tester), '停止');

    client.emitState(conn.ConnectionState.backoff);
    client.rows = [_row(running: false)];
    client.emitState(conn.ConnectionState.serving);
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey('running')),
      findsNothing,
      reason: '断线期间收口的那一轮，重连后运行条必须消失',
    );
    expect(_primaryTooltip(tester), '发送', reason: '输入栏从「停止」回到可发送（不再停在运行态）');
    // 收掉运行条的 1 秒时钟（不留 pending timer 给下一个用例）。
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ChatPage：**只靠 `status` 帧**也能让运行条起来/收掉（不再依赖 turn 事件）', (
    tester,
  ) async {
    final client = _ReconnectClient(rows: [_row(running: false)]);
    final app = AppModel(client: client);
    addTearDown(app.dispose);
    await app.start();
    await app.refreshSessions();
    await app.openSession('s1');
    client.emit('s1', _userMessage());
    await tester.pumpWidget(_chatPage(app));
    await tester.pump();
    expect(find.byKey(const ValueKey('running')), findsNothing);

    // 宿主说这一轮开始跑了（真实路径上同时会有 `turn/start` 提供时钟起点）。
    client.emit('s1', _turn('turn/start', 2, 1700000000000));
    client.emitStatus('s1', true);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('running')), findsOneWidget);
    expect(_primaryTooltip(tester), '停止');

    client.emitStatus('s1', false);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const ValueKey('running')), findsNothing);
    expect(_primaryTooltip(tester), '发送');
    await tester.pumpWidget(const SizedBox());
  });
}

Widget _chatPage(AppModel app) => MaterialApp(
  theme: DshTheme.dark(),
  home: ChatPage(
    app: app,
    onOpenDrawer: () {},
    onNewSession: () {},
    drawer: const Drawer(child: SizedBox()),
  ),
);

String? _primaryTooltip(WidgetTester tester) => tester
    .widget<Tooltip>(
      find
          .descendant(
            of: find.byKey(const Key('composer-primary')),
            matching: find.byType(Tooltip),
          )
          .first,
    )
    .message;
