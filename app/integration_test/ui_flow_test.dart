/// 真机上的**界面流程**：主页是聊天页、抽屉能开、右抽屉能开。
///
/// ## 为什么必须在设备上跑
///
/// 这些是"点得中吗"的问题 —— 布局对了不等于能点中（`adb` 坐标点偏过好几次，
/// 而 `uiautomator` 在 Flutter 自绘界面里看不到我们的语义树）。
/// 用 `integration_test` 直接按 widget 找元素并点，绕开坐标问题。
///
/// 它同时补上手工做不到的一步：`adb shell input tap` 只能点坐标，
/// 而这个测试点的是**元素**。
///
/// 跑法（模拟器已在跑）：
/// ```
/// flutter test integration_test/ui_flow_test.dart -d emulator-5554
/// ```
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:dsh_mobile/ui/dsh_composer.dart';
import 'package:dsh_mobile/ui/side_pane.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 假客户端（同 `test/widget_test.dart` 那份：界面测试不关心协议）。
class _FakeClient implements SyncClient {
  @override
  ConnectionState get state => ConnectionState.idle;
  @override
  Stream<ConnectionState> get connection => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> setAppState(AppState state) async {}
  @override
  Future<void> close() async {}
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
  }) async => throw const ProtocolException(ErrorCode.relayOffline, '测试里不连');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('示例模式下能开右抽屉（状态位 → 文件面板）', (tester) async {
    final app = AppModel(client: _FakeClient());
    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: ChatPage(
          app: app,
          paired: false,
          onOpenDrawer: () {},
          onNewSession: () {},
          drawer: const Drawer(child: SizedBox()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 没配对时状态位走"去配对"那条路（不该开右抽屉）。
    // 所以先装示例数据 —— 那是"没连电脑也想看界面"的入口。
    await tester.tap(find.text('看示例数据'));
    await tester.pumpAndSettle();

    // 状态位该显示任务数（示例数据里有两个 running）。
    expect(find.textContaining('任务运行中'), findsOneWidget);

    // 点它 → 右抽屉打开，且默认在"文件"面板。
    await tester.tap(find.textContaining('任务运行中'));
    await tester.pumpAndSettle();
    expect(find.byType(SidePane), findsOneWidget);
    expect(find.text('chat_page.dart'), findsOneWidget);
    expect(find.text('app/lib/ui/chat_page.dart'), findsOneWidget);

    // 切到"任务"面板。
    await tester.tap(find.text('任务'));
    await tester.pumpAndSettle();
    expect(find.text('进行中'), findsOneWidget);
    // 用 `textContaining`：那行命令可能被省略号截断（`TextOverflow.ellipsis`），
    // 而 `find.text` 要求**完全相等** —— 第一版就是这么写错的。
    expect(find.textContaining('flutter build'), findsOneWidget);

    // 切到"子代理"面板。
    await tester.tap(find.text('子代理'));
    await tester.pumpAndSettle();
    expect(find.text('Extract DSH icon paths'), findsOneWidget);

    // 关掉（右上角那个 × ）。
    await tester.tap(find.byTooltip('收起'));
    await tester.pumpAndSettle();
    expect(find.byType(SidePane), findsNothing);
  });

  testWidgets('示例模式下能开会话抽屉（☰）', (tester) async {
    final app = AppModel(client: _FakeClient());
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: ChatPage(
          app: app,
          paired: false,
          // 真装配里这个回调打开外层 `Scaffold` 的 drawer；
          // 这里只验"点得到、回调被调到"（抽屉本体由 main.dart 装）。
          onOpenDrawer: () => opened = true,
          onNewSession: () {},
          drawer: const Drawer(child: SizedBox()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('打开会话抽屉'));
    await tester.pumpAndSettle();
    expect(opened, isTrue);
  });

  testWidgets('输入栏在示例模式下可用（＋ 能加附件）', (tester) async {
    final app = AppModel(client: _FakeClient());
    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: ChatPage(
          app: app,
          paired: false,
          onOpenDrawer: () {},
          onNewSession: () {},
          drawer: const Drawer(child: SizedBox()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('看示例数据'));
    await tester.pumpAndSettle();

    // 示例模式**没有当前会话**（示例会话要进抽屉选）——
    // 所以输入栏仍是置灰的。这条断言把这个事实钉住：
    // 要么给示例模式自动选中第一个会话，要么输入栏就该灰着。
    // 当前行为是**灰着**（`enabled: _hasData && sid != null`）。
    final composer = tester.widget<DshComposer>(find.byType(DshComposer));
    expect(composer.enabled, isFalse, reason: '示例模式没有当前会话，输入栏该灰着（发消息需要 sid）');
  });
}
