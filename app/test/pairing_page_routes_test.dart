/// 配对页**把"这张码有哪几条路"摆出来**（2026-11-04）。
///
/// 两件事必须让用户在拨号之前就看见：
/// - 电脑侧出码时没登记上中转 → 这张码**只能在同一 WiFi 下用**；
/// - 两条路都在 → 走哪两条、先试哪条、现在正在试哪条。
///
/// 判据是"用户看得见"：`Key('pairing-lan-only')` 与 `Key('pairing-stage')` 都真的在树上。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/core/pairing_client.dart';
import 'package:dsh_mobile/core/pairing_flow.dart';
import 'package:dsh_mobile/core/transport.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/pairing_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String _payload({List<String> lan = const [], bool lanOnly = false}) =>
    jsonEncode({
      'v': 2,
      'relay': 'wss://relay.example/ws/connector',
      'pcId': 'conn-1',
      'pcPubEd': 'aa' * 32,
      'pcPubDh': 'bb' * 32,
      'offerId': 'abL3sSH5gLJpTBBsqPUzJg',
      'code': 'zyXWvUTSrqPONMLKjihgfe',
      if (lan.isNotEmpty) 'lan': lan,
      if (lanOnly) 'lanOnly': true,
    });

Widget _page({
  required HttpSender send,
  required PairingTransportFactory transportFor,
  PairingPreference prefer = PairingPreference.auto,
}) => MaterialApp(
  theme: DshTheme.dark(),
  home: PairingPage(
    onPaired: (_) async {},
    send: send,
    transportFor: transportFor,
    prefer: prefer,
    // 局域网明文要放行，否则码里的 `lan` 会在解析时被丢掉（那是地址边界的正常行为）。
    allowInsecureLocal: true,
  ),
);

/// 一条拨不通的传输（局域网那条腿死掉时的形状）。
class _DeadTransport implements ChannelTransport {
  @override
  Future<Stream<TransportEvent>> connect() async =>
      throw const TransportException('建连失败：拨不通');

  @override
  bool send(String line) => false;

  @override
  Future<void> close() async {}
}

void main() {
  testWidgets('降级码：扫完就显式说"只能在同一 Wi-Fi 下使用"，不用等失败才猜', (tester) async {
    await tester.pumpWidget(
      _page(
        send: (HttpCall call) async =>
            throw const SocketException('Software caused connection abort'),
        transportFor: (_) => _DeadTransport(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      _payload(lan: ['ws://192.168.1.5:8790'], lanOnly: true),
    );
    await tester.tap(find.text('连接电脑'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('pairing-lan-only')), findsOneWidget);
    expect(
      find.textContaining('只能在同一 Wi-Fi 下使用'),
      findsWidgets,
      reason: '降级标要显示在二维码旁边/输入框下方，不是只进日志',
    );
    // 局域网那条也拨不通时，原因必须说"同一 WiFi"，而不是"重新出码"。
    expect(find.textContaining('只能在同一 WiFi 下使用'), findsWidgets);
  });

  testWidgets('两条路都在：说明两条路，并显示"正在试"哪一条', (tester) async {
    final gate = Completer<HttpResult>();
    await tester.pumpWidget(
      _page(
        // 中转优先：先换票（HTTP 卡在 gate 上，界面停在"正在试：换票…"）。
        prefer: PairingPreference.relay,
        send: (HttpCall call) => gate.future,
        transportFor: (_) => _DeadTransport(),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      _payload(lan: ['ws://192.168.1.5:8790']),
    );
    await tester.tap(find.text('连接电脑'));
    for (var i = 0; i < 8; i += 1) {
      await tester.pump();
    }

    expect(find.textContaining('这张码有两条路：局域网直连（1 个地址） · 中转。'), findsOneWidget);
    expect(find.byKey(const Key('pairing-stage')), findsOneWidget);
    expect(find.textContaining('正在试：换票…'), findsOneWidget);

    gate.complete(
      const HttpResult(status: 409, body: '{"error":"pairing-unavailable"}'),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('重新出码'), findsOneWidget);
  });
}
