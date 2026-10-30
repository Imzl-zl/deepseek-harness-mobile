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
import 'package:dsh_mobile/ui/dsh_popover.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host({
  required ConnectionSummary connection,
  required VoidCallback onRePair,
  Rect? anchor,
  HostSwitchSeam? hostSwitch,
}) => MaterialApp(
  theme: DshTheme.dark(),
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () => showConnectionActionsSheet(
          context,
          connection: connection,
          onRePair: onRePair,
          anchor: anchor,
          hostSwitch: hostSwitch,
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

  testWidgets('切换电脑：多机入口与「切回上一台」都在，且各自回调一次', (tester) async {
    var switched = 0;
    var back = 0;
    await tester.pumpWidget(
      _host(
        connection: fellBack,
        onRePair: () {},
        hostSwitch: (
          otherHostCount: 1,
          onSwitch: () => switched++,
          onSwitchBack: () => back++,
          switchBackLabel: '客厅那台',
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('切换电脑'), findsOneWidget);
    expect(find.text('还有 1 台已配对的电脑'), findsOneWidget);
    expect(find.text('切回上一台'), findsOneWidget);
    expect(find.text('回到「客厅那台」'), findsOneWidget);

    await tester.tap(find.text('切回上一台'));
    await tester.pumpAndSettle();
    expect(back, 1);
    expect(switched, 0, reason: '两个动作不许互相触发');
  });

  testWidgets('只有一台电脑时不摆「切换电脑」（没有可换的）', (tester) async {
    await tester.pumpWidget(
      _host(
        connection: fellBack,
        onRePair: () {},
        hostSwitch: (
          otherHostCount: 0,
          onSwitch: () {},
          onSwitchBack: null,
          switchBackLabel: null,
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('切换电脑'), findsNothing);
    expect(find.text('切回上一台'), findsNothing);
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

  testWidgets('给了锚点：面板长在触发点下面（顶栏那条，不是底部 sheet）', (tester) async {
    // 顶栏状态点大约在 y≈100~138；这里直接给它的矩形。
    const anchor = Rect.fromLTWH(300, 100, 38, 38);
    await tester.pumpWidget(
      _host(connection: fellBack, onRePair: () {}, anchor: anchor),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final panel = tester.getRect(find.byKey(popoverPanelKey));
    expect(
      panel.top - anchor.bottom,
      lessThan(80),
      reason: '面板顶边要贴着状态点（底部 sheet 会差出一整屏）',
    );
    expect(
      (panel.left - anchor.left).abs(),
      lessThan(80),
      reason: '水平方向也要落在状态点这一侧',
    );
    // 内容与底部 sheet 那份逐字相同（形态不同，动作不漂移）。
    expect(find.text('重新配对（换一台电脑）'), findsOneWidget);
  });

  testWidgets('不给锚点：仍是底部 sheet（空态出路 / 抽屉连接行）', (tester) async {
    await tester.pumpWidget(_host(connection: fellBack, onRePair: () {}));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(popoverPanelKey), findsNothing, reason: '没有锚点就不该长成浮层');
    expect(find.text('重新配对（换一台电脑）'), findsOneWidget);
  });
}
