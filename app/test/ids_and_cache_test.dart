/// 两个小工具（批 G1）：手拼幂等键、源身份缓存。
///
/// ## 为什么值得单独钉
///
/// - **幂等键**：同一个 `requestId` 发两次，宿主按 `rpcId` 去重（`commands.ts:602-614`），
///   第二次写会被当成重发**静默丢掉**。全仓 16 处手拼 `microsecondsSinceEpoch`，
///   紧挨着的两次调用在同一微秒里是可能撞的 —— 一处拼错就是"点了没反应"。
/// - **源缓存**：`AppModel` 有四处 `(source: …, value: …)` 各写一遍命中判断，
///   漏一个 `identical` 就会每次 build 重算整张表（或更糟：换源后继续用旧值）。
///
/// Note: 取舍见 `.agents/notes/proposed/2026-10-27-ui-state-design.md` §6.B/§6.C。
library;

import 'package:dsh_mobile/data/cache.dart';
import 'package:dsh_mobile/data/ids.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('newRequestId', () {
    test('带前缀（服务端日志与去重表靠它认来源）', () {
      expect(newRequestId('sel'), startsWith('sel-'));
    });

    test('**同一微秒里连续两次也不同**（撞了会被宿主当重发静默丢掉）', () {
      final ids = {for (var i = 0; i < 50; i += 1) newRequestId('p')};
      expect(ids.length, 50);
    });
  });

  group('SourceCache', () {
    test('同一个源对象 → 只算一次', () {
      final cache = SourceCache<int>();
      final source = Object();
      var builds = 0;
      int build() => ++builds;

      expect(cache.read(source, build), 1);
      expect(cache.read(source, build), 1);
      expect(builds, 1);
    });

    test('换一个源对象（哪怕内容一样） → 重算', () {
      final cache = SourceCache<int>();
      var builds = 0;
      int build() => ++builds;

      cache.read(Object(), build);
      cache.read(Object(), build);
      expect(builds, 2, reason: '判据是**身份**不是相等：列表每次刷新都是新对象');
    });

    test('缓存到的值是 null 也算命中（"没有"是一个有效结果）', () {
      final cache = SourceCache<String?>();
      final source = Object();
      var builds = 0;
      String? build() {
        builds += 1;
        return null;
      }

      expect(cache.read(source, build), isNull);
      expect(cache.read(source, build), isNull);
      expect(builds, 1, reason: '把 null 当"未命中"会让每次 build 重算');
    });

    test('可以取到已缓存的值而不重算（读侧先问一句的场景）', () {
      final cache = SourceCache<int>();
      final source = Object();
      expect(cache.peek(source), isNull);
      cache.read(source, () => 7);
      expect(cache.peek(source), 7);
      expect(cache.peek(Object()), isNull, reason: '别的源不该看见这份值');
    });
  });
}
