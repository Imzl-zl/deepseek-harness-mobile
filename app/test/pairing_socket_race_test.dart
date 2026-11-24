/// 真 socket 回归：成功的局域网配对不能被半开的另一地址阻塞。
library;

import 'dart:async';
import 'dart:io';

import 'package:dsh_mobile/core/crypto.dart';
import 'package:dsh_mobile/core/pairing.dart';
import 'package:dsh_mobile/core/pairing_flow.dart';
import 'package:dsh_mobile/core/transport.dart';
import 'package:dsh_mobile/model/route_policy.dart';
import 'package:dsh_mobile/platform/websocket_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_pc.dart';

void main() {
  test(
    '半开 WebSocket：close 立即完成且在途拨号立即失败',
    () async {
      final hanging = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requested = Completer<void>();
      final incoming = hanging.listen((request) {
        if (!requested.isCompleted) requested.complete();
        // 接住 TCP/HTTP 升级请求，但不回 101。
      });
      final transport = WebSocketTransport(
        WebSocketTransportOptions(url: 'ws://127.0.0.1:${hanging.port}/ws'),
      );
      final connecting = transport.connect();
      Object? cancelled;
      unawaited(
        connecting.then<void>(
          (_) {},
          onError: (Object error) {
            cancelled = error;
          },
        ),
      );
      addTearDown(() async {
        await incoming.cancel();
        await hanging.close(force: true);
        await connecting.then((_) {}, onError: (Object _) {});
      });
      await requested.future.timeout(const Duration(seconds: 5));

      var closed = false;
      unawaited(
        transport.close().then<void>((_) {
          closed = true;
        }),
      );
      await pumpEventQueue();
      expect(closed, isTrue, reason: '配对赢家在等输家 close；关闭不能等待还没连上的 sink');
      expect(
        cancelled,
        isA<TransportException>(),
        reason: '取消要使在途 connect 失败，而不是等原建连超时',
      );
      expect(transport.send('x\n'), isFalse);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('局域网已握手成功：另一地址不回升级应答也能立即确认配对', () async {
    const pcSeed =
        'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1';
    final identity = await deriveIdentity('01' * 32);
    final pcIdentity = await deriveIdentity(pcSeed);
    final hanging = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final working = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final hangingRequested = Completer<void>();
    final incoming = hanging.listen((request) {
      if (!hangingRequested.isCompleted) hangingRequested.complete();
    });
    final offer = PairingOffer(
      relayUrl: 'ws://127.0.0.1:8787',
      pcId: 'conn-1',
      pcSignPubHex: pcIdentity.sign.publicKeyHex,
      pcDhPubHex: pcIdentity.dh.publicKeyHex,
      offerId: 'zyXWvUTSrqPONMLKjihgfe',
      code: 'abL3sSH5gLJpTBBsqPUzJg',
      lanUrls: [
        'ws://127.0.0.1:${hanging.port}',
        'ws://127.0.0.1:${working.port}',
      ],
      lanOnly: true,
    );
    final pc = FakePc(
      pcSeedHex: pcSeed,
      offer: offer,
      candidate: offer.candidate(identity, '我的手机'),
    );
    final established = Completer<void>();
    WebSocket? peer;
    StreamSubscription<TransportEvent>? responses;
    final requests = working.listen((request) async {
      // 赢家回话前，先确认输家真的已进入网络升级等待。
      await hangingRequested.future;
      final socket = await WebSocketTransformer.upgrade(request);
      peer = socket;
      responses = (await pc.connect()).listen((event) {
        if (event is TransportMessage) socket.add(event.chunk);
      });
      socket.listen((dynamic line) async {
        await pc.receive('$line');
        if (pc.established && !established.isCompleted) established.complete();
      });
    });
    PairingAttempt? attempt;
    final pairing =
        beginPairing(
          offer: offer,
          identity: identity,
          deviceName: '我的手机',
          send: (_) async => throw StateError('局域网配对不能换票'),
          transportFor: (url) =>
              WebSocketTransport(WebSocketTransportOptions(url: url)),
          allowInsecureLocal: true,
          prefer: RoutePolicy.directOnly,
        ).then((value) {
          attempt = value;
          return value;
        });
    pairing.ignore();
    addTearDown(() async {
      await incoming.cancel();
      await hanging.close(force: true);
      await peer?.close();
      await requests.cancel();
      await working.close(force: true);
      await attempt?.cancel();
      await responses?.cancel();
      await pc.close();
    });
    await established.future.timeout(const Duration(seconds: 5));
    await pumpEventQueue();
    expect(attempt, isNotNull, reason: '真实握手已完成，确认卡不该等另一地址的永不完成 sink.close');
    expect(attempt!.dialUrl, offer.lanUrls.last);
    expect(pc.commitPayload, isNull, reason: '没有用户确认时绝不发送秘密');
    final ack = await attempt!.commit();
    expect(ack.devId, await offer.candidate(identity, '我的手机').deviceId());
    expect(pc.commitPayload?['code'], offer.code);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
