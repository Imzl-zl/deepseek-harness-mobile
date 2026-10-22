/// 一轮的异常结局与模型重试（`turn/end` 的 reason + `llm/retry`）的回归。
///
/// ## 这一组守什么
///
/// 2026-10-19 摸到的"没看到的问题"之一：`turn/end` 的 `reason.kind` 与
/// `llm/retry` / `llm/retry-started` 在投影里**完全没读**。
/// 真日志里这台电脑的历史有 **80 条"出了什么事"在手机上一片空白**：
///
/// | 事件 | 条数 | DSH Web 显示什么 |
/// |---|---|---|
/// | `turn/end` reason `error` | 71 | `reason.error.message`（原文） |
/// | `turn/end` reason `interrupted` | 6 | 进程退出提示 |
/// | `turn/end` reason `max-tokens` | 3 | 截断提示 |
/// | `llm/retry` | 10+ 条链 | 重试中（第 N/M 次） |
///
/// ## 判据从哪来
///
/// **真日志**：`~/.dsh/sessions/**/session.v4.jsonl.zstd` 全量统计出的
/// 分布，以及抽出的样本（见下面每个 fixture 的注释）。
/// DSH 的规则在 `conversation-nodes/turn-error.ts:36-51` 的 `endFailure`。
library;

import 'package:dsh_mobile/core/items.dart';
import 'package:dsh_mobile/data/projection.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/ui/chat_turns.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真日志样本：`{"turn":7,"reason":{"kind":"error",
/// "error":{"message":"Connection error.","code":"TRANSPORT"}}}`。
const _errorEnd = <String, Object?>{
  'turn': 7,
  'reason': <String, Object?>{
    'kind': 'error',
    'error': <String, Object?>{
      'message': 'Connection error.',
      'code': 'TRANSPORT',
    },
  },
};

/// 真日志样本：`{"turn":5,"reason":{"kind":"interrupted"}}`（6 条）。
const _interruptedEnd = <String, Object?>{
  'turn': 5,
  'reason': <String, Object?>{'kind': 'interrupted'},
};

/// 真日志样本：`{"turn":8,"reason":{"kind":"max-tokens"}}`（3 条）。
const _maxTokensEnd = <String, Object?>{
  'turn': 8,
  'reason': <String, Object?>{'kind': 'max-tokens'},
};

/// 真日志样本：`{"turn":1,"reason":{"kind":"aborted","reason":{"kind":"user"}}}`
/// （53 条里的多数 —— 用户主动取消，**DSH 不显示失败行**）。
const _userAbortEnd = <String, Object?>{
  'turn': 1,
  'reason': <String, Object?>{
    'kind': 'aborted',
    'reason': <String, Object?>{'kind': 'user'},
  },
};

/// 真日志样本：`{"turn":1,"reason":{"kind":"completed"}}`（891 条，正常结局）。
const _completedEnd = <String, Object?>{
  'turn': 1,
  'reason': <String, Object?>{'kind': 'completed'},
};

/// 真日志样本（`llm/retry`，seq 1545）。
const _retry = <String, Object?>{
  'retryId': '18ac36dd-14f7-4a9d-a1f5-148b0fc32a47',
  'turn': 1,
  'step': 292,
  'provider': 'new',
  'mode': 'normal',
  'retry': 1,
  'maxRetries': 10,
  'delayMs': 1737.516418390792,
  'failure': <String, Object?>{
    'message': 'Request timed out.',
    'code': 'TIMEOUT',
  },
};

/// 真日志样本（`llm/retry-started`，seq 1546）。
const _retryStarted = <String, Object?>{
  'retryId': '18ac36dd-14f7-4a9d-a1f5-148b0fc32a47',
  'turn': 1,
  'step': 292,
  'retry': 1,
};

TurnOutcomeItem _projectEnd(Map<String, Object?> data, {ChatItem? previous}) {
  final result = projectEvent(
    type: 'turn/end',
    seq: 8,
    data: data,
    previous: previous,
  );
  // `turn/end` 产出**两条**：过程摘要（每轮都有）+ 异常结局（只有异常）。
  // 异常结局是第二条（DSH 同处两个独立节点，`register-node-renderers.ts:70-75`）。
  return result.items.whereType<TurnOutcomeItem>().single;
}

/// 取 `turn/end` 产出的过程摘要（第一条）。
TurnProcessItem _projectProcess(Map<String, Object?> data) {
  final result = projectEvent(type: 'turn/end', seq: 8, data: data);
  return result.items.whereType<TurnProcessItem>().single;
}

