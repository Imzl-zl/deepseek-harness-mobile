/// `parseJobFrame`：job 面的 **wire 边界**（连接器 → 手机的唯一入口）。
///
/// ## 为什么这一层要直接钉，而不是靠上层用例
///
/// 上一轮改的是这一层的**消费方**（重开流替换而非追加，见
/// `implemented/2026-11-11-job-output-buffer.md`），而边界本身只有**间接**覆盖：
/// `job_panel_test.dart` 直接构造 `JobRow` 交给 `JobBook`，**根本不经过 `parseJobFrame`**。
/// 于是"帧上的字段有没有落到 `JobRow`"这类事，组件用例全绿也证明不了 ——
/// 本轮就靠这一层抓到一个真缺陷：`job.sid` 在线上帧里由连接器盖
/// （`connector/src/job-subscriptions.ts:98-101`），`JobBook._applyRow` 也按它归桶，
/// 而这里从来没读过它 ⇒ 帧路径永远退回归"当前会话"。
///
/// ## 抛与不抛的分界
///
/// - **身份 / 游标字段**（`jobId`、`kind`、`chunks`、`at`、`next`、`startedAt`、
///   `outputTotal`）认不出就抛：它们决定"这条帧是什么、接着从哪读"，猜一个值等于
///   把一帧解不开伪装成解开了（调用方据此转成 `JobError` 显示"这一帧没解出来"）。
/// - **展示字段**（`id` / `kind`(行内) / `label` / `status` / `progress` / `detail` /
///   `finishedAt` / `sid`）兜一个空值：它们是"画成什么样"，不是"是谁"。兜底写在
///   下面的用例里，改动它必须改这些断言。
///
/// 契约 §5.3 / `connector/src/protocol/job-output.ts` 的 `JobOutputFrame` 是唯一的形状真值。
library;

import 'dart:convert';

import 'package:dsh_mobile/core/job.dart';
import 'package:flutter_test/flutter_test.dart';

/// 连接器 `JobRowView` 的线上形状（`protocol/job-output.ts:54-67`）。
Map<String, Object?> _wireRow({
  Object? id = 'j1',
  Object? kind = 'pwsh',
  Object? label = 'flutter build apk',
  Object? status = 'running',
  Object? startedAt = 1700000000000,
  Object? outputTotal = 1024,
  Object? progress,
  Object? detail,
  Object? finishedAt,
  Object? sid,
}) => <String, Object?>{
  'id': id,
  'kind': kind,
  'label': label,
  'status': status,
  'startedAt': startedAt,
  'outputTotal': outputTotal,
  'progress': ?progress,
  'detail': ?detail,
  'finishedAt': ?finishedAt,
  'sid': ?sid,
};

String _frame(Map<String, Object?> payload) => jsonEncode(payload);

