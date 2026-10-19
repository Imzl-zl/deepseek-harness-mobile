/// "滚到顶就翻页"的判据回归。
///
/// ## 这一组守什么
///
/// 2026-10-26 接上历史翻页的最后一个调用点。触发点在
/// `_ConversationFlow`（私有 StatefulWidget）里，widget 测试构不出它 ——
/// 所以把"到没到顶"抽成 `ui/load_older_trigger.dart` 的纯函数，
/// 这里验判据，触发点只剩"把判据接上"的一行。
///
/// 三条容易写错的：
/// 1. **`reverse: true` 下"历史那一端"是 `maxScrollExtent`**（不是 0）——
///    列表倒序，offset 0 是最新一端。搞反了就永远不触发。
/// 2. **`maxScrollExtent <= 0` 时不翻**：没有可滚内容时 `pixels` 也是 0，
///    "到顶"恒真，会在每次布局时都触发。
/// 3. **`hasMore` 为假时不翻**：那可能是"确定没有"也可能是"不知道"，
///    两种情况都不该发一次必然空手的请求。
library;

import 'package:dsh_mobile/ui/load_older_trigger.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shouldLoadOlder', () {
    test('reverse 列表：滚到 maxScrollExtent 一端才翻', () {
      // 1000px 可滚内容。阈值是 80px。
      expect(
        shouldLoadOlder(pixels: 100, maxScrollExtent: 1000, hasMore: true),
        isFalse,
        reason: '还在最新一端，不翻',
      );
      expect(
        shouldLoadOlder(pixels: 800, maxScrollExtent: 1000, hasMore: true),
        isFalse,
        reason: '差 200px，还没到',
      );
      expect(
        shouldLoadOlder(pixels: 930, maxScrollExtent: 1000, hasMore: true),
        isTrue,
        reason: '进 80px 余量了就翻（不用死死顶住）',
      );
      expect(
        shouldLoadOlder(pixels: 1000, maxScrollExtent: 1000, hasMore: true),
        isTrue,
        reason: '绝对顶上也翻',
      );
    });

    test('正序列表（reverse: false）：顶在 0 那一端', () {
      expect(
        shouldLoadOlder(
          pixels: 50,
          maxScrollExtent: 1000,
          hasMore: true,
          reverse: false,
        ),
        isTrue,
      );
      expect(
        shouldLoadOlder(
          pixels: 500,
          maxScrollExtent: 1000,
          hasMore: true,
          reverse: false,
        ),
        isFalse,
      );
    });

    test('没有可滚内容：不翻（否则每次布局都触发）', () {
      expect(
        shouldLoadOlder(pixels: 0, maxScrollExtent: 0, hasMore: true),
        isFalse,
        reason: 'maxScrollExtent 为 0 时"到顶"恒真，必须挡掉',
      );
    });

    test('hasMore 为假：不翻（不知道 / 确定没有，都不该发空请求）', () {
      expect(
        shouldLoadOlder(pixels: 1000, maxScrollExtent: 1000, hasMore: false),
        isFalse,
      );
    });
  });
}
