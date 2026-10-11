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
}
