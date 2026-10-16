/// 设置页「连接方式」（端点选择器）的 widget 回归。
///
/// ## 这一组守什么
///
/// 1. **顺序即偏好**：行序 = 端点表序，第一条带「首选」；点一条 = 置顶
///    （`AppModel.preferEndpoint`，只改序不删条目）并落盘；
/// 2. **状态全部来自真实拨号记录**：`当前连接` / `拨不通：原因` / `拨通过` /
///    `还没试过` 四档，没有记录就说"还没试过"—— 不猜；
/// 3. **「当前连接」只在服务态标**：拨通记录跨连接保留，重连中把上一条的
///    赢家标成"当前"会与顶栏/连接 sheet 的说法打架；
/// 4. 空端点表（没配对）给空态，**不摆假行**。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/endpoint.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/settings_page.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

class _FakeClient implements SyncClient {
  _FakeClient({ConnectionState state = ConnectionState.serving})
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
  Future<void> setAppState(AppState state) async {}

  @override
  Future<void> close() async {}

  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();

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
  }) async => throw UnimplementedError('设置页不该发方法');
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

Widget _host(AppModel app) => MaterialApp(
  theme: DshTheme.dark(),
  home: SettingsPage(app: app),
);

void main() {
  AppModel buildApp({
    List<Endpoint> endpoints = const [_direct, _relay],
    void Function(List<Endpoint>)? onEndpointsChanged,
    ConnectionState state = ConnectionState.serving,
  }) {
    final app = AppModel(
      client: _FakeClient(state: state),
      endpoints: endpoints,
      onEndpointsChanged: onEndpointsChanged == null
          ? null
          : (list) async => onEndpointsChanged(list),
    );
    return app;
  }

  testWidgets('端点行按表序渲染：kind + 地址(+自报名) + 首选', (tester) async {
    final app = buildApp();
    await tester.pumpWidget(_host(app));
    await tester.pumpAndSettle();

    expect(find.text('连接方式'), findsOneWidget);
    expect(find.text('直连'), findsOneWidget);
    expect(find.text('中转'), findsOneWidget);
    // 连接器自报的名字（网卡名）拼在地址后面，没有就不显示。
    expect(find.text('ws://192.168.2.43:8790 · Wi-Fi'), findsOneWidget);
    expect(find.text('ws://192.168.2.43:8787 · 中转'), findsOneWidget);
    expect(find.text('首选'), findsOneWidget, reason: '只有第一条带首选');
    addTearDown(app.dispose);
  });

  testWidgets('点非首实行 → 置顶 + 落盘 + toast', (tester) async {
    final persisted = <List<Endpoint>>[];
    final app = buildApp(onEndpointsChanged: persisted.add);
    await tester.pumpWidget(_host(app));
    await tester.pumpAndSettle();

    await tester.tap(find.text('中转'));
    await tester.pumpAndSettle();

    expect(app.endpoints.map((e) => e.url).toList(), [
      _relay.url,
      _direct.url,
    ], reason: '只改顺序，两条都还在');
    expect(persisted, hasLength(1), reason: '改了要落盘，重启后还是这个偏好');
    expect(find.text('已把「中转」设为首选，下次重连生效'), findsOneWidget);
    addTearDown(app.dispose);
  });

  testWidgets('点首实行 → 不动 + "已经是首选项"', (tester) async {
    var persisted = 0;
    final app = buildApp(
      onEndpointsChanged: (_) {
        persisted++;
      },
    );
    await tester.pumpWidget(_host(app));
    await tester.pumpAndSettle();

    await tester.tap(find.text('直连'));
    await tester.pumpAndSettle();

    expect(app.endpoints.map((e) => e.url).toList(), [_direct.url, _relay.url]);
    expect(persisted, 0, reason: '没变化不落盘');
    expect(find.text('「直连」已经是首选项'), findsOneWidget);
    addTearDown(app.dispose);
  });

  testWidgets('状态四档：当前连接 / 拨不通(带原因) / 拨通过 / 还没试过', (tester) async {
    final app = buildApp(endpoints: const [_direct, _relay, _extra, _never]);
    await app.start(); // serving
    // 这一轮：直连拨不通 → 回落中转；extra 上一轮拨通过；never 从没试过。
    app.reportActiveEndpoint(_relay);
    app.reportEndpointAttempt(
      _direct,
      const EndpointAttempt(ok: false, reason: '连接超时'),
    );
    app.reportEndpointAttempt(_relay, const EndpointAttempt(ok: true));
    app.reportEndpointAttempt(_extra, const EndpointAttempt(ok: true));
    await tester.pumpWidget(_host(app));
    await tester.pumpAndSettle();

    expect(find.text('当前连接'), findsOneWidget);
    expect(find.text('拨不通：连接超时'), findsOneWidget);
    expect(find.text('拨通过'), findsOneWidget);
    expect(find.text('还没试过'), findsOneWidget);
    addTearDown(app.dispose);
  });

  testWidgets('回落时顶部块说清"为什么没走直连"', (tester) async {
    final app = buildApp();
    await app.start();
    app.reportActiveEndpoint(_relay);
    app.reportEndpointAttempt(
      _direct,
      const EndpointAttempt(ok: false, reason: '连接超时'),
    );
    await tester.pumpWidget(_host(app));
    await tester.pumpAndSettle();

    expect(find.text('当前连接：中转 · ws://192.168.2.43:8787'), findsOneWidget);
    expect(find.text('直连 ws://192.168.2.43:8790 拨不通（连接超时）'), findsOneWidget);
    addTearDown(app.dispose);
  });

  testWidgets('重连中：不把上一条的赢家标成"当前连接"', (tester) async {
    // 拨通记录跨连接保留，而连接 sheet/顶栏此时说的是"重连中…"——
    // 同一个事实只能有一套说法。
    final app = buildApp(state: ConnectionState.backoff);
    await app.start();
    app.reportActiveEndpoint(_relay);
    await tester.pumpWidget(_host(app));
    await tester.pumpAndSettle();

    expect(find.text('重连中…'), findsOneWidget);
    expect(find.text('当前连接'), findsNothing);
    addTearDown(app.dispose);
  });

  testWidgets('空端点表（没配对）：空态，不摆假行', (tester) async {
    final app = buildApp(endpoints: const []);
    await tester.pumpWidget(_host(app));
    await tester.pumpAndSettle();

    expect(find.text('还没有端点。配对成功后，这里会列出可拨的地址。'), findsOneWidget);
    expect(find.text('直连'), findsNothing);
    addTearDown(app.dispose);
  });
}

const _extra = Endpoint(
  kind: EndpointKind.direct,
  url: 'ws://192.168.2.44:8790',
  label: '以太网',
);

const _never = Endpoint(
  kind: EndpointKind.relay,
  url: 'wss://relay.example',
  label: '备用中转',
);
