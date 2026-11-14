/// 「连接方式」策略的**唯一过滤点**（`core/endpoint_policy.dart`）。
///
/// 这里钉住三件事：
/// 1. `auto` 下直连整体排在中转之前 —— 这是 2026-11-13 分桶改动的核心；
/// 2. 两档单一策略下另一半**不进候选集合**（不是"排后面"，是根本不试）；
/// 3. 过滤不改入参顺序之外的任何东西（纯函数，返回新列表）。
library;

import 'package:dsh_mobile/core/endpoint.dart';
import 'package:dsh_mobile/core/endpoint_policy.dart';
import 'package:dsh_mobile/model/route_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const direct = Endpoint(
    kind: EndpointKind.direct,
    url: 'ws://192.168.2.71:8790',
  );
  const relay = Endpoint(kind: EndpointKind.relay, url: 'wss://relay.example');
  const other = Endpoint(kind: EndpointKind.direct, url: 'ws://10.0.0.9:8790');

  List<String> urls(List<Endpoint> list) => [for (final e in list) e.url];

  test('auto：直连整体排在中转之前（入参顺序不重要）', () {
    final out = endpointsForPolicy([
      relay,
      other,
      direct,
    ], policy: RoutePolicy.auto);
    expect(urls(out), [other.url, direct.url, relay.url]);
  });

  test('auto：只有中转时原样返回', () {
    final out = endpointsForPolicy([relay], policy: RoutePolicy.auto);
    expect(urls(out), [relay.url]);
  });

  test('只用直连：中转不进候选（不是排后面，是根本不试）', () {
    final out = endpointsForPolicy([
      relay,
      direct,
    ], policy: RoutePolicy.directOnly);
    expect(urls(out), [direct.url]);
  });

  test('只用中转：直连不进候选', () {
    final out = endpointsForPolicy([
      direct,
      relay,
    ], policy: RoutePolicy.relayOnly);
    expect(urls(out), [relay.url]);
  });

  test('不改入参（纯函数）', () {
    final input = [relay, direct];
    endpointsForPolicy(input, policy: RoutePolicy.auto);
    expect(urls(input), [relay.url, direct.url], reason: '调用方手里的表不被就地重排');
  });
}
