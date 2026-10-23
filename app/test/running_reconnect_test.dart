/// 断线 → 重连：运行条（`_runningSids`）必须能按第一包收口。
///
/// ## 这一组守什么
///
/// 断线期间收口的一轮，`turn/end` **不保证**以事件形式回来：重连的第一包按协议
/// 只有两种结果 —— **增量**（含漏掉的 `turn/end`）或**快照页**（只有条目
/// `{seq,itemId,text}`，没有事件类型；`connector/src/protocol/recovery.ts:298-311`，
/// fixture `01-normal-delta` / `04-window-missed-baseline`）。旧实现里
/// `_runningSids` 只由 `turn/end` 撤，于是快照页那条 sid 永远留着 ——
/// 运行条转到杀 App、输入栏永远「排队发送」。
///
/// 修法是"重连时按 `session.list` 重建"，并且**事件流仍然赢过快照**：
///
/// - 断线期间收口（新快照说 `false`，或增量里的 `turn/end` 先于快照落地）⇒ `false`；
/// - 断线期间没收到口、这一轮仍在跑（新快照说 `true`，或增量里的 `turn/start`
///   先于快照落地）⇒ `true`；
/// - 重连那包 `session.list` 读失败 ⇒ 保持原值（不知道就不撤）。
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

/// 能推连接状态、能换 `session.list` 应答、能推事件的替身。
///
/// `listGate` 用来把"事件先到、快照后到"排出来：重连的 `session.list` 会卡在
/// 它上面，测试先推一条事件，再放行快照 —— 那正是真机上"请求已发出、应答
/// 还在路上"的窗口。
class _ReconnectClient extends FakeSyncClient {
  _ReconnectClient({required List<Map<String, Object?>> rows}) : _rows = rows;

  List<Map<String, Object?>> _rows;
  final _states = StreamController<conn.ConnectionState>.broadcast();
  final _sessions = StreamController<SessionDelta>.broadcast();
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

  @override
  conn.ConnectionState get state => _state;
  @override
  Stream<conn.ConnectionState> get connection => _states.stream;
  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();
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

  test('增量里的 turn/end 先于快照落地：旧快照的 true 不许把它加回来', () async {
    final client = _ReconnectClient(rows: [_row(running: true)]);
    final app = await _started(client);
    expect(app.runningOf('s1'), isTrue);

    client.emitState(conn.ConnectionState.backoff);
    final gate = Completer<void>();
    client.listGate = gate;
    // 这一包是在 turn/end 之前算的：它仍说 true。
    client.rows = [_row(running: true)];
    client.emitState(conn.ConnectionState.serving);
    await _settle();

    // 重连的补课事件（增量）先说这一轮结束了。
    client.emit('s1', _turn('turn/end', 2, 1700000040000));
    await _settle();
    expect(app.runningOf('s1'), isFalse);

    gate.complete();
    await _settle();
    expect(
      app.runningOf('s1'),
      isFalse,
      reason: '这一包比 turn/end 旧：不许用旧 true 把刚结束的一轮钉死',
    );
  });

  test('增量里的 turn/start 先于快照落地：旧快照的 false 不许关掉刚起的一轮', () async {
    final client = _ReconnectClient(rows: [_row(running: false)]);
    final app = await _started(client);
    expect(app.runningOf('s1'), isFalse);

    client.emitState(conn.ConnectionState.backoff);
    final gate = Completer<void>();
    client.listGate = gate;
    // 这一包是在 turn/start 之前算的：它仍说 false。
    client.rows = [_row(running: false)];
    client.emitState(conn.ConnectionState.serving);
    await _settle();

    client.emit('s1', _turn('turn/start', 1, 1700000000000));
    await _settle();
    expect(app.runningOf('s1'), isTrue);

    gate.complete();
    await _settle();
    expect(
      app.runningOf('s1'),
      isTrue,
      reason: '这一包比 turn/start 旧：不许用旧 false 关掉刚起的一轮',
    );
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
