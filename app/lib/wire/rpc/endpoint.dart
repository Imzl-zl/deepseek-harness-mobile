/// **端点自报面**（`endpoint.describe`）的唯一入口。
///
/// 形状出处 `connector/src/endpoints.ts:31-40`：`{endpoints: [{kind, url, label?}]}`。
/// `kind` 只有 `relay` / `direct`；**顺序即偏好**（direct 先于 relay）。
///
/// ## 为什么这里不返回 `WireReading`
///
/// 这个方法的整条语义就是"**有可能没有**"：
/// - 老连接器没有这个方法（`connector/unsupported`，由调用方接住）；
/// - 有方法但这台机器一个直连面都没起 ⇒ `{endpoints: []}`。
///
/// 两种情形在手机上的正确表现是**同一句话**（"端点表就是配对时那一条"），
/// 所以包一层 `WireReading` 只会把"没有"和"读不懂"混成同一格 ——
/// 而这一层要解决的恰恰是"两者必须分开"。形状检查由
/// `core/endpoint.dart` 的 `parseEndpointList` / `endpointFromJson` 做
/// （认不出的条目跳过，不猜）。
///
/// Note: 布局与批次见 `.agents/notes/implemented/2026-10-25-wire-rpc-layer-layout.md`。
library;

import '../../core/endpoint.dart' show Endpoint, parseEndpointList;
import '../../core/sync_client.dart';

/// 方法名只在这里出现一次（`connector/src/handlers.ts:796`）。
const String _kDescribe = 'endpoint.describe';

/// 拉一次电脑侧自报的端点表（空表 = 这台没有可发现的端点）。
Future<List<Endpoint>> loadEndpoints(SyncClient client) async {
  final result = await client.call<Object?>(_kDescribe, const {});
  return parseEndpointList(result);
}
