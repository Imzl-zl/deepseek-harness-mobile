/// 测试共用的 `SyncClient` 基类。
///
/// ## 为什么有它
///
/// `SyncClient` 是 `abstract interface class`，每个替身都要实现**全部**成员。
/// 2026-10-19 给它加 `page` 与"`subscribe` 回 `SessionAnchor`"时，
/// 28 个测试文件里的替身全部编译不过 —— 而它们**没有一个关心翻页**。
///
/// 所以把"翻页相关的默认行为"收在这里：**默认没有更多历史、翻页返回空页**。
/// 关心它的测试在自己的替身里覆盖。
///
/// 其余成员给 `UnimplementedError` 默认值：这样任何子类**自动是
/// `SyncClient` 的完整实现**（`implements` 时 Dart 会逼替身写全，
/// 而 `extends` 一个没实现全的抽象类只会得到"不是子类型"的错）。
/// 替身仍然只写它关心的那几个 —— 没写的会在被调时炸，
/// 而那正是"这个用例居然调了它"的信号。
///
/// ## 用法
///
/// ```dart
/// class _FakeClient extends FakeSyncClient {
///   @override
///   ConnectionState get state => ConnectionState.serving;
///   …
/// }
/// ```
///
/// **不要 `implements SyncClient`**：那会绕开这些默认值，下次接口一长又炸一片。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/snapshot_call.dart';
import 'package:dsh_mobile/core/snapshot_digest.dart';
import 'package:dsh_mobile/core/sync_client.dart';

/// `SyncClient` 的测试基类。
abstract class FakeSyncClient implements SyncClient, SnapshotCaller {
  // ---- 只读快照的摘要（契约 §5.7）----
  //
  // 基类实现的是**真的那套**（键 = 方法+参数、应用成功才记）：替身只要实现 `call`，
  // 快照路径就与生产同形，于是"`notModified` 什么都不做"这类用例测的是真逻辑，
  // 而不是替身自己编的一套。

  /// 已"应用"过的摘要（键 → 摘要）。测试想模拟"服务端说没变"时直接往里塞
  /// （形状与服务端同一口径：43 个 base64url 字符，值本身不参与断言）。
  final Map<String, String> appliedSnapshotDigests = <String, String>{};

  @override
  Future<SnapshotReply<Object?>> callSnapshotWithDigest(
    String method,
    Map<String, Object?> params,
  ) async {
    final key = snapshotKeyOf(method, params);
    final value = await call<Object?>(method, params);
    // 服务端的"没变"就长这样；替身按同一形状作答，用例才测得到那个分支。
    if (value is Map && value['notModified'] == true) {
      return SnapshotReply<Object?>.notModified(key: key);
    }
    return SnapshotReply<Object?>.body(value, key: key);
  }

  @override
  void commitSnapshotDigest(String key) {
    appliedSnapshotDigests[key] = 'test-digest';
  }
  // ---- 翻页相关：本版新加的默认值 ----

  @override
  Future<SessionAnchor> subscribe(String sid) async =>
      const SessionAnchor(since: 0, hasMore: false);

  @override
  Future<SessionPage> page({
    required String sid,
    required int beforeSeq,
    int maxMessages = SyncClient.kHistoryPageMaxMessages,
    int minMessages = SyncClient.kHistoryPageMinMessages,
    int minTurns = SyncClient.kHistoryPageMinTurns,
  }) async => const SessionPage(events: [], hasMore: false);

  @override
  bool hasOlderHistory(String sid) => false;

  /// **默认炸**（而不是回一条空事件）：`refetch` 没有"退化的成功"，
  /// 编一条事件会让"大条目出现了"这个断言在假数据上变绿。
  /// 关心它的用例在自己的替身里覆盖（`sync_client_impl_page_test.dart`）。
  @override
  Future<SessionEvent> refetch({required String sid, required int seq}) async =>
      throw UnimplementedError('测试替身没有声明 refetch');

  // ---- 其余成员：默认"这个用例不该调我" ----

  @override
  ConnectionState get state => throw UnimplementedError('测试替身没有声明 state');

  @override
  Stream<ConnectionState> get connection =>
      throw UnimplementedError('测试替身没有声明 connection');

  @override
  Stream<JobFrame> get jobUpdates =>
      throw UnimplementedError('测试替身没有声明 jobUpdates');

  /// 会话运行态流：**默认是空流** —— `AppModel.start()` 无条件订阅它，
  /// 而绝大多数用例不关心"在不在跑"。关心它的用例自己覆盖这个 getter
  /// （`running_reconnect_test.dart` 里那个带控制器的替身）。
  @override
  Stream<SessionStatus> get sessionStatus =>
      const Stream<SessionStatus>.empty();

  /// 宿主状态变更提示（`host` 帧）：**默认空流** —— `AppModel.start()` 无条件订阅它，
  /// 而绝大多数用例不关心"电脑侧改了快照"。关心它的用例自己覆盖这个 getter
  /// （`host_state_wiring_test.dart`）。
  @override
  Stream<HostStateChanged> get hostStateChanges =>
      const Stream<HostStateChanged>.empty();

  @override
  Stream<SessionDelta> sessionUpdates(String sid) =>
      throw UnimplementedError('测试替身没有声明 sessionUpdates');

  @override
  Future<void> start() async => throw UnimplementedError('测试替身没有声明 start');

  @override
  Future<void> reconnect() async =>
      throw UnimplementedError('测试替身没有声明 reconnect');

  @override
  Future<void> setAppState(AppState state) async =>
      throw UnimplementedError('测试替身没有声明 setAppState');

  @override
  Future<void> close() async => throw UnimplementedError('测试替身没有声明 close');

  @override
  Future<void> unsubscribe(String sid) async =>
      throw UnimplementedError('测试替身没有声明 unsubscribe');

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async => throw UnimplementedError('测试替身没有声明 call');
}
