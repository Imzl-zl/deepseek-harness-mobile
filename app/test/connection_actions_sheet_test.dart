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
  VoidCallback? onAddHost,
  VoidCallback? onRetry,
  VoidCallback? onReconnect,
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
          onAddHost: onAddHost,
          onRetry: onRetry,
          onReconnect: onReconnect,
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
    // 台数是动态事实：做成右侧的值，不再是一整句副标题（2026-11-13）。
    expect(find.text('1 台'), findsOneWidget);
    expect(find.text('还有 1 台已配对的电脑'), findsNothing);
    expect(find.text('切回上一台'), findsOneWidget);
    expect(find.text('回到「客厅那台」'), findsOneWidget);

    await tester.tap(find.text('切回上一台'));
    await tester.pumpAndSettle();
    expect(back, 1);
    expect(switched, 0, reason: '两个动作不许互相触发');
  });

  testWidgets('给了「添加电脑」：副标题写明后果，点它只走添加（不动重新配对）', (tester) async {
    var add = 0;
    var rePair = 0;
    await tester.pumpWidget(
      _host(
        connection: fellBack,
        onRePair: () => rePair++,
        onAddHost: () => add++,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('添加电脑'), findsOneWidget);
    // 两行后果相反（一个保留、一个清掉），副标题必须把这件事写出来。
    // 2026-11-13 收窄成「保留这台」：原句"再配一台；现在这台保留"里的前半句
    // 从标题就能读出来。
    expect(find.text('保留这台'), findsOneWidget);
    expect(find.text('再配一台；现在这台保留'), findsNothing);

    await tester.tap(find.text('添加电脑'));
    await tester.pumpAndSettle();

    expect(add, 1);
    expect(rePair, 0, reason: '「添加」绝不能顺带清凭据');
    expect(find.text('添加电脑'), findsNothing, reason: 'sheet 已关');
  });

  testWidgets('没给「添加电脑」时不摆这一行（没配对时"连电脑"就是它本身）', (tester) async {
    await tester.pumpWidget(_host(connection: fellBack, onRePair: () {}));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('添加电脑'), findsNothing);
  });

  // ---- 2026-11-13 收窄：删掉的两条与合并的一对 ----

  testWidgets('不再摆「打开侧面板」与「手动填写电脑地址」', (tester) async {
    // 前者是右缘抽屉的第二个入口（用户原话："我侧滑都打开了"），
    // 后者挪进「换个连接方式」列表的末尾。
    await tester.pumpWidget(_host(connection: fellBack, onRePair: () {}));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('打开侧面板'), findsNothing);
    expect(find.text('手动填写电脑地址'), findsNothing);
  });

  testWidgets('「重新连接」与「重试连接」只剩一行：放弃自动重连时换标题', (tester) async {
    var reconnect = 0;
    var retry = 0;
    await tester.pumpWidget(
      _host(
        connection: fellBack,
        onRePair: () {},
        onReconnect: () => reconnect++,
        onRetry: () => retry++,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('重试连接'), findsOneWidget);
    expect(find.text('重新连接'), findsNothing, reason: '两个同义动作不许各占一行');

    await tester.tap(find.text('重试连接'));
    await tester.pumpAndSettle();
    expect(retry, 1);
    expect(reconnect, 0, reason: 'gaveUp 时走的是"再试一轮"，不是普通重拨');
  });

  testWidgets('没有 onRetry 时这一行叫「重新连接」', (tester) async {
    var reconnect = 0;
    await tester.pumpWidget(
      _host(
        connection: fellBack,
        onRePair: () {},
        onReconnect: () => reconnect++,
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('重新连接'), findsOneWidget);
    await tester.tap(find.text('重新连接'));
    await tester.pumpAndSettle();
    expect(reconnect, 1);
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

  testWidgets('动作行对朗读器是按钮，名字就是标题', (tester) async {
    await tester.pumpWidget(_host(connection: fellBack, onRePair: () {}));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 这些行是 `ListTile`：它自带 `button: true`（`list_tile.dart:992-993` 的
    // `internalAddSemanticForOnTap`）。这条用例钉的是**它们走的是那个控件** ——
    // 哪天有人把某一行换成手写 `InkWell`，角色会静默消失，而视觉一点不变。
    final node = tester.getSemantics(find.text('重新配对（换一台电脑）'));
    expect(node, isSemantics(isButton: true, hasTapAction: true));
    expect(
      node.getSemanticsData().label,
      contains('会清掉本机凭据'),
      reason: '副标题是这一行的后果，不能只念标题',
    );
  });
}
