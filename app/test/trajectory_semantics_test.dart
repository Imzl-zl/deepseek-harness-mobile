/// 轨迹页的**语义**：轮次行是一个按钮，时间轴每一格自己也是一个有名字的按钮。
///
/// ## 为什么时间轴要"一格一个节点"
///
/// 时间轴的触摸命中是**按 x 坐标**算的（`segmentAt` + `kTimelineHitSlop`，因为
/// 段只有 3dp 宽，自己收不到点击）。朗读器不是这样工作的：它的双击是
/// **激活当前节点**，不按坐标，也不需要 48dp 的身体 —— 所以"一格一个 `Semantics`
/// 节点"正好把这份数据第一次变成可达的。
///
/// 反过来，如果只给整条轨道一个手势节点，朗读器会念出一个**无名可点区**
/// （`GestureDetector` 只装 tap 动作、不装名字），那正是"假入口"的语义版。
/// 所以 `_Track` 的 `GestureDetector` 现在 `excludeFromSemantics: true`。
///
/// 判据与取舍见 `.agents/notes/implemented/2026-11-12-a11y-sheet-and-trajectory.md`。
library;

import 'package:dsh_mobile/model/trajectory.dart';
import 'package:dsh_mobile/theme/dsh_icons.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/trajectory_page.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一条 wire 形状的段（键名与连接器 `viewSchema` 逐字对应）。
Map<String, Object?> _step({
  String kind = 'tool',
  required int seq,
  required int offsetMs,
  int? durationMs = 1000,
  bool isError = false,
  String label = 'bash',
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
  'label': label,
};

/// 走**真解析器**变成 `TrajectoryTurn`（不从常量抄一遍形状）。
TrajectoryTurn _turn(int turn, List<Map<String, Object?>> steps) {
  final view = parseTrajectory(<String, Object?>{
    'turns': <Object?>[
      <String, Object?>{
        'turn': turn,
        'startSeq': turn * 10,
        'startTime': 1_700_000_000_000,
        'endTime': 1_700_000_000_000 + 60000,
        'durationMs': 60000,
        'outcome': 'completed',
        'stepsTruncated': false,
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

Widget _wrap(Widget child) => MaterialApp(
  theme: DshTheme.dark(),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('轮次行：按钮角色 + 名字仍是「第 N 轮」', (tester) async {
    await tester.pumpWidget(
      _wrap(
        TrajectoryTab(
          turns: <TraceTurn>[
            TraceTurn(
              turn: 7,
              prompt: '跑一下',
              response: '好了',
              trajectory: _turn(7, <Map<String, Object?>>[
                _step(kind: 'assistant', seq: 71, offsetMs: 0, label: ''),
                _step(seq: 72, offsetMs: 1000),
              ]),
              messageCount: 2,
              toolCallCount: 1,
            ),
          ],
          onTapTurn: (_) {},
          onTapSegment: (_, _) {},
        ),
      ),
    );

    final node = tester.getSemantics(
      find.byKey(const ValueKey<String>('trajectory-row-7')),
    );
    expect(
      node,
      isSemantics(isButton: true, hasTapAction: true),
      reason: '行是手写的 InkWell：不加角色，朗读器念完文字就停',
    );
    expect(
      node.getSemanticsData().label,
      contains('第 7 轮'),
      reason: '只加角色，不能把行里的文字吞掉',
    );
  });

  testWidgets('时间轴每一格：独立按钮节点，名字说得出类别 / 工具名 / 失败', (tester) async {
    var tapped = <TrajectoryStep>[];
    await tester.pumpWidget(
      _wrap(
        TrajectoryTab(
          turns: <TraceTurn>[
            TraceTurn(
              turn: 7,
              prompt: '',
              response: '',
              trajectory: _turn(7, <Map<String, Object?>>[
                _step(kind: 'assistant', seq: 71, offsetMs: 0, label: ''),
                _step(seq: 72, offsetMs: 1000, durationMs: 20000),
                _step(
                  seq: 73,
                  offsetMs: 21000,
                  durationMs: 5000,
                  isError: true,
                  label: 'read',
                ),
              ]),
            ),
          ],
          onTapTurn: (_) {},
          onTapSegment: (_, steps) => tapped = steps,
        ),
      ),
    );

    // **一格一个节点**：名字里有类别（或工具名），失败的那格明说"失败"。
    final bash = tester.getSemantics(find.bySemanticsLabel('工具 bash'));
    expect(
      bash,
      isSemantics(isButton: true, hasTapAction: true),
      reason: '手指要 3dp 精度，朗读器只要一个节点 + 一个动作',
    );

    final failed = tester.getSemantics(find.bySemanticsLabel('工具 read，失败'));
    expect(failed, isSemantics(isButton: true, hasTapAction: true));

    // 激活节点的动作真的能到那一步（不是只画了一个按钮外表）。
    tester.semantics.performAction(
      find.semantics.byLabel('工具 read，失败'),
      SemanticsAction.tap,
    );
    await tester.pump();
    expect(tapped.map((step) => step.seq), <int>[
      73,
    ], reason: '这一格只代表那一步 —— 点它打开的就是那一步的详情');
  });

  testWidgets('没有回调时不装成入口：不报按钮、不画箭头', (tester) async {
    await tester.pumpWidget(
      _wrap(
        TrajectoryTab(
          turns: <TraceTurn>[
            TraceTurn(
              turn: 7,
              prompt: '跑一下',
              response: '好了',
              trajectory: _turn(7, <Map<String, Object?>>[
                _step(kind: 'assistant', seq: 71, offsetMs: 0, label: ''),
              ]),
            ),
          ],
          // 两个回调都不给：这一行就是纯展示。
        ),
      ),
    );

    final row = tester.getSemantics(
      find.byKey(const ValueKey<String>('trajectory-row-7')),
    );
    expect(row, isNot(isSemantics(isButton: true)), reason: '点不动的行不该被念成按钮');
    final chevrons = tester
        .widgetList<DshIcon>(find.byType(DshIcon))
        .where((icon) => icon.name == 'chevronRight');
    expect(
      chevrons,
      isEmpty,
      reason: '箭头是“会带你去别处”的承诺，没有去处就不画（`settings_row.dart` 同一条）',
    );
  });

  testWidgets('行里没有「无名可点区」：时间轴的手势不再自己造一个节点', (tester) async {
    await tester.pumpWidget(
      _wrap(
        TrajectoryTab(
          turns: <TraceTurn>[
            TraceTurn(
              turn: 7,
              prompt: '',
              response: '',
              trajectory: _turn(7, <Map<String, Object?>>[
                _step(kind: 'assistant', seq: 71, offsetMs: 0, label: ''),
                _step(seq: 72, offsetMs: 1000, durationMs: 20000),
              ]),
            ),
          ],
          onTapTurn: (_) {},
          onTapSegment: (_, _) {},
        ),
      ),
    );

    final row = tester.getSemantics(
      find.byKey(const ValueKey<String>('trajectory-row-7')),
    );
    final unnamed = <SemanticsNode>[];
    void visit(SemanticsNode node) {
      for (final child in node.debugListChildrenInOrder(
        DebugSemanticsDumpOrder.traversalOrder,
      )) {
        final data = child.getSemanticsData();
        if (data.hasAction(SemanticsAction.tap) && data.label.trim().isEmpty) {
          unnamed.add(child);
        }
        visit(child);
      }
    }

    visit(row);
    expect(
      unnamed,
      isEmpty,
      reason:
          '整条轨道那个 GestureDetector 只装点击动作、不装名字 —— '
          '朗读器会念出一个不知道干什么的可点区（假入口的语义版）',
    );
  });
}
