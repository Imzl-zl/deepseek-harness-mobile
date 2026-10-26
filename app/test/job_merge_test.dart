/// `JobRow` 的合并规则：**终态单向**。
///
/// 规则只有一份（`core/job.dart` 的 [mergeJobRow] / [mergeJobSnapshot]）：
/// `job.list` 快照与 `job` 帧推送都走它。理由见
/// `.agents/notes/proposed/2026-10-26-wire-review-fixes.md`（第 2 批）。
library;

import 'package:dsh_mobile/core/job.dart';
import 'package:flutter_test/flutter_test.dart';

JobRow _row(String status, {int? finishedAt}) => JobRow(
  id: 'j1',
  kind: 'pwsh',
  label: 'flutter build apk',
  status: status,
  startedAt: 1,
  outputTotal: 0,
  finishedAt: finishedAt,
);

void main() {
  group('mergeJobRow：同一个 jobId 是一次运行，终态不会复活', () {
    test('live → 终态：照收（任务真的结束了）', () {
      final merged = mergeJobRow(
        _row('running'),
        _row('completed', finishedAt: 9),
      );
      expect(merged.status, 'completed');
      expect(merged.finishedAt, 9);
    });

    test('终态 → live：留终态（旧快照 / 迟到帧不许回退）', () {
      final merged = mergeJobRow(
        _row('completed', finishedAt: 9),
        _row('running'),
      );
      expect(merged.status, 'completed');
      expect(merged.finishedAt, 9);
    });

    test('stopping 也算 live：终态不许被"停止中"回退', () {
      final merged = mergeJobRow(
        _row('killed', finishedAt: 9),
        _row('stopping'),
      );
      expect(merged.status, 'killed');
    });

    test('终态 → 另一个终态：照收（failed → completed 是更新）', () {
      final merged = mergeJobRow(
        _row('failed', finishedAt: 9),
        _row('completed', finishedAt: 10),
      );
      expect(merged.status, 'completed');
      expect(merged.finishedAt, 10);
    });

    test('没有已有行：照收', () {
      expect(mergeJobRow(null, _row('running')).status, 'running');
    });
  });

  group('mergeJobSnapshot：整份快照逐行套同一条规则', () {
    test('已结束的行不被快照里的 live 盖回', () {
      final merged = mergeJobSnapshot(
        [_row('completed', finishedAt: 9)],
        [_row('running')],
      );
      expect(merged.single.status, 'completed');
    });

    test('快照里没有的行丢弃（快照是这个会话的全集）', () {
      final merged = mergeJobSnapshot(
        [_row('completed', finishedAt: 9), _row('running').copyWithId('j2')],
        [_row('running')],
      );
      expect(merged.map((row) => row.id).toList(), ['j1']);
    });
  });
}

extension on JobRow {
  JobRow copyWithId(String id) => JobRow(
    id: id,
    kind: kind,
    label: label,
    status: status,
    startedAt: startedAt,
    outputTotal: outputTotal,
    progress: progress,
    detail: detail,
    finishedAt: finishedAt,
    sid: sid,
  );
}
