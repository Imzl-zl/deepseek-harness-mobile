/// 头部 chip 文案的回归。
///
/// 守的是**措辞与 DSH Web 逐字一致**：2026-10-15 手机上把子智能体写成"子代理"，
/// 用户一眼看出"这不是同一个东西"。文案来源：
/// `packages/client/ui-subagent/src/client/locales.ts:36-39` 与
/// `packages/client/ui-jobs/src/client/locales.ts:8-11`。
library;

import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('头部 chip 文案（逐字照 DSH Web）', () {
    test('子智能体：有运行中就带"正在运行"', () {
      expect(
        liveChipLabel(
          count: 3,
          running: 1,
          noun: '个子智能体',
          runningSuffix: '，正在运行',
        ),
        '3 个子智能体，正在运行',
      );
      expect(
        liveChipLabel(
          count: 3,
          running: 0,
          noun: '个子智能体',
          runningSuffix: '，正在运行',
        ),
        '3 个子智能体',
      );
    });

    test('后台任务：有运行中是"运行中",否则裸计数', () {
      expect(
        liveChipLabel(
          count: 2,
          running: 2,
          noun: '个后台任务',
          runningSuffix: '运行中',
        ),
        '2 个后台任务运行中',
      );
      expect(
        liveChipLabel(
          count: 2,
          running: 0,
          noun: '个后台任务',
          runningSuffix: '运行中',
        ),
        '2 个后台任务',
      );
    });
  });
}
