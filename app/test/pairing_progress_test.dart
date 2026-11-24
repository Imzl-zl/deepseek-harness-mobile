/// 配对检测与回执落盘的 UI 回归；协议应答方复用既有 FakePc。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dsh_mobile/core/crypto.dart';
import 'package:dsh_mobile/core/frame.dart' show randomBytes;
import 'package:dsh_mobile/core/pairing.dart';
import 'package:dsh_mobile/core/pairing_client.dart';
import 'package:dsh_mobile/model/route_policy.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/pairing_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_pc.dart';

class PairingUiHarness {
  PairingUiHarness(this.offer, this.onPaired, {this.loadDeviceCode});
  static const pcSeed =
      'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1';
  final PairingOffer offer;
  final Future<void> Function(PairingResult) onPaired;
  final Future<String> Function()? loadDeviceCode;
  final urls = <String>[];
  final calls = <HttpCall>[];
  final ticket = Completer<HttpResult>();
  FakePc? pc;

  static Future<PairingUiHarness> create(
    Future<void> Function(PairingResult) onPaired, {
    bool relay = false,
    Future<String> Function()? loadDeviceCode,
  }) async {
    final identity = await deriveIdentity(pcSeed);
    return PairingUiHarness(
      PairingOffer(
        relayUrl: 'ws://127.0.0.1:8787',
        pcId: 'conn-1',
        pcSignPubHex: identity.sign.publicKeyHex,
        pcDhPubHex: identity.dh.publicKeyHex,
        offerId: 'zyXWvUTSrqPONMLKjihgfe',
        code: 'abL3sSH5gLJpTBBsqPUzJg',
        lanUrls: const ['ws://192.168.1.5:8790'],
        lanOnly: !relay,
      ),
      onPaired,
      loadDeviceCode: loadDeviceCode,
    );
  }

  Widget page() => MaterialApp(
    theme: DshTheme.dark(),
    home: PairingPage(
      onPaired: onPaired,
      loadDeviceCode: loadDeviceCode,
      send: (call) {
        calls.add(call);
        return ticket.future;
      },
      prefer: RoutePolicy.auto,
      allowInsecureLocal: true,
      transportFor: (url) {
        urls.add(url);
        final uri = Uri.parse(url);
        final encoded = uri.queryParameters['cand'];
        if (encoded == null) throw StateError('取消后不应建立中转候选');
        final candidate =
            jsonDecode(
                  utf8.decode(base64Url.decode(base64Url.normalize(encoded))),
                )
                as Map<String, dynamic>;
        return pc = FakePc(
          pcSeedHex: pcSeed,
          offer: offer,
          candidate: PairingCandidate(
            offerId: candidate['offerId'] as String,
            devPubEdHex: candidate['devPubEd'] as String,
            devPubDhHex: candidate['devPubDh'] as String,
            name: candidate['name'] as String,
          ),
        );
      },
    ),
  );

  String payload() => jsonEncode({
    'v': 2,
    'relay': offer.relayUrl,
    'pcId': offer.pcId,
    'pcPubEd': offer.pcSignPubHex,
    'pcPubDh': offer.pcDhPubHex,
    'offerId': offer.offerId,
    'code': offer.code,
    'lan': offer.lanUrls,
    if (offer.lanOnly) 'lanOnly': true,
  });

  Future<void> start(WidgetTester tester) async {
    await tester.pumpWidget(page());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), payload());
    await tester.tap(find.text('连接电脑'));
    await pump(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -700));
    await tester.pump(const Duration(milliseconds: 300));
    await pump(tester);
  }

  Future<void> pump(WidgetTester tester) async {
    for (var i = 0; i < 30; i += 1) {
      await tester.pump(const Duration(milliseconds: 1));
    }
  }

  Future<void> confirm(WidgetTester tester) async {
    final confirm = find.text('确认并配对');
    expect(confirm, findsOneWidget, reason: '已完成受限握手时显示确认卡');
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await pump(tester);
    await pc!.drain();
    await tester.runAsync(() async {
      await pumpEventQueue();
    });
    await pump(tester);
  }
}

