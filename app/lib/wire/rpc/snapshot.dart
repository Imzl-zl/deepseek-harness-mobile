/// 只读快照的**一次调用 + 解码**（契约 §5.7 的 `digest` / `notModified`）。
///
/// ## 为什么要有这个 helper
///
/// 十个只读快照方法（`session.list` / `session.projections` / `settings.describe` /
/// `job.list` / `session.modelCatalog` / `permission.catalog` / `agentPresets.list` /
/// `workspace.list` / `repo.info` / `endpoint.describe`）本来各自写
/// "call + valueOrReport"，现在各自还要多两件事：带摘要、把"没变"当三态之一定下来。
/// 三处各写一遍就必然有一次写错，而写错的症状是**安静的**：
/// 把 `notModified` 当成"读不出"⇒ 界面报错；当成"空结果"⇒ 界面被清空。
///
/// ## 三态是必需的
///
/// - `body(value)`：拿到正文（`value` 可能是 `null` —— 那是**合法结论**，
///   如 `{available:false}` 或"没有这个会话的科目"）；
/// - `notModified`：服务端说"你手里那包就是最新的" ⇒ 调用方**什么都不做**；
/// - 解码失败仍然是 `body(null)` **加上** `valueOrReport` 的计数：
///   形状坏了要留声（`wire/reading.dart` 的口径），而它不该被当成"没变"。
///
/// Note: 摘要的键是 `(方法, 参数)`，由 `core/snapshot_digest.dart` 的
/// `snapshotKeyOf` 规范化 —— 分页后同方法不同参数是两个包，共用一个摘要就是错配。
library;

import '../../core/snapshot_call.dart';
import '../../core/snapshot_digest.dart';
import '../../core/sync_client.dart';
import '../reading.dart';

/// 带摘要地读一份只读快照。
///
/// [read] 是**纯解码**（`wire/reading.dart` 的口径）：它的 `WireBad` 会被计一次数
/// 并降级成 `null`，与逐面自己写 `valueOrReport` 时逐字相同。
Future<SnapshotReply<T>> loadSnapshot<T>(
  SyncClient client,
  String method,
  Map<String, Object?> params,
  WireReading<T> Function(Object? result) read,
) async {
  final reply = await client.callSnapshot(method, params);
  if (reply.notModified) return SnapshotReply<T>.notModified(key: reply.key);
  return SnapshotReply<T>.body(
    valueOrReport(read(reply.value), method),
    key: reply.key,
  );
}
