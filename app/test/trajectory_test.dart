/// 轨迹页（`ui/trajectory_page.dart` + `ui/trajectory_timeline.dart`）的回归。
///
/// 规格见 `docs/subsystems/trajectory-page.md`。
///
/// ## 这一组守五件事
///
/// 1. **一轮一行**：`第 N 轮` + 用时 + 提问 / 结果预览 + 计数；
/// 2. **用时诚实**：时长只读 `trajectory` 投影；投影里没有就说「用时未知」、
///    这一轮还在跑就说「进行中」、失败 / 停止替换掉时长
///    （DSH `TurnProcessNodeView.tsx:24-30` 同一条）；
/// 3. **时间轴是比例**：段的 `left` / `width` 由 `offsetMs` / `durationMs`
///    两个**电脑侧给的数**算出来，窄屏上不横滑；
/// 4. **进行中的轮只画起点标记**（没有右端就没有比例）；
/// 5. **截断要明说**（`truncated` 那几行）。
///
/// ## 2026-10-15：示例数据已删，数据由用例自己给
///
/// 原来这些用例不传数据，靠 widget 里的 `_sampleRows` / `_sampleEntries` 兜底 ——
/// 于是"删掉假数据"这个动作会让它们全红，而红的原因是"示例没了"，不是"功能坏了"。
library;

import 'dart:math' as math;

import 'package:dsh_mobile/model/trajectory.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/trajectory_page.dart';
import 'package:dsh_mobile/ui/trajectory_timeline.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

/// 一条 wire 形状的段（键名与连接器 `viewSchema` 逐字对应）。
Map<String, Object?> _step({
  String kind = 'tool',
  required int seq,
  int offsetMs = 0,
  int? durationMs = 1000,
  bool isError = false,
}) => <String, Object?>{
  'kind': kind,
  'seq': seq,
  'startTime': 1_700_000_000_000 + offsetMs,
  'endTime': durationMs == null
      ? null
      : 1_700_000_000_000 + offsetMs + durationMs,
  'offsetMs': offsetMs,
  'durationMs': durationMs,
  'isError': isError,
  'label': kind == 'tool' ? 'read' : '',
};

/// 走**真解析器**变成 `TrajectoryTurn`（不从常量抄一遍形状）。
TrajectoryTurn _turn(
  int turn, {
  int? durationMs = 1000,
  String? outcome = 'completed',
  List<Map<String, Object?>> steps = const [],
  bool stepsTruncated = false,
}) {
  final view = parseTrajectory(<String, Object?>{
    'turns': <Object?>[
      <String, Object?>{
        'turn': turn,
        'startSeq': turn * 10,
        'startTime': 1_700_000_000_000,
        'endTime': durationMs == null ? null : 1_700_000_000_000 + durationMs,
        'durationMs': durationMs,
        'outcome': outcome,
        'stepsTruncated': stepsTruncated,
        'steps': steps,
      },
    ],
    'truncated': false,
    'droppedTurns': 0,
    'droppedSteps': 0,
  });
  expect(view, isNotNull, reason: '用例自己造的 wire 形状必须能被解析器认');
  return view!.turns.single;
}

/// 三条轮次行：一条正常、一条失败、一条**投影里没有**。
List<TraceTurn> _turns() => <TraceTurn>[
  TraceTurn(
    turn: 1,
    prompt: '帮我启动',
    response: '已经在跑了',
    trajectory: _turn(
      1,
      durationMs: 30000,
      steps: <Map<String, Object?>>[
        _step(kind: 'assistant', seq: 11, offsetMs: 0, durationMs: 1000),
        _step(seq: 12, offsetMs: 1000, durationMs: 29000),
      ],
    ),
    messageCount: 4,
    toolCallCount: 2,
  ),
  TraceTurn(
    turn: 2,
    prompt: '再跑一次',
    response: '这一轮失败了',
    trajectory: _turn(
      2,
      durationMs: 120000,
      outcome: 'error',
      steps: <Map<String, Object?>>[
        _step(seq: 21, offsetMs: 0, durationMs: 120000, isError: true),
      ],
    ),
    messageCount: 6,
    failed: true,
  ),
  const TraceTurn(turn: 3, prompt: '', response: '还没结束'),
];

