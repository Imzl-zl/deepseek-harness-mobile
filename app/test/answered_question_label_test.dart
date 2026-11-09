/// 已回答的问答在**聊天流**里的标题。
///
/// ## 这一条守什么
///
/// 一次 `ask_user_question` 答完之后，那条 `ToolCallItem` 留在会话流里。它原来的标题是
/// 工具名 `ask_user_question` —— 对用户来说那是一个函数名，不是"这里发生过什么"。
/// 所以已完成（`ToolCallStatus.completed`）的问答卡标题改成「问答 · 已回答」，
/// 问题与所选答案仍旧在 `detail` 里（展开可回看）。
///
/// **不是接管卡那句**：`ui/takeover.dart:559` 的「已回答 · <选项>」是答完之后贴在
/// 输入栏上方的瞬时回执，答完就撤；这里是历史条目，会一直留在聊天流里。
///
/// 第二条用例是反面对照：别的工具（`bash`）照旧显示工具名 —— 标题规则只对
/// 已回答的问答生效，不许外溢成"所有工具都换个说法"。
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';
import 'projection_fixture.dart';

class _FakeClient extends FakeSyncClient {
  @override
  ConnectionState get state => ConnectionState.serving;

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
    // 投影面回一份**空的**值包：这一组不关心权限 chip，只关心卡片标题。
    if (method == 'session.projections') return <String, Object?>{} as T;
    return <String, Object?>{} as T;
  }
}

/// 一条**已回答**的问答条目：先 `tool/call`，再 `tool/result` 覆盖同一条。
///
/// 走 `projectEvent` 而不是手搓 `ToolCallItem`：状态（`completed`）与 `detail` 都是
/// 投影算出来的，手搓就等于把"投影会不会把问答画成已完成"这条排除在测试之外。
ChatItem _answeredQuestion() {
  final call = projectEvent(
    type: 'tool/call',
    seq: 1,
    data: <String, Object?>{
      'turn': 1,
      'step': 1,
      'callId': 'call-q',
      'name': 'ask_user_question',
      'arguments':
          '{"questions":[{"id":"scope","question":"选哪个范围？",'
          '"options":[{"label":"全部"}]}]}',
    },
  ).item!;
  return projectEvent(
    type: 'tool/result',
    seq: 2,
    previous: call,
    data: <String, Object?>{
      'turn': 1,
      'step': 1,
      'callId': 'call-q',
      'message': <String, Object?>{
        'role': 'tool',
        'toolCallId': 'call-q',
        'id': 'r-call-q',
        'isError': false,
        'content': <Object?>[
          <String, Object?>{'type': 'text', 'text': '已收到回答'},
        ],
      },
    },
  ).item!;
}

/// 一条普通的、已完成的 `bash`（反面对照）。
ChatItem _completedBash() => const ToolCallItem(
  itemId: 't:call-b',
  seq: 3,
  updatedAt: 0,
  turn: 1,
  name: 'bash',
  status: ToolCallStatus.completed,
  summary: 'ls',
);

Future<AppModel> _pump(WidgetTester tester, List<ChatItem> items) async {
  final app = AppModel(client: _FakeClient());
  await tester.pumpWidget(
    MaterialApp(
      theme: DshTheme.dark(),
      home: ChatPage(
        app: app,
        paired: true,
        onOpenDrawer: () {},
        onNewSession: () {},
        drawer: const Drawer(child: SizedBox()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  app.seedForTest(sid: 'qa', title: '问答', updatedAt: 1, items: items);
  await app.openSession('qa');
  await tester.pumpAndSettle();
  addTearDown(app.dispose);
  return app;
}

void main() {
  testWidgets('已回答的 ask_user_question：标题是「问答 · 已回答」，不再显示工具名', (tester) async {
    await _pump(tester, [_answeredQuestion()]);

    expect(find.text('问答 · 已回答'), findsOneWidget);
    expect(
      find.text('ask_user_question'),
      findsNothing,
      reason: '工具名对用户没有意义：这一条的标题该说"这里发生过什么"',
    );
  });

  testWidgets('别的工具照旧显示工具名（标题规则不外溢）', (tester) async {
    await _pump(tester, [_completedBash()]);

    expect(find.text('bash'), findsOneWidget);
    expect(find.text('问答 · 已回答'), findsNothing);
  });
}
