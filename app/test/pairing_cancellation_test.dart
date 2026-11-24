/// 候选取消不能被迟到的拨号结果复活。
library;

import 'dart:async';

import 'package:dsh_mobile/core/crypto.dart';
import 'package:dsh_mobile/core/pairing.dart';
import 'package:dsh_mobile/core/pairing_channel.dart';
import 'package:dsh_mobile/core/transport.dart';
import 'package:flutter_test/flutter_test.dart';

class LateTransport implements ChannelTransport {
  final ready = Completer<Stream<TransportEvent>>();
  final events = StreamController<TransportEvent>.broadcast();
  final List<String> sent = [];
  int connects = 0;

  @override
  Future<Stream<TransportEvent>> connect() {
    connects += 1;
    return ready.future;
  }

  @override
  bool send(String line) {
    sent.add(line);
    return true;
  }

  @override
  Future<void> close() async {}
}

void main() {
  test(
    '取消后的迟到 connect 不订阅、不发 hello、不重新启动握手',
    () async {
      final identity = await deriveIdentity('01' * 32);
      final pc = await deriveIdentity('a1' * 32);
      final offer = PairingOffer(
        relayUrl: 'ws://127.0.0.1:8787',
        pcId: 'conn-1',
        pcSignPubHex: pc.sign.publicKeyHex,
        pcDhPubHex: pc.dh.publicKeyHex,
        offerId: 'zyXWvUTSrqPONMLKjihgfe',
        code: 'abL3sSH5gLJpTBBsqPUzJg',
      );
      final candidate = offer.candidate(identity, '我的手机');
      final transport = LateTransport();
      final channel = PairingChannel(
        transport: transport,
        offer: offer,
        identity: identity,
        candidate: candidate,
        devId: await candidate.deviceId(),
      );
      final opening = channel.open();
      opening.ignore();
      await pumpEventQueue();
      expect(transport.connects, 1);
      await channel.close();
      transport.ready.complete(transport.events.stream);
      await expectLater(opening, throwsA(isA<TransportException>()));
      await pumpEventQueue();
      expect(
        transport.sent,
        isEmpty,
        reason: 'open 已取消，迟到 connect 没有权利再启动握手和计时器',
      );
      await transport.events.close();
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
