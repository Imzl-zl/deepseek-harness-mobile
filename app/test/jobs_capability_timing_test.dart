/// `caps.jobs` 的**时机**：能力位决定发不发 `job.list`，所以决定之前得先读到它。
///
/// ## 这一组守什么
///
/// `implemented/2026-11-11-jobs-capability-gate.md` 让 `refreshJobs` 看 `_jobsAvailable`，
/// 而那个值在**读到 `repo.info` 之前**只是默认值（`true`）。首屏那条路是
/// 「九项并行发起 → **只等行** → 落点」（`landAfterConnect`），落点开会话时
/// `repo.info` 往往还没回来 —— 于是缺 jobs 的部署上，**每进程第一次**开会话
/// 仍会发一次注定失败的 `job.list`，并被画成"任务读取失败"。
///
/// 修法不是"未知一律不发"（那会让 `repo.info` 读不到的连接上任务面永远黑着，
/// 而且每一个 `job.list` 的既有用例都得先造一份 `repo.info` 应答），
/// 而是**等这一次读取**：`refreshJobs` 在 `_repoInfoKnown == false` 时先 `await`
/// 首屏批次已经发起的那一次 `repo.info`（`_repoInfoInFlight`）。没有在飞就不等，
/// 所以"从没读过 `repo.info`"的路径照旧发。取舍见
/// `.agents/notes/implemented/2026-11-12-caps-settlement.md`。
///
/// ## 为什么这条要用真 `AppModel` + 落点跑
///
/// `jobs_capability_test.dart` 直接调 `refreshJobs`，它证明不了"落点开会话的那一刻
/// 有没有在读 `repo.info`" —— 而那正是这个缺陷的形状。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 记账替身：`repo.info` 可以被 [repoInfoGate] 压住。
class _TimingClient extends FakeSyncClient {
  _TimingClient({
    required this.caps,
    this.rows = const <Map<String, Object?>>[],
  });

  final Map<String, Object?> caps;
  final List<Map<String, Object?>> rows;

  /// 已发起（发起顺序）。
  final List<String> called = <String>[];

  /// 压住 `repo.info` 的应答 —— 模拟"首屏批次还没回来"。
  Completer<void>? repoInfoGate;

  @override
  ConnectionState get state => ConnectionState.serving;
  @override
  Stream<ConnectionState> get connection => const Stream.empty();
  @override
  Stream<JobFrame> get jobUpdates => const Stream.empty();
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();
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
  Future<SessionAnchor> subscribe(String sid) async =>
      const SessionAnchor(since: 0, hasMore: false);

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    called.add(method);
    if (method == 'repo.info') {
      final gate = repoInfoGate;
      if (gate != null) await gate.future;
      return <String, Object?>{
            'protocol': 1,
            'caps': caps,
            'methods': <String>[],
          }
          as T;
    }
    final Object answer = switch (method) {
      'session.list' => <String, Object?>{'sessions': rows},
      'session.projections' => <String, Object?>{'values': <String, Object?>{}},
      'settings.describe' => <String, Object?>{'sections': <Object?>[]},
      'job.list' => <String, Object?>{'jobs': <Object?>[]},
      'session.modelCatalog' => <String, Object?>{'available': false},
      'permission.catalog' => <String, Object?>{'available': false},
      'agentPresets.list' => <String, Object?>{'presets': <Object?>[]},
      'workspace.list' => <String, Object?>{
        'workspaces': <Object?>[],
        'archivedSessionIds': <Object?>[],
        'pinnedSessionIds': <Object?>[],
      },
      _ => <String, Object?>{},
    };
    return answer as T;
  }
}

/// 一个会话的线上行形状（落点要用 `updatedAt` / `running`）。
Map<String, Object?> _row(String sid) => <String, Object?>{
  'sid': sid,
  'updatedAt': 1,
  'running': false,
  'blank': false,
  'subagent': false,
};

/// 让已经排队的微任务 / 零延时 future 跑完（纯 `test()` 里没有 `pump`）。
Future<void> _settle() async {
  for (var i = 0; i < 6; i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('首屏：能力位还没回来时开会话，不发 job.list（缺 jobs 的部署不再假失败一次）', () async {
    final client = _TimingClient(
      caps: <String, Object?>{'jobs': false},
      rows: <Map<String, Object?>>[_row('s1')],
    );
    final app = AppModel(client: client);
    addTearDown(app.dispose);
    await app.start();
    client.repoInfoGate = Completer<void>();

    final landing = app.landAfterConnect();
    await _settle();

    expect(
      client.called,
      contains('repo.info'),
      reason: '首屏批次要先发起能力位读取（判据的前提）',
    );
    expect(
      client.called,
      isNot(contains('job.list')),
      reason: '能力位还没答复时，_jobsAvailable 只是默认值，不是这台电脑的答复',
    );

    client.repoInfoGate!.complete();
    await landing;

    expect(app.jobsAvailable, isFalse);
    expect(
      client.called,
      isNot(contains('job.list')),
      reason: '答复是"没有这个面" ⇒ 一次都不许发',
    );
  });

  test('首屏：能力位回来是"有" ⇒ 开会话这一次**等它**再发（不是不发）', () async {
    final client = _TimingClient(
      caps: <String, Object?>{'jobs': true},
      rows: <Map<String, Object?>>[_row('s1')],
    );
    final app = AppModel(client: client);
    addTearDown(app.dispose);
    await app.start();
    client.repoInfoGate = Completer<void>();

    final landing = app.landAfterConnect();
    await _settle();
    expect(client.called, isNot(contains('job.list')));

    client.repoInfoGate!.complete();
    await landing;

    expect(app.jobsAvailable, isTrue);
    expect(
      client.called.where((m) => m == 'job.list'),
      hasLength(1),
      reason: '该发的那一次不能因为"等"而丢掉 —— 任务面板会一直是空的',
    );
    expect(
      client.called.lastIndexOf('repo.info'),
      lessThan(client.called.indexOf('job.list')),
      reason: '顺序是判据：先读到能力位，再决定发',
    );
  });

  test('从没读过 repo.info（单测 / 老流程）：照旧发，判据不会变成静默不发', () async {
    final client = _TimingClient(caps: <String, Object?>{});
    final app = AppModel(client: client);
    addTearDown(app.dispose);
    await app.start();

    await app.refreshJobs('s1');

    expect(client.called, <String>[
      'job.list',
    ], reason: '没有在飞的能力位读取 ⇒ 不等，也不自己发起一次（多一个往返换不来判据）');
    expect(
      client.called,
      isNot(contains('repo.info')),
      reason: 'refreshJobs 不许替调用方去读能力位 —— 那是首屏批次的事',
    );
  });
}
