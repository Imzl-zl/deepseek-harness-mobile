/// 统计格式化的回归（`lib/model/session_stats.dart`）。
///
/// ## 向量从哪来
///
/// **不是自己想的数** —— 逐条照抄 DSH Web 自己的测试
/// （`packages/client/ui-chat/tests/chat-stats.client.spec.tsx`）：
/// token 紧凑格式在 `:128-133`，时长在 `:135-138`，
/// 缓存命中（含"部分命中绝不四舍五入成 100"那一整张表）在 `:215-236`。
/// 同一批输入在两个端必须给出同一个字符串，否则"同一个会话两个百分比你选哪个"。
library;

import 'package:dsh_mobile/model/session_stats.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Web `chat-stats.client.spec.tsx:128-133` 的 formatTokens 向量。
  group('formatTokenCount：与 Web 的 formatTokens 同一批向量', () {
    test('紧凑格式', () {
      expect(formatTokenCount(517), '517');
      expect(formatTokenCount(12_240), '12.2K');
      expect(formatTokenCount(517_000), '517K');
      expect(formatTokenCount(1_230_000), '1.2M');
    });
  });

  // Web `chat-stats.client.spec.tsx:135-138` 的 formatDuration 向量
  // （中文模板：`{seconds}秒` / `{minutes}分{seconds}秒`）。
  group('formatCompactDuration：与 Web 的 formatDuration 同一批向量', () {
    test('一分钟内一位小数，之上分秒', () {
      expect(formatCompactDuration(45_230), '45.2秒');
      expect(formatCompactDuration(162_000), '2分42秒');
    });
  });

  // Web `chat-stats.client.spec.tsx:215-236` 的 formatCacheHitPercent 向量表。
  // 每个用例是 (cacheReadTokens, uncachedInputTokens)，分母 = 两者之和
  // （cacheWriteTokens 为 0；Web 的 tokenUsage() 助手正是这个形状）。
  group('formatCacheHitPercent：与 Web 同一批向量（部分命中不变成 100）', () {
    (int, int, String) vector(int read, int uncached, String expected) =>
        (read, uncached, expected);

    final vectors = <(int, int, String)>[
      vector(986, 14, '99'),
      vector(991, 9, '99'),
      vector(9_949, 51, '99'),
      vector(995, 5, '99.5'),
      vector(9_994, 6, '99.9'),
      vector(9_995, 5, '99.95'),
      vector(19_991, 9, '99.96'),
      vector(19_997, 3, '99.99'),
      vector(19_999, 1, '99.995'),
      vector(39_999, 1, '99.998'),
      // 真机上就是它：差一个 token 也是 99.9x，绝不显示成 100。
      vector(9_007_199_254_740_991, 1, '99.99999999999999'),
      vector(10_000, 0, '100'),
    ];

    for (final (read, uncached, expected) in vectors) {
      test('read=$read uncached=$uncached → $expected', () {
        expect(formatCacheHitPercent(read, read + uncached), expected);
      });
    }

    test('没有 prompt 输入：null', () {
      expect(formatCacheHitPercent(0, 0), isNull);
    });
  });

  // Web `message-chrome.ts:71-74` 的 formatTokensPerSecond。
  group('formatTokensPerSecond：≥10 取整，<10 一位小数', () {
    test('两档', () {
      expect(formatTokensPerSecond(75), '75');
      expect(formatTokensPerSecond(4.24), '4.2');
      expect(formatTokensPerSecond(0), '0');
    });
  });

  // Web `token-format.ts:23-30` 的 formatExactTokens（千分位）。
  group('formatExactTokens：千分位分组', () {
    test('分组', () {
      expect(formatExactTokens(5), '5');
      expect(formatExactTokens(12_480), '12,480');
      expect(formatExactTokens(302_804), '302,804');
    });
  });

  // 用量 pill 的合计与命中文字（Web `StatsPills.tsx:288-302`）。
  group('TokenUsage：pill 文案', () {
    test('合计含输出、命中文字带小数位', () {
      const usage = TokenUsage(
        uncachedInputTokens: 5,
        outputTokens: 1,
        cacheReadTokens: 9_995,
        cacheWriteTokens: 0,
      );
      expect(usage.grandTotal, 10_001);
      expect(usage.totalLabel, '10K');
      // 9995 / 10000 = 99.95% —— 部分命中不取整成 100。
      expect(usage.cacheHitText, '99.95');
    });

    test('没有计费输入：命中文字 null（不显示 0%）', () {
      const usage = TokenUsage(
        uncachedInputTokens: 0,
        outputTokens: 0,
        cacheReadTokens: 0,
        cacheWriteTokens: 0,
      );
      expect(usage.cacheHitText, isNull);
    });
  });
}
