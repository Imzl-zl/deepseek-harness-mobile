/// 头部 chip 文案与**计数口径**的回归。
///
/// 守的是"与 DSH Web 一致"这件事，两处都是踩过坑才补的：
/// - 2026-10-15 手机上把子智能体写成"子代理"，用户一眼看出"这不是同一个东西"；
/// - 2026-10-16 探索原生能力时又发现**两处口径错**：① 子智能体的可见文案被我们
///   拼上了"正在运行"（Web 的 `count.total` 只有总数，"正在运行"那句在 aria-label 里）；
///   ② 后台任务在跑时报的是**总数**加"运行中"（Web 报的是**在跑的个数**）。
///
/// 文案与算法来源：
/// `packages/client/ui-subagent/src/client/locales.ts:36-39` 与
/// `SubagentHeaderLineage.tsx:679-711`；
/// `packages/client/ui-jobs/src/client/locales.ts:8-11` 与
/// `JobListAction.tsx:450-453`。
library;

import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('头部 chip 文案（与 DSH Web 逐字一致）', () {
    test('子智能体：可见文案只报总数，"正在运行"只在 aria 里', () {
      expect(subagentChipLabel(3), '3 个子智能体');
      expect(
        subagentChipAria(total: 3, running: 1),
        '1 个子智能体，正在运行',
        reason: 'aria 报的是**在跑的个数**（SubagentHeaderLineage.tsx:679-680）',
      );
      expect(
        subagentChipAria(total: 3, running: 0),
        '3 个子智能体',
        reason: '没有在跑的就退回总数',
      );
    });

    test('后台任务：在跑报在跑的个数，否则报总数', () {
      expect(jobChipLabel(live: 2, total: 2), '2 个后台任务运行中');
      expect(
        jobChipLabel(live: 1, total: 5),
        '1 个后台任务运行中',
        reason: '在跑时报**在跑的个数**，不是总数（JobListAction.tsx:453）',
      );
      expect(jobChipLabel(live: 0, total: 5), '5 个后台任务');
    });
  });
}
