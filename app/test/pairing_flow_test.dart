/// 配对链编排的单测（规格 `docs/subsystems/pairing-v2.md` §5）。
///
/// ## 它验的是"顺序与接线"，不是密码学
///
/// 这一层把四件事串起来：**换票(候选) → 带票升级 → 受限握手 → 提交秘密**，
/// 而其中最关键的一点是**分两段**：`beginPairing` 走到"通道已就绪、秘密未发"就停下，
/// 配对码要等 [PairingAttempt.commit] 才出去（v2 的硬不变量：用户确认前不发秘密）。
///
/// 所以这里的断言是"**确认之前，电脑侧一个字节的秘密都没收到**"——
/// 把两段合成一段的写法照样能"配对成功"，差别只在这一条断言上。
///
/// ## 三个缝都是注入的
///
/// HTTP、传输（真实 socket）、帧 id/临时密钥/nonce（确定化），所以这条链在毫秒内跑完，
/// 而"升级 URL 是不是带上了票""换票请求里有没有秘密"这类**只在真机上才暴露的接线错误**
/// 在这里就能钉住。电脑侧那一半由 `test/support/fake_pc.dart` 说。
library;

import 'dart:convert';

import 'package:dsh_mobile/core/crypto.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/pairing.dart';
import 'package:dsh_mobile/core/pairing_client.dart';
import 'package:dsh_mobile/core/pairing_flow.dart';
import 'package:dsh_mobile/core/transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_pc.dart';

const _phoneSeed =
    '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20';
const _pcSeed =
    'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1';

/// 记账用的假 HTTP：记下每一次调用，回一张固定的票。
class _TicketRecorder {
  _TicketRecorder([this.responses = const []]);

  final List<HttpResult> responses;
  final List<HttpCall> calls = [];

  Future<HttpResult> call(HttpCall request) async {
    calls.add(request);
    if (responses.isEmpty) {
      return const HttpResult(
        status: 201,
        body: '{"ticket":"TICKET-1","expiresAt":7}',
      );
    }
    final index = calls.length - 1;
    return responses[index < responses.length ? index : responses.length - 1];
  }
}

