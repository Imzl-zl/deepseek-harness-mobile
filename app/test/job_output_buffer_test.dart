/// 任务输出缓冲的两个判据：**重开流不叠加**、**长期跑不无限涨**。
///
/// ## 为什么需要它
///
/// 宿主（DSH）的 `job.follow` 契约（`packages/api/job-controller/src/types.ts:55-62`）：
///
/// > *Absolute byte offset to resume from (a prior frame's `next`). Omitted, the
/// > stream starts at the **oldest retained byte**.*
///
/// 也就是说 `follow`（不带 `from`）会**从头重放宿主持有的那一窗**。而手机侧
/// 展开一个任务是 `follow`、收起是 `unfollow`（`ui/chat_page.dart:2877-2879`）——
/// 于是"展开 → 收起 → 再展开"会让宿主的重放**追加到同一份缓冲里**：
/// 用户看到的是一段重复的日志。
///
/// `JobOpened` 帧就是"一条新流开始了"的信号，它带着 `from`（重放从哪开始）。
/// 这条用例钉的是：**收到 `JobOpened` 就把缓冲重置**（而不是 `putIfAbsent`）。
///
/// 第二条判据是内存：宿主自己只留 **256 KiB**（live）/ **16 KiB**（结算后）
/// （`packages/jobs/jobs-local/src/index.ts:37,40` 的 `DEFAULT_RETAIN_BYTES` /
/// `DEFAULT_SETTLED_RETAIN_BYTES`）。手机不该留得比宿主更久 —— 那是在保留
/// 宿主已经判定"不值得留"的字节。
library;

import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/data/job_book.dart';
import 'package:flutter_test/flutter_test.dart';

JobRow _row(String id, {String status = 'running', int total = 0}) => JobRow(
  id: id,
  kind: 'pwsh',
  label: 'build',
  status: status,
  startedAt: 1,
  outputTotal: total,
  sid: 's1',
);

/// 一段输出帧（`from` 是宿主给的续读偏移，这里只关心文本）。
JobFrame _out(String jobId, String text, {bool gapBefore = false}) => JobOutput(
  jobId: jobId,
  chunks: [JobChunk(text: text, at: 0, gapBefore: gapBefore)],
  next: text.length,
);

void main() {
  test('重新展开（新流）不叠加：JobOpened 之后缓冲从零开始', () {
    final book = JobBook();
    book.ensureBucket('s1');

    // 第一次展开：opened(from 0) → 两批输出。
    book.applyFrame(JobOpened(jobId: 'j1', row: _row('j1'), from: 0));
    book.applyFrame(_out('j1', '第一行\n'));
    book.applyFrame(_out('j1', '第二行\n'));
    expect(book.outputOf('j1'), '第一行\n第二行\n');

    // 收起（不再收帧），然后**再展开**：宿主从头重放同一段。
    book.applyFrame(JobOpened(jobId: 'j1', row: _row('j1'), from: 0));
    book.applyFrame(_out('j1', '第一行\n'));
    book.applyFrame(_out('j1', '第二行\n'));

    expect(book.outputOf('j1'), '第一行\n第二行\n', reason: '重放必须替换，不是追加（否则日志看两遍）');
  });

  test('从中间续读（from > 0）：重置并显式说明前面丢了', () {
    final book = JobBook();
    book.ensureBucket('s1');

    book.applyFrame(JobOpened(jobId: 'j1', row: _row('j1'), from: 0));
    book.applyFrame(_out('j1', '早期输出\n'));

    // 宿主的保留窗已经淘汰了前面那一段，重放从第 4096 字节开始。
    book.applyFrame(JobOpened(jobId: 'j1', row: _row('j1'), from: 4096));
    book.applyFrame(_out('j1', '后来的输出\n'));

    expect(book.outputOf('j1'), contains('后来的输出'));
    expect(
      book.outputOf('j1'),
      contains('较早的输出已被淘汰'),
      reason: '从中间开始就必须说出来，不能假装这是完整日志',
    );
    expect(
      book.outputOf('j1'),
      isNot(contains('早期输出')),
      reason: '不要把"上一条流的残余"混进这一条流',
    );
  });

  test('长期运行：缓冲按宿主的保留量封顶，只留尾巴', () {
    final book = JobBook();
    book.ensureBucket('s1');
    book.applyFrame(JobOpened(jobId: 'j1', row: _row('j1'), from: 0));

    // 每批 1 KiB、共 600 批 ≈ 600 KiB —— 超过宿主 live 保留的 256 KiB。
    final chunk = '${'x' * 1023}\n';
    for (var i = 0; i < 600; i += 1) {
      book.applyFrame(_out('j1', chunk));
    }

    final text = book.outputOf('j1');
    expect(text.length, lessThan(700 * 1024), reason: '不能无限涨（宿主自己只留 256 KiB）');
    expect(text, contains('较早的输出已被淘汰'), reason: '裁掉了就要说');
  });

  test('任务结算后收紧到宿主的 settled 保留量', () {
    final book = JobBook();
    book.ensureBucket('s1');
    book.applyFrame(JobOpened(jobId: 'j1', row: _row('j1'), from: 0));

    for (var i = 0; i < 100; i += 1) {
      book.applyFrame(_out('j1', '${'y' * 1023}\n'));
    }
    final before = book.outputOf('j1').length;
    expect(before, greaterThan(16 * 1024));

    // 宿主在结算时把 ring 收紧到 16 KiB（`jobs-local/src/index.ts:624-628`）：
    // 手机跟着收紧，别替宿主留着它已经丢掉的东西。
    book.applyFrame(
      JobStatus(
        jobId: 'j1',
        row: _row('j1', status: 'completed'),
      ),
    );
    expect(
      book.outputOf('j1').length,
      lessThan(before),
      reason: '结算后应收到 16 KiB 那一档',
    );
  });
}
