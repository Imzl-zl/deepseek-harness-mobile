/// 后台任务这条链的跨层回归（`job.*` 方法 + `job` 帧 → 任务面板）。
///
/// ## 为什么单独一组
///
/// 这一层 2026-10-15 才接上，接之前 App 里是**三条写死的示例任务**
/// （含假的 `flutter build apk` 输出与假的"等待审批"）—— 真机上与真数据
/// 一模一样，用户无法分辨。所以这里钉的不只是"能显示"，而是
/// **"没有电脑侧数据时必须是空的"**：示例数据最大的代价是它看起来像真的。
///
/// 三条难在单测里复现的性质：
/// 1. **点开会话就拉清单**：漏了它任务面板永远空着，而那和"电脑上没有任务"
///    在界面上完全一样；
/// 2. **`job` 帧的四种 kind 都要接**：漏一种的表现是"任务在跑但没有输出"；
/// 3. **`gapBefore` / `lossy` 必须显式提示**：静默拼接会伪造输出
///    （`plugin-and-jobs-notes.md` §B.4）。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fake_sync_client.dart';

/// 可推 `job` 帧的假客户端。
class _JobClient extends FakeSyncClient {
  _JobClient({this.onCall});

  final Object? Function(String method, Map<String, Object?> params)? onCall;
  final List<String> called = [];
  final _jobs = StreamController<JobFrame>.broadcast();

  @override
  ConnectionState get state => ConnectionState.serving;

  @override
  Stream<ConnectionState> get connection => const Stream.empty();

  @override
  Stream<JobFrame> get jobUpdates => _jobs.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> reconnect() => start();

  @override
  Future<void> setAppState(AppState state) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> unsubscribe(String sid) async {}

  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    called.add(method);
    final result = onCall?.call(method, params);
    return result as T;
  }

  void push(JobFrame frame) => _jobs.add(frame);
}

Map<String, Object?> _rowJson(
  String id, {
  String status = 'running',
  int startedAt = 1000,
  int outputTotal = 0,
  int? finishedAt,
}) => {
  'id': id,
  'kind': 'pwsh',
  'label': 'flutter build apk --debug',
  'status': status,
  'startedAt': startedAt,
  'outputTotal': outputTotal,
  'finishedAt': ?finishedAt,
};

