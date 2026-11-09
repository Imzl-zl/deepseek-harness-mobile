/// 「原始 JSON」那一屏：**投影字段级**，不是原始 payload。
///
/// ## 为什么这条要单独守
///
/// 轨迹页的数据来自 `trajectory` 投影，它只下发每段的结构化字段
/// （`kind` / `seq` / `startTime` / `endTime` / `offsetMs` / `durationMs` /
/// `isError` / `label`）—— 电脑侧的原始事件帧**没有过线**。
///
/// 所以那个按钮叫「原始 JSON」时，很容易被读成"这就是电脑侧发过来的东西"。
/// 一旦被这么用（拿它当抓包证据 / 拿它排查线上形状），结论就是错的，而且不会报错。
/// 唯一的防线是标题与正文里那句「非原始 payload」—— 这里把它钉住。
library;

import 'dart:convert';

import 'package:dsh_mobile/model/trajectory.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/trajectory_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

TrajectoryStep _step({
  int seq = 7,
  int offsetMs = 300,
  int? durationMs = 1200,
  bool isError = false,
  String label = 'bash',
}) => TrajectoryStep(
  kind: TrajectoryStepKind.tool,
  seq: seq,
  startTime: 1760000000000,
  endTime: durationMs == null ? null : 1760000001200,
  offsetMs: offsetMs,
  durationMs: durationMs,
  isError: isError,
  label: label,
);

void main() {
  test('字段投影：字段名与值原样，还在跑的段不补 0', () {
    final decoded =
        jsonDecode(
              trajectoryFieldsJson([
                _step(),
                _step(seq: 8, offsetMs: 900, durationMs: null, isError: true),
              ]),
            )
            as List;

    expect(decoded, hasLength(2));
    final first = decoded.first as Map;
    expect(first['kind'], 'tool');
    expect(first['seq'], 7);
    expect(first['offsetMs'], 300);
    expect(first['durationMs'], 1200);
    expect(first['isError'], false);
    expect(first['label'], 'bash');
    expect(
      (decoded[1] as Map)['durationMs'],
      isNull,
      reason: '还在跑的段没有用时 —— 补 0 会让"进行中"变成"0 毫秒"',
    );
    expect((decoded[1] as Map)['isError'], isTrue);
  });

  testWidgets('对话框标题写清「非原始 payload」，正文先说明它是什么', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showTrajectoryFieldsJson(
              context,
              turn: 3,
              steps: [
                _step(),
                _step(seq: 8, offsetMs: 900, label: 'read'),
              ],
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('非原始 payload'),
      findsOneWidget,
      reason: '标题不带这句，就会被当成"电脑侧到底发了什么"的证据',
    );
    expect(find.textContaining('第 3 轮'), findsOneWidget);
    expect(find.textContaining('2 段'), findsOneWidget, reason: '多了就要说几段');
    expect(find.textContaining('不是电脑侧的原始事件帧'), findsOneWidget);
    expect(find.textContaining('"offsetMs": 900'), findsOneWidget);
  });
}
