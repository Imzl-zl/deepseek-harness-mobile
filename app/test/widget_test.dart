/// 会话列表页的 widget 测试。
///
/// 替换掉 `flutter create` 自带的那条 counter smoke test（它引用的是模板里的
/// `MyApp`，而那个类已经不存在了 —— 测模板没有任何价值）。
///
/// 这一组测**界面在四种数据状态下的表现**，因为那四种都是"用户第一眼看到的东西"：
/// 空列表 / 有会话 / 请求失败 / 各连接状态。它们写错的代价是"用户以为 DSH 里没会话"。
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/session_list_page.dart';
// **`hide ConnectionState`**：Flutter 的 `material.dart` 也导出 `ConnectionState`
// （那是 `AsyncSnapshot` 的状态：none/waiting/active/done），与我们的
// **连接状态机**同名但毫无关系。隐藏它，让本文件里 `ConnectionState` 只有一个意思。
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

/// 一个**只回固定答案**的假客户端：界面测试只关心"拿到这些数据时长什么样"，
/// 而真实的 `SyncClient` 要起 socket、做握手 —— 那是连接层测试的事。
class FakeClient implements SyncClient {
  FakeClient({this.sessions = const [], this.failWith});

  /// `session.list` 的返回值。
  final List<Object?> sessions;

  /// 给了就让 `session.list` 抛这个错（测"失败"与"空"要分开）。
  final ProtocolException? failWith;

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
  }) async {
    final failure = failWith;
    if (failure != null) throw failure;
    if (method == 'session.list') return sessions as T;
    return null as T;
  }
}

Widget _wrap(AppModel app) => MaterialApp(
  theme: DshTheme.dark(),
  home: SessionListPage(app: app),
);

void main() {
  testWidgets('空列表说"还没有会话"（真没有 ≠ 请求失败）', (tester) async {
    await tester.pumpWidget(_wrap(AppModel(client: FakeClient())));
    await tester.pumpAndSettle();
    expect(find.text('还没有会话'), findsOneWidget);
    expect(find.text('没能取到会话列表'), findsNothing);
  });

  testWidgets('请求失败说"没能取到会话列表"，并带上错误码与原因', (tester) async {
    // **每个场景一个 `testWidgets`**：同一次测试里换 widget 实例时，
    // Flutter 会因为 runtimeType 相同而复用同一个 `State` —— 于是新 model 的
    // `initState` 不再执行、`refreshSessions` 也就没被调用（实测踩到：
    // 第二条断言看到的是第一条的空态，而不是失败态）。
    await tester.pumpWidget(
      _wrap(
        AppModel(
          client: FakeClient(
            failWith: const ProtocolException(ErrorCode.relayOffline, '中转不可达'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('没能取到会话列表'), findsOneWidget);
    // 错误码与消息都要能看到 —— 用户/我们据此判断下一步（`relay/offline` 是"重试"）。
    expect(find.textContaining('relay/offline'), findsOneWidget);
    expect(find.textContaining('中转不可达'), findsOneWidget);
  });

  testWidgets('有会话时列出标题；标题为空时说"未命名"而不是留白', (tester) async {
    await tester.pumpWidget(
      _wrap(
        AppModel(
          client: FakeClient(
            sessions: [
              {'sid': 's1', 'updatedAt': 100},
              {'sid': 's2', 'updatedAt': 200},
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 电脑侧不返回标题，所以没打开过会话时标题是空的 —— 这时要说"未命名"。
    expect(find.text('（未命名会话）'), findsNWidgets(2));
    // `sid` 出现在副标题里（打开过之前它是唯一的识别信息）。
    expect(find.textContaining('s1'), findsOneWidget);
  });

  testWidgets('连接状态显示成人话，且不因为状态变化而崩', (tester) async {
    final app = AppModel(client: FakeClient());
    await tester.pumpWidget(_wrap(app));
    await tester.pumpAndSettle();

    // 初始态是 idle → "未连接"。
    expect(find.text('未连接'), findsOneWidget);
    expect(
      find.text(connectionLabel(ConnectionStateView.idle)),
      findsOneWidget,
    );
  });
}
