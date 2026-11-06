/// `HostRpcHolder` 的实现：把这条连接上的**两个口**装配起来。
///
/// 它自己一个方法都不实现 —— 读在 `wire/host_reads.dart`、写在 `wire/host_writes.dart`。
/// 装配点把它当工厂给连接层（`hostRpc: WireHostRpc.new`），
/// `core/sync_client_impl.dart` 就因此能在**不 import `wire/`** 的前提下拿到两个口。
///
/// Note: 为什么读写分两个口见 `core/host_rpc.dart` 的文件头；
/// 端口形状的两版（逐方法转发 → 能力持有者）见
/// `.agents/notes/implemented/2026-11-06-p1b-hostrpc-holder.md`。
library;

import '../core/event_fields.dart';
import '../core/host_rpc.dart';
import '../core/sync_client.dart';
import 'event_fields.dart';
import 'host_reads.dart';
import 'host_writes.dart';

/// 一条连接上的读 / 写能力。
final class WireHostRpc implements HostRpcHolder {
  WireHostRpc(this.client);

  /// 这条连接（工厂 `hostRpc` 收到的那一个）。
  final SyncClient client;

  @override
  late final HostReads reads = WireHostReads(client);

  @override
  late final HostWrites writes = WireHostWrites(client);

  /// 纯解码，不碰连接 —— 一个 `const` 实例就够了（`WireHostRpc` 因为它不是 `const`
  /// 才用 `late final`，这里没必要跟着）。
  @override
  EventFields get eventFields => const WireEventFields();
}
