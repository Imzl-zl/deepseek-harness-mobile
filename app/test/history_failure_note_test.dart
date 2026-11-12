/// 翻更早的历史失败时，界面必须**说出来**（`HistoryFailureNote`）。
///
/// ## 这条用例钉的是什么
///
/// `AppModel.loadOlderHistory` 失败会把原因记进 `AppModel.historyFailure`，
/// 而那条判据原来**没有任何界面消费者** —— 全仓只有单测读过它。真机上的样子是：
/// 用户往上滑，以为"历史就这么多"，实际上是一次失败的请求；而且
/// `hasOlderHistory` 故意不因失败变假（否则用户会以为历史到此为止），
/// 于是每次滑到顶都会**再发一次注定失败的请求**。
///
/// 两半都要钉：
/// 1. 文案出现在流的最早那一端（`reason` 原样带出来，不吞）；
/// 2. `shouldLoadOlder` 在失败后不再触发（见 `load_older_trigger_test.dart`）。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart' show ConnectionState;
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:dsh_mobile/ui/history_failure_note.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

void main() {
  testWidgets('失败原因原样画出来，且指明怎么恢复', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.light(),
        home: const Scaffold(
          body: HistoryFailureNote(reason: 'session/window-missed'),
        ),
      ),
    );

    expect(find.text('更早的历史没拿到'), findsOneWidget);
    // **原因不吞**：它就是用户唯一能拿去查的东西（也是我们排查的入口）。
    expect(find.textContaining('session/window-missed'), findsOneWidget);
    // 恢复路径必须写出来 —— 契约 §3.1 的动作是"重新订阅走快照"＝重进会话。
    expect(find.textContaining('重新进入这个会话'), findsOneWidget);
  });

  testWidgets('不给假按钮（重试必然再失败一次）', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.light(),
        home: const Scaffold(
          body: HistoryFailureNote(reason: 'session/window-missed'),
        ),
      ),
    );

    expect(find.byType(ElevatedButton), findsNothing);
    expect(find.byType(TextButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
  });

  // **接线用例**：组件自己画得对，不等于它会被挂在屏幕上。
  // 变异校验过：把 `ChatPage` 里 `historyFailure: app.historyFailure` 改成 `null`
  // 之后，只有这一条会红（上面两条组件用例照样绿）—— 那正是"测了组件、没测接线"。
  testWidgets('接线：AppModel 翻页失败 ⇒ 会话页真的出现这一行', (tester) async {
    final client = _FailingPageClient();
    final app = AppModel(client: client);
    addTearDown(app.dispose);
    await app.start();
    await app.openSession('s1');

    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: ChatPage(
          app: app,
          paired: true,
          onConnect: () {},
          onRePair: () {},
          onOpenDrawer: () {},
          onNewSession: () {},
          drawer: const Drawer(child: SizedBox()),
        ),
      ),
    );
    // **不用 `pumpAndSettle`**：会话页里有活时钟与淡出动画，永远不 settle
    // （tools.md 的"有界等待"那条教训）。
    // 窗口里先有一条（`loadOlderHistory` 的切点取自"当前最早一条"）。
    // **`Future.delayed` 在 `testWidgets` 的假时钟里不会自己走**，要用 pump 推。
    client.seedWindow();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(HistoryFailureNote), findsNothing, reason: '还没翻过页');

    // 翻一页（失败），再重画。
    expect(await app.loadOlderHistory('s1'), isFalse);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.byType(HistoryFailureNote),
      findsOneWidget,
      reason: '失败必须被喂进界面（没有消费者 = 用户以为"历史就这么多"）',
    );
    expect(find.textContaining('session/window-missed'), findsOneWidget);

    // **重进会话就把提示撤掉**：重新订阅成功拿到的是新快照，
    // 上一次的 `window-missed` 已经不成立。不清的话它会永远挂在最早那一端。
    await app.openSession('s1');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(HistoryFailureNote), findsNothing);
  });
}

/// 翻页永远回 `session/window-missed` 的替身（接线用例用）。
class _FailingPageClient extends FakeSyncClient {
  final _events = StreamController<SessionDelta>.broadcast();

  @override
  ConnectionState get state => ConnectionState.serving;
  @override
  Stream<ConnectionState> get connection => const Stream.empty();
  @override
  Stream<JobFrame> get jobUpdates => const Stream.empty();
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => _events.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> setAppState(AppState state) async {}
  @override
  bool hasOlderHistory(String sid) => true;

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async => <String, Object?>{} as T;

  /// 推一条窗口里已有的事件（否则 `loadOlderHistory` 在第一道门就返回）。
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
  Future<SessionPage> page({
    required String sid,
    required int beforeSeq,
    int maxMessages = SyncClient.kHistoryPageMaxMessages,
    int minMessages = SyncClient.kHistoryPageMinMessages,
    int minTurns = SyncClient.kHistoryPageMinTurns,
  }) async => const SessionPage(
    events: [],
    hasMore: true,
    failure: 'session/window-missed',
  );
}
