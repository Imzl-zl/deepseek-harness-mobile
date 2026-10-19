/// 对话页空态的"没连上"分支（连接方式选择器第 3 步的可见面）。
///
/// ## 这一组守什么
///
/// **配对但没连上时，空态说"连不上"，不说"还没有会话"**。2026-10-16 实测：
/// 电脑换地址后全部端点拨不通，空屏却显示"还没有会话 · 在电脑上用 DSH 开一个"——
/// 用户被引向一个根本不存在的动作（电脑上其实有会话，只是手机拨不通）。
/// 三个状态（没配对 / 没连上 / 真没有会话）在界面上都是空屏，而下一步动作
/// 完全不同，所以必须分开说。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/endpoint.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'fake_sync_client.dart';

class _FakeClient extends FakeSyncClient {
  _FakeClient({ConnectionState state = ConnectionState.closed})
    : _state = state;

  final ConnectionState _state;
  final _states = StreamController<ConnectionState>.broadcast();

  @override
  ConnectionState get state => _state;

  @override
  Stream<ConnectionState> get connection => _states.stream;

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
  }) async => throw UnimplementedError('空态不该发方法');
}

const _direct = Endpoint(
  kind: EndpointKind.direct,
  url: 'ws://192.168.2.43:8790',
  label: 'Wi-Fi',
);
const _relay = Endpoint(
  kind: EndpointKind.relay,
  url: 'ws://192.168.2.43:8787',
  label: '中转',
);

void main() {
  /// 建一个"已配对但连不上"的 AppModel。
  Future<AppModel> disconnectedApp({bool allFailed = true}) async {
    final app = AppModel(
      client: _FakeClient(),
      endpoints: const [_direct, _relay],
    );
    await app.start(); // state = closed → 界面视图'已断开'
    if (allFailed) {
      app.reportEndpointAttempt(
        _direct,
        const EndpointAttempt(ok: false, reason: '连接超时'),
      );
      app.reportEndpointAttempt(
        _relay,
        const EndpointAttempt(ok: false, reason: '连接超时'),
      );
    }
    return app;
  }

  Widget host(AppModel app, {bool paired = true}) => MaterialApp(
    theme: DshTheme.dark(),
    home: ChatPage(
      app: app,
      paired: paired,
      onOpenDrawer: () {},
      onNewSession: () {},
      onRePair: () {},
      drawer: const SizedBox.shrink(),
    ),
  );

  testWidgets('全部端点拨不通：空态说"已断开"+ 诊断，不说"还没有会话"', (tester) async {
    final app = await disconnectedApp();
    await tester.pumpWidget(host(app));
    await tester.pumpAndSettle();

    expect(find.text('已断开'), findsOneWidget);
    expect(find.text('2 个端点都拨不通（电脑可能不在线，或换了网络地址）'), findsOneWidget);
    expect(
      find.text('还没有会话'),
      findsNothing,
      reason: '连不上时说"没有会话"会把用户引向"去电脑上开会话"这个不存在的动作',
    );
    // 出路仍在（议题 3：任何状态 ≤2 步走到重新配对）。
    expect(find.text('重新配对（换一台电脑）'), findsOneWidget);
    addTearDown(app.dispose);
  });

  testWidgets('连不上但没有拨号记录：只给状态，不编诊断', (tester) async {
    final app = await disconnectedApp(allFailed: false);
    await tester.pumpWidget(host(app));
    await tester.pumpAndSettle();

    expect(find.text('已断开'), findsOneWidget);
    expect(find.text('连上之后，会话列表会自动出现。'), findsOneWidget);
    expect(find.textContaining('拨不通'), findsNothing);
    addTearDown(app.dispose);
  });

  testWidgets('连上了且真没有会话：说"还没有会话"（新分支不劫持服务态）', (tester) async {
    final app = AppModel(client: _FakeClient(state: ConnectionState.serving));
    await app.start();
    await tester.pumpWidget(host(app));
    await tester.pumpAndSettle();

    expect(find.text('还没有会话'), findsOneWidget);
    expect(find.text('已断开'), findsNothing);
    addTearDown(app.dispose);
  });

  testWidgets('没配对：照旧说"还没连电脑"', (tester) async {
    final app = AppModel(client: _FakeClient());
    await tester.pumpWidget(host(app, paired: false));
    await tester.pumpAndSettle();

    expect(find.text('还没连电脑'), findsOneWidget);
    expect(find.text('已断开'), findsNothing);
    addTearDown(app.dispose);
  });
}