void main() {
  group('四种 kind 的正样本：字段逐项落位', () {
    test('opened：行 + from', () {
      final frame = parseJobFrame(
        _frame({
          'kind': 'opened',
          'jobId': 'j1',
          'job': _wireRow(
            progress: '50%',
            detail: 'building',
            finishedAt: 1700000009999,
            sid: 's1',
          ),
          'from': 42,
        }),
      );

      expect(frame, isA<JobOpened>());
      final opened = frame as JobOpened;
      expect(opened.jobId, 'j1');
      expect(opened.from, 42);
      expect(opened.row.id, 'j1');
      expect(opened.row.kind, 'pwsh');
      expect(opened.row.label, 'flutter build apk');
      expect(opened.row.status, 'running');
      expect(opened.row.startedAt, 1700000000000);
      expect(opened.row.outputTotal, 1024);
      expect(opened.row.progress, '50%');
      expect(opened.row.detail, 'building');
      expect(opened.row.finishedAt, 1700000009999);
      expect(opened.row.sid, 's1', reason: '连接器在帧的 job 上盖了 sid，丢了就只能按"当前会话"猜');
      expect(opened.row.isLive, isTrue);
    });

    test('output：chunks / next / lossy', () {
      final frame = parseJobFrame(
        _frame({
          'kind': 'output',
          'jobId': 'j1',
          'chunks': [
            {'at': 10, 'text': 'hello\n'},
            {
              'at': 16,
              'text': 'oops\n',
              'channel': 'stderr',
              'gapBefore': true,
            },
          ],
          'next': 21,
          'lossy': true,
        }),
      );

      expect(frame, isA<JobOutput>());
      final output = frame as JobOutput;
      expect(output.jobId, 'j1');
      expect(output.next, 21);
      expect(output.lossy, isTrue);
      expect(output.chunks, hasLength(2));
      expect(output.chunks[0].at, 10);
      expect(output.chunks[0].text, 'hello\n');
      expect(output.chunks[0].channel, isNull);
      expect(output.chunks[0].gapBefore, isFalse);
      expect(output.chunks[1].at, 16);
      expect(output.chunks[1].text, 'oops\n');
      expect(output.chunks[1].channel, 'stderr');
      expect(output.chunks[1].gapBefore, isTrue);
    });

    test('status：行落位（终态也会走这条）', () {
      final frame = parseJobFrame(
        _frame({
          'kind': 'status',
          'jobId': 'j1',
          'job': _wireRow(status: 'completed', finishedAt: 1700000009999),
        }),
      );

      expect(frame, isA<JobStatus>());
      final status = frame as JobStatus;
      expect(status.jobId, 'j1');
      expect(status.row.status, 'completed');
      expect(status.row.statusText, '已完成');
      expect(status.row.finishedAt, 1700000009999);
      expect(status.row.isLive, isFalse);
    });

    test('error：message 落位（宿主没有这一帧，通道补的）', () {
      final frame = parseJobFrame(
        _frame({'kind': 'error', 'jobId': 'j1', 'message': '实时输出流中断：boom'}),
      );

      expect(frame, isA<JobError>());
      final error = frame as JobError;
      expect(error.jobId, 'j1');
      expect(error.message, '实时输出流中断：boom');
    });
  });

  group('坏载荷必须抛，不许猜', () {
    test('载荷不是 JSON 对象', () {
      expect(() => parseJobFrame('[]'), throwsFormatException);
      expect(
        () => parseJobFrame('not json'),
        throwsFormatException,
        reason: 'jsonDecode 自己的 FormatException 也照抛',
      );
    });

    test('缺 jobId / jobId 是空串 / 不是字符串', () {
      expect(
        () => parseJobFrame(_frame({'kind': 'error', 'message': 'x'})),
        throwsFormatException,
      );
      expect(
        () => parseJobFrame(
          _frame({'kind': 'error', 'jobId': '', 'message': 'x'}),
        ),
        throwsFormatException,
        reason: '空串当键会让所有无名任务挤成同一行',
      );
      expect(
        () => parseJobFrame(_frame({'kind': 'error', 'jobId': 7})),
        throwsFormatException,
      );
    });

    test('kind 不认识 / 缺失', () {
      expect(
        () => parseJobFrame(_frame({'kind': 'weird', 'jobId': 'j1'})),
        throwsFormatException,
      );
      expect(
        () => parseJobFrame(_frame({'jobId': 'j1'})),
        throwsFormatException,
      );
    });

    test('output 帧 chunks 不是数组', () {
      expect(
        () => parseJobFrame(
          _frame({'kind': 'output', 'jobId': 'j1', 'chunks': {}, 'next': 0}),
        ),
        throwsFormatException,
      );
      expect(
        () =>
            parseJobFrame(_frame({'kind': 'output', 'jobId': 'j1', 'next': 0})),
        throwsFormatException,
        reason: '缺 chunks 与"空 chunks"是两件事：后者是合法的空批',
      );
    });

    test('游标不是整数就抛（at / next / startedAt / outputTotal）', () {
      expect(
        () => parseJobFrame(
          _frame({
            'kind': 'output',
            'jobId': 'j1',
            'chunks': [
              {'at': '10', 'text': 'x'},
            ],
            'next': 10,
          }),
        ),
        throwsFormatException,
      );
      expect(
        () => parseJobFrame(
          _frame({
            'kind': 'output',
            'jobId': 'j1',
            'chunks': <Object?>[],
            'next': 10.5,
          }),
        ),
        throwsFormatException,
      );
      expect(
        () => parseJobFrame(
          _frame({
            'kind': 'opened',
            'jobId': 'j1',
            'job': _wireRow(startedAt: 'x'),
            'from': 0,
          }),
        ),
        throwsFormatException,
      );
      expect(
        () => parseJobFrame(
          _frame({
            'kind': 'opened',
            'jobId': 'j1',
            'job': _wireRow(outputTotal: null),
            'from': 0,
          }),
        ),
        throwsFormatException,
      );
      expect(
        () => parseJobFrame(
          _frame({
            'kind': 'opened',
            'jobId': 'j1',
            'job': _wireRow(),
            'from': '0',
          }),
        ),
        throwsFormatException,
      );
    });

    test('opened / status 的 job 不是对象', () {
      expect(
        () => parseJobFrame(
          _frame({'kind': 'opened', 'jobId': 'j1', 'job': [], 'from': 0}),
        ),
        throwsFormatException,
      );
      expect(
        () => parseJobFrame(_frame({'kind': 'status', 'jobId': 'j1'})),
        throwsFormatException,
      );
    });
  });

  group('展示字段的兜底（身份字段与 status 都不兜）', () {
    test('kind / label 不是 String ⇒ 空串（行 id 退回帧的 jobId）', () {
      final frame =
          parseJobFrame(
                _frame({
                  'kind': 'status',
                  'jobId': 'j9',
                  'job': {
                    'id': 7,
                    'kind': 7,
                    'label': 7,
                    'status': 'running',
                    'startedAt': 1,
                    'outputTotal': 0,
                  },
                }),
              )
              as JobStatus;

      expect(frame.row.kind, '');
      expect(frame.row.label, '');
      expect(frame.row.id, 'j9', reason: '行 id 缺失时退回帧的 jobId —— 身份字段只能取真值，不许编');
    });

    test('status 缺了 / 不是非空字符串 ⇒ **抛**（不当 running）', () {
      // `status ?? 'running'` 就是「任务永远转」的形态：`job.list` 那条路
      // （`wire/rpc/job.dart` 的 `_jobRowOf`）已经按这条判据要求必填，
      // 两条路对同一个键只能同一个纪律。
      for (final bad in <Object?>[null, 7, '']) {
        expect(
          () => parseJobFrame(
            _frame({
              'kind': 'status',
              'jobId': 'j1',
              'job': _wireRow(status: bad),
            }),
          ),
          throwsFormatException,
          reason: 'status = $bad 时整帧应该认不出（由调用方转成 JobError）',
        );
      }
    });

    test('可选项缺省即 null（progress / detail / finishedAt / sid）', () {
      final frame =
          parseJobFrame(
                _frame({'kind': 'status', 'jobId': 'j1', 'job': _wireRow()}),
              )
              as JobStatus;

      expect(frame.row.progress, isNull);
      expect(frame.row.detail, isNull);
      expect(frame.row.finishedAt, isNull);
      expect(
        frame.row.sid,
        isNull,
        reason: '老连接器不带 sid —— null 表示"这帧没有出处"，由调用方决定要不要猜',
      );
    });

    test('finishedAt 只认 int：double / 字符串都当没有', () {
      for (final bad in <Object>[1.5, '1700000009999']) {
        final frame =
            parseJobFrame(
                  _frame({
                    'kind': 'status',
                    'jobId': 'j1',
                    'job': _wireRow(finishedAt: bad),
                  }),
                )
                as JobStatus;
        expect(frame.row.finishedAt, isNull, reason: '坏的展示字段不值得换掉整帧');
      }
    });

    test('error 帧缺 message ⇒ 一句中文兜底，不是空响应', () {
      final frame =
          parseJobFrame(_frame({'kind': 'error', 'jobId': 'j1'})) as JobError;
      expect(frame.message, '未知原因');
    });
  });

  group('output 帧的三种可选取值各自成立', () {
    JobOutput parse({
      Object? channel,
      bool gapBefore = false,
      bool lossy = false,
    }) =>
        parseJobFrame(
              _frame({
                'kind': 'output',
                'jobId': 'j1',
                'chunks': [
                  {
                    'at': 0,
                    'text': 'x',
                    'channel': ?channel,
                    if (gapBefore) 'gapBefore': true,
                  },
                ],
                'next': 1,
                if (lossy) 'lossy': true,
              }),
            )
            as JobOutput;

    test('channel：三种线上词各认一遍，缺席即 null', () {
      expect(parse(channel: 'stdout').chunks.single.channel, 'stdout');
      expect(parse(channel: 'stderr').chunks.single.channel, 'stderr');
      expect(parse(channel: 'log').chunks.single.channel, 'log');
      expect(parse().chunks.single.channel, isNull);
      expect(
        parse(channel: 7).chunks.single.channel,
        isNull,
        reason: 'channel 是展示分类，认不出就不分类，不抛',
      );
    });

    test('gapBefore：只有 true 算真（缺席 / 别的值都算 false）', () {
      expect(parse(gapBefore: true).chunks.single.gapBefore, isTrue);
      expect(parse().chunks.single.gapBefore, isFalse);
      final weird =
          parseJobFrame(
                _frame({
                  'kind': 'output',
                  'jobId': 'j1',
                  'chunks': [
                    {'at': 0, 'text': 'x', 'gapBefore': 'yes'},
                  ],
                  'next': 1,
                }),
              )
              as JobOutput;
      expect(weird.chunks.single.gapBefore, isFalse);
    });

    test('lossy：只有 true 算真', () {
      expect(parse(lossy: true).lossy, isTrue);
      expect(parse().lossy, isFalse);
    });

    test('chunks 里认不出的条目跳过，好的照收', () {
      final frame =
          parseJobFrame(
                _frame({
                  'kind': 'output',
                  'jobId': 'j1',
                  'chunks': [
                    'nope',
                    {'at': 5, 'text': 'ok'},
                  ],
                  'next': 7,
                }),
              )
              as JobOutput;
      expect(frame.chunks.single.at, 5);
      expect(frame.next, 7);
    });
  });
}
