/// 轨迹页接真投影的回归（`turnOutline` → 账本）。
///
/// ## 这一组守什么
///
/// 2026-10-19 发现的"没看到的问题"之一：`TrajectoryTab` 一直接收
/// `rows` / `entries`，而 `chat_page.dart` 的 `_TrajectoryTab` **只传了
/// `onTapEntry`** —— 两个表恒为空，轨迹页永远显示"电脑侧跑完一轮后…"。
/// 契约里 `turnOutline` 投影一直都在（`session.projections`，§5.7），
/// 手机也早就解析了别的投影，只是从没把它接进来。
///
/// 三条判据：
/// 1. `AppModel.turnOutline` 按 wire view 解析（`{turn, seq, prompt, response}`）；
/// 2. 形状不对的项**跳过**，不抛（投影认不出 = 空态，不是崩）；
/// 3. 空表时轨迹页显示空态，**不造假数据**（2026-10-15 删 `_sampleRows` 的理由）。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/model/trajectory.dart';
import 'package:dsh_mobile/model/turn_outline.dart';
import 'package:dsh_mobile/ui/trajectory_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fake_sync_client.dart';

class _OutlineClient extends FakeSyncClient {
  _OutlineClient(this.projections);

  final Map<String, Object?> projections;

  final _sessions = StreamController<SessionDelta>.broadcast();

  @override
  conn.ConnectionState get state => conn.ConnectionState.serving;
  @override
  Stream<conn.ConnectionState> get connection => const Stream.empty();
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
  Stream<SessionDelta> sessionUpdates(String sid) => _sessions.stream;

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'session.projections') return projections as T;
    return <String, Object?>{} as T;
  }
}

