/// 连接操作 sheet 的「当前连接」块回归（连接方式选择器第 1 步）。
///
/// ## 这一组守什么
///
/// 1. 块在 sheet 顶部，两行：走哪条 + 为什么没走首选（回落时）；
/// 2. **块不可点** —— 它是事实的呈示，不是入口。点它不该弹出任何操作，
///    否则"看一眼当前连接"会变成一次误触发的重新配对；
/// 3. 加块不动原来的动作行（重新配对 / 取消照旧）。
library;

import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/connection_actions_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host({
  required ConnectionSummary connection,
  required VoidCallback onRePair,
}) => MaterialApp(
  theme: DshTheme.dark(),
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () => showConnectionActionsSheet(
          context,
          connection: connection,
          onRePair: onRePair,
        ),
        child: const Text('open'),
      ),
    ),
  ),
);

void main() {
  const fellBack = (
    line: '当前连接：中转 · ws://192.168.2.43:8787',
    note: '直连 ws://192.168.2.43:8790 拨不通（连接超时）',
  );

  testWidgets('顶部块：行 + 回落原因都在', (tester) async {
    await tester.pumpWidget(_host(connection: fellBack, onRePair: () {}));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text(fellBack.line), findsOneWidget);
    expect(find.text(fellBack.note), findsOneWidget);
  });

  testWidgets('块**不可点**：点它不触发任何连接操作', (tester) async {
    var rePair = 0;
    await tester.pumpWidget(
      _host(connection: fellBack, onRePair: () => rePair++),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text(fellBack.line));
    await tester.pumpAndSettle();

    expect(rePair, 0, reason: '看一眼当前连接不该触发重新配对');
    expect(find.text('重新配对（换一台电脑）'), findsOneWidget, reason: 'sheet 还开着，没有误动作');
  });

  testWidgets('动作行照旧：重新配对 pop 并回调', (tester) async {
    var rePair = 0;
    await tester.pumpWidget(
      _host(connection: fellBack, onRePair: () => rePair++),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('重新配对（换一台电脑）'));
    await tester.pumpAndSettle();

    expect(rePair, 1);
    expect(find.text('重新配对（换一台电脑）'), findsNothing, reason: 'sheet 已关');
  });

  testWidgets('没回落时只有一行（不摆空的原因行）', (tester) async {
    await tester.pumpWidget(
      _host(
        connection: (line: '当前连接：直连 · ws://192.168.2.43:8790', note: null),
        onRePair: () {},
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('当前连接：直连 · ws://192.168.2.43:8790'), findsOneWidget);
    expect(find.textContaining('拨不通'), findsNothing);
  });
}
