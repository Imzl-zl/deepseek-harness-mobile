/// 换了网络连不上时的那条出路：**手动填电脑地址，只加进表，由用户自己选它连**。
///
/// 守两件事：
/// 1. 连接操作 sheet 里有这个入口（三处入口共用同一个 sheet）；
/// 2. 填完**不许自动拨** —— "什么时候连"是用户的动作（用户原话：
///    "我肯定手动去连接啊"）。设置页那句承诺也是同一句：*"已添加，下次重连会试它"*。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/endpoint.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/add_endpoint_dialog.dart';
import 'package:dsh_mobile/ui/connection_actions_sheet.dart';
import 'package:dsh_mobile/ui/connection_summary_block.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

class _BareClient extends FakeSyncClient {
  @override
  ConnectionState get state => ConnectionState.serving;
  @override
  Stream<ConnectionState> get connection => const Stream.empty();
  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> reconnect() async {}
  @override
  Future<void> setAppState(AppState state) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> unsubscribe(String sid) async {}
  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async => <String, Object?>{} as T;
}

void main() {
  testWidgets('连接 sheet 有「手动填写电脑地址」这一行（带"不自动连"的说明）', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showConnectionActionsSheet(
                  context,
                  // `ConnectionSummary` 是记录（`({line, note})`），不是类。
                  connection: (line: '我的电脑', note: null),
                  onRePair: () {},
                  onManualEndpoint: () => tapped += 1,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('手动填写电脑地址'), findsOneWidget);
    expect(
      find.textContaining('不会自动连'),
      findsOneWidget,
      reason: '填完不会自己切过去 —— 这是唯一非显然的一条，要说出来',
    );

    await tester.tap(find.text('手动填写电脑地址'));
    await tester.pumpAndSettle();
    expect(tapped, 1);
  });

  testWidgets('填完地址只加进表：**不自动拨**', (tester) async {
    final saved = <List<Endpoint>>[];
    var reconnects = 0;
    final app = AppModel(
      client: _BareClient(),
      onEndpointsChanged: (endpoints) async => saved.add(endpoints),
      onRequestEndpoint: (_) => reconnects += 1,
      onReconnect: () async => reconnects += 1,
    );
    addTearDown(app.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => unawaitedAdd(context, app),
                child: const Text('add'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('add'));
    await tester.pumpAndSettle();
    expect(find.text('添加端点'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'ws://192.168.3.8:8790');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    expect(
      app.endpoints.map((e) => e.url),
      contains('ws://192.168.3.8:8790'),
      reason: '新地址要进表（否则用户没有可选的）',
    );
    expect(app.endpoints.last.manual, isTrue, reason: '手填的要带上标记');
    expect(saved, isNotEmpty, reason: '端点表要落盘');
    expect(reconnects, 0, reason: '**不许自动拨**：连不连是用户的事');
  });

  _relayGroup();
  _directSchemeGroup();
}

/// 把 `addEndpointOnly` 包一层（它要 context，测试里从按钮的 context 拿）。
void unawaitedAdd(BuildContext context, AppModel app) {
  unawaited(addEndpointOnly(context, app));
}

/// 一个只会弹「添加端点」的按钮（结果是 `AddedEndpoint`）。
Widget _dialogOpener(
  void Function(AddedEndpoint?) onResult,
  EndpointKind kind,
) => MaterialApp(
  theme: DshTheme.dark(),
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () async =>
              onResult(await showAddEndpointDialog(context, initialKind: kind)),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

/// 直连两档：局域网的 `ws://`，或外部终结 TLS 的 `wss://`（frp / 反代 / tailscale serve）。
///
/// 监听面自己不终结 TLS，但「前面那一跳终结了」是合法且推荐的形态 ——
/// 拒绝 `wss://` 等于把「有域名的人」挡在外面（frp 教程的主线正是它）。
void _directSchemeGroup() {
  testWidgets('直连收 wss://：TLS 在前面那一跳，地址本身仍然有效', (tester) async {
    AddedEndpoint? added;
    await tester.pumpWidget(
      _dialogOpener((v) => added = v, EndpointKind.direct),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'wss://dsh.example.com');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    expect(added?.endpoint.kind, EndpointKind.direct);
    expect(added?.endpoint.url, 'wss://dsh.example.com');
    expect(added?.allowPlaintextPublic, isFalse, reason: 'wss 有 TLS，不需要明文确认');
  });

  testWidgets('公网明文直连仍然要勾确认：不勾就加不进去', (tester) async {
    AddedEndpoint? added;
    await tester.pumpWidget(
      _dialogOpener((v) => added = v, EndpointKind.direct),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 203.0.113.0/24 是 TEST-NET-3：肯定不是私网，走“公网”那一档。
    await tester.enterText(find.byType(TextField), 'ws://203.0.113.9:18790');
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(added, isNull, reason: '公网明文没确认就不许落表');
    expect(find.textContaining('请先勾选确认'), findsOneWidget);

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(added?.endpoint.url, 'ws://203.0.113.9:18790');
    expect(added?.allowPlaintextPublic, isTrue);
  });
}

void _relayGroup() {
  testWidgets('中转是**选**的：默认内置那条（开箱即用，不用填）', (tester) async {
    AddedEndpoint? added;
    await tester.pumpWidget(
      _dialogOpener((v) => added = v, EndpointKind.relay),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('内置中转'), findsOneWidget);
    expect(
      find.text(kBuiltinRelayUrl),
      findsOneWidget,
      reason: '地址直接写在选项上 —— 用户不该需要记得那个域名',
    );
    expect(
      find.byType(TextField),
      findsNothing,
      reason: '内置 = 不用填（用户原话：开箱即用的东西不该要人填）',
    );

    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(added?.endpoint.kind, EndpointKind.relay);
    expect(added?.endpoint.url, kBuiltinRelayUrl);
    expect(added?.allowPlaintextPublic, isFalse, reason: '内置那条是 wss，不需要明文确认');
  });

  testWidgets('换成自己的中转：只有选了「自定义」才出现输入框，填什么加什么', (tester) async {
    AddedEndpoint? added;
    await tester.pumpWidget(
      _dialogOpener((v) => added = v, EndpointKind.relay),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'wss://relay.mine.dev');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    expect(added?.endpoint.url, 'wss://relay.mine.dev');
    expect(added?.endpoint.kind, EndpointKind.relay, reason: '自定义只是换地址，种类还是中转');
  });

  testWidgets('再点回「内置中转」就换回那条（用户的地址不会被抹掉，但不再提交它）', (tester) async {
    AddedEndpoint? added;
    await tester.pumpWidget(
      _dialogOpener((v) => added = v, EndpointKind.relay),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'wss://relay.mine.dev');
    await tester.tap(find.text('内置中转'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();

    expect(added?.endpoint.url, kBuiltinRelayUrl);
  });
}
