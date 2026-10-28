/// 任务状态词：五档映射成中文，**未知状态不回显宿主原词**。
///
/// 判据：DSH 的 `JobStatus` 是封闭五档（`packages/jobs/jobs/src/view.ts:19`：
/// `'running' | 'stopping' | 'completed' | 'killed' | 'failed'`），
/// 且桌面从不把状态词直接当文本画出来 —— 它映射成文案或 `data-state`
/// （`ui-jobs/src/client/JobListAction.tsx:148-150`、`TerminalBlock.tsx:153`）。
library;

import 'package:dsh_mobile/core/job.dart';
import 'package:flutter_test/flutter_test.dart';

JobRow _job(String status) => JobRow(
  id: 'j1',
  label: 'pnpm test',
  kind: 'pwsh',
  status: status,
  startedAt: 0,
  outputTotal: 0,
);

void main() {
  test('五档都有中文（与 DSH 状态词一一对应）', () {
    expect(_job('running').statusText, '进行中');
    expect(_job('stopping').statusText, '停止中');
    expect(_job('completed').statusText, '已完成');
    expect(_job('killed').statusText, '已停止');
    expect(_job('failed').statusText, '失败');
  });

  test('版本漂移出来的状态不回显英文原词', () {
    expect(_job('done').statusText, '状态未知');
    expect(_job('whatever').statusText, '状态未知');
  });
}