void main() {
  testWidgets('局域网已通立即可确认，不等待挂起的中转换票', (tester) async {
    PairingResult? saved;
    final harness = await PairingUiHarness.create((result) async {
      saved = result;
    }, relay: true);
    try {
      await harness.start(tester);
      expect(harness.pc?.established, isTrue, reason: '真实协议握手已经成功');
      final buttons = tester.widgetList<FilledButton>(
        find.byType(FilledButton),
      );
      expect(
        buttons.any(
          (button) =>
              button.child is Text &&
              (button.child as Text).data == '确认并配对' &&
              button.onPressed != null,
        ),
        isTrue,
        reason: '可用直连不能被尚无结论的中转挡住确认',
      );
      await harness.confirm(tester);
      expect(saved, isNotNull, reason: '确认后回执立即进入持久化回调');
    } finally {
      await tester.pumpWidget(const SizedBox());
      if (!harness.ticket.isCompleted) {
        harness.ticket.complete(
          const HttpResult(
            status: 409,
            body: '{"error":"pairing-unavailable"}',
          ),
        );
      }
      await harness.pump(tester);
    }
  });

  testWidgets('成功回执立刻保存并连接，不需要再点完成', (tester) async {
    PairingResult? saved;
    final harness = await PairingUiHarness.create((result) async {
      saved = result;
    });
    await harness.start(tester);
    await harness.confirm(tester);
    expect(saved, isNotNull, reason: '回执不是只留在页面里等待下一次点击');
    expect(saved!.devId, await harness.pc!.candidate.deviceId());
    expect(find.text('完成'), findsNothing, reason: '用户已经确认授权，不再附加一次落盘门');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('本机保存失败明确说已登记，重试同一回执不重新提交秘密', (tester) async {
    final saved = <PairingResult>[];
    final harness = await PairingUiHarness.create((result) async {
      saved.add(result);
      if (saved.length == 1) throw StateError('secure-store-failure');
    });
    await harness.start(tester);
    await harness.confirm(tester);
    expect(saved, hasLength(1), reason: '成功回执即调用真实边界，而非再等完成按钮');
    expect(find.textContaining('电脑已经登记'), findsWidgets);
    final retry = find.text('重试保存并连接');
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await harness.pump(tester);
    expect(saved, hasLength(2));
    expect(saved[1], same(saved[0]), reason: '保留同一回执，不生成新密钥或签发新令牌');
    final commits = harness.pc!.lines.where(
      (line) =>
          (jsonDecode(line) as Map<String, dynamic>)['t'] == 'pair-commit',
    );
    expect(commits, hasLength(1), reason: '保存重试不是再次消费二维码授权');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('稳定设备码仅在加密提交过线，不进候选URL或匿名换票', (tester) async {
    final code = base64UrlNoPad(randomBytes(16));
    final harness = await PairingUiHarness.create(
      (_) async {},
      relay: true,
      loadDeviceCode: () async => code,
    );
    try {
      await harness.start(tester);
      await harness.confirm(tester);
      expect(
        harness.pc!.commitPayload?['deviceCode'],
        code,
        reason: '通过真实页面确认和受限加密通道送到电脑侧',
      );
      for (final url in harness.urls) {
        final encoded = Uri.parse(url).queryParameters['cand']!;
        final candidate =
            jsonDecode(
                  utf8.decode(base64Url.decode(base64Url.normalize(encoded))),
                )
                as Map<String, dynamic>;
        expect(candidate.containsKey('deviceCode'), isFalse);
      }
      expect(harness.calls, isNotEmpty);
      for (final call in harness.calls) {
        expect(call.body!.contains(code), isFalse);
      }
      expect(
        harness.pc!.lines.join().contains(code),
        isFalse,
        reason: '稳定定位码也不在转发明文里',
      );
    } finally {
      await tester.pumpWidget(const SizedBox());
      if (!harness.ticket.isCompleted) {
        harness.ticket.complete(
          const HttpResult(
            status: 409,
            body: '{"error":"pairing-unavailable"}',
          ),
        );
      }
      await harness.pump(tester);
    }
  });
}
