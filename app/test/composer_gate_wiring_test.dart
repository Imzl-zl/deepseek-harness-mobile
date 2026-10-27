// `ConnectionState` 与 `flutter/material.dart` 的同名枚举冲突：显式前缀。
import 'package:dsh_mobile/core/connection.dart' as core;
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 发送门槛与输入栏的**接线**（纯函数矩阵在 `composer_gate_test.dart`）。
///
/// 这里锁两件事：
/// 1. blank 会话 + 工作区解析不出来 ⇒ **不能发**，且占位文案说出缺什么
///    （桌面 `ConversationContent.tsx:142` 的 `inert` + `:152` 的 `placeholder.workspace`）；
/// 2. **不能发 ≠ 整条栏死**：模型/权限 chip 仍可点（桌面 `empty` 只禁主键，
///    2026-10-27 这条被本文件抓过一次回归 —— 空草稿时 chip 全灰）。
///
/// Note: 判据与取舍见 `.agents/notes/proposed/2026-10-27-ui-state-design.md` §4。
void main() {
  /// 记下发过哪些写操作；其余一律按"没连上"拒（与 `chat_takeover_wiring_test` 同一条）。
  final prompts = <Map<String, Object?>>[];

  setUp(prompts.clear);

  Future<AppModel> pumpChat(
    WidgetTester tester, {
    required String sid,
    required bool blank,
    bool seedItems = false,
  }) async {
    final app = AppModel(client: _RecordingClient(prompts));
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
    app.seedForTest(
      sid: sid,
      title: '',
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      items: seedItems ? _oneUserMessage(sid) : const [],
      blank: blank,
    );
    await tester.pumpAndSettle();
    await app.openSession(sid);
    await tester.pumpAndSettle();
    return app;
  }

  testWidgets('blank 会话且工作区解析不出来：占位说"选择工作区"，打字也发不出去', (tester) async {
    await pumpChat(tester, sid: 'blank-1', blank: true);

    // ① 占位文案 = 门槛给的那句（与 hero 的 chip 同一常量）。
    expect(find.text('选择工作区'), findsWidgets);

    // ② 打了字也发不出去（门槛挡住；没有会话工作区这一事实来自 `workspace.list` 为空）。
    await tester.enterText(find.byType(TextField).last, '你好');
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('composer-primary')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(prompts, isEmpty, reason: 'blank 会话没有工作区时不允许发出去');
  });

  testWidgets('正文空 ≠ 整条栏死：空草稿时权限 chip 仍可点', (tester) async {
    // **这一条钉的是 2026-10-27 的回归**：把输入栏的 `enabled` 直接接成
    // "能发/能停"，于是空草稿时模型与权限 chip 全灰 —— 用户在打字之前
    // 根本选不了模型。桌面 `empty` 只禁主键（`InputBar.tsx:343`）。
    await pumpChat(tester, sid: 'sid-1', blank: false, seedItems: true);

    // 目录拿不到 ⇒ 点开只会 toast 一句"拿不到权限预设目录"。
    // 这条断言的是**chip 还活着**（可点），不是那句子。
    await tester.tap(find.byKey(const Key('composer-access')));
    await tester.pumpAndSettle();
    expect(find.text('拿不到权限预设目录：电脑侧没有返回 permission.catalog'), findsOneWidget);
  });

  testWidgets('普通会话：占位不是"选择工作区"，打字后能发出去', (tester) async {
    await pumpChat(tester, sid: 'sid-1', blank: false, seedItems: true);

    expect(find.text('选择工作区'), findsNothing);

    await tester.enterText(find.byType(TextField).last, '你好');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('composer-primary')));
    await tester.pumpAndSettle();

    expect(prompts, hasLength(1));
    expect(prompts.single['sid'], 'sid-1');
  });
}

List<ChatItem> _oneUserMessage(String sid) => <ChatItem>[
  MessageItem(
    itemId: '$sid:1',
    seq: 1,
    updatedAt: 1,
    role: MessageRole.user,
    text: '先聊一句',
  ),
];

/// `session.prompt` 记账，其余按"没连上"拒。
class _RecordingClient extends FakeSyncClient {
  _RecordingClient(this.prompts);

  final List<Map<String, Object?>> prompts;

  @override
  core.ConnectionState get state => core.ConnectionState.serving;
  @override
  Stream<core.ConnectionState> get connection => const Stream.empty();
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
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();
  @override
  Future<void> unsubscribe(String sid) async {}

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'session.prompt') {
      prompts.add(params);
      return <String, Object?>{'accepted': true} as T;
    }
    throw const ProtocolException(ErrorCode.relayOffline, '测试里不连');
  }
}
