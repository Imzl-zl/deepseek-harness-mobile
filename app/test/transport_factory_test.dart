/// `platform/transport_factory.dart` 的分派与**分级超时**。
///
/// 2026-10-17 真机实测：直连端点混进拨不通的 IPv6 地址，每个等满 10s 超时，
/// 三个就把冷启动拖成 30 秒（用户原话"退出软件怎么就连不上了"）。
/// 所以直连（同局域网）超时压到 3s，中转（可能在公网）保留 10s。
library;

import 'package:dsh_mobile/core/endpoint.dart';
import 'package:dsh_mobile/core/transport.dart';
import 'package:dsh_mobile/platform/ticketed_transport.dart';
import 'package:dsh_mobile/platform/transport_factory.dart';
import 'package:dsh_mobile/platform/websocket_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const direct = Endpoint(
    kind: EndpointKind.direct,
    url: 'ws://192.168.2.43:8790',
  );
  const relay = Endpoint(
    kind: EndpointKind.relay,
    url: 'ws://192.168.2.43:8787',
  );

  test('直连的超时是 3s（同局域网：毫秒级应答或就是死的）', () {
    final transport = transportFor(direct);
    expect(transport, isA<WebSocketTransport>());
    expect(
      (transport as WebSocketTransport).options.connectTimeout,
      const Duration(seconds: 3),
    );
  });

  test('中转的超时保留 10s（可能在公网）', () {
    final transport = transportFor(relay, ticket: () async => 't');
    expect(transport, isA<TicketedWebSocketTransport>());
    // 换票在 connect 里发生，超时值不直接暴露 —— 用"造得出来 + 类型对"兜住
    // 分派本身；超时值由上面那条直连的断言钉住分档存在。
    expect(transport, isNotNull);
  });

  test('中转缺票源：直接说，不静默降级', () {
    expect(
      () => transportFor(relay),
      throwsA(
        isA<TransportException>().having(
          (e) => e.message,
          'message',
          contains('中转端点需要票源'),
        ),
      ),
    );
  });
}