void main() {
  test('点开会话就拉一次任务清单（漏了它面板永远空着）', () async {
    final client = _JobClient(
      onCall: (method, params) => method == 'job.list'
          ? {
              'jobs': [
                _rowJson('j1'),
                _rowJson('j5', status: 'completed', finishedAt: 1003),
              ],
            }
          : null,
    );
    final app = AppModel(client: client);
    await app.start();

    await app.openSession('sid_A');

    expect(client.called, contains('job.list'), reason: '点开会话要刷任务清单');
    expect(app.jobsOf('sid_A').map((j) => j.id).toList(), ['j1', 'j5']);
    app.dispose();
  });

  test('电脑侧没有任务时是**空表**，不是示例数据', () async {
    // 这是示例数据最大的代价：它看起来和真数据一模一样。
    final client = _JobClient(
      onCall: (method, params) =>
          method == 'job.list' ? {'jobs': const []} : null,
    );
    final app = AppModel(client: client);
    await app.start();

    await app.openSession('sid_A');

    expect(app.jobsOf('sid_A'), isEmpty);
    app.dispose();
  });

  test('`job.list` 失败：留声但不炸（任务面板空着比会话打不开可接受）', () async {
    final client = _JobClient(
      onCall: (method, params) =>
          throw const ProtocolException(ErrorCode.internal, 'boom'),
    );
    final app = AppModel(client: client);
    await app.start();

    await app.openSession('sid_A');

    expect(app.lastError, isNotNull, reason: '失败必须留声');
    app.dispose();
  });

  test('`opened` 帧：任务行进状态，输出从头开始拼', () async {
    final client = _JobClient(onCall: (m, p) => null);
    final app = AppModel(client: client);
    await app.start();
    await app.openSession('sid_A');

    client.push(
      const JobOpened(
        jobId: 'j1',
        row: JobRow(
          id: 'j1',
          kind: 'pwsh',
          label: 'flutter build apk',
          status: 'running',
          startedAt: 1000,
          outputTotal: 0,
        ),
        from: 0,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(app.jobsOf('sid_A').single.id, 'j1');
    expect(app.jobOutput('j1'), '');
    app.dispose();
  });

  // **回归 2026-10-15 真机 bug**：帧上带 sid 时按它归桶，而不是按地图插入序猜。
  // 旧实现是 `_jobs.keys.last` —— 它的致命场景是 A → B → **再回 A**：
  // A 的桶早就建过（再开不会重新插入），插入序末位仍是 B，于是 A 里新起的任务
  // 被归给 B。用户正在看 A，**A 不显示后台任务 chip**，B 反而凭空多一个。
  // 表现与"电脑侧没这个任务"一模一样，所以它值得一条专门的钉子。
  test('帧带 sid 就按 sid 归桶（不是按开过谁猜）', () async {
    final client = _JobClient(onCall: (m, p) => null);
    final app = AppModel(client: client);
    await app.start();
    // A → B → 回 A：旧实现在这一刻把新任务归给 B。
    await app.openSession('sid_A');
    await app.openSession('sid_B');
    await app.openSession('sid_A');

    client.push(
      const JobOpened(
        jobId: 'j9',
        row: JobRow(
          id: 'j9',
          kind: 'pwsh',
          label: 'flutter build apk',
          status: 'running',
          startedAt: 1000,
          outputTotal: 0,
          sid: 'sid_A',
        ),
        from: 0,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(app.jobsOf('sid_A').map((j) => j.id), [
      'j9',
    ], reason: '正在看的会话必须收到这个任务，否则 chip 不显示');
    expect(app.jobsOf('sid_B'), isEmpty, reason: 'B 不该凭空多一个任务');
    app.dispose();
  });

  test('老连接器（帧不带 sid）：退回归到当前会话', () async {
    final client = _JobClient(onCall: (m, p) => null);
    final app = AppModel(client: client);
    await app.start();
    await app.openSession('sid_A');
    await app.openSession('sid_B');

    client.push(
      const JobOpened(
        jobId: 'j8',
        row: JobRow(
          id: 'j8',
          kind: 'pwsh',
          label: 'x',
          status: 'running',
          startedAt: 1000,
          outputTotal: 0,
        ),
        from: 0,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(app.jobsOf('sid_B').map((j) => j.id), ['j8']);
    app.dispose();
  });

  test('`output` 帧：按序追加，`gapBefore` 显式提示（不许静默拼接）', () async {
    final client = _JobClient(onCall: (m, p) => null);
    final app = AppModel(client: client);
    await app.start();
    await app.openSession('sid_A');
    client.push(
      const JobOpened(
        jobId: 'j1',
        row: JobRow(
          id: 'j1',
          kind: 'pwsh',
          label: 'x',
          status: 'running',
          startedAt: 1000,
          outputTotal: 0,
        ),
        from: 0,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    client.push(
      const JobOutput(
        jobId: 'j1',
        chunks: [
          JobChunk(at: 0, text: 'Running Gradle…\n'),
          JobChunk(at: 17, text: '> Task :app:compile\n', gapBefore: true),
        ],
        next: 40,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(app.jobOutput('j1'), contains('Running Gradle…'));
    expect(app.jobOutput('j1'), contains('> Task :app:compile'));
    // **缺口必须看得见**：静默拼接会让两段不相邻的输出看起来是连续的。
    expect(app.jobOutput('j1'), contains('已被淘汰'));
    app.dispose();
  });

  test('`lossy` 帧：上报"部分输出已丢失"', () async {
    final client = _JobClient(onCall: (m, p) => null);
    final app = AppModel(client: client);
    await app.start();
    await app.openSession('sid_A');

    client.push(
      const JobOutput(
        jobId: 'j9',
        chunks: [JobChunk(at: 0, text: 'tail')],
        next: 4,
        lossy: true,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(app.jobError('j9'), contains('丢失'));
    app.dispose();
  });

  test('`status` 帧：终态更新那一行', () async {
    final client = _JobClient(
      onCall: (m, p) => m == 'job.list'
          ? {
              'jobs': [_rowJson('j1')],
            }
          : null,
    );
    final app = AppModel(client: client);
    await app.start();
    await app.openSession('sid_A');
    expect(app.jobsOf('sid_A').single.status, 'running');

    client.push(
      const JobStatus(
        jobId: 'j1',
        row: JobRow(
          id: 'j1',
          kind: 'pwsh',
          label: 'flutter build apk',
          status: 'completed',
          startedAt: 1000,
          outputTotal: 12,
          finishedAt: 1003,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final row = app.jobsOf('sid_A').single;
    expect(row.status, 'completed');
    expect(row.isLive, isFalse);
    app.dispose();
  });

  test('`error` 帧：订阅中断要显式提示', () async {
    final client = _JobClient(onCall: (m, p) => null);
    final app = AppModel(client: client);
    await app.start();
    await app.openSession('sid_A');

    client.push(const JobError(jobId: 'j1', message: '宿主流出错'));
    await Future<void>.delayed(Duration.zero);

    expect(app.jobError('j1'), '宿主流出错');
    app.dispose();
  });

  test('展开 / 收起：与 job.follow / job.unfollow 一对一', () async {
    final client = _JobClient(
      onCall: (m, p) => m == 'job.list'
          ? {
              'jobs': [_rowJson('j1')],
            }
          : null,
    );
    final app = AppModel(client: client);
    await app.start();
    await app.openSession('sid_A');

    await app.followJob('sid_A', 'j1');
    expect(client.called, contains('job.follow'));
    expect(app.isJobFollowed('sid_A', 'j1'), isTrue);

    // 重复 follow 本地要挡一次：否则 UI 上会"点了两下、输出翻倍"。
    final before = client.called.where((m) => m == 'job.follow').length;
    await app.followJob('sid_A', 'j1');
    expect(client.called.where((m) => m == 'job.follow').length, before);

    await app.unfollowJob('sid_A', 'j1');
    expect(client.called, contains('job.unfollow'));
    expect(app.isJobFollowed('sid_A', 'j1'), isFalse);
    app.dispose();
  });

  test('follow 失败：撤掉本地标记（否则显示"已订阅"却永远没输出）', () async {
    final client = _JobClient(
      onCall: (m, p) => m == 'job.list'
          ? {
              'jobs': [_rowJson('j1')],
            }
          : throw const ProtocolException(ErrorCode.internal, 'follow 炸了'),
    );
    final app = AppModel(client: client);
    await app.start();
    await app.openSession('sid_A');

    await app.followJob('sid_A', 'j1');

    expect(app.isJobFollowed('sid_A', 'j1'), isFalse);
    expect(app.jobError('j1'), isNotNull);
    app.dispose();
  });

  test('kill 回电脑侧的结论，不做乐观更新', () async {
    final client = _JobClient(
      onCall: (m, p) => switch (m) {
        'job.list' => {
          'jobs': [_rowJson('j1')],
        },
        'job.kill' => {'outcome': 'requested'},
        _ => null,
      },
    );
    final app = AppModel(client: client);
    await app.start();
    await app.openSession('sid_A');

    expect(await app.killJob('sid_A', 'j1'), 'requested');
    // 终态要等 `status` 帧：任务行此刻还是 running。
    expect(app.jobsOf('sid_A').single.status, 'running');
    app.dispose();
  });

  test('帧解析失败：转成 JobError，不断连接', () async {
    final client = _JobClient(onCall: (m, p) => null);
    final app = AppModel(client: client);
    await app.start();
    await app.openSession('sid_A');

    // 一帧解不动就断连接太狠，而这帧只是任务输出。
    client.push(const JobError(jobId: '?', message: '任务帧解不开：FormatException'));
    await Future<void>.delayed(Duration.zero);

    expect(app.jobError('?'), contains('解不开'));
    app.dispose();
  });
}
