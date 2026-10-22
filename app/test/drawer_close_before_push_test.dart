/// 「从抽屉里 push 一个全屏页」回来之后，抽屉必须是**关着的**。
///
/// ## 测的是什么（真机 2026-10-22 复现三次的那条回归）
///
/// 抽屉不是路由：打开它给**当前路由**挂一个 `LocalHistoryEntry`
/// （`packages/flutter/lib/src/material/drawer.dart:529-541`）。所以"收抽屉"
/// 曾写成 `Navigator.maybePop()`。那条路**不成立**：
///
/// 1. `NavigatorState.maybePop` 是 `async`，`await route.willPop()`
///    （`packages/flutter/lib/src/widgets/navigator.dart:5539`）；
///    `willPop` 本身也是 `async`（`widgets/routes.dart:934` / `:2008`）——
///    于是 `pop()` 一定发生在**下一拍**。
/// 2. 然后它重新取一次栈顶，发现"不是刚才那个"就直接放弃：
///    `if (lastEntry != newLastEntry) { return true; }`
///    （`navigator.dart:5547-5551`）。
/// 3. 而我们正是在同一拍 push 了设置页 ⇒ 抽屉的 history entry 一个都没被
///    `didPop`（`routes.dart:950-967`）摘掉 ⇒ 抽屉原样开着。
///
/// 现在的生产通路是 `ChatPageState.openFromDrawer`（先 `closeDrawer()` 再
/// `push`），本测就调它 —— 把接线改回 `maybePop()` 会让这条红。
///
/// ## 判据
///
/// 回到聊天页后 `Scaffold.isDrawerOpen == isFalse`（与真机同一条）。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

class _FakeClient extends FakeSyncClient {
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
  }) async => throw const ProtocolException(ErrorCode.relayOffline, '测试里不连');
}

/// 起一页**真的** `ChatPage`（含它自己的 `Scaffold.drawer`），并返回它的状态。
Future<ChatPageState> _pumpChat(
  WidgetTester tester,
  GlobalKey<NavigatorState> navKey,
) async {
  final chatKey = GlobalKey<ChatPageState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navKey,
      theme: DshTheme.dark(),
      home: ChatPage(
        key: chatKey,
        app: AppModel(client: _FakeClient()),
        paired: false,
        onOpenDrawer: () => chatKey.currentState?.openDrawer(),
        onNewSession: () {},
        drawer: const Drawer(child: SizedBox(height: 200)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return chatKey.currentState!;
}

ScaffoldState _chatScaffold(WidgetTester tester) => tester.state<ScaffoldState>(
  find
      .descendant(of: find.byType(ChatPage), matching: find.byType(Scaffold))
      .first,
);

void main() {
  testWidgets('从抽屉 push 全屏页再返回：抽屉必须已经关掉', (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    final chat = await _pumpChat(tester, navKey);

    // 1) 开抽屉（走顶栏那枚 ☰，与真机同一条路）。
    await tester.tap(find.byTooltip('打开会话抽屉'));
    await tester.pumpAndSettle();
    expect(
      _chatScaffold(tester).isDrawerOpen,
      isTrue,
      reason: '抽屉没开，后面的断言没有意义',
    );

    // 2) 走**生产通路**打开一个全屏页（设置页在真机上就是这条）。
    unawaited(
      chat.openFromDrawer(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Center(child: Text('全屏占位页'))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('全屏占位页'), findsOneWidget, reason: '全屏页应当被 push 进来');

    // 3) 返回聊天页。
    navKey.currentState!.pop();
    await tester.pumpAndSettle();

    // 判据：抽屉必须是关的 —— 这就是真机上"返回后抽屉还开着"的那条回归。
    expect(
      _chatScaffold(tester).isDrawerOpen,
      isFalse,
      reason: '返回后抽屉还开着 = 收抽屉那句没生效（见本文件头）',
    );
  });
}