Widget _wrap(Widget child) => MaterialApp(
  theme: DshTheme.dark(),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('一轮一行：轮次号 / 提问 / 结果 / 计数都在，且轮次升序', (tester) async {
    await tester.pumpWidget(_wrap(TrajectoryTab(turns: _turns())));
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

  testWidgets('用时：有就说时长、没有就说未知、失败替换成「失败」', (tester) async {
    await tester.pumpWidget(_wrap(TrajectoryTab(turns: _turns())));
    await tester.pumpAndSettle();

    expect(find.text('30 秒'), findsOneWidget);
    expect(find.text('用时未知'), findsOneWidget);
    expect(find.text('失败'), findsOneWidget, reason: '失败比"跑了多久"重要');
    // 失败那轮的用时**不显示**（120 秒不该出现）。
    expect(find.text('2 分 0 秒'), findsNothing);
  });

  testWidgets('时间轴：一段一条，位置与长度按投影给的 offsetMs / durationMs', (tester) async {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final turn = _turn(
      1,
      durationMs: 10000,
      steps: <Map<String, Object?>>[
        _step(kind: 'assistant', seq: 11, offsetMs: 0, durationMs: 2000),
        _step(seq: 12, offsetMs: 2000, durationMs: 3000),
      ],
    );
    await tester.pumpWidget(
      _wrap(
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: TrajectoryTimeline(turn: turn),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 几何从**纯函数**读（widget 测试不量像素）：
    // 轨道宽度 = 390 - 32 = 358dp。
    final segments = layoutTimelineSegments(
      steps: turn.steps,
      turnDurationMs: turn.durationMs,
      width: 358,
    );
    expect(segments.length, 2);
    expect(segments[0].left, 0);
    expect(segments[0].width, closeTo(358 * 0.2, 0.001));
    expect(segments[1].left, closeTo(358 * 0.2, 0.001));
    expect(segments[1].width, closeTo(358 * 0.3, 0.001));
    // 行：助手在上、工具在下。**紧凑后的行号** —— 这一轮没有压缩段，
    // 所以工具是第 1 行（不是第 2 行），否则会画到控件高度之外。
    expect(segments[0].lane, 0);
    expect(segments[1].lane, 1);
    expect(
      timelineHeight(turn.steps),
      greaterThanOrEqualTo(
        (segments.map((s) => s.lane + 1).reduce(math.max)) *
            kTimelineLaneHeight,
      ),
      reason: '每一行都必须落在控件高度之内（2026-10-22 真机：工具段被画到框外）',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('进行中的轮：一段都不给长度，只按顺序摆起点标记', (tester) async {
    final turn = _turn(
      1,
      durationMs: null,
      steps: <Map<String, Object?>>[
        _step(kind: 'assistant', seq: 11, offsetMs: 0, durationMs: null),
        _step(seq: 12, offsetMs: 500, durationMs: null),
      ],
    );
    // 没有跨度就没有比例 —— 纯函数直接给空表（调用方改画起点标记）。
    expect(
      layoutTimelineSegments(
        steps: turn.steps,
        turnDurationMs: turn.durationMs,
        width: 358,
      ),
      isEmpty,
    );

    await tester.pumpWidget(
      _wrap(
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: TrajectoryTimeline(turn: turn),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('过窄的**相邻**段并成一格，但点开时一段都不少', (tester) async {
    // 100 秒的轮、轨道 358dp：两段各 10ms 落成 0.036dp，必须合并；
    // 另有一段 20 秒（71.6dp）宽到不用并 —— 它守"合并只吃相邻的过窄段"。
    final turn = _turn(
      1,
      durationMs: 100000,
      steps: <Map<String, Object?>>[
        _step(kind: 'assistant', seq: 11, offsetMs: 0, durationMs: 30000),
        _step(seq: 12, offsetMs: 40000, durationMs: 10),
        _step(seq: 13, offsetMs: 40010, durationMs: 10),
        _step(seq: 14, offsetMs: 60000, durationMs: 20000),
      ],
    );
    final segments = layoutTimelineSegments(
      steps: turn.steps,
      turnDurationMs: turn.durationMs,
      width: 358,
    );
    // 模型泳道 1 格（宽段）+ 工具泳道 2 格（合并段 + 宽段）。
    expect(segments.length, 3);
    final merged = segments.singleWhere((s) => s.merged);
    // 工具段是这一轮的第 2 条泳道 ⇒ 紧凑后落在第 1 行。
    expect(merged.lane, 1, reason: '合并只在同一条泳道内发生');
    expect(merged.steps.map((s) => s.seq), <int>[
      12,
      13,
    ], reason: '合并只改画法，原始段一段都不丢');
    expect(merged.width, greaterThanOrEqualTo(kTimelineMinSegmentWidth));
    expect(
      merged.left,
      closeTo(358 * 40000 / 100000, 0.001),
      reason: '合并段的左边界取第一段',
    );

    // 点它要能打开（`segmentAt` 的容差比段本身宽）。
    expect(segmentAt(segments, merged.left)?.merged, isTrue);
    expect(segmentAt(segments, -100), isNull, reason: '点空白处不硬塞最近的一段');
  });

  testWidgets('点一格回调（接线到段的详情）', (tester) async {
    final turn = _turn(
      1,
      durationMs: 10000,
      steps: <Map<String, Object?>>[
        _step(seq: 11, offsetMs: 0, durationMs: 5000),
      ],
    );
    List<TrajectoryStep>? tapped;
    await tester.pumpWidget(
      _wrap(
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: TrajectoryTimeline(
              turn: turn,
              onTapSegment: (steps) => tapped = steps,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TrajectoryTimeline));
    await tester.pumpAndSettle();
    expect(tapped, isNotNull);
    expect(tapped!.single.seq, 11);
  });

  testWidgets('截断要说出来（`truncated` 不是静默的）', (tester) async {
    await tester.pumpWidget(
      _wrap(
        TrajectoryTab(
          turns: _turns(),
          truncationLabel: trajectoryTruncationLabel(
            parseTrajectory(<String, Object?>{
              'turns': <Object?>[
                <String, Object?>{
                  'turn': 1,
                  'startSeq': 1,
                  'startTime': 0,
                  'endTime': 1,
                  'durationMs': 1,
                  'outcome': 'completed',
                  'stepsTruncated': false,
                  'steps': <Object?>[],
                },
              ],
              'truncated': true,
              'droppedTurns': 4,
              'droppedSteps': 30,
            }),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('时间轴不全'), findsOneWidget);
    expect(find.textContaining('4 轮'), findsOneWidget);
  });

  testWidgets('汇总行：已知用时 / 未知分句说', (tester) async {
    await tester.pumpWidget(_wrap(TrajectoryTab(turns: _turns())));
    await tester.pumpAndSettle();
    // 第 1、2 轮都有投影（失败那轮的 120 秒是真花的，照样进总时长 ——
    // 只是它自己的标签被"失败"替换掉）；第 3 轮投影里没有。
    expect(find.text('共 3 轮 · 已知用时 2 分 30 秒 · 1 轮用时未知'), findsOneWidget);
  });

  testWidgets('点一行回调（接线到 sheet-traj）', (tester) async {
    TraceTurn? tapped;
    await tester.pumpWidget(
      _wrap(TrajectoryTab(turns: _turns(), onTapTurn: (t) => tapped = t)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('第 2 轮'));
    await tester.pumpAndSettle();
    expect(tapped?.turn, 2);
  });

  testWidgets('390dp 上不横滑：没有 640px 的固定宽度、没有横滑提示', (tester) async {
    // 原型 `.gantt-in { width:640px }` 是桌面形态；390dp 竖屏上先横滑才知道
    // 有内容。时间轴按可用宽度画，靠"过窄段合并"解决密度（见 timeline 文件头）。
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_wrap(TrajectoryTab(turns: _turns())));
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
        TrajectoryTab(
          turns: [
            TraceTurn(
              turn: 1,
              prompt: 'record the prompt for the next session please',
              response:
                  'I have written it into docs/ and added three assertions to the regression suite '
                  'so the next session cannot silently drop the marker again.',
              trajectory: _turn(1, durationMs: 5000),
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
      find.textContaining('电脑侧跑完一轮后'),
      findsOneWidget,
      reason: '要说清数据来源是电脑侧',
    );
    for (final name in ['第 1 轮', '第 2 轮']) {
      expect(find.text(name), findsNothing, reason: '$name 是示例数据');
    }
  });

  testWidgets('这台电脑没给时间轴：空态说的是"去查电脑"，不是"再等等"', (tester) async {
    await tester.pumpWidget(_wrap(const TrajectoryTab(timelineMissing: true)));
    await tester.pumpAndSettle();
    expect(find.textContaining('这台电脑没给时间轴'), findsOneWidget);
    expect(find.textContaining('trajectory'), findsOneWidget);
  });

  testWidgets('**不摆假入口**：没有「时长/轮次/调用」chip，也没有搜索钮', (tester) async {
    // 2026-10-22 用户原话「时间轴，轮次，调用都没有啊」：那一行 chip 长得像切换器，
    // 实际三个都没有 onTap、搜索钮是 `onPressed: () {}`。按第八条教训
    //（承诺了没做比没有更糟）删掉，等各自有数据源再加回来。
    await tester.pumpWidget(_wrap(TrajectoryTab(turns: _turns())));
    await tester.pumpAndSettle();

    for (final label in ['时长', '轮次', '调用']) {
      expect(find.text(label), findsNothing, reason: '「$label」是没有实现的假 chip');
    }
    expect(find.byTooltip('搜索轨迹'), findsNothing, reason: '搜索钮没有实现');
  });
}
