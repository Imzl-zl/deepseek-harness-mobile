/// 轨迹页（`ui/trajectory_page.dart`）的回归。
///
/// 规格见 `docs/subsystems/trajectory-page.md`。
///
/// ## 这一组守四件事
///
/// 1. **一轮一行**：`第 N 轮` + 用时 + 提问 / 结果预览 + 计数；
/// 2. **用时诚实**：有 `TurnProcessItem` 说时长，没有就说「用时未加载」，
///    失败 / 停止替换掉时长（DSH `TurnProcessNodeView.tsx:24-30` 同一条）；
/// 3. **迷你条是比例**：长度 = 该轮 / 最长一轮（不是每轮一样长）；
/// 4. **单列、不横滑**：390dp 上没有任何 640px 的固定宽度（那是原型的桌面形态）。
///
/// ## 2026-10-15：示例数据已删，数据由用例自己给
///
/// 原来这些用例不传数据，靠 widget 里的 `_sampleRows` / `_sampleEntries` 兜底 ——
/// 于是"删掉假数据"这个动作会让它们全红，而红的原因是"示例没了"，不是"功能坏了"。
library;

import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/trajectory_page.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

/// 三条轮次行：一条正常、一条失败、一条用时未加载。
const _turns = <TraceTurn>[
  TraceTurn(
    turn: 1,
    prompt: '帮我启动',
    response: '已经在跑了',
    elapsedMs: 30000,
    messageCount: 4,
    toolCallCount: 2,
    barFraction: 0.25,
  ),
  TraceTurn(
    turn: 2,
    prompt: '再跑一次',
    response: '这一轮失败了',
    elapsedMs: 120000,
    messageCount: 6,
    failed: true,
    barFraction: 1,
  ),
  TraceTurn(turn: 3, prompt: '', response: '还没结束'),
];

