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

import 'dart:async';
import 'dart:convert';

import 'package:dsh_mobile/core/crypto.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/pairing.dart';
import 'package:dsh_mobile/core/pairing_client.dart';
import 'package:dsh_mobile/core/pairing_flow.dart';
import 'package:dsh_mobile/core/transport.dart';
import 'package:dsh_mobile/model/route_policy.dart';
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
            // 局域网那句是聚合的，中转那句仍是它自己那句（两条腿两件事）。
            .having((e) => e.message, 'message', contains('试了 1 个地址'))
            .having((e) => e.message, '中转原因', contains('配对码尚未在中转登记成功')),
      ),
    );
    expect(urls, hasLength(1), reason: '换票被拒就不该再去建连');
    expect(http.calls, hasLength(1), reason: '局域网失败之后要真的回落去换票');
  });

  test('局域网：候选全部**同时**拨出，一条不通不影响另一条', () async {
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

    // 死的那条不会拖住第二条：两条都在这一轮里被拨到（串行时会先等满第一条的超时）。
    expect(urls, hasLength(2));
    expect(urls[0], startsWith('ws://10.0.0.7:8790'));
    expect(urls[1], startsWith('ws://192.168.1.5:8790'));
    expect(attempt.dialUrl, 'ws://192.168.1.5:8790');
    expect(http.calls, isEmpty, reason: '有一条局域网通了就不该再走中转');
  });

  test('局域网：同一 /24 的那条先发起（换 WiFi 之后不用用户手动排）', () async {
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
        return url.startsWith('ws://192.168.1.5') ? pc : _DeadTransport();
      },
      allowInsecureLocal: true,
      // 本机在 192.168.1.0/24 上：那条应当被提到最前面（先发起、先占赢面）。
      myIpv4: '192.168.1.23',
      newFrameIdHex: () => 'p1',
      newEphemeralSeedHex: () => 'e5' * 32,
      newNonceHex: () => 'a7' * 32,
    );
    addTearDown(attempt.cancel);

    expect(urls.first, startsWith('ws://192.168.1.5:8790'));
    expect(urls, hasLength(2), reason: '两条都拨（并行），只是同网段那条排在前面');
    expect(attempt.dialUrl, 'ws://192.168.1.5:8790');
    expect(http.calls, isEmpty, reason: '同一 /24 直连通了就不该再换票');
  });

  // ---- 多选题（电脑报多条局域网地址）：先通者胜，失败只说一句话 ----

  test('三个候选里第二个通：配对成功，第一条/第三条的失败不影响结论', () async {
    final lan = offerWithLan([
      'ws://192.168.1.5:8790',
      'ws://192.168.1.6:8790',
      'ws://192.168.1.7:8790',
    ]);
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
        return url.startsWith('ws://192.168.1.6') ? pc : _DeadTransport();
      },
      allowInsecureLocal: true,
      newFrameIdHex: () => 'p1',
      newEphemeralSeedHex: () => 'e5' * 32,
      newNonceHex: () => 'a7' * 32,
    );
    addTearDown(attempt.cancel);

    expect(urls, hasLength(3), reason: '三条候选都要被拨到');
    expect(attempt.dial, PairingDial.lan);
    expect(attempt.dialUrl, 'ws://192.168.1.6:8790', reason: '通的这条才是这次的路');
    expect(http.calls, isEmpty, reason: '有一条通了就不该走中转');
    // 结论是"这一次配对能走下去"，而不是"有一条失败就整轮失败"。
    final ack = await attempt.commit();
    expect(ack.devId, await candidate.deviceId());
  });

  test('三个全不通：失败文案只说一句（含"试了 3 个地址"），不含具体 IP', () async {
    final lan = offerWithLan([
      'ws://192.168.1.5:8790',
      'ws://192.168.1.6:8790',
      'ws://192.168.1.7:8790',
    ]);
    final http = _TicketRecorder();
    final urls = <String>[];
    String? message;
    await expectLater(
      beginPairing(
        offer: lan,
        identity: identity,
        deviceName: '我的手机',
        send: http.call,
        allowInsecureLocal: true,
        // 只用直连：把"局域网这条腿的文案"单独钉住（auto 会在后面接中转那句）。
        prefer: RoutePolicy.directOnly,
        transportFor: (url) {
          urls.add(url);
          return _DeadTransport();
        },
        newFrameIdHex: () => 'p1',
        newEphemeralSeedHex: () => 'e5' * 32,
        newNonceHex: () => 'a7' * 32,
      ),
      throwsA(
        isA<TransportException>().having(
          (e) => message = e.message,
          'message',
          contains('试了 3 个地址'),
        ),
      ),
    );
    expect(urls, hasLength(3));
    expect(message, contains('局域网不通'));
    expect(message, contains('是否同一 Wi-Fi'), reason: '一句话里带用户能做的动作');
    // **不逐条拼明细**：地址与原始错误不该出现在给用户看的那句话里。
    expect(message, isNot(contains('192.168.')), reason: '失败文案里不该有具体 IP');
    expect(message, isNot(contains('拨不通')), reason: '也不该把每条原始错误拼进来');
    expect(http.calls, isEmpty, reason: '只用直连：不换票');
  });

  test('并行：三条握手是**同时发起**的（不是一条等满超时再下一条）', () async {
    final lan = offerWithLan([
      'ws://192.168.1.5:8790',
      'ws://192.168.1.6:8790',
      'ws://192.168.1.7:8790',
    ]);
    final http = _TicketRecorder();
    final started = <String>[];
    final gated = <_GatedTransport>[];
    final pairing = beginPairing(
      offer: lan,
      identity: identity,
      deviceName: '我的手机',
      send: http.call,
      allowInsecureLocal: true,
      prefer: RoutePolicy.directOnly,
      transportFor: (url) {
        started.add(url);
        final transport = _GatedTransport();
        gated.add(transport);
        return transport;
      },
      newFrameIdHex: () => 'p1',
      newEphemeralSeedHex: () => 'e5' * 32,
      newNonceHex: () => 'a7' * 32,
    );
    // 把已排队的微任务跑完，但**一条握手都还没回来**（gate 全关着）。
    await pumpEventQueue();
    expect(started, hasLength(3), reason: '串行写法在这里只会发起 1 条（第一条没回来就不会拨第二条）');
    expect(gated, hasLength(3));

    // 全部放开（都失败）：三条都在飞，结论是那一句聚合文案。
    for (final transport in gated) {
      transport.fail();
    }
    await expectLater(
      pairing,
      throwsA(
        isA<TransportException>().having(
          (e) => e.message,
          'message',
          contains('试了 3 个地址'),
        ),
      ),
    );
  });

  test('并行：先通者胜，还在握手的那几条**当场收掉**（不留半开连接）', () async {
    final lan = offerWithLan([
      'ws://192.168.1.5:8790',
      'ws://192.168.1.6:8790',
    ]);
    final http = _TicketRecorder();
    final candidate = lan.candidate(identity, '我的手机');
    final pc = FakePc(pcSeedHex: _pcSeed, offer: lan, candidate: candidate);
    final slow = _GatedTransport();
    final attempt = await beginPairing(
      offer: lan,
      identity: identity,
      deviceName: '我的手机',
      send: http.call,
      transportFor: (url) => url.startsWith('ws://192.168.1.5') ? slow : pc,
      allowInsecureLocal: true,
      newFrameIdHex: () => 'p1',
      newEphemeralSeedHex: () => 'e5' * 32,
      newNonceHex: () => 'a7' * 32,
    );
    addTearDown(attempt.cancel);

    expect(
      attempt.dialUrl,
      'ws://192.168.1.6:8790',
      reason: '先通的那条赢，而不是排在前面那条（它还在握手中）',
    );
    expect(slow.closed, isTrue, reason: '输家必须被收掉：半开的 socket 会占端口与超时预算');
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

  // ---- 连接方式策略（`device.route_policy`）：配对与连接共用一个设置 ----

  test('只用中转：只换票，局域网地址一个都不拨', () async {
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
      prefer: RoutePolicy.relayOnly,
      newFrameIdHex: () => 'p1',
      newEphemeralSeedHex: () => 'e5' * 32,
      newNonceHex: () => 'a7' * 32,
    );
    addTearDown(attempt.cancel);

    expect(http.calls, hasLength(1), reason: '只用中转：先换票');
    expect(attempt.dial, PairingDial.relay);
    expect(urls.single, startsWith('ws://127.0.0.1:8787/ws/device?ticket='));
  });

  test('只用中转 + 中转失败：**不回落**局域网（"不偷偷改路"）', () async {
    final lan = offerWithLan(['ws://192.168.1.5:8790']);
    final http = _TicketRecorder(const [
      HttpResult(status: 409, body: '{"error":"pairing-unavailable"}'),
    ]);
    final urls = <String>[];
    final candidate = lan.candidate(identity, '我的手机');
    final pc = FakePc(pcSeedHex: _pcSeed, offer: lan, candidate: candidate);

    await expectLater(
      beginPairing(
        offer: lan,
        identity: identity,
        deviceName: '我的手机',
        send: http.call,
        transportFor: (url) {
          urls.add(url);
          return pc;
        },
        allowInsecureLocal: true,
        prefer: RoutePolicy.relayOnly,
        newFrameIdHex: () => 'p1',
        newEphemeralSeedHex: () => 'e5' * 32,
        newNonceHex: () => 'a7' * 32,
      ),
      throwsA(isA<ProtocolException>()),
    );
    expect(urls, isEmpty, reason: '用户说了只用中转，就不该去拨局域网那条');
  });

  test('自动：码里有局域网地址就先直连（不再按网段猜）', () async {
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
      // 本机在 10.0.0.0/24，而码里只有 192.168.1.5 —— 网段不同**不再**影响先试哪条：
      // 码里有局域网地址就是电脑出码时的现证，先拨它；失败 3s 内才回落中转。
      myIpv4: '10.0.0.7',
      newFrameIdHex: () => 'p1',
      newEphemeralSeedHex: () => 'e5' * 32,
      newNonceHex: () => 'a7' * 32,
    );
    addTearDown(attempt.cancel);

    expect(http.calls, isEmpty, reason: '先去局域网，不先换票');
    expect(attempt.dial, PairingDial.lan);
    expect(urls.single, startsWith('ws://192.168.1.5:8790'));
  });

  test('只用直连而码里没有局域网地址：明说冲突，不猜一个中转出来', () async {
    // 模块级 `offer` 就是"老载荷"形状：只有中转，没有 `lan`。
    final http = _TicketRecorder();
    final urls = <String>[];

    await expectLater(
      beginPairing(
        offer: offer,
        identity: identity,
        deviceName: '我的手机',
        send: http.call,
        transportFor: (url) {
          urls.add(url);
          return _DeadTransport();
        },
        allowInsecureLocal: true,
        prefer: RoutePolicy.directOnly,
        newFrameIdHex: () => 'p1',
        newEphemeralSeedHex: () => 'e5' * 32,
        newNonceHex: () => 'a7' * 32,
      ),
      throwsA(
        isA<TransportException>().having(
          (error) => error.message,
          'message',
          contains('只用直连'),
        ),
      ),
    );
    expect(http.calls, isEmpty);
    expect(urls, isEmpty);
  });

  // ---- 同时探两条路：配对页据此把选择交给用户（2026-11-17） ----

  PairingOffer withLan({bool lanOnly = false}) => PairingOffer(
    relayUrl: offer.relayUrl,
    pcId: offer.pcId,
    pcSignPubHex: offer.pcSignPubHex,
    pcDhPubHex: offer.pcDhPubHex,
    offerId: offer.offerId,
    code: offer.code,
    lanUrls: const ['ws://127.0.0.1:8790'],
    lanOnly: lanOnly,
    routes: lanOnly ? const {'lan'} : const {'lan', 'relay'},
  );

  test('两条都探：两条都开、只换一次票，结果各自如实', () async {
    final target = withLan();
    final http = _TicketRecorder();
    final candidate = target.candidate(identity, '我的手机');
    final seen = <String>[];
    final probe = await probePairing(
      offer: target,
      identity: identity,
      deviceName: '我的手机',
      send: http.call,
      transportFor: (url) {
        seen.add(url);
        return FakePc(pcSeedHex: _pcSeed, offer: target, candidate: candidate);
      },
      allowInsecureLocal: true,
      newFrameIdHex: () => 'p1',
      newEphemeralSeedHex: () => 'e5' * 32,
      newNonceHex: () => 'a7' * 32,
    );
    addTearDown(probe.cancelAll);

    expect(probe.routes.length, 2);
    expect(probe.attemptOf(PairingDial.lan), isNotNull);
    expect(probe.attemptOf(PairingDial.relay), isNotNull);
    expect(http.calls.length, 1, reason: '中转那张票只换一次');
    expect(seen.length, 2, reason: '两条路各拨一次');
  });

  test('降级码只探局域网：一条路、零 HTTP', () async {
    final target = withLan(lanOnly: true);
    final http = _TicketRecorder();
    final candidate = target.candidate(identity, '我的手机');
    final probe = await probePairing(
      offer: target,
      identity: identity,
      deviceName: '我的手机',
      send: http.call,
      transportFor: (_) =>
          FakePc(pcSeedHex: _pcSeed, offer: target, candidate: candidate),
      allowInsecureLocal: true,
      newFrameIdHex: () => 'p1',
      newEphemeralSeedHex: () => 'e5' * 32,
      newNonceHex: () => 'a7' * 32,
    );
    addTearDown(probe.cancelAll);

    expect(probe.routes.length, 1);
    expect(probe.attemptOf(PairingDial.lan), isNotNull);
    expect(http.calls, isEmpty, reason: '没有中转那条腿，不该去换票');
  });

  test('两条都不通：不抛异常，两条原因都在（界面要一起摆出来）', () async {
    final target = withLan();
    final http = _TicketRecorder(const [
      HttpResult(status: 409, body: '{"error":"pairing-unavailable"}'),
    ]);
    final probe = await probePairing(
      offer: target,
      identity: identity,
      deviceName: '我的手机',
      send: http.call,
      transportFor: (_) => _DeadTransport(),
      allowInsecureLocal: true,
      newFrameIdHex: () => 'p1',
      newEphemeralSeedHex: () => 'e5' * 32,
      newNonceHex: () => 'a7' * 32,
    );

    expect(probe.routes.length, 2);
    for (final route in probe.routes) {
      expect(route.attempt, isNull);
      expect(route.failure, isNotNull, reason: '每一条都要有自己的原因');
    }
  });

  test('只用直连：**不碰中转**（零 HTTP），只探局域网', () async {
    final target = withLan();
    final candidate = target.candidate(identity, '我的手机');
    final probe = await probePairing(
      offer: target,
      identity: identity,
      deviceName: '我的手机',
      send: (call) async => throw StateError('只用直连时不该换票：${call.url}'),
      transportFor: (_) =>
          FakePc(pcSeedHex: _pcSeed, offer: target, candidate: candidate),
      allowInsecureLocal: true,
      prefer: RoutePolicy.directOnly,
      newFrameIdHex: () => 'p1',
      newEphemeralSeedHex: () => 'e5' * 32,
      newNonceHex: () => 'a7' * 32,
    );
    addTearDown(probe.cancelAll);

    expect(probe.routes.length, 1);
    expect(probe.attemptOf(PairingDial.lan), isNotNull);
    expect(probe.attemptOf(PairingDial.relay), isNull, reason: '策略排除的那条不该被探');
  });

  test('只用中转：局域网地址一个都不拨', () async {
    final target = withLan();
    final http = _TicketRecorder();
    final candidate = target.candidate(identity, '我的手机');
    final dialed = <String>[];
    final probe = await probePairing(
      offer: target,
      identity: identity,
      deviceName: '我的手机',
      send: http.call,
      transportFor: (url) {
        dialed.add(url);
        return FakePc(pcSeedHex: _pcSeed, offer: target, candidate: candidate);
      },
      allowInsecureLocal: true,
      prefer: RoutePolicy.relayOnly,
      newFrameIdHex: () => 'p1',
      newEphemeralSeedHex: () => 'e5' * 32,
      newNonceHex: () => 'a7' * 32,
    );
    addTearDown(probe.cancelAll);

    expect(probe.routes.length, 1);
    expect(probe.attemptOf(PairingDial.relay), isNotNull);
    expect(dialed.length, 1, reason: '只拨了中转那条');
    expect(dialed.single, contains('/ws/device'), reason: '拨的是中转升级地址，不是局域网');
  });

  test('只用中转 + 只含局域网的码：一条都不探（策略与码冲突）', () async {
    final target = withLan(lanOnly: true);
    final probe = await probePairing(
      offer: target,
      identity: identity,
      deviceName: '我的手机',
      send: (call) async => throw StateError('这张码不含中转，不该换票：${call.url}'),
      transportFor: (_) => _DeadTransport(),
      allowInsecureLocal: true,
      prefer: RoutePolicy.relayOnly,
      newFrameIdHex: () => 'p1',
      newEphemeralSeedHex: () => 'e5' * 32,
      newNonceHex: () => 'a7' * 32,
    );

    expect(probe.routes, isEmpty);
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

/// 一条**由测试控制何时回话**的传输：用来证明"同时发起"与"输家被收掉"。
///
/// 不用真实 sleep 竞速：`connect()` 停在 [_gate] 上，只有测试放手（或 [close]）才继续，
/// 于是"三条都发起了"是**观察得到的事实**，而不是"等得够久"的猜测。
class _GatedTransport implements ChannelTransport {
  final Completer<void> _gate = Completer<void>();

  /// 被 [close] 收掉过（输家必须走到这里，否则就是一条半开连接）。
  bool closed = false;

  /// 放手：让它像一条拨不通的地址那样结束（握手失败）。
  void fail() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  Future<Stream<TransportEvent>> connect() async {
    await _gate.future;
    throw const TransportException('建连失败：拨不通');
  }

  @override
  bool send(String line) => false;

  @override
  Future<void> close() async {
    closed = true;
    // 收尾也要放手：否则这里的 `connect()` 会永远挂着（一条永不完成的 future）。
    fail();
  }
}