void main() {
  group('AppModel.turnOutline 按 wire view 解析', () {
    test('四项都取到；缺字段的项跳过而不是抛', () async {
      final app = AppModel(
        client: _OutlineClient({
          'turnOutline': <Object?>[
            <String, Object?>{
              'turn': 1,
              'seq': 6,
              'prompt': '记录一下给我新会话提示词',
              'response': '已写进 docs/',
            },
            // 缺 seq：这一项没有意义（跳转不到消息），跳过。
            <String, Object?>{'turn': 2, 'prompt': 'x', 'response': 'y'},
            // turn 不是 int：跳过。
            <String, Object?>{
              'turn': '3',
              'seq': 9,
              'prompt': '',
              'response': '',
            },
            // 形状对但预览为空：**保留**（轮次存在，只是没预览）——
            // 空预览由 `promptLabel` / `responseLabel` 给占位。
            <String, Object?>{
              'turn': 4,
              'seq': 12,
              'prompt': '',
              'response': '',
            },
          ],
        }),
      );
      addTearDown(app.dispose);
      await app.start();
      // 投影**按 sid 存**（`refreshProjections(sid)`），而"当前会话那一包"
      // 只在 `sid == currentSid` 时才落地（子级目录的重读不能覆盖它），
      // 所以先打开会话 —— 生产里也是 `openSession` 调它。
      await app.openSession('s1');

      final outline = app.turnOutline;
      expect(outline.length, 2, reason: '另两项形状不对，跳过');
      expect(outline.first.turn, 1);
      expect(outline.first.prompt, '记录一下给我新会话提示词');
      expect(outline.first.response, '已写进 docs/');
      // 空预览给占位，不留一片白。
      expect(outline.last.promptLabel, TurnOutlineEntry.kEmptyPreview);
      expect(outline.last.responseLabel, TurnOutlineEntry.kEmptyPreview);
    });

    test('投影缺失 = 空表（不抛、不造）', () async {
      final app = AppModel(client: _OutlineClient(const {}));
      addTearDown(app.dispose);
      await app.start();
      expect(app.turnOutline, isEmpty);
    });
  });

  group('轨迹页', () {
    testWidgets('空表显示空态，不摆假行', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: TrajectoryTab(onTapTurn: null))),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('电脑侧跑完一轮后'), findsOneWidget);
    });

    testWidgets('有轮次就一行一轮，提问与回复都显示', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TrajectoryTab(
              turns: [TraceTurn(turn: 1, prompt: '帮我启动', response: '已经在跑了')],
              onTapTurn: null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('第 1 轮'), findsOneWidget);
      expect(find.text('提问：帮我启动'), findsOneWidget);
      expect(find.text('结果：已经在跑了'), findsOneWidget);
    });
  });

  group('buildTraceTurns：turnOutline × trajectory 投影 × 本轮条目', () {
    test('用时与时间轴按轮次号 join 到对应那一行', () {
      final turns = buildTraceTurns(
        outline: const [
          TurnOutlineEntry(turn: 1, seq: 6, prompt: 'a', response: 'b'),
          TurnOutlineEntry(turn: 2, seq: 20, prompt: 'c', response: 'd'),
        ],
        items: const [
          TurnProcessItem(
            itemId: 'p:1',
            seq: 8,
            updatedAt: 100,
            turn: 1,
            messageCount: 3,
            toolCallCount: 2,
          ),
        ],
        trajectory: _view([
          _turn(1, durationMs: 90000, steps: [_step(kind: 'tool', seq: 7)]),
        ]),
      );
      expect(turns.length, 2);
      expect(turns[0].durationMs, 90000);
      expect(turns[0].timeLabel, '1 分 30 秒');
      expect(turns[0].countsLabel, '3 条消息 · 2 次工具');
      expect(turns[0].trajectory?.steps.length, 1, reason: '时间轴的段来自投影');
      // 第 2 轮不在投影里（更早的轮被上限截掉 / 没给）：如实说"用时未知"。
      expect(turns[1].durationMs, isNull);
      expect(turns[1].timeLabel, '用时未知');
      expect(turns[1].trajectory, isNull);
    });

    test('进行中的轮说「进行中」，不是「用时未知」', () {
      final turns = buildTraceTurns(
        outline: const [
          TurnOutlineEntry(turn: 1, seq: 1, prompt: '', response: ''),
        ],
        items: const [],
        // `durationMs` / `outcome` 都是 null = 还在跑。
        trajectory: _view([
          _turn(
            1,
            durationMs: null,
            outcome: null,
            steps: [_step(kind: 'assistant', seq: 2, durationMs: null)],
          ),
        ]),
      );
      expect(turns[0].running, isTrue);
      expect(turns[0].timeLabel, '进行中');
      expect(turns[0].durationMs, isNull, reason: '进行中的轮没有时长 —— 手机不编一个');
    });

    test('结局以投影为准：`outcome == error` 就说失败（即使条目上没标）', () {
      final turns = buildTraceTurns(
        outline: const [
          TurnOutlineEntry(turn: 1, seq: 1, prompt: '', response: ''),
          TurnOutlineEntry(turn: 2, seq: 9, prompt: '', response: ''),
        ],
        items: const [],
        trajectory: _view([
          _turn(1, durationMs: 5000, outcome: 'error'),
          _turn(2, durationMs: 5000, outcome: 'aborted'),
        ]),
      );
      expect(turns[0].timeLabel, '失败');
      expect(turns[1].timeLabel, '已停止');
    });

    test('投影缺席（这台电脑没给）时退回条目上的结局，且没有时间轴', () {
      final turns = buildTraceTurns(
        outline: const [
          TurnOutlineEntry(turn: 1, seq: 1, prompt: '', response: ''),
        ],
        items: const [
          TurnProcessItem(
            itemId: 'p:1',
            seq: 2,
            updatedAt: 1,
            turn: 1,
            failed: true,
          ),
        ],
        trajectory: null,
      );
      expect(turns[0].timeLabel, '失败', reason: '条目上标了失败就照说');
      expect(turns[0].trajectory, isNull);
    });
  });

  group('trajectoryTruncationLabel：截断要明说', () {
    test('没截过 = null（不摆一行废话）', () {
      expect(trajectoryTruncationLabel(null), isNull);
      expect(
        trajectoryTruncationLabel(
          _view([_turn(1, durationMs: 1000)], truncated: false),
        ),
        isNull,
      );
    });

    test('截过就说丢了多少（数字只来自投影自报的字段）', () {
      final label = trajectoryTruncationLabel(
        _view(
          [_turn(1, durationMs: 1000)],
          truncated: true,
          droppedTurns: 3,
          droppedSteps: 12,
        ),
      );
      expect(label, isNotNull);
      expect(label, contains('3 轮'));
      expect(label, contains('12 步'));
      expect(label, contains('不全'));
    });
  });

  group('traceSummaryLabel', () {
    test('已知用时 + 进行中 + 未知分三句说', () {
      final turns = [
        const TraceTurn(
          turn: 1,
          prompt: '',
          response: '',
          trajectory: TrajectoryTurn(
            turn: 1,
            startSeq: 1,
            startTime: 0,
            endTime: 60000,
            durationMs: 60000,
            outcome: 'completed',
            stepsTruncated: false,
            steps: [],
          ),
        ),
        const TraceTurn(turn: 2, prompt: '', response: ''),
        TraceTurn(
          turn: 3,
          prompt: '',
          response: '',
          // `durationMs: null` = 还在跑（`_trajectoryTurn` 走真解析器）。
          trajectory: _trajectoryTurn(3, durationMs: null),
        ),
      ];
      final label = traceSummaryLabel(turns);
      expect(label, contains('共 3 轮'));
      expect(label, contains('已知用时 1 分 0 秒'));
      expect(label, contains('1 轮进行中'));
      expect(label, contains('1 轮用时未知'));
    });
  });
}