Widget _wrap(Widget child) => MaterialApp(
  theme: DshTheme.dark(),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('一轮一行：轮次号 / 提问 / 结果 / 计数都在，且轮次升序', (tester) async {
    await tester.pumpWidget(_wrap(const TrajectoryTab(turns: _turns)));
    await tester.pumpAndSettle();

    for (final label in ['第 1 轮', '第 2 轮', '第 3 轮']) {
      expect(find.text(label), findsOneWidget, reason: '缺「$label」');
    }
    expect(find.text('提问：帮我启动'), findsOneWidget);
    expect(find.text('结果：已经在跑了'), findsOneWidget);
    expect(find.text('4 条消息 · 2 次工具'), findsOneWidget);

    // 轮次升序：第 3 轮在第 1 轮下面。
    final first = tester.getTopLeft(find.text('第 1 轮')).dy;
    final last = tester.getTopLeft(find.text('第 3 轮')).dy;
    expect(last, greaterThan(first), reason: '顺序照 turnOutline 的轮次升序');
  });

  testWidgets('内容超一屏时**打开就滚到末尾**（最新一轮）', (tester) async {
    // 行数少时不用 reverse（那会把内容顶到下半截），所以"落在最新一轮"
    // 只能靠首帧后滚到底。这里用小屏 + 12 轮逼出溢出。
    tester.view.physicalSize = const Size(390 * 3, 420 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _wrap(
        TrajectoryTab(
          turns: [
            for (var i = 1; i <= 12; i += 1)
              TraceTurn(turn: i, prompt: '第 $i 句', response: '第 $i 答'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    expect(
      position.pixels,
      position.maxScrollExtent,
      reason: '首帧后要锚到末尾，而不是停在最早一轮',
    );
    expect(find.text('第 12 轮'), findsOneWidget);
  });

  testWidgets('用时：有就说时长、没有就说未加载、失败替换成「失败」', (tester) async {
    await tester.pumpWidget(_wrap(const TrajectoryTab(turns: _turns)));
    await tester.pumpAndSettle();

    expect(find.text('30 秒'), findsOneWidget);
    expect(find.text('用时未加载'), findsOneWidget);
    expect(find.text('失败'), findsOneWidget, reason: '失败比"跑了多久"重要');
    // 失败那轮的用时**不显示**（120 秒不该出现）。
    expect(find.text('2 分 0 秒'), findsNothing);
  });

  testWidgets('迷你条是**比例**：30s / 120s = 25%', (tester) async {
    await tester.pumpWidget(_wrap(const TrajectoryTab(turns: _turns)));
    await tester.pumpAndSettle();

    // 条的填充与空余都是 `Expanded(flex:)`（整数，可直接断言）。
    final flexes = tester
        .widgetList<Expanded>(find.byType(Expanded))
        .map((e) => e.flex)
        .toList();
    expect(flexes, contains(250), reason: '30s 相对 120s 是 25%');
    expect(flexes, contains(750));
    expect(flexes, contains(1000), reason: '最长那一轮铺满');

    // 没有可信用时的轮**不画条**（3 轮里只有 2 条：250+750 与铺满的 1000）。
    final bars = find.byWidgetPredicate(
      (w) =>
          w is Expanded && (w.flex == 250 || w.flex == 750 || w.flex == 1000),
    );
    expect(bars, findsNWidgets(3), reason: '两条迷你条：25% 那条两段、铺满那条一段');
  });

  testWidgets('汇总行：有未加载的轮就说清有几轮', (tester) async {
    await tester.pumpWidget(_wrap(const TrajectoryTab(turns: _turns)));
    await tester.pumpAndSettle();
    expect(
      find.text('共 3 轮 · 已知用时 2 分 30 秒（1 轮未加载）'),
      findsOneWidget,
      reason: '不说明的话"已知用时"会被读成全会话总时长',
    );
  });

  testWidgets('点一行回调（接线到 sheet-traj）', (tester) async {
    TraceTurn? tapped;
    await tester.pumpWidget(
      _wrap(TrajectoryTab(turns: _turns, onTapTurn: (t) => tapped = t)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('第 2 轮'));
    await tester.pumpAndSettle();
    expect(tapped?.turn, 2);
  });

  testWidgets('390dp 上不横滑：没有 640px 的固定宽度、没有横滑提示', (tester) async {
    // 原型 `.gantt-in { width:640px }` 是桌面形态；390dp 竖屏上先横滑才知道
    // 有内容，而时间轴那四行还没有数据源（见 docs/subsystems/trajectory-page.md §1）。
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(const TrajectoryTab(turns: _turns)));
    await tester.pumpAndSettle();

    final wide = tester
        .widgetList<SizedBox>(find.byType(SizedBox))
        .where((s) => s.width == 640);
    expect(wide, isEmpty, reason: '不该再有 640px 的固定宽度');
    expect(find.text('← 横滑查看完整时间轴 →'), findsNothing);
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长英文回复在 390dp 上不溢出（按词换行、两行截断）', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _wrap(
        const TrajectoryTab(
          turns: [
            TraceTurn(
              turn: 1,
              prompt: 'record the prompt for the next session please',
              response:
                  'I have written it into docs/ and added three assertions to the regression suite '
                  'so the next session cannot silently drop the marker again.',
              elapsedMs: 5000,
              barFraction: 1,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '溢出会以 FlutterError 抛出');
    final response = tester.widget<Text>(
      find.textContaining('I have written it into docs/'),
    );
    expect(response.maxLines, 2);
    expect(response.overflow, TextOverflow.ellipsis);
  });

  testWidgets('**不传数据是空态**，不造一份假的', (tester) async {
    await tester.pumpWidget(_wrap(const TrajectoryTab()));
    await tester.pumpAndSettle();

    expect(find.text('还没有轨迹'), findsOneWidget);
    expect(
      find.textContaining('turnOutline'),
      findsOneWidget,
      reason: '要说清数据来源',
    );
    for (final name in ['第 1 轮', '第 2 轮']) {
      expect(find.text(name), findsNothing, reason: '$name 是示例数据');
    }
  });

  testWidgets('**不摆假入口**：没有「时长/轮次/调用」chip，也没有搜索钮', (tester) async {
    // 2026-10-22 用户原话「时间轴，轮次，调用都没有啊」：那一行 chip 长得像切换器，
    // 实际三个都没有 onTap、搜索钮是 `onPressed: () {}`。按第八条教训
    //（承诺了没做比没有更糟）删掉，等各自有数据源再加回来。
    await tester.pumpWidget(_wrap(const TrajectoryTab(turns: _turns)));
    await tester.pumpAndSettle();

    for (final label in ['时长', '轮次', '调用']) {
      expect(find.text(label), findsNothing, reason: '「$label」是没有实现的假 chip');
    }
    expect(find.byTooltip('搜索轨迹'), findsNothing, reason: '搜索钮没有实现');
  });

  group('traceSummaryLabel', () {
    test('全都加载了：不带括号', () {
      expect(
        traceSummaryLabel(const [
          TraceTurn(turn: 1, prompt: '', response: '', elapsedMs: 60000),
        ]),
        '共 1 轮 · 用时 1 分 0 秒',
      );
    });

    test('一条都没加载：直说未加载，不摆 0', () {
      expect(
        traceSummaryLabel(const [
          TraceTurn(turn: 1, prompt: '', response: ''),
          TraceTurn(turn: 2, prompt: '', response: ''),
        ]),
        '共 2 轮 · 用时未加载',
      );
    });

    test('空表给空串（调用方不该显示这一行）', () {
      expect(traceSummaryLabel(const []), '');
    });
  });
}
