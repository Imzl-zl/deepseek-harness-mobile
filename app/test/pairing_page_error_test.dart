/// 配对页的**失败必须说出来**。
///
/// 2026-10-28 真机：扫了码点「连接电脑」，页面 2 秒后回到原样 —— 不弹、不连、没有原因。
/// 根因是换票走 `http.Client`，它抛的是 `SocketException` / `TimeoutException`
/// （Android 的明文拦截就是 `SocketException … errno = 103`），而页面只捕获
/// `ProtocolException` / `TransportException`，于是异常从异步里溜走、界面毫无反应。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_mobile/core/pairing_client.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/pairing_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一份形状合法的 v2 载荷（真值取自 `pairing_vectors_test.dart` 的 good 样本）。
String _payload({String relay = 'wss://relay.example/ws/connector'}) =>
    jsonEncode({
      'v': 2,
      'relay': relay,
      'pcId': 'conn-1',
      'pcPubEd': 'aa' * 32,
      'pcPubDh': 'bb' * 32,
      'offerId': 'abL3sSH5gLJpTBBsqPUzJg',
      'code': 'zyXWvUTSrqPONMLKjihgfe',
    });

Widget _page({required HttpSender send}) => MaterialApp(
  theme: DshTheme.dark(),
  home: PairingPage(
    onPaired: (_) async {},
    send: send,
    transportFor: (String _) => throw StateError('还没到建传输那一步'),
  ),
);

void main() {
  testWidgets('换票抛 SocketException（明文被拦）→ 页面显示原因，不是静默', (tester) async {
    await tester.pumpWidget(
      _page(
        send: (HttpCall call) async =>
            throw const SocketException('Software caused connection abort'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), _payload());
    await tester.tap(find.text('连接电脑'));
    await tester.pump();
    await tester.pumpAndSettle();

    // 判据是**用户看得见**：文案带"配对没走通"，而不是只剩一个空页面。
    expect(find.textContaining('配对没走通'), findsOneWidget);
    expect(
      find.textContaining('Software caused connection abort'),
      findsOneWidget,
    );
  });

  testWidgets('中转拒绝（401/409）→ 显示协议给的那句，并带错误码', (tester) async {
    await tester.pumpWidget(
      _page(
        send: (HttpCall call) async => const HttpResult(
          status: 409,
          body: '{"error":"pairing-unavailable"}',
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), _payload());
    await tester.tap(find.text('连接电脑'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.textContaining('重新出码'), findsOneWidget, reason: '原因要说人话');
    expect(
      find.textContaining('protocol/not-paired'),
      findsOneWidget,
      reason: '错误码带上',
    );
  });
}
