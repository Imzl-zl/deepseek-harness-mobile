/// 顶栏左上角那枚「开抽屉」字形 = `☰`（自画），不是 DSH 的 `panelLeft`。
///
/// 为什么值得钉住：这一步是**有意偏离**（桌面用面板图标折叠侧栏，手机开的是会话列表），
/// 而"偏离"最容易在某次重构里被改回去 —— 改回去不会红任何既有用例，
/// 只会再收到一次"这图标有点丑"。
///
/// 判据两条：
/// 1. 顶栏按钮里是我们的三横线字形（[DshMenuGlyph]），不是 `panelLeft` 的 SVG；
/// 2. 点它照旧开抽屉（形状换了，语义不许跟着换）。
library;

import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/dsh_app_bar.dart';
import 'package:dsh_mobile/ui/dsh_menu_glyph.dart';
import 'package:dsh_mobile/ui/dsh_state_dot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('顶栏开抽屉用的是 ☰ 字形，并且点了会回调', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.light(),
        home: Scaffold(
          appBar: ChatAppBar(
            title: '会话标题',
            onOpenDrawer: () => opened += 1,
            onNewSession: () {},
            connectionState: DshStateDotState.done,
            connectionTooltip: '已连接',
            onConnectionTap: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(DshMenuGlyph), findsOneWidget);
    // 图标名只当兜底（`DshAppBarButton` 要求名字合法），真正画的是字形。
    final button = tester.widget<DshAppBarButton>(
      find.byType(DshAppBarButton).first,
    );
    expect(button.glyph, isNotNull);

    await tester.tap(find.byTooltip('打开会话抽屉'));
    await tester.pumpAndSettle();
    expect(opened, 1);
  });
}
