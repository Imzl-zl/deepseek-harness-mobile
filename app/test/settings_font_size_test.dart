/// 设置页「字号大小」那一行（步进器 10–22）。
///
/// 守三件事：
///
/// 1. 行在通用组里、显示当前值（默认 14）；
/// 2. **±1** 真的改到 `AppModel.contentFontSize`（并且落盘走同一条路）；
/// 3. **边界不可越过**：到 10 / 22 之后对应那颗按钮点不动（不是静默）。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/theme/dsh_colors.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

class _Client extends FakeSyncClient {
  final _states = StreamController<conn.ConnectionState>.broadcast();

  @override
  conn.ConnectionState get state => conn.ConnectionState.serving;
  @override
  Stream<conn.ConnectionState> get connection => _states.stream;
  @override
  Stream<JobFrame> get jobUpdates => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> reconnect() => start();
  @override
  Future<void> setAppState(AppState state) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> unsubscribe(String sid) async {}
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();
}

Widget _host(AppModel app) => MaterialApp(
  theme: DshTheme.dark(),
  home: SettingsPage(
    app: app,
    themeMode: DshThemeMode.system,
    onThemeMode: (_) async {},
  ),
);

void main() {
  testWidgets('字号大小：显示当前值，±1 真的改，边界点不动', (tester) async {
    final semantics = tester.ensureSemantics();
    final app = AppModel(client: _Client());
    addTearDown(app.dispose);
    await tester.pumpWidget(_host(app));
    await tester.pumpAndSettle();

    // 通用组在页面靠上，但要先滚到那一行（设置页是多组的长列表）。
    final label = find.text('字号大小');
    await tester.scrollUntilVisible(
      label,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(label, findsOneWidget);
    expect(find.text('仅影响会话内容的字号'), findsOneWidget);
    expect(find.text('14'), findsOneWidget, reason: '默认 14');

    await tester.tap(find.bySemanticsLabel('调大字号'));
    await tester.pumpAndSettle();
    expect(app.contentFontSize, 15);
    expect(find.text('15'), findsOneWidget);

    // 一路到上界，再点一次不该越过。
    for (var i = 0; i < 10; i += 1) {
      await tester.tap(find.bySemanticsLabel('调大字号'));
      await tester.pumpAndSettle();
    }
    expect(app.contentFontSize, 22);
    await tester.tap(find.bySemanticsLabel('调大字号'));
    await tester.pumpAndSettle();
    expect(app.contentFontSize, 22, reason: '上界 22 不可越过');

    // 反向一路到下界。
    for (var i = 0; i < 20; i += 1) {
      await tester.tap(find.bySemanticsLabel('调小字号'));
      await tester.pumpAndSettle();
    }
    expect(app.contentFontSize, 10);
    await tester.tap(find.bySemanticsLabel('调小字号'));
    await tester.pumpAndSettle();
    expect(app.contentFontSize, 10, reason: '下界 10 不可越过');

    // 语义句柄要在用例体内释放（框架在收尾时才校验，`addTearDown` 太晚）。
    semantics.dispose();
  });
}