/// 造一条 wire 形状的段（键名与连接器的 `viewSchema` 逐字对应）。
Map<String, Object?> _step({
  required String kind,
  required int seq,
  int offsetMs = 0,
  int? durationMs = 1000,
}) => <String, Object?>{
  'kind': kind,
  'seq': seq,
  'startTime': 1_700_000_000_000 + offsetMs,
  'endTime': durationMs == null
      ? null
      : 1_700_000_000_000 + offsetMs + durationMs,
  'offsetMs': offsetMs,
  'durationMs': durationMs,
  'isError': false,
  'label': kind == 'tool' ? 'read' : '',
};

/// 造一条 wire 形状的轮（`durationMs` 不给 = 还在跑）。
Map<String, Object?> _turn(
  int turn, {
  int? durationMs = 1000,
  String? outcome = 'completed',
  List<Map<String, Object?>> steps = const [],
}) => <String, Object?>{
  'turn': turn,
  'startSeq': turn * 10,
  'startTime': 1_700_000_000_000,
  'endTime': durationMs == null ? null : 1_700_000_000_000 + durationMs,
  'durationMs': durationMs,
  'outcome': outcome,
  'stepsTruncated': false,
  'steps': steps,
};

/// 走**真解析器**把一条 wire 形状的轮变成 `TrajectoryTurn`。
TrajectoryTurn _trajectoryTurn(
  int turn, {
  int? durationMs = 1000,
  List<Map<String, Object?>> steps = const [],
}) => _view([_turn(turn, durationMs: durationMs, steps: steps)]).turns.single;

/// 走**真解析器**把 wire 形状变成 `TrajectoryView`（不从常量抄一遍）。
TrajectoryView _view(
  List<Map<String, Object?>> turns, {
  bool truncated = false,
  int droppedTurns = 0,
  int droppedSteps = 0,
}) {
  final view = parseTrajectory(<String, Object?>{
    'turns': turns,
    'truncated': truncated,
    'droppedTurns': droppedTurns,
    'droppedSteps': droppedSteps,
  });
  expect(view, isNotNull, reason: '测试自己造的 wire 形状必须能被解析器认');
  return view!;
}
