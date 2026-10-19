/// 上下文压缩标记（`compaction/start` + `summary` + `end`）的回归。
///
/// ## 这一组守什么
///
/// 2026-10-19 顺着 DSH Web 节点清单摸到的**最后一个**缺口：
/// `compaction/*` 三个事件完全没接。DSH Web 在压缩落定时显示一条检查点
/// （摘要 + 替换条目数 + 压掉的 token），手机上没有 —— 于是"之前的对话
/// 被总结成一段摘要替换掉了"这件事**完全不可见**，而它影响后续**所有**轮次。
///
/// ## 判据从哪来
///
/// **真日志**：`~/.dsh/sessions/--D-sudy-myproject-dsh-mobile--/
/// session-1f80f156-…/session.v4.jsonl.zstd` 里那条 604975 token 的压缩
/// （**本会话自己的检查点** —— 我正在读的这段上下文就是它产生的）。
/// DSH 的规则在 `conversation-nodes/command.ts:101-131` 的 `compactSummary`。
library;

import 'package:dsh_mobile/core/items.dart';
import 'package:dsh_mobile/data/projection.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/ui/chat_turns.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真日志样本（`compaction/start`，seq 4717）。
const _start = <String, Object?>{
  'compactionId': '324ce65d-a430-4342-af3f-70f432a76d50',
  'turn': 6,
};

/// 真日志样本（`compaction/summary`，seq 4718）。`summary` 是 text 块数组，
/// `shadowedSeqs` 有 142 个元素，`shadowedTokenCount` 是 604975。
const _summary = <String, Object?>{
  'compactionId': '324ce65d-a430-4342-af3f-70f432a76d50',
  'summary': <Object?>[
    <String, Object?>{
      'type': 'text',
      'text':
          '## Primary Request and Intent\n- Original task (verbatim scope): fix …',
    },
  ],
  'shadowedSeqs': <Object?>[8, 9, 10, 4619, 26],
  'shadowedTokenCount': 604975,
  'provider': 'deepseek',
  'model': 'step-5-preview',
  'maxTokens': 128000,
};

/// 真日志样本（`compaction/end`，seq 4720）。
const _end = <String, Object?>{
  'compactionId': '324ce65d-a430-4342-af3f-70f432a76d50',
  'turn': 6,
};

CompactionItem _project(Map<String, Object?> data, {ChatItem? previous}) {
  final result = projectEvent(
    type: 'compaction/summary',
    seq: 4718,
    data: data,
    previous: previous,
  );
  return result.items.single as CompactionItem;
}

void main() {
  group('三条事件共用同一个 itemId', () {
    test('compactionId 配对', () {
      final ids = [
        itemIdOf(
          const EventLike(type: 'compaction/start', seq: 4717, data: _start),
        ),
        itemIdOf(
          const EventLike(
            type: 'compaction/summary',
            seq: 4718,
            data: _summary,
          ),
        ),
        itemIdOf(
          const EventLike(type: 'compaction/end', seq: 4720, data: _end),
        ),
      ];
      expect(ids.toSet().length, 1, reason: '三条必须同一个 id');
      expect(ids.first, 'x:324ce65d-a430-4342-af3f-70f432a76d50');
    });

    test('缺 compactionId 抛错（不静默退化）', () {
      expect(
        () => itemIdOf(
          const EventLike(
            type: 'compaction/end',
            seq: 4720,
            data: <String, Object?>{'turn': 6},
          ),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('compaction/summary 投影', () {
    test('摘要 = text 块拼接，两个计数取到', () {
      final item = _project(_summary);
      expect(item.summary, contains('## Primary Request and Intent'));
      expect(item.shadowedItemCount, 5, reason: 'shadowedSeqs 的长度');
      expect(item.shadowedTokenCount, 604975);
      expect(item.stats, '替换 5 条 · 压掉 605K tok');
    });

    test('start / end 没有内容时跳过（不是失败）', () {
      for (final type in const ['compaction/start', 'compaction/end']) {
        final result = projectEvent(type: type, seq: 4717, data: _start);
        expect(result.items, isEmpty, reason: '$type 无内容可显示');
        expect(result.skipReason, isNotNull);
      }
    });

    test('start / end 在 summary 之后是更新（继承内容）', () {
      final summary = _project(_summary);
      final end =
          projectEvent(
                type: 'compaction/end',
                seq: 4720,
                data: _end,
                previous: summary,
              ).items.single
              as CompactionItem;
      expect(end.itemId, summary.itemId);
      expect(end.summary, summary.summary);
      expect(end.shadowedTokenCount, 604975);
    });

    test('shadowedSeqs 含非整数或负数时整项作 null（DSH 的严判据）', () {
      // 两类都试：字符串（`is! int`）与负数（`seq < 0`）。少一类，
      // 对应的校验分支就成了死代码 —— 变异验证时测试不会红。
      for (final bad in <Object?>['x', -1]) {
        final item = _project(<String, Object?>{
          ..._summary,
          'shadowedSeqs': <Object?>[8, 9, bad],
        });
        expect(
          item.shadowedItemCount,
          isNull,
          reason: 'shadowedSeqs 含 $bad 时整个计数作废',
        );
        expect(item.shadowedTokenCount, 604975, reason: '另一项不受影响');
        expect(item.stats, '压掉 605K tok', reason: '只列有的');
      }
    });

    test('shadowedTokenCount 是负数时作 null', () {
      final item = _project(<String, Object?>{
        ..._summary,
        'shadowedTokenCount': -1,
      });
      expect(item.shadowedTokenCount, isNull);
    });

    test('手动 /compact 不走这里（有 sourceCommandId）', () {
      final result = projectEvent(
        type: 'compaction/summary',
        seq: 4718,
        data: <String, Object?>{..._summary, 'sourceCommandId': 'cmd-1'},
      );
      expect(result.items, isEmpty);
      expect(result.skipReason, contains('命令卡'));
    });

    test('summary 里非 text 块跳过，不摊平', () {
      final item = _project(<String, Object?>{
        ..._summary,
        'summary': <Object?>[
          <String, Object?>{'type': 'image', 'url': 'http://x'},
          <String, Object?>{'type': 'text', 'text': '只有这段'},
        ],
      });
      expect(item.summary, '只有这段');
    });
  });

  group('真事件 → 投影 → 渲染（三段贯通）', () {
    testWidgets('压缩标记一行：标题 + 统计，摘要可展开', (tester) async {
      final item = _project(_summary);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: CompactionRow(summary: item.summary, stats: item.stats),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已压缩上下文'), findsOneWidget);
      expect(find.text('替换 5 条 · 压掉 605K tok'), findsOneWidget);
      // 摘要默认收起（它可能上万字符，展开会把对话流冲掉）。
      expect(find.textContaining('## Primary Request'), findsNothing);
      // 点开才看得见。
      await tester.tap(find.text('已压缩上下文'));
      await tester.pumpAndSettle();
      expect(find.textContaining('## Primary Request'), findsOneWidget);
    });
  });
}
