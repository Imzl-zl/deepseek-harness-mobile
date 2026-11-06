/// `HostRpc` 的实现：**形状知识仍然只在 `wire/`**（本文件只是把它接到端口上）。
///
/// ## 它做什么、不做什么
///
/// 什么都不加：发请求、带摘要、解码、把形状缺陷报给 `WireDiagnostics` 全在
/// `wire/rpc/projections.dart` 的 `loadSessionProjections` 里
/// （`wire/rpc/snapshot.dart` 的 `loadSnapshot` 统一做"三态 + 计数"）。
/// 这一层只把端口的方法名对应到那个函数上 —— 两边写两套判据的话，
/// "读不出来要不要计数"迟早有两份答案。
///
/// 装配点把它当工厂给连接层（`hostRpc: WireHostRpc.new`），
/// `core/sync_client_impl.dart` 就因此能在**不 import `wire/`** 的前提下拿到它。
///
/// Note: `.agents/notes/implemented/2026-11-06-p1b-batch1-session-family.md`。
library;

import '../core/host_rpc.dart';
import '../core/session_list_page.dart';
import '../core/snapshot_digest.dart';
import '../core/sync_client.dart';
import 'rpc/projections.dart';
import 'rpc/session.dart';

/// 端口 `HostRpc` 的唯一实现（本轮：会话投影 + 会话行两族）。
final class WireHostRpc implements HostRpc {
  /// 构造参数是**这个能力属于哪条连接**（工厂 `hostRpc` 收到的就是它）。
  ///
  /// 不存字段：每个方法自己收一个 `client`（端口照抄 `loadXxx(client, …)` 的形状），
  /// 而两者生产里永远是同一个对象 —— 存下来只多一个"能力挂在 A、却拿 B 去发请求"的
  /// 可能性，没有别的作用。
  const WireHostRpc(SyncClient _);

  @override
  Future<SnapshotReply<SessionProjections?>> projections(
    SyncClient client, {
    required String sid,
  }) => loadSessionProjections(client, sid: sid);

  @override
  Future<SnapshotReply<SessionListPage>> sessionRows(
    SyncClient client, {
    int? limit,
    int? offset,
  }) => loadSessionList(client, limit: limit, offset: offset);
}
