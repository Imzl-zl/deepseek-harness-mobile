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
    expect(find.textContaining('再自己选它连接'), findsOneWidget);

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
}

/// 把 `addEndpointOnly` 包一层（它要 context，测试里从按钮的 context 拿）。
void unawaitedAdd(BuildContext context, AppModel app) {
  unawaited(addEndpointOnly(context, app));
}
