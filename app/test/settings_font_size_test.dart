/// 设置页「界面字号」那一行（App 内四档倍率）。
///
/// 守三件事：
///
/// 1. 行在通用组里、显示当前档位（默认「标准」）；
/// 2. 点开是四档（较小 / 标准 / 较大 / 特大），选完**落到 `AppModel`**（并落盘走同一条路）；
/// 3. 档位是倍率（0.9 / 1.0 / 1.15 / 1.3），不是 px —— 等比放大不改变对比关系。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/preferences.dart';
import 'package:dsh_mobile/model/theme_mode.dart';
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
    theme: ThemeController(),
    onThemeMode: (_) async {},
    onSurfaceAlpha: (_) async {},
    hasWallpaper: false,
    onPickWallpaper: () async {},
    onClearWallpaper: () async {},
  ),
);

void main() {
  testWidgets('界面字号：四档、默认标准、选完真的落到 AppModel', (tester) async {
    final app = AppModel(client: _Client());
    addTearDown(app.dispose);
    await tester.pumpWidget(_host(app));
    await tester.pumpAndSettle();

    final label = find.text('界面字号');
    await tester.scrollUntilVisible(
      label,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(label, findsOneWidget);
    // 行上显示的是「标准」（设置页里「工作步骤展示」也有一档叫标准，
    // 所以必须把 finder 限定到**这一行**）。
    final row = find.ancestor(of: label, matching: find.byType(ListTile));
    expect(find.descendant(of: row, matching: find.text('标准')), findsOneWidget);
    expect(app.uiScaleIndex, kUiScaleDefaultIndex, reason: '默认标准档');

    await tester.tap(label);
    await tester.pumpAndSettle();
    // 四档都在，且带百分比。
    for (final name in kUiScaleLabels) {
      expect(find.text(name), findsWidgets, reason: '档位 $name 要在选择器里');
    }
    expect(find.text('130%'), findsOneWidget);

    await tester.tap(find.text('特大'));
    await tester.pumpAndSettle();
    expect(app.uiScaleIndex, 3);
    expect(app.uiScale, 1.3);
    expect(find.text('特大'), findsOneWidget, reason: '行上显示新档位');
  });
}