void main() {
  late IdentityKeys identity;
  late PairingOffer offer;

  setUp(() async {
    identity = await deriveIdentity(_phoneSeed);
    final pc = await deriveIdentity(_pcSeed);
    offer = PairingOffer(
      // **带路径**：配置里 relayUrl 常写成 `/ws/connector`（那是电脑侧拨号用的那条路）。
      // 手机侧必须丢掉它 —— 否则会拼出 `/ws/connector/ws/device`（404）。
      relayUrl: 'ws://127.0.0.1:8787/ws/connector',
      pcId: 'conn-1',
      pcSignPubHex: pc.sign.publicKeyHex,
      pcDhPubHex: pc.dh.publicKeyHex,
      offerId: 'zyXWvUTSrqPONMLKjihgfe',
      code: 'abL3sSH5gLJpTBBsqPUzJg',
    );
  });

  /// 起一条链：假 HTTP + 电脑侧替身。返回替身与"见过的升级 URL"。
  ///
  /// `beginPairing` 的产物挂在 [attemptOf] 上（Dart 的记录类型塞不下它，
  /// 而调用方需要它来 `commit`）。
  final attemptOf = <FakePc, PairingAttempt>{};

  Future<({FakePc pc, List<String> urls})> begin({
    required _TicketRecorder http,
    void Function(String stage)? onStage,
    Map<String, Object?>? commitFailure,
  }) async {
    final urls = <String>[];
    final candidate = offer.candidate(identity, '我的手机');
    final pc = FakePc(
      pcSeedHex: _pcSeed,
      offer: offer,
      candidate: candidate,
      commitFailure: commitFailure,
    );
    final attempt = await beginPairing(
      offer: offer,
      identity: identity,
      deviceName: '我的手机',
      send: http.call,
      transportFor: (url) {
        urls.add(url);
        return pc;
      },
      onStage: onStage,
      // 测试里的中转是明文 `ws://127.0.0.1`：显式开启本机调试（生产只认 wss）。
      allowInsecureLocal: true,
      newFrameIdHex: () => 'p1',
      newEphemeralSeedHex: () => 'e5' * 32,
      newNonceHex: () => 'a7' * 32,
    );
    addTearDown(attempt.cancel);
    attemptOf[pc] = attempt;
    return (pc: pc, urls: urls);
  }

  test('顺序：先换票（不带头、不带秘密），再带票升级，最后才提交', () async {
    final http = _TicketRecorder();
    final stages = <String>[];
    final chain = await begin(http: http, onStage: stages.add);

    // 换票**只调一次**，走根上的 `/ws-ticket`，body 是候选身份（没有秘密）。
    expect(http.calls, hasLength(1));
    expect(http.calls.single.url, 'http://127.0.0.1:8787/ws-ticket');
    expect(http.calls.single.headers.containsKey('authorization'), isFalse);
    final body = jsonDecode(http.calls.single.body!) as Map<String, Object?>;
    expect(body['offerId'], offer.offerId);
    expect(body['devPubEd'], identity.sign.publicKeyHex);
    expect(body.containsKey('code'), isFalse);
    expect(http.calls.single.body, isNot(contains(offer.code)));

    // 升级 URL 带着刚换到的票，且**路径在根上**。
    expect(chain.urls.single, 'ws://127.0.0.1:8787/ws/device?ticket=TICKET-1');
    // 老载荷（没有 lan）走中转：确认卡上写的就是"中转 + 根地址"，不是带票的拨号地址。
    expect(attemptOf[chain.pc]!.dial, PairingDial.relay);
    expect(attemptOf[chain.pc]!.dialUrl, offer.relayUrl);

    // **确认之前**：电脑侧只收到握手两帧，一个字节的秘密都没有。
    await chain.pc.drain();
    final types = chain.pc.lines
        .map((line) => (jsonDecode(line.trim()) as Map<String, Object?>)['t'])
        .toList();
    expect(types, ['hello', 'confirm']);
    expect(chain.pc.commitPayload, isNull);
    expect(
      chain.pc.lines.join().contains(offer.code),
      isFalse,
      reason: '用户还没确认，配对码不该出现在任何一帧里',
    );

    // 进度文案要覆盖前三步（用户该看到自己在哪一步）。
    expect(stages, containsAllInOrder(['换票…', '连接电脑…', '等待你确认']));
  });

  test('确认提交：秘密经密文过去，回执被解析成结构化结果', () async {
    final http = _TicketRecorder();
    final chain = await begin(http: http);
    final attempt = attemptOf[chain.pc]!;

    final ack = await attempt.commit();

    expect(chain.pc.commitPayload, {
      'v': 2,
      'offerId': offer.offerId,
      'code': offer.code,
    });
    expect(ack.devId, isNotEmpty);
    expect(ack.sas, matches(RegExp(r'^\d{6}$')));
    expect(ack.pcId, 'conn-1');
    expect(ack.deviceToken, isNotEmpty);
    expect(ack.refreshToken, isNotEmpty);
  });

  test('重新配对：previousPairingId 经密文过去，换票请求里没有它', () async {
    final http = _TicketRecorder();
    final chain = await begin(http: http);
    final attempt = attemptOf[chain.pc]!;

    await attempt.commit(previousPairingId: 'x' * 43);

    expect(chain.pc.commitPayload, {
      'v': 2,
      'offerId': offer.offerId,
      'code': offer.code,
      'previousPairingId': 'x' * 43,
    });
    // 换票那一跳是**匿名**的（此刻还没有任何凭据）：previousPairingId 只进
    // `pair-commit` 的密文，不进 `/ws-ticket` 的 body —— 中转不该看见它。
    final ticket = jsonDecode(http.calls.single.body!) as Map<String, Object?>;
    expect(ticket.containsKey('previousPairingId'), isFalse);
  });

  test('提交默认用二维码里那个码；显式传码是"提交错码"的场景', () async {
    final http = _TicketRecorder();
    final chain = await begin(
      http: http,
      commitFailure: <String, Object?>{
        'ok': false,
        'reason': '配对秘密或连接身份不匹配，请重新核对二维码',
      },
    );
    final attempt = attemptOf[chain.pc]!;

    await expectLater(
      attempt.commit(code: 'wrong-code'),
      throwsA(
        isA<ProtocolException>().having(
          (e) => e.message,
          'message',
          '配对秘密或连接身份不匹配，请重新核对二维码',
        ),
      ),
    );
    expect(chain.pc.commitPayload!['code'], 'wrong-code');
  });

  test('换票被拒时**不建连**（凭据没拿到就不该去拨号）', () async {
    final http = _TicketRecorder(const [
      HttpResult(status: 409, body: '{"error":"pairing-unavailable"}'),
    ]);
    var dialed = false;
    await expectLater(
      beginPairing(
        offer: offer,
        identity: identity,
        deviceName: '我的手机',
        send: http.call,
        allowInsecureLocal: true,
        transportFor: (_) {
          dialed = true;
          return FakePc(
            pcSeedHex: _pcSeed,
            offer: offer,
            candidate: offer.candidate(identity, '我的手机'),
          );
        },
      ),
      throwsA(isA<ProtocolException>()),
    );
    expect(dialed, isFalse, reason: '没换到票就不该去升级（那必然是一个 401）');
  });

  test('用户放弃：cancel 之后提交必失败，且电脑侧没收到秘密', () async {
    final http = _TicketRecorder();
    final chain = await begin(http: http);
    final attempt = attemptOf[chain.pc]!;

    await attempt.cancel();
    await expectLater(attempt.commit(), throwsA(isA<ProtocolException>()));
    await chain.pc.drain();
    expect(chain.pc.commitPayload, isNull, reason: '取消之后一个字节的秘密都不该出去');
  });

  test('升级地址必须**丢掉路径**（配置里那条是电脑侧拨号用的）', () async {
    final http = _TicketRecorder();
    final chain = await begin(http: http);
    expect(
      chain.urls.single,
      startsWith('ws://127.0.0.1:8787/ws/device?ticket='),
    );
    expect(chain.urls.single, isNot(contains('/ws/connector')));
  });

  // ---- 局域网直连（二维码的 `lan`）：同一套帧，不经过中转 ----

  /// 同一张码，但电脑侧报了一组局域网地址。
  PairingOffer offerWithLan(List<String> lan, {bool lanOnly = false}) =>
      PairingOffer(
        relayUrl: offer.relayUrl,
        pcId: offer.pcId,
        pcSignPubHex: offer.pcSignPubHex,
        pcDhPubHex: offer.pcDhPubHex,
        offerId: offer.offerId,
        code: offer.code,
        lanUrls: lan,
        lanOnly: lanOnly,
      );

  test('局域网：有 lan 就先拨它，全程不换票，帧序列与中转那条完全一样', () async {
    final lan = offerWithLan(['ws://192.168.1.5:8790']);
    final http = _TicketRecorder();
    final urls = <String>[];
    final candidate = lan.candidate(identity, '我的手机');
    final pc = FakePc(pcSeedHex: _pcSeed, offer: lan, candidate: candidate);
    final attempt = await beginPairing(
      offer: lan,
      identity: identity,
      deviceName: '我的手机',
      send: http.call,
      transportFor: (url) {
        urls.add(url);
        return pc;
      },
      allowInsecureLocal: true,
      newFrameIdHex: () => 'p1',
      newEphemeralSeedHex: () => 'e5' * 32,
      newNonceHex: () => 'a7' * 32,
    );
    addTearDown(attempt.cancel);

    expect(http.calls, isEmpty, reason: '局域网直连不需要换票 —— 那一步就是中转');
    expect(attempt.dial, PairingDial.lan, reason: '确认卡要如实说这次走的是局域网');
    expect(attempt.dialUrl, 'ws://192.168.1.5:8790');
    expect(urls, hasLength(1));
    final dial = Uri.parse(urls.single);
    expect(dial.scheme, 'ws');
    expect(dial.host, '192.168.1.5');
    expect(dial.port, 8790);
    expect(dial.queryParameters['pair'], lan.offerId);

    // 候选身份随请求过去（握手第一步就要用它验签），且里面**没有秘密**。
    final wire =
        jsonDecode(
              utf8.decode(
                base64Url.decode(
                  base64Url.normalize(dial.queryParameters['cand']!),
                ),
              ),
            )
            as Map<String, Object?>;
    expect(wire['offerId'], lan.offerId);
    expect(wire['devPubEd'], identity.sign.publicKeyHex);
    expect(wire['devPubDh'], identity.dh.publicKeyHex);
    expect(wire['name'], '我的手机');
    expect(wire.containsKey('code'), isFalse, reason: '候选身份里不许有秘密');

    // **帧本身没改**：局域网只是换了传输。
    await pc.drain();
    final types = pc.lines
        .map((line) => (jsonDecode(line.trim()) as Map<String, Object?>)['t'])
        .toList();
    expect(types, ['hello', 'confirm']);
    expect(pc.lines.join().contains(lan.code), isFalse);

    final ack = await attempt.commit();
    expect(ack.devId, await candidate.deviceId());
  });

  test('局域网全拨不通：回落换票，最终错误里点出"局域网也没通"', () async {
    final lan = offerWithLan(['ws://192.168.1.5:8790']);
    final http = _TicketRecorder(const [
      HttpResult(status: 409, body: '{"error":"pairing-unavailable"}'),
    ]);
    final urls = <String>[];
    await expectLater(
      beginPairing(
        offer: lan,
        identity: identity,
        deviceName: '我的手机',
        send: http.call,
        allowInsecureLocal: true,
        transportFor: (url) {
          urls.add(url);
          return _DeadTransport();
        },
      ),
      throwsA(
        isA<ProtocolException>()
            // **错误码不能丢**（`clientAction` 靠它决定"重扫"还是"重试"）。
            .having((e) => e.code, 'code', ErrorCode.notPaired)
            .having((e) => e.message, 'message', contains('局域网直连没通（1 个地址）')),
      ),
    );
    expect(urls, hasLength(1), reason: '换票被拒就不该再去建连');
    expect(http.calls, hasLength(1), reason: '局域网失败之后要真的回落去换票');
  });

  test('局域网：一条拨不通就换下一条（电脑侧给的顺序即偏好）', () async {
    final lan = offerWithLan(['ws://10.0.0.7:8790', 'ws://192.168.1.5:8790']);
    final http = _TicketRecorder();
    final urls = <String>[];
    final candidate = lan.candidate(identity, '我的手机');
    final pc = FakePc(pcSeedHex: _pcSeed, offer: lan, candidate: candidate);
    final attempt = await beginPairing(
      offer: lan,
      identity: identity,
      deviceName: '我的手机',
      send: http.call,
      transportFor: (url) {
        urls.add(url);
        return url.startsWith('ws://10.0.0.7') ? _DeadTransport() : pc;
      },
      allowInsecureLocal: true,
      newFrameIdHex: () => 'p1',
      newEphemeralSeedHex: () => 'e5' * 32,
      newNonceHex: () => 'a7' * 32,
    );
    addTearDown(attempt.cancel);

    expect(urls, hasLength(2));
    expect(urls[0], startsWith('ws://10.0.0.7:8790'));
    expect(urls[1], startsWith('ws://192.168.1.5:8790'));
    expect(http.calls, isEmpty, reason: '第二条通了就不该再走中转');
  });

  test('局域网：同一 /24 的那条先拨（换 WiFi 之后不用用户手动排）', () async {
    final lan = offerWithLan(['ws://10.0.0.7:8790', 'ws://192.168.1.5:8790']);
    final http = _TicketRecorder();
    final urls = <String>[];
    final candidate = lan.candidate(identity, '我的手机');
    final pc = FakePc(pcSeedHex: _pcSeed, offer: lan, candidate: candidate);
    final attempt = await beginPairing(
      offer: lan,
      identity: identity,
      deviceName: '我的手机',
      send: http.call,
      transportFor: (url) {
        urls.add(url);
        return pc;
      },
      allowInsecureLocal: true,
      // 本机在 192.168.1.0/24 上：那条应当被提到最前面。
      myIpv4: '192.168.1.23',
      newFrameIdHex: () => 'p1',
      newEphemeralSeedHex: () => 'e5' * 32,
      newNonceHex: () => 'a7' * 32,
    );
    addTearDown(attempt.cancel);

    expect(urls.single, startsWith('ws://192.168.1.5:8790'));
    expect(http.calls, isEmpty, reason: '同一 /24 直连通了就不该再换票');
  });

  // ---- 降级码（`lanOnly`）：只有局域网那条路 ----

  test('降级码 + 局域网不通：不换票，直接说"只能在同一 WiFi 下使用"', () async {
    final lan = offerWithLan(['ws://192.168.1.5:8790'], lanOnly: true);
    final http = _TicketRecorder();
    await expectLater(
      beginPairing(
        offer: lan,
        identity: identity,
        deviceName: '我的手机',
        send: http.call,
        allowInsecureLocal: true,
        transportFor: (_) => _DeadTransport(),
      ),
      throwsA(
        isA<TransportException>().having(
          (e) => e.message,
          'message',
          contains('只能在同一 WiFi 下使用'),
        ),
      ),
    );
    // **不换票**：那张码这次没在中转登记，换票只会拿到 409 ——
    // 多一次请求只会把"不在同一个 WiFi"说成"重新出码"。
    expect(http.calls, isEmpty);
  });

  test('降级码 + 局域网通：照常配对（只是没有中转那条腿）', () async {
    final lan = offerWithLan(['ws://192.168.1.5:8790'], lanOnly: true);
    final http = _TicketRecorder();
    final candidate = lan.candidate(identity, '我的手机');
    final pc = FakePc(pcSeedHex: _pcSeed, offer: lan, candidate: candidate);
    final attempt = await beginPairing(
      offer: lan,
      identity: identity,
      deviceName: '我的手机',
      send: http.call,
      allowInsecureLocal: true,
      transportFor: (_) => pc,
      newFrameIdHex: () => 'p1',
      newEphemeralSeedHex: () => 'e5' * 32,
      newNonceHex: () => 'a7' * 32,
    );
    addTearDown(attempt.cancel);

    expect(attempt.dial, PairingDial.lan);
    expect(http.calls, isEmpty);
  });

  // ---- 拨号顺序偏好（`device.pairing_prefer`）：只改顺序，失败仍回落 ----

  test('中转优先：两条都在也先换票；局域网那条一个都不拨', () async {
    final lan = offerWithLan(['ws://192.168.1.5:8790']);
    final http = _TicketRecorder();
    final urls = <String>[];
    final candidate = lan.candidate(identity, '我的手机');
    final pc = FakePc(pcSeedHex: _pcSeed, offer: lan, candidate: candidate);
    final attempt = await beginPairing(
      offer: lan,
      identity: identity,
      deviceName: '我的手机',
      send: http.call,
      transportFor: (url) {
        urls.add(url);
        return pc;
      },
      allowInsecureLocal: true,
      prefer: PairingPreference.relay,
      newFrameIdHex: () => 'p1',
      newEphemeralSeedHex: () => 'e5' * 32,
      newNonceHex: () => 'a7' * 32,
    );
    addTearDown(attempt.cancel);

    expect(http.calls, hasLength(1), reason: '中转优先：先换票');
    expect(attempt.dial, PairingDial.relay);
    expect(urls.single, startsWith('ws://127.0.0.1:8787/ws/device?ticket='));
  });

  test('中转优先 + 中转失败：仍回落到局域网直连（"失败仍回落"是前提）', () async {
    final lan = offerWithLan(['ws://192.168.1.5:8790']);
    final http = _TicketRecorder(const [
      HttpResult(status: 409, body: '{"error":"pairing-unavailable"}'),
    ]);
    final urls = <String>[];
    final candidate = lan.candidate(identity, '我的手机');
    final pc = FakePc(pcSeedHex: _pcSeed, offer: lan, candidate: candidate);
    final attempt = await beginPairing(
      offer: lan,
      identity: identity,
      deviceName: '我的手机',
      send: http.call,
      transportFor: (url) {
        urls.add(url);
        return pc;
      },
      allowInsecureLocal: true,
      prefer: PairingPreference.relay,
      newFrameIdHex: () => 'p1',
      newEphemeralSeedHex: () => 'e5' * 32,
      newNonceHex: () => 'a7' * 32,
    );
    addTearDown(attempt.cancel);

    expect(http.calls, hasLength(1));
    expect(urls.single, startsWith('ws://192.168.1.5:8790'));
    expect(attempt.dial, PairingDial.lan);
  });

  test('自动 + 不同网段：先中转（出门在外不该先为局域网白等一个超时）', () async {
    final lan = offerWithLan(['ws://192.168.1.5:8790']);
    final http = _TicketRecorder();
    final urls = <String>[];
    final candidate = lan.candidate(identity, '我的手机');
    final pc = FakePc(pcSeedHex: _pcSeed, offer: lan, candidate: candidate);
    final attempt = await beginPairing(
      offer: lan,
      identity: identity,
      deviceName: '我的手机',
      send: http.call,
      transportFor: (url) {
        urls.add(url);
        return pc;
      },
      allowInsecureLocal: true,
      // 本机在 10.0.0.0/24，而码里只有 192.168.1.5。
      myIpv4: '10.0.0.7',
      newFrameIdHex: () => 'p1',
      newEphemeralSeedHex: () => 'e5' * 32,
      newNonceHex: () => 'a7' * 32,
    );
    addTearDown(attempt.cancel);

    expect(http.calls, hasLength(1));
    expect(attempt.dial, PairingDial.relay);
  });
}

/// 一条**拨不通**的传输：局域网地址死掉时 `connect()` 抛（与真机上的超时/拒绝同形）。
class _DeadTransport implements ChannelTransport {
  @override
  Future<Stream<TransportEvent>> connect() async =>
      throw const TransportException('建连失败：拨不通');

  @override
  bool send(String line) => false;

  @override
  Future<void> close() async {}
}
