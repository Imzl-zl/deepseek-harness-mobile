/// 工作区分组的回归（`workspace.list` + `bucketSessionsByWorkspace`）。
///
/// 守的是**结构**：会话列表必须按工作区分组（Web 的侧栏就是 工作区 → 会话），
/// 而不是按日期拍平 —— 项目一多,在时间里翻会话就是用户 2026-10-15 提的
/// "我好多项目,我找半天会话吗"。
library;

import 'package:dsh_mobile/model/workspace.dart';
import 'package:flutter_test/flutter_test.dart';

WorkspaceGroup ws(String id, String title, List<String> sids) => WorkspaceGroup(
  workspaceId: id,
  title: title,
  path: '/repo/$id',
  sessionIds: sids,
);

List<String> labelsOf(List<WorkspaceBucket> buckets) => [
  for (final b in buckets) b.label,
];

void main() {
  group('按工作区分桶', () {
    test('顺序照电脑侧给的行序,分组头用工作区的名字', () {
      final buckets = bucketSessionsByWorkspace(
        ['s1', 's2', 's3'],
        [
          ws('w2', 'deepseek-harness', ['s3']),
          ws('w1', 'dsh-mobile', ['s1']),
        ],
      );

      expect(labelsOf(buckets), ['deepseek-harness', 'dsh-mobile', '未分组']);
      expect(buckets[0].sessionIds, ['s3']);
      expect(buckets[1].sessionIds, ['s1']);
      expect(buckets[2].sessionIds, ['s2'], reason: '不在任何工作区里的会话进「未分组」,不丢');
    });

    test('一个会话只进一个桶(不重复出现)', () {
      // 同一个 sid 被两个工作区同时报到(电脑侧数据不一致时):第一次认领就定。
      final buckets = bucketSessionsByWorkspace(
        ['s1'],
        [
          ws('w1', 'A', ['s1']),
          ws('w2', 'B', ['s1']),
        ],
      );

      expect(labelsOf(buckets), ['A']);
    });

    test('工作区里没有会话就不出这个桶(不出空组)', () {
      final buckets = bucketSessionsByWorkspace(
        ['s1'],
        [
          ws('w1', 'A', ['sX']),
        ],
      );

      expect(labelsOf(buckets), ['未分组'], reason: '空分组头会让人以为这个项目坏了');
    });

    test('拿不到工作区清单:不分组,而不是按 cwd 猜', () {
      final buckets = bucketSessionsByWorkspace(['s1', 's2'], const []);

      expect(labelsOf(buckets), ['会话']);
      expect(buckets.single.sessionIds, ['s1', 's2']);
    });

    test('全部分组完就没有「未分组」桶', () {
      final buckets = bucketSessionsByWorkspace(
        ['s1', 's2'],
        [
          ws('w1', 'A', ['s1', 's2']),
        ],
      );

      expect(labelsOf(buckets), ['A']);
    });
  });
}