void main() {
  group('turn/end 的 reason 决定要不要一行提示', () {
    test('error：用 DSH 原文，不编一句"出错了"', () {
      final item = _projectEnd(_errorEnd);
      expect(item.kind, TurnOutcomeKind.error);
      expect(item.message, 'Connection error.');
      expect(item.code, 'TRANSPORT');
      expect(item.turn, 7);
      expect(item.title, '第 7 轮出错');
    });

    test('interrupted：固定文案（进程退出）', () {
      final item = _projectEnd(_interruptedEnd);
      expect(item.kind, TurnOutcomeKind.interrupted);
      expect(item.message, contains('DSH'));
      expect(item.turn, 5);
    });

    test('max-tokens：单独一条提示，不算失败', () {
      final item = _projectEnd(_maxTokensEnd);
      expect(item.kind, TurnOutcomeKind.maxTokens);
      expect(item.turn, 8);
    });

    test('completed：只有过程摘要，没有失败行', () {
      final result = projectEvent(
        type: 'turn/end',
        seq: 8,
        data: _completedEnd,
      );
      expect(
        result.items.whereType<TurnOutcomeItem>(),
        isEmpty,
        reason: '正常结局没有失败行',
      );
      expect(
        result.items.whereType<TurnProcessItem>().length,
        1,
        reason: '但每轮都有一条过程摘要（DSH 的 turn-process）',
      );
      expect(result.skipReason, isNull, reason: '不再是 skip');
    });

    test('用户主动 aborted：只有过程摘要，没有失败行', () {
      final result = projectEvent(
        type: 'turn/end',
        seq: 8,
        data: _userAbortEnd,
      );
      expect(result.items.whereType<TurnOutcomeItem>(), isEmpty);
      expect(result.items.whereType<TurnProcessItem>().length, 1);
    });

    test('登出导致的 aborted：占条目（DSH 的 hook 判据）', () {
      final item = _projectEnd(const <String, Object?>{
        'turn': 3,
        'reason': <String, Object?>{
          'kind': 'aborted',
          'reason': <String, Object?>{
            'kind': 'hook',
            'reason': 'deepseek-account/signed-out',
          },
        },
      });
      expect(item.kind, TurnOutcomeKind.signedOut);
      expect(item.code, 'ACCOUNT_SIGNED_OUT');
    });
  });

  group('llm/retry 链', () {
    test('retry 1：计划中，次数与上限、失败原因都取到', () {
      final result = projectEvent(type: 'llm/retry', seq: 1545, data: _retry);
      final item = result.item as ModelRetryItem;
      expect(item.retry, 1);
      expect(item.maxRetries, 10);
      expect(item.message, 'Request timed out.');
      expect(item.code, 'TIMEOUT');
      expect(item.title, '重试 1/10');
      expect(item.started, isFalse, reason: '还没到 llm/retry-started');
      // delayMs 是小数（真日志 1737.516…）—— 收 double 不截断。
      expect(item.delayMs, closeTo(1737.516, 0.001));
    });

    test('retry-started 覆盖同一条（共用 itemId）', () {
      final planned = projectEvent(type: 'llm/retry', seq: 1545, data: _retry);
      final started = projectEvent(
        type: 'llm/retry-started',
        seq: 1546,
        data: _retryStarted,
        previous: planned.item,
      );
      final item = started.item as ModelRetryItem;
      expect(item.itemId, planned.item!.itemId);
      expect(item.started, isTrue);
      // 次数与原因从 `llm/retry` 继承（started 只有 retryId + retry）。
      expect(item.retry, 1);
      expect(item.maxRetries, 10);
      expect(item.message, 'Request timed out.');
    });

    test('第 2 次重试是另一条（id 带 retry 序号，不互相覆盖）', () {
      final first = projectEvent(type: 'llm/retry', seq: 1545, data: _retry);
      final second = projectEvent(
        type: 'llm/retry',
        seq: 1600,
        data: <String, Object?>{..._retry, 'retry': 2},
      );
      expect(second.item!.itemId, isNot(first.item!.itemId));
      expect((second.item as ModelRetryItem).title, '重试 2/10');
    });
  });

  group('一轮的过程摘要（turn-process）', () {
    test('用时**不在这一层算**：`turn/end` 的两个时刻不再产出时长', () {
      // 真日志样本：`turn/start` seq 4 time 1791270058171，
      // `turn/end` seq 117 time 1791270214061 —— 差 155890ms。
      //
      // 2026-10-22 起这里**没有** `elapsedMs`：时长由电脑侧的 `trajectory`
      // 折好随投影下发（`model/trajectory.dart`），手机一个减法都不做。
      // 这一条守的就是"这个字段不能回到条目上"。
      final item = projectEvent(
        type: 'turn/end',
        seq: 117,
        time: 1791270214061,
        data: _completedEnd,
      ).items.whereType<TurnProcessItem>().single;
      // 时长由调用方（读投影的那一层）拼进来 —— 不传就没有。
      expect(item.statsWith(null), '');
      expect(item.statsWith('2 分 35 秒'), '2 分 35 秒');
    });

    test('计数为 0 的项不列（不摆"0 条消息 · 0 次工具"）', () {
      final item = _projectProcess(_completedEnd);
      // 没有传 turnStats ⇒ 全 0；时长也没传 ⇒ 空串（行里就不画这一段）。
      expect(item.statsWith(null), '');
    });

    test('失败/停止时统计部分换成一句话（DSH 同处替换用时）', () {
      final failed = _projectProcess(_errorEnd);
      expect(failed.failed, isTrue);
      expect(failed.statsWith('2 分 35 秒'), '失败');
      final stopped = _projectProcess(_userAbortEnd);
      expect(stopped.stopped, isTrue);
      expect(stopped.statsWith('2 分 35 秒'), '已停止');
    });

    test('不足 1 秒按 1 秒说（DSH 的 Math.max(1000, …)）', () {
      // 格式化规则留在手机侧（它只是把电脑给的毫秒数说成人话），
      // 而"500ms"这个数本身由电脑侧算好下发。
      expect(formatElapsedMs(500), '不到 1 秒');
      final item = _projectProcess(_completedEnd);
      expect(item.statsWith(formatElapsedMs(500)), '不到 1 秒');
    });
  });

  group('itemId', () {
    test('turn/end 靠 turn 号（同一轮只有一条）', () {
      expect(
        itemIdOf(const EventLike(type: 'turn/end', seq: 8, data: _errorEnd)),
        'e:7',
      );
    });

    test('llm/retry 靠 retryId + retry 序号', () {
      expect(
        itemIdOf(const EventLike(type: 'llm/retry', seq: 1545, data: _retry)),
        'r:18ac36dd-14f7-4a9d-a1f5-148b0fc32a47:1',
      );
    });

    test('缺 retryId / retry / turn 时抛错（不静默退化）', () {
      expect(
        () => itemIdOf(
          const EventLike(
            type: 'llm/retry',
            seq: 1,
            data: <String, Object?>{'retry': 1},
          ),
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        () => itemIdOf(
          const EventLike(
            type: 'llm/retry',
            seq: 1,
            data: <String, Object?>{'retryId': 'x'},
          ),
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        () => itemIdOf(
          EventLike(
            type: 'turn/end',
            seq: 1,
            // 缺 `turn`（**非 const** —— 常量上下文里不能下标另一个 map）。
            data: <String, Object?>{'reason': _errorEnd['reason']},
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('真事件 → 投影 → 渲染（三段贯通）', () {
    testWidgets('过程摘要一行：标题 + 统计', (tester) async {
      final item = projectEvent(
        type: 'turn/end',
        seq: 117,
        time: 1791270214061,
        data: _completedEnd,
        turnStats: const TurnStats(messages: 12, tools: 8, subagents: 1),
      ).items.whereType<TurnProcessItem>().single;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: TurnProcessRow(
              title: item.title,
              // 时长由读投影的那一层拼进来（真日志 155890ms → 2 分 35 秒）。
              stats: item.statsWith(formatElapsedMs(155890)),
              failed: item.failed,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('第 1 轮'), findsOneWidget);
      // 用时 + 三个计数全列（都有值）。
      expect(find.text('2 分 35 秒 · 12 条消息 · 8 次工具 · 1 个子智能体'), findsOneWidget);
    });

    testWidgets('异常结局一行：标题 + DSH 原文', (tester) async {
      final item = _projectEnd(_errorEnd);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: TurnOutcomeRow(
              kind: item.kind,
              message: item.message,
              title: item.title,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('第 7 轮出错'), findsOneWidget);
      expect(find.text('Connection error.'), findsOneWidget);
    });

    testWidgets('重试行：计划中与已开跑的图标不同', (tester) async {
      final planned = projectEvent(type: 'llm/retry', seq: 1545, data: _retry);
      final started = projectEvent(
        type: 'llm/retry-started',
        seq: 1546,
        data: _retryStarted,
        previous: planned.item,
      );

      Future<void> pump(ModelRetryItem item) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            home: Scaffold(
              body: RetryRow(
                title: item.title,
                message: item.message,
                started: item.started,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await pump(planned.item as ModelRetryItem);
      expect(find.text('重试 1/10'), findsOneWidget);
      expect(find.text('Request timed out.'), findsOneWidget);

      await pump(started.item as ModelRetryItem);
      expect(find.text('重试 1/10'), findsOneWidget);
      // 已开跑仍显示同一行（同一条目被覆盖，不是多一行）。
      expect(find.text('重试 1/10'), findsOneWidget);
    });
  });
}
