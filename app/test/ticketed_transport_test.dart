/// 带票传输的单测（契约 §2 的连接建立）。
///
/// ## 这一组钉住的是**票**，不是 URL
///
/// 升级 URL 的形状归 `core/endpoint.dart`（唯一 owner），断言在 `endpoint_test.dart`。
/// 这里只管票的两条纪律：
///
/// 1. **每次建连换一张**（见 `ticketed_transport_test` 的调用点与连接层）：
///    票一次性，而连接层退避后会反复重连 —— 换一次就复用的话，第二次重连必然 401，
///    症状是"用一会儿就再也连不上"。
/// 2. **换票失败要如实抛**，不静默降级成"连根路径试试"（那必然 404，
///    而错误信息会指向连接失败，真因却是凭据）。
library;

import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/transport.dart';
import 'package:dsh_mobile/platform/ticketed_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('换票失败要如实抛，不静默降级', () {
    test('换票被拒：抛 TransportException，带原始错误信息与错误码', () async {
      // **允许连接层按退避重试**是对的处置；但错误信息必须能分辨
      // "凭据不对"与"网络不通" —— 否则 401 会被当成网络问题查半天。
      //
      // **错误码必须带上**（议题 2 的真因）：丢码 = 连接层把"身份不被认"
      // 与"中转不可达"看成一回事 → 永远退避重连 → 用户卡在"重连中…"。
      final transport = TicketedWebSocketTransport(
        endpoint: 'ws://127.0.0.1:1',
        ticket: () async => throw const ProtocolException(
          ErrorCode.notPaired,
          '换票被拒（HTTP 401）：{"error":"unauthorized"}',
        ),
      );

      await expectLater(
        transport.connect(),
        throwsA(
          isA<TransportException>()
              .having(
                (e) => e.message,
                'message',
                allOf(contains('换票失败'), contains('401')),
              )
              .having((e) => e.code, 'code', ErrorCode.notPaired),
        ),
      );
    });

    test('429 限流：透传 rateLimited 码（**不是** notPaired，连接层会退避）', () async {
      // 限流是"稍后重试"，不是"永久失败"—— 两者客户端动作不同
      // （`backoffRetry` vs `rePair`），所以码必须分开透传。
      final transport = TicketedWebSocketTransport(
        endpoint: 'ws://127.0.0.1:1',
        ticket: () async => throw const ProtocolException(
          ErrorCode.rateLimited,
          '换票被拒（HTTP 429）',
        ),
      );

      await expectLater(
        transport.connect(),
        throwsA(
          isA<TransportException>().having(
            (e) => e.code,
            'code',
            ErrorCode.rateLimited,
          ),
        ),
      );
    });

    test('换票抛别的异常时原样冒出去（不吞、不假装成连不上）', () async {
      final transport = TicketedWebSocketTransport(
        endpoint: 'ws://127.0.0.1:1',
        ticket: () async => throw StateError('DNS 挂了'),
      );
      await expectLater(transport.connect(), throwsA(isA<StateError>()));
    });
  });

  group('未建连时的行为', () {
    test('没连上就 send：如实回 false（不是"发出去了"）', () {
      final transport = TicketedWebSocketTransport(
        endpoint: 'ws://127.0.0.1:1',
        ticket: () async => 'T1',
      );
      expect(transport.send('{"v":1}\n'), isFalse);
    });

    test('close 是幂等的（没连过也能关）', () async {
      final transport = TicketedWebSocketTransport(
        endpoint: 'ws://127.0.0.1:1',
        ticket: () async => 'T1',
      );
      await transport.close();
      await transport.close();
    });
  });
}
