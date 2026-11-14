/// 按**用户想走哪条路**过滤候选端点（`model/route_policy.dart`）。
///
/// 这是"要不要试这条端点"的**唯一过滤点**：拨号（`core/endpoint_transport.dart`）
/// 与配对（`core/pairing_flow.dart` 的那两条腿）都从这里取候选，不再各写一份
/// "先直连还是先中转"的判据。
///
/// `auto` 的语义只有一条：**直连全部排在 relay 之前**。直连能不能通由竞速证明，
/// 不由网段推断（`myIpv4` 只用于多条直连之间的排序，见 `dialOrder`）。
library;

import '../model/route_policy.dart';
import 'endpoint.dart';

/// 过滤 + 定序。返回新列表，不改入参。
List<Endpoint> endpointsForPolicy(
  Iterable<Endpoint> endpoints, {
  required RoutePolicy policy,
}) {
  final direct = <Endpoint>[];
  final relay = <Endpoint>[];
  for (final endpoint in endpoints) {
    switch (endpoint.kind) {
      case EndpointKind.direct:
        if (policy != RoutePolicy.relayOnly) direct.add(endpoint);
      case EndpointKind.relay:
        if (policy != RoutePolicy.directOnly) relay.add(endpoint);
    }
  }
  // `auto` 与两档单一策略都按"直连在前"排；单一策略下另一半必为空。
  return <Endpoint>[...direct, ...relay];
}
