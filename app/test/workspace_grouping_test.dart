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

  // 列表可见性:**逐条照 DSH Web 的 sessionVisible**
  // (`packages/client/ui-workspace/src/client/tree.ts:238-255`)。
  // 2026-10-15 真机对比:Web 的 anatomy-test 3 条、手机 4 条 ——
  // 多的那条是子智能体会话,而连接器一直在发 `subagent` 标志,是手机没解析也没用。
  group('会话可见性(照 DSH Web 的 sessionVisible)', () {
    test('子智能体的子会话不列', () {
      expect(
        sessionVisible(
          subagent: true,
          blank: false,
          isCurrent: false,
          archived: false,
        ),
        isFalse,
      );
      expect(
        sessionVisible(
          subagent: true,
          blank: false,
          isCurrent: true,
          archived: false,
        ),
        isFalse,
        reason: 'Web 的判据是 origin,与是否当前无关',
      );
    });

    test('blank(从没跑过)且不是当前会话的不列', () {
      expect(
        sessionVisible(
          subagent: false,
          blank: true,
          isCurrent: false,
          archived: false,
        ),
        isFalse,
      );
      expect(
        sessionVisible(
          subagent: false,
          blank: true,
          isCurrent: true,
          archived: false,
        ),
        isTrue,
        reason: '正在看的那个 blank 会话要留着,否则用户刚点开就没了',
      );
    });

    test('普通会话照常列', () {
      expect(
        sessionVisible(
          subagent: false,
          blank: false,
          isCurrent: false,
          archived: false,
        ),
        isTrue,
      );
      expect(
        sessionVisible(
          subagent: false,
          blank: false,
          isCurrent: true,
          archived: false,
        ),
        isTrue,
      );
    });

    // 归档的默认不列 —— 照 Web 的默认过滤档(`ArchivedFilter === 'default'`):
    // `case 'default': return !archived.has(session.id)`(`tree.ts:247-248`)。
    // **归档优先于其他判据**:归档的当前会话也不列(它已经不在列表里了)。
    test('已归档的不列(哪怕是当前会话)', () {
      expect(
        sessionVisible(
          subagent: false,
          blank: false,
          isCurrent: false,
          archived: true,
        ),
        isFalse,
      );
      expect(
        sessionVisible(
          subagent: false,
          blank: false,
          isCurrent: true,
          archived: true,
        ),
        isFalse,
        reason: '归档不是"藏起来但还开着"——Web 连当前会话也照样过滤',
      );
    });
  });
}
