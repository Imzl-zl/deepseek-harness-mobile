/// 设置页「背景 / 透明度」两行（手机侧自有的外观扩展）。
///
/// 守四件事：
///
/// 1. 两行在「通用」组里，跟在「主题」之后，值来自 `ThemeController`（活值）；
/// 2. 没壁纸时，背景 sheet 只有"从相册选一张"，**不摆**"去掉背景"；
/// 3. 有壁纸时两行都给；
/// 4. **透明度滑杆拖动即生效**：`onTransparency` 收到的是夹取过的值，
///    行右端的文案随之变（不是等关掉 sheet 才更新），且**能拉到 100%**。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/appearance.dart';
import 'package:dsh_mobile/model/theme_mode.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 只要"连着的状态"够用 —— 这一组断言不碰通道。
class _Client extends FakeSyncClient {
  @override
  conn.ConnectionState get state => conn.ConnectionState.serving;
  @override
  Stream<conn.ConnectionState> get connection =>
      const Stream<conn.ConnectionState>.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> unsubscribe(String sid) async {}
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();
}

Widget _host(
  AppModel app, {
  required ThemeController theme,
  bool hasWallpaper = false,
  Future<void> Function(int)? onTransparency,
  Future<void> Function()? onClear,
}) => MaterialApp(
  theme: DshTheme.dark(),
  home: SettingsPage(
    app: app,
    theme: theme,
    onThemeMode: (_) async {},
    onTransparency: onTransparency ?? (_) async {},
    hasWallpaper: hasWallpaper,
    onPickWallpaper: () async {},
    onClearWallpaper: onClear ?? () async {},
  ),
);

void main() {
  testWidgets('两行在通用组里：默认「无」+「0%」', (tester) async {
    final app = AppModel(client: _Client());
    addTearDown(app.dispose);
    final theme = ThemeController();
    await tester.pumpWidget(_host(app, theme: theme));
    await tester.pumpAndSettle();

    expect(find.text('主题'), findsOneWidget);
    expect(find.text('背景'), findsOneWidget);
    expect(find.text('透明度'), findsOneWidget);
    expect(find.text('无'), findsOneWidget);
    expect(find.text('0%'), findsOneWidget);
    expect(find.text('已设置'), findsNothing);
    // **没有说明文字**：用户自己看得出来，不在这里给他念规则。
    expect(find.textContaining('遮罩'), findsNothing);
    expect(find.textContaining('最低'), findsNothing);
  });

  testWidgets('没壁纸：背景 sheet 只有选一张，没有"去掉背景"', (tester) async {
    final app = AppModel(client: _Client());
    addTearDown(app.dispose);
    await tester.pumpWidget(_host(app, theme: ThemeController()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('背景'));
    await tester.pumpAndSettle();
    expect(find.text('从相册选一张'), findsOneWidget);
    expect(find.text('去掉背景'), findsNothing);
  });

  testWidgets('有壁纸：两行都给，去掉背景会回调', (tester) async {
    final app = AppModel(client: _Client());
    addTearDown(app.dispose);
    var cleared = 0;
    await tester.pumpWidget(
      _host(
        app,
        theme: ThemeController(),
        hasWallpaper: true,
        onClear: () async => cleared += 1,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('已设置'), findsOneWidget);
    await tester.tap(find.text('背景'));
    await tester.pumpAndSettle();
    expect(find.text('从相册选一张'), findsOneWidget);
    await tester.tap(find.text('去掉背景'));
    await tester.pumpAndSettle();
    expect(cleared, 1);
  });

  testWidgets('透明度：拖滑杆当场生效，行右端跟着变', (tester) async {
    final app = AppModel(client: _Client());
    addTearDown(app.dispose);
    final theme = ThemeController();
    final seen = <int>[];
    await tester.pumpWidget(
      _host(
        app,
        theme: theme,
        onTransparency: (value) async {
          seen.add(value);
          // 真装配层做的事：写进控制器（设置页读的就是它）。
          theme.setTransparency(value);
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('透明度'));
    await tester.pumpAndSettle();
    expect(find.byType(Slider), findsOneWidget);

    // 往右拖 = 更透明（左端 0% 实心、右端 100% 全透）。
    await tester.drag(find.byType(Slider), const Offset(120, 0));
    await tester.pumpAndSettle();

    expect(seen, isNotEmpty, reason: '拖动过程中就要回调，不能等松手/关闭 sheet');
    for (final value in seen) {
      expect(
        value,
        inInclusiveRange(kTransparencyOpaque, kTransparencyMax),
        reason: '回调值必须是夹取过的',
      );
    }
    expect(seen.last, greaterThan(kTransparencyOpaque));
    // 行右端的文案已经变了（不是 0%）。
    expect(find.text(transparencyLabel(seen.last)), findsWidgets);

    // **能拉到完全透明**：一直拖到最右端，回调里出现过 100。
    await tester.drag(find.byType(Slider), const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(seen.last, kTransparencyMax, reason: '不许有隐藏下限');
  });
}
