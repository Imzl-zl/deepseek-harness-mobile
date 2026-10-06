/// 接管卡在**聊天页里的接线**（不是接管逻辑本身 —— 那是 `takeover_test.dart`）。
///
/// ## 为什么这一组放在 `test/` 而不是 `integration_test/`
///
/// 它验的是"接管卡接进了底部、且与输入栏共存"，那是**纯 widget 组装**，
/// 不需要平台插件。而 `integration_test/` 那一组（真机）里也有同一条 ——
/// 两边都留是因为它们的失败原因不同：
///
/// - 这一条：接线错了（比如忘了把 `TakeoverPanel` 放进 Column）；
/// - 真机那条：**点得中吗**（布局对了不等于能点中）。
///
/// 实测教训：模拟器在这台机器上跑 `integration_test` 时**反复崩**
///（进程直接消失，日志无异常），所以关键接线必须有单测兜底 ——
/// 否则"真机跑不起来"会等于"这条路径完全没验"。
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:dsh_mobile/ui/dsh_composer.dart';
import 'package:dsh_mobile/ui/takeover.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

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
        drawer: const Drawer(child: SizedBox()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('看示例数据'));
  await tester.pumpAndSettle();
  // 需要一个当前会话，输入栏与统计条才活。
  await app.openSession('preview-1');
  await tester.pumpAndSettle();
}

/// 走 `＋` 菜单 → "演示：接管输入栏"。
Future<void> _enqueueDemo(WidgetTester tester) async {
  await tester.tap(find.byTooltip('添加文件或调用指令'));
  await tester.pumpAndSettle();
  // **先滚到它再点**：菜单 6 项，最后一项在 320×640 上超出屏幕
  //（`tap` 会报 "would not hit test"）。
  await tester.ensureVisible(find.text('演示：接管输入栏'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('演示：接管输入栏'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('接管卡接进底部，且**输入栏仍在**（并排而不是替换）', (tester) async {
    await _pumpChat(tester);
    // 装之前：只有输入栏。
    expect(find.byType(TakeoverPanel), findsOneWidget);
    expect(find.text('等待审批'), findsNothing);

    await _enqueueDemo(tester);

    // 装之后：接管卡在，输入栏**也还在**。
    expect(find.text('等待审批'), findsOneWidget);
    expect(
      find.byType(DshComposer),
      findsOneWidget,
      reason: '接管卡与输入栏并排（手机上更省高度，且不会让用户以为输入框不见了）',
    );
    // 接管卡在输入栏**上方**。
    final card = tester.getRect(find.text('等待审批'));
    final composer = tester.getRect(find.byType(DshComposer));
    expect(
      card.bottom,
      lessThanOrEqualTo(composer.top + 1),
      reason: '接管卡该在输入栏上方',
    );
  });

  testWidgets('队列是瀑布：审批答完才轮到提问，再答完才轮到计划', (tester) async {
    await _pumpChat(tester);
    await _enqueueDemo(tester);

    // ① 审批。
    expect(find.text('等待审批'), findsOneWidget);
    expect(find.text('等待回答'), findsNothing, reason: '瀑布：一次只出一个');

    await tester.tap(find.text('允许一次'));
    await tester.pumpAndSettle();

    // ② 提问。
    expect(find.text('等待回答'), findsOneWidget);
    expect(find.text('等待确认计划'), findsNothing);
    // 推荐是独立徽标（不在标签里）。
    expect(find.text('推荐'), findsOneWidget);
    expect(find.textContaining('（推荐）'), findsNothing);

    // 未回答时提交无效。
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();
    expect(find.text('等待回答'), findsOneWidget, reason: '没答就不该走');

    await tester.tap(find.text('先只拆资源束'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();

    // ③ 计划。
    expect(find.text('等待确认计划'), findsOneWidget);
    await tester.tap(find.text('同意执行'));
    await tester.pumpAndSettle();

    // 三个都答完 → 接管卡消失，输入栏还在。
    expect(find.text('等待确认计划'), findsNothing);
    expect(find.byType(DshComposer), findsOneWidget);
  });

  testWidgets('完全权限下审批**不入队**（但提问与计划照常）', (tester) async {
    // §7.10：完全权限下审批不再逐次确认 —— 那是"已授权"的**结果**。
    // 这一条在接管层有用例，这里验的是**接线**：切了权限档，
    // 聊天页里的接管队列真的跟着变了。
    await _pumpChat(tester);

    // 先切到完全权限（走权限 sheet + 风险门）。
    await tester.tap(find.byTooltip('工作区内可改'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完全权限'));
    await tester.pumpAndSettle();
    // 风险门：勾选 + 启用。
    await tester.tap(find.text('我已了解风险'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('启用'));
    await tester.pumpAndSettle();

    await _enqueueDemo(tester);

    // 审批被跳过 ⇒ 直接是提问（瀑布里的下一个）。
    expect(find.text('等待审批'), findsNothing, reason: '完全权限下审批不该入队');
    expect(find.text('等待回答'), findsOneWidget);
  });

  testWidgets('收起接管卡：卡片消失但队列不减（可恢复）', (tester) async {
    await _pumpChat(tester);
    await _enqueueDemo(tester);
    expect(find.text('等待审批'), findsOneWidget);

    await tester.tap(find.byTooltip('收起'));
    await tester.pumpAndSettle();
    expect(find.text('等待审批'), findsNothing);
    expect(find.byType(DshComposer), findsOneWidget, reason: '输入栏该回来');
  });
}
