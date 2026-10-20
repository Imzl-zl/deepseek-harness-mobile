/// `turn-tail` 操作行（复制 + 用量 pill）的回归。
///
/// ## 这一组守什么
///
/// 用户 2026-10-20：「dsh web 我看每个消息完毕有复制用量啥的」。
/// DSH 的形态是**独立的 `turn-tail` 行**（`turn/end` 时以 seq+0.1 物化，
/// `conversation-nodes/turn-tail.ts:107-140`），按钮里我们只做
/// **复制 + 用量 pill**（点赞/分支要未接的写面，时钟与左侧用时重复）。
///
/// ## 形状来自真日志
///
/// `~/.dsh/sessions/**/session.v4.jsonl.zstd` 解出的样本（8634 条
/// `assistant/message` 都带它）：
///
/// ```json
/// {"inputTokens": 66352, "outputTokens": 110,
///  "totalTokens": 94408, "cacheReadTokens": 27946}
/// ```
///
/// 验算：`totalTokens − outputTokens = 94298`，
/// `inputTokens + cacheReadTokens = 66352 + 27946 = 94298` ✓
/// —— 所以 `inputTokens` 是**未缓存**输入，不是"全部输入"。
library;

import 'package:dsh_mobile/data/projection.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/ui/chat_turns.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真日志里那一条（见文件头）。
const _realUsage = <String, Object?>{
  'inputTokens': 66352,
  'outputTokens': 110,
  'totalTokens': 94408,
  'cacheReadTokens': 27946,
};

