/// 子智能体行的**运行态视图**（`model/subagent.dart`）的纯 Dart 回归。
///
/// 这组守的是"数字与状态不许编"：
/// - 活动态是两个维度的合成，**不能**由 `mode` 推（2026-10-21 的真缺陷）；
/// - 耗时是 `subagentTiming` 累加的**活跃轮次**时间，不是"现在减创建时间"；
/// - token 是四个互不重叠桶之和；没给就是没有，不补零。
///
/// 期望值全部来自 DSH 源码里的模板与判据（逐条标了出处），
/// **不是**把实现的输出抄一遍。
library;

import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/model/session_stats.dart';
import 'package:dsh_mobile/model/subagent.dart';
import 'package:flutter_test/flutter_test.dart';

const _row = SubagentRow(
  id: 'child-1',
  createdAt: 5000,
  mode: 'continuable',
  label: '调研实现',
);

const _usage = TokenUsage(
  uncachedInputTokens: 1000,
  outputTokens: 200,
  cacheReadTokens: 40000,
  cacheWriteTokens: 500,
);

void main() {
  group('SubagentTiming.durationMs（Web 的 activityDuration）', () {
    // 判据逐字照 `ui-subagent/.../SubagentHeaderLineage.tsx:86-90`：
    //   active === undefined        → settledMs
    //   running                     → settledMs + (now - since)
    //   已停                        → settledMs + (active.through - since)
    const timing = SubagentTiming(
      settledMs: 2000,
      activeSince: 10000,
      activeThrough: 13000,
    );

    test('没有 active：就是 settledMs，且不随 now 变', () {
      const settled = SubagentTiming(settledMs: 7000);
      expect(settled.durationMs(running: true, now: 999999), 7000);
      expect(settled.durationMs(running: false, now: 999999), 7000);
    });

    test('正在跑：按 now 长', () {
      expect(timing.durationMs(running: true, now: 15000), 2000 + 5000);
      expect(timing.durationMs(running: true, now: 16000), 2000 + 6000);
    });

    test('已经停了：用同一个切面的 active.through 封住 —— 再晚的 now 也不长', () {
      // DSH README 原话：an interrupted open turn is bounded by its same-cut
      // `active.through`, never by newer session metadata（`README.md:66`）。
      expect(timing.durationMs(running: false, now: 13000), 2000 + 3000);
      expect(timing.durationMs(running: false, now: 600000), 2000 + 3000);
    });

    test('through 早于 since：夹到 0（不出现负时长）', () {
      const odd = SubagentTiming(
        settledMs: 100,
        activeSince: 9000,
        activeThrough: 8000,
      );
      expect(odd.durationMs(running: false, now: 9999), 100);
    });
  });

  group('parseSubagentTiming（形状逐字照 projection.ts:35-43）', () {
    test('完整形状：三个字段都读到', () {
      final timing = parseSubagentTiming({
        'settledMs': 1500,
        'active': {'since': 10, 'through': 20},
        'lastTurnCompleted': true,
      })!;
      expect(timing.settledMs, 1500);
      expect(timing.activeSince, 10);
      expect(timing.activeThrough, 20);
      expect(timing.lastTurnCompleted, isTrue);
    });

    test('lastTurnCompleted 缺省是 false（投影里它是可选的）', () {
      expect(parseSubagentTiming({'settledMs': 0})!.lastTurnCompleted, isFalse);
    });

    test('缺 settledMs：认不出（null）', () {
      expect(
        parseSubagentTiming({
          'active': {'since': 1, 'through': 2},
        }),
        isNull,
      );
      expect(parseSubagentTiming({}), isNull);
      expect(parseSubagentTiming('x'), isNull);
    });

    test('active 存在但时间戳不齐：整条认不出（不降级成 settledMs）', () {
      expect(
        parseSubagentTiming({
          'settledMs': 10,
          'active': {'since': 1},
        }),
        isNull,
      );
      expect(parseSubagentTiming({'settledMs': 10, 'active': 'x'}), isNull);
    });
  });

  group('SubagentNode：活动态是 running × lastTurnCompleted', () {
    // 判据照 `SubagentHeaderLineage.tsx:250-256`：
    //   completed = !external && activity === inactive && lastTurnCompleted
    test('正在跑 ⇒ running（不管 lastTurnCompleted）', () {
      const node = SubagentNode(
        row: _row,
        running: true,
        timing: SubagentTiming(settledMs: 0, lastTurnCompleted: true),
      );
      expect(node.activity, SubagentActivity.running);
      expect(node.activityText, '正在运行');
    });

    test('停了且最近一轮正常完成 ⇒ completed', () {
      const node = SubagentNode(
        row: _row,
        timing: SubagentTiming(settledMs: 1, lastTurnCompleted: true),
      );
      expect(node.activity, SubagentActivity.completed);
      expect(node.activityText, '已完成');
    });

    test('停了但没有"正常完成"的记号 ⇒ inactive（不是 completed）', () {
      const node = SubagentNode(row: _row);
      expect(node.activity, SubagentActivity.inactive);
      expect(node.activityText, '当前未运行');
    });

    test('**可续聊的子会话跑完就是这里** —— 不能再说"正在运行"', () {
      // 这正是 2026-10-21 的真缺陷：`mode == continuable` 被当成 running。
      const node = SubagentNode(
        row: _row,
        running: false,
        timing: SubagentTiming(settledMs: 9000, lastTurnCompleted: true),
      );
      expect(node.row.mode, 'continuable');
      expect(node.activity, SubagentActivity.completed);
    });

    test('外部任务没有活动态词（Web 对它不给 activity 文案）', () {
      const node = SubagentNode(
        row: SubagentRow(id: 'ext', createdAt: 1, mode: 'external'),
        running: false,
        timing: SubagentTiming(settledMs: 1, lastTurnCompleted: true),
      );
      expect(
        node.activity,
        SubagentActivity.inactive,
        reason: 'external 不算 completed（Web 的 completed 有 `!external` 前置）',
      );
      expect(node.activityText, isNull);
    });
  });

  group('详情行：title · mode · activity · 时长', () {
    // 时长在**详情行**里（触屏：右列只放 token 一个数），没有计时就不出这一段。
    test('四段都有', () {
      const node = SubagentNode(
        row: _row,
        title: '调研实现',
        running: true,
        timing: SubagentTiming(
          settledMs: 0,
          activeSince: 0,
          activeThrough: 65000,
        ),
      );
      // 在跑 ⇒ 时长按 `now` 算（`activityDuration`，`:86-90`）。
      expect(node.detailLine(65000), '调研实现 · 可继续 · 正在运行 · 1分05秒');
    });

    test('没有标题：不留一个空段', () {
      const node = SubagentNode(row: _row);
      expect(node.detailLine(0), '可继续 · 当前未运行');
    });

    test('没有计时：不出时长那一段', () {
      const node = SubagentNode(row: _row, title: '调研实现');
      expect(node.detailLine(999999), '调研实现 · 可继续 · 当前未运行');
    });

    test('外部任务：只有 标题 · 外部任务', () {
      const node = SubagentNode(
        row: SubagentRow(id: 'ext', createdAt: 1, mode: 'external'),
        title: '外部跑批',
      );
      expect(node.detailLine(0), '外部跑批 · 外部任务');
    });

    test('mode 词逐字照 DSH 的 zh 词典（locales.ts:26-29）', () {
      expect(
        const SubagentRow(id: 'a', createdAt: 1, mode: 'one-shot').modeText,
        '一次性',
      );
      expect(
        const SubagentRow(id: 'a', createdAt: 1, mode: 'continuable').modeText,
        '可继续',
      );
      expect(
        const SubagentRow(id: 'a', createdAt: 1, mode: 'external').modeText,
        '外部任务',
      );
      expect(
        const SubagentRow(id: 'a', createdAt: 1, mode: 'unknown').modeText,
        '模式未知',
      );
    });
  });

  group('token 指标', () {
    test('四个桶之和（Web tokenTotal :66-74）', () {
      const node = SubagentNode(row: _row, tokens: _usage);
      expect(node.tokenTotal, 41700);
      // `tokens.total` = `{value} tok`，数值走 formatTokenCount（>100 取整）。
      expect(node.tokenText, '41.7K tok');
    });

    test('没给：没有指标（不是 0 tok）', () {
      const node = SubagentNode(row: _row);
      expect(node.tokenTotal, isNull);
      expect(node.tokenText, isNull);
    });

    test('四桶全零：当作"还没用"，不摆 0 tok', () {
      const node = SubagentNode(
        row: _row,
        tokens: TokenUsage(
          uncachedInputTokens: 0,
          outputTokens: 0,
          cacheReadTokens: 0,
          cacheWriteTokens: 0,
        ),
      );
      expect(node.tokenTotal, isNull);
      expect(node.tokenText, isNull);
    });

    test('不到 1K 原样（formatTokenCount 与 Web 的 formatTokens 同一条）', () {
      const node = SubagentNode(
        row: _row,
        tokens: TokenUsage(
          uncachedInputTokens: 300,
          outputTokens: 200,
          cacheReadTokens: 0,
          cacheWriteTokens: 0,
        ),
      );
      expect(node.tokenText, '500 tok');
    });
  });

  group('耗时文字（Web formatDuration + zh 模板 locales.ts:8-17）', () {
    test('模板逐档', () {
      expect(formatSubagentDuration(0), '0秒');
      expect(formatSubagentDuration(59000), '59秒');
      // `duration.minutes` = '{minutes}分{seconds}秒'，秒补两位。
      expect(formatSubagentDuration(65000), '1分05秒');
      // `duration.hours` = '{hours}小时{minutes}分{seconds}秒'。
      expect(formatSubagentDuration(3723000), '1小时02分03秒');
      // `duration.daysHours` = '{days}天{hours}小时'。
      expect(formatSubagentDuration(90000000), '1天1小时');
      // `duration.days` = '{days}天'（整点时不带小时）。
      expect(formatSubagentDuration(86400000), '1天');
      // `duration.months` = '约{months}个月'。
      expect(formatSubagentDuration(2592000000), '约1个月');
      // `duration.monthsDays` = '约{months}个月{days}天'。
      expect(formatSubagentDuration(2678400000), '约1个月1天');
      // `duration.years` = '约{years}年'。
      expect(formatSubagentDuration(31536000000), '约1年');
    });

    test('负值夹到 0（不显示负时长）', () {
      expect(formatSubagentDuration(-5000), '0秒');
    });

    test('行上的耗时：没给计时就没有这一格', () {
      const none = SubagentNode(row: _row);
      expect(none.durationText(999999), isNull);
    });

    test('行上的耗时：已停用 active.through 封住', () {
      const node = SubagentNode(
        row: _row,
        running: false,
        timing: SubagentTiming(
          settledMs: 0,
          activeSince: 0,
          activeThrough: 65000,
        ),
      );
      expect(node.durationText(999999999), '1分05秒');
    });
  });
}
