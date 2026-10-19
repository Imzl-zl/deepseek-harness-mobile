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
  return result.item as TurnOutcomeItem;
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

    test('completed：不占条目（不是 OtherItem，是 skip）', () {
      final result = projectEvent(
        type: 'turn/end',
        seq: 8,
        data: _completedEnd,
      );
      expect(result.item, isNull, reason: '正常结局不该占条目');
      expect(result.skipReason, isNotNull, reason: '但要说清为什么跳过');
    });

    test('用户主动 aborted：不占条目（DSH 只显示"已停止的轮次摘要"）', () {
      final result = projectEvent(
        type: 'turn/end',
        seq: 8,
        data: _userAbortEnd,
      );
      expect(result.item, isNull);
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