void main() {
  group('TurnTokenUsage.fromWire', () {
    test('真日志的形状解析得出，inputTokens 是未缓存输入', () {
      final usage = TurnTokenUsage.fromWire(_realUsage)!;
      expect(usage.totalTokens, 94408);
      expect(usage.outputTokens, 110);
      expect(usage.inputTokens, 66352);
      expect(usage.cacheReadTokens, 27946);
      // 未缓存 + 缓存读取 = 总量 − 输出（这一条钉住"inputTokens 的语义"）。
      expect(
        usage.inputTokens + usage.cacheReadTokens!,
        usage.totalTokens - usage.outputTokens,
      );
    });

    test('缺任何一个必填字段就整个不要（不把缺的当 0）', () {
      for (final missing in ['inputTokens', 'outputTokens', 'totalTokens']) {
        final wire = Map<String, Object?>.from(_realUsage)..remove(missing);
        expect(
          TurnTokenUsage.fromWire(wire),
          isNull,
          reason: '缺 $missing 时不能说"用了 0"',
        );
      }
      expect(TurnTokenUsage.fromWire(null), isNull);
      expect(TurnTokenUsage.fromWire('nope'), isNull);
    });

    test('负数当认不出', () {
      final wire = Map<String, Object?>.from(_realUsage)..['totalTokens'] = -1;
      expect(TurnTokenUsage.fromWire(wire), isNull);
    });
  });

  group('TurnTokenUsage 相加', () {
    const first = TurnTokenUsage(
      inputTokens: 100,
      outputTokens: 10,
      totalTokens: 200,
      cacheReadTokens: 90,
    );
    const second = TurnTokenUsage(
      inputTokens: 200,
      outputTokens: 20,
      totalTokens: 400,
      cacheReadTokens: 190,
    );

    test('三个必填相加', () {
      final sum = first + second;
      expect(sum.inputTokens, 300);
      expect(sum.outputTokens, 30);
      expect(sum.totalTokens, 600);
      expect(sum.cacheReadTokens, 280);
    });

    test('缓存档一边缺就整体不知道（不摆偏小的数）', () {
      // 与 DSH 的 `cacheRead.every(isCount) ? safeSum(...) : undefined`
      // 同一条（`turn-usage.ts:136-138`）：一边缺就整体不知道 ——
      // 摆一个偏小的数会让人以为缓存命中很差。
      const noCache = TurnTokenUsage(
        inputTokens: 1,
        outputTokens: 1,
        totalTokens: 2,
      );
      expect((first + noCache).cacheReadTokens, isNull);
      expect((noCache + first).cacheReadTokens, isNull);
    });
  });

  group('投影把 usage 带上', () {
    test('assistant/message 的 data.usage 进 MessageItem', () {
      // 真日志里 `data` 的键是 `turn, step, message, usage, stream`
      // —— usage 在 **data 顶层**，不在 data.message 里。
      final item = projectEvent(
        type: 'assistant/message',
        seq: 5,
        time: 1,
        data: <String, Object?>{
          'turn': 1,
          'step': 1,
          'message': <String, Object?>{
            'id': 'm1',
            'role': 'assistant',
            'content': [
              <String, Object?>{'type': 'text', 'text': '答案'},
            ],
          },
          'usage': _realUsage,
        },
      ).items.whereType<MessageItem>().single;

      expect(item.text, '答案');
      expect(item.usage, isNotNull);
      expect(item.usage!.totalTokens, 94408);
    });

    test('没有 usage 的助手消息：usage 是 null，不是 0', () {
      final item = projectEvent(
        type: 'assistant/message',
        seq: 6,
        time: 1,
        data: <String, Object?>{
          'message': <String, Object?>{
            'id': 'm2',
            'role': 'assistant',
            'content': [
              <String, Object?>{'type': 'text', 'text': '没用量'},
            ],
          },
        },
      ).items.whereType<MessageItem>().single;
      expect(item.usage, isNull);
    });
  });

  group('操作行', () {
    const usage = TurnTokenUsage(
      inputTokens: 66352,
      outputTokens: 110,
      totalTokens: 94408,
      cacheReadTokens: 27946,
    );

    Widget host({TurnTokenUsage? u, String copyText = '可复制的正文'}) => MaterialApp(
      home: Scaffold(
        body: TurnProcessRow(
          title: '第 3 轮',
          stats: '2 分 36 秒 · 12 条消息',
          usage: u,
          copyText: copyText,
        ),
      ),
    );

    testWidgets('用量 pill 的文案与 DSH 同构：`用量 94.4K tok`', (tester) async {
      await tester.pumpWidget(host(u: usage));
      await tester.pumpAndSettle();
      // 同一个格式化函数（`formatTokenCount`）：94408 → `94.4K`。
      expect(find.text('用量 94.4K tok'), findsOneWidget);
      // 标题与统计照旧都在。
      expect(find.text('第 3 轮'), findsOneWidget);
      expect(find.text('2 分 36 秒 · 12 条消息'), findsOneWidget);
    });

    testWidgets('没有用量就不摆 pill（不显示 `0 tok`）', (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(find.textContaining('用量'), findsNothing);
    });

    testWidgets('点用量 pill 开明细：精确值 + 缓存命中 + 四个桶', (tester) async {
      await tester.pumpWidget(host(u: usage));
      await tester.pumpAndSettle();

      await tester.tap(find.text('用量 94.4K tok'));
      await tester.pumpAndSettle();

      expect(find.text('本轮用量'), findsOneWidget);
      // 精确值三位分组。
      expect(find.text('94,408 tok'), findsOneWidget);
      expect(find.text('66,352 tok'), findsOneWidget);
      expect(find.text('27,946 tok'), findsOneWidget);
      // 缓存命中：27946 / (66352+27946) = 29.6% → 取整 30。
      expect(find.text('30%'), findsOneWidget);
      // 输出那一行也在。
      expect(find.text('110 tok'), findsOneWidget);
    });

    testWidgets('没有正文就不摆复制钮', (tester) async {
      await tester.pumpWidget(host(copyText: ''));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('turn-copy')), findsNothing);
    });

    testWidgets('点复制：真的写进剪贴板，并短暂变"已复制"', (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('turn-copy')));
      await tester.pumpAndSettle();

      final setData = calls.firstWhere(
        (c) => c.method == 'Clipboard.setData',
        orElse: () => throw StateError('没有调用 Clipboard.setData'),
      );
      expect(
        (setData.arguments as Map)['text'],
        '可复制的正文',
        reason: '复制的必须是该轮助手回复的正文',
      );
      // 1 秒内显示"已复制"（DSH 同处是 1 秒后回退，`MessageIconActions.tsx:62-76`）。
      expect(find.text('已复制'), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('已复制'), findsNothing, reason: '过了提示窗口要回退');
      expect(find.text('复制'), findsOneWidget);
    });
  });
}
