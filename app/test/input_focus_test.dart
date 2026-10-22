/// 输入法**只许由用户点输入框引起** —— 抽屉 / 弹层 / 路由的开合不许把它叫回来。
///
/// ## 这条测守的是什么（真机复现过的因果链，见 `lib/ui/input_focus.dart`）
///
/// 抽屉打开时 `DrawerController` 把焦点搬进抽屉
/// （`packages/flutter/lib/src/material/drawer.dart:538`）；
/// 关闭时框架把**页面里上一次的焦点节点**设回 first focus
/// （`packages/flutter/lib/src/widgets/focus_manager.dart:1444-1461`）——
/// 那通常就是输入栏，而 `EditableText._handleFocusChanged` 一拿回焦点就开输入连接
/// （`packages/flutter/lib/src/widgets/editable_text.dart:4752-4753`）。
///
/// 真机（2026-10-22）：抽屉关掉后 `dumpsys input_method` 的 `mInputShown` 由
/// `false` 变 `true`，就是要修的那件事。
///
/// ## 判据为什么是这两条
///
/// - `focusNode.hasFocus`：**根因面**。焦点回到输入框就一定会开输入连接，
///   与 `TestTextInput` 是否记账无关。
/// - `testTextInput.isVisible`：**用户面**。它是 `TextInput.show` 的平台调用
///   （`packages/flutter_test/lib/src/test_text_input.dart` 的 `_isVisible`），
///   即"输入法被要求弹出"。
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:dsh_mobile/ui/dsh_composer.dart';
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

/// 起一页**真的** `ChatPage`（含它自己的 `Scaffold.drawer` 与输入栏）。
///
/// 用真页而不是拼一个 `Scaffold`：要钉的正是**接线**——
/// `Scaffold.onDrawerChanged` 那一行如果被删掉，只有真页能红。
Future<void> _pumpChat(WidgetTester tester) async {
  final app = AppModel(client: _FakeClient());
  await tester.pumpWidget(
    MaterialApp(
      theme: DshTheme.dark(),
      home: ChatPage(
        app: app,
        paired: false,
        onOpenDrawer: () {},
        onNewSession: () {},
        drawer: const Drawer(child: SizedBox(height: 200)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('看示例数据'));
  await tester.pumpAndSettle();
  // 有当前会话，输入栏才活（否则它整块不在树里）。
  await app.openSession('preview-1');
  await tester.pumpAndSettle();
}

Finder get _composerField => find.descendant(
  of: find.byType(DshComposer),
  matching: find.byType(TextField),
);

Finder get _composerEditable => find.descendant(
  of: find.byType(DshComposer),
  matching: find.byType(EditableText),
);

void main() {
  testWidgets('关掉抽屉后焦点不许回到输入框（输入法不许自己弹出来）', (tester) async {
    await _pumpChat(tester);

    // 1) 用户点输入框 —— **这是唯一允许输入法出现的路径**。
    await tester.tap(_composerField);
    await tester.pumpAndSettle();
    expect(
      tester.widget<EditableText>(_composerEditable).focusNode.hasFocus,
      isTrue,
      reason: '点输入框之后它应当有焦点（否则下面的断言是恒真的）',
    );
    expect(tester.testTextInput.isVisible, isTrue, reason: '点输入框之后输入法应当被叫起来');

    // 2) 开抽屉（走顶栏那枚 ☰，与真机同一条路）。
    await tester.tap(find.byTooltip('打开会话抽屉'));
    await tester.pumpAndSettle();
    final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold).first);
    expect(scaffold.isDrawerOpen, isTrue, reason: '抽屉没开，后面的断言没有意义');

    // 3) 点空白关闭（抽屉遮罩在面板右侧，与手点空白是同一条 `close()`）。
    await tester.tapAt(const Offset(700, 300));
    await tester.pumpAndSettle();
    expect(scaffold.isDrawerOpen, isFalse, reason: '抽屉没关上');

    // 4) 判据：焦点没有回到输入框，输入法也没有被重新叫起来。
    expect(
      tester.widget<EditableText>(_composerEditable).focusNode.hasFocus,
      isFalse,
      reason: '关掉抽屉后焦点回到了输入框 —— 下一步输入法就会自己弹出来',
    );
    expect(tester.testTextInput.isVisible, isFalse, reason: '关掉抽屉后输入法被重新叫起来了');
  });
}
