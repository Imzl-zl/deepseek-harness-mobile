/// `caps.jobs` 决定**要不要发 `job.list`** —— 没装 jobs 的部署里那个方法不存在。
///
/// ## 为什么它与另外四个能力位不同
///
/// `caps.references` / `files` / `changes` / `plugins` 决定"这一屏显不显示"：
/// 缺了就不画，画了也读不到。`caps.jobs` 决定"要不要**发一次调用**"：
/// 连接器在缺服务时根本不挂 `job.*`（`connector/src/handlers.ts:1582`），
/// 发出去只会拿 `connector/unsupported`，而它会被画成"任务读取失败"——
/// **把缺服务画成故障**，正是本仓反复修的那一类。
///
/// 反过来，`caps` 里**没有**这个键时按"有"处理：老连接器照样能拉任务，
/// 猜错的代价是一次多余的成功调用，而不是整块能力消失。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart' show ConnectionState;
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// `caps` 由构造参数决定；`job.list` 与 `session.list` 都记账。
class _Client extends FakeSyncClient {
  _Client(this.caps);

  final Map<String, Object?> caps;
  final List<String> calls = [];

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
  Future<void> setAppState(AppState state) async {}

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    calls.add(method);
    if (method == 'repo.info') {
      return <String, Object?>{
            'protocol': 1,
            'caps': caps,
            'methods': <String>[],
          }
          as T;
    }
    if (method == 'session.list') {
      return <String, Object?>{'sessions': <Object?>[]} as T;
    }
    return <String, Object?>{} as T;
  }
}

void main() {
  test('caps.jobs 为 false：不发 job.list（缺服务不是故障）', () async {
    final client = _Client(<String, Object?>{'jobs': false});
    final app = AppModel(client: client);
    addTearDown(app.dispose);

    await app.refreshRepoInfo();
    expect(app.jobsAvailable, isFalse);
    client.calls.clear();

    await app.refreshJobs('s1');
    expect(
      client.calls.where((m) => m == 'job.list'),
      isEmpty,
      reason: '没装 jobs 的部署里连接器不挂 job.*，发了只会拿 unsupported',
    );
  });

  test('caps.jobs 为 true：照常发', () async {
    final client = _Client(<String, Object?>{'jobs': true});
    final app = AppModel(client: client);
    addTearDown(app.dispose);

    await app.refreshRepoInfo();
    expect(app.jobsAvailable, isTrue);
    client.calls.clear();

    await app.refreshJobs('s1');
    expect(client.calls.where((m) => m == 'job.list'), hasLength(1));
  });

  test('caps 里没有这个键（老连接器）：按"有"处理，照样发', () async {
    final client = _Client(<String, Object?>{});
    final app = AppModel(client: client);
    addTearDown(app.dispose);

    await app.refreshRepoInfo();
    expect(app.jobsAvailable, isTrue, reason: '猜错时宁可多发一次成功调用，也不要让整块能力消失');
    client.calls.clear();

    await app.refreshJobs('s1');
    expect(client.calls.where((m) => m == 'job.list'), hasLength(1));
  });
}
