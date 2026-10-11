/// 候选（首配）受限通道的单测（规格 `docs/subsystems/pairing-v2.md` §4–§5）。
///
/// ## 这一组钉住的是"秘密只在密文里"和"上下文真的进了被签的字节"
///
/// 两件事都属于**错了不会报错**的那一类：
///
/// 1. `pair-commit` 的载荷是配对码。它明文上线不会让任何断言失败（两侧照样"配对成功"），
///    只会让经中转的那一跳把唯一的授权凭据交出去。所以这里既看**解密后的载荷**，
///    也在**原始行**里搜一遍码 —— 后者才是"有没有明文上线"的判据。
/// 2. 配对握手上下文进的是被签的字节。拼错的表现是**验签失败**，而错误信息会说
///    "公钥被替换"—— 真因在一处拼串上，报出来的却像中间人攻击。所以这里让电脑侧替身
///    用**另一个上下文**（设备名不同）签，断言手机侧确实拒绝。
///
/// ## 电脑侧是替身，所以这一组不是跨端证据
///
/// 见 `test/support/fake_pc.dart` 的说明：它验的是"手机侧符合契约"，
/// 跨端证据在 `connector/tests/pairing-e2e.test.ts` 与真机集成用例里。
library;

import 'dart:convert';

import 'package:dsh_mobile/core/crypto.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/pairing.dart';
import 'package:dsh_mobile/core/pairing_channel.dart';
import 'package:dsh_mobile/core/transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_pc.dart';

const _phoneSeed =
    '0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20';
const _pcSeed =
    'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1';

void main() {
  late IdentityKeys phone;
  late PairingOffer offer;
  late String code;

  setUp(() async {
    phone = await deriveIdentity(_phoneSeed);
    final pc = await deriveIdentity(_pcSeed);
    code = 'abL3sSH5gLJpTBBsqPUzJg';
    offer = PairingOffer(
      relayUrl: 'ws://127.0.0.1:8787',
      pcId: 'conn-1',
      pcSignPubHex: pc.sign.publicKeyHex,
      pcDhPubHex: pc.dh.publicKeyHex,
      offerId: 'zyXWvUTSrqPONMLKjihgfe',
      code: code,
    );
  });

  /// 建一条通道 + 一个电脑侧替身，并把通道开起来。
  Future<(PairingChannel, FakePc)> open({
    String? candidateName,
    Map<String, Object?>? reply,
    Map<String, Object?>? commitFailure,
  }) async {
    final candidate = offer.candidate(phone, candidateName ?? '我的手机');
    final pc = FakePc(
      pcSeedHex: _pcSeed,
      offer: offer,
      // 替身用**另一个名字**算上下文时，被签的字节就与手机侧不同 ——
      // 这正是"中转换了候选信息"的等价场景。
      candidate: candidateName == null
          ? candidate
          : offer.candidate(phone, '别的手机'),
      reply: reply,
      commitFailure: commitFailure,
    );
    final channel = PairingChannel(
      transport: pc,
      offer: offer,
      identity: phone,
      candidate: candidate,
      devId: await candidate.deviceId(),
      newFrameIdHex: () => 'id-1',
      newEphemeralSeedHex: () => 'e5' * 32,
      newNonceHex: () => 'a7' * 32,
    );
    await channel.open();
    return (channel, pc);
  }

  group('握手：三帧走完，秘密还没出去', () {
    test('握完手电脑侧只收到握手两帧（hello / confirm），没有提交帧', () async {
      final (channel, pc) = await open();
      // 握手期只该有 `hello` 与 `confirm`：配对码要等用户确认才发。
      expect(pc.lines, hasLength(2));
      final types = pc.lines
          .map((line) => (jsonDecode(line.trim()) as Map<String, Object?>)['t'])
          .toList();
      expect(types, ['hello', 'confirm']);
      final hello = jsonDecode(pc.lines.first.trim()) as Map<String, Object?>;
      expect(hello['v'], 1);
      // 握手帧的线上形状里没有 `fc`（§3）：多一个会让线上帧与契约不符。
      expect(hello.containsKey('fc'), isFalse);
      // 等替身把手上的帧处理完再看它的状态：它那边的密钥派生是异步的
      // （见 `FakePc.drain` 的说明）。
      await pc.drain();
      expect(pc.established, isTrue, reason: '电脑侧替身应当已经谈成密钥');
      // 秘密没出去：替身一个字节的解密载荷都没拿到。
      expect(pc.commitPayload, isNull);
      await channel.close();
    });

    test('上下文对不上时握手失败（中转换掉候选信息就是这种形态）', () async {
      // 替身用另一个设备名算上下文 ⇒ 它签的字节与手机侧不同 ⇒ 手机侧验签不过。
      // 这一条是"上下文确实进了被签的字节"的判据：没进的话两边照样握手成功。
      await expectLater(
        open(candidateName: '中转替换后的名字'),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.notPaired,
          ),
        ),
      );
    });
  });

  group('提交：秘密只在密文里', () {
    test('pair-commit 是封箱帧、fc 从 0 起，解出来正是 {v:2, offerId, code}', () async {
      final (channel, pc) = await open();
      final ack = await channel.commit(code);

      expect(ack.devId, isNotEmpty);
      expect(ack.deviceToken, isNotEmpty);
      expect(ack.refreshToken, isNotEmpty);
      expect(pc.commitPayload, {
        'v': 2,
        'offerId': offer.offerId,
        'code': code,
      });

      // 线上那一帧：带 `box` 与 `fc`，没有 `sid`（配对帧没有会话）。
      final commitLine = pc.lines.last.trim();
      final frame = jsonDecode(commitLine) as Map<String, Object?>;
      expect(frame['t'], 'pair-commit');
      expect(frame['fc'], 0, reason: '握手后第一帧业务帧的 fc 仍是 0');
      expect(frame['box'], isA<String>());
      expect(frame.containsKey('sid'), isFalse);

      // **真正的判据**：原始行里不许出现配对码 —— 明文上线不会让上面任何一条失败。
      expect(commitLine.contains(code), isFalse, reason: '配对码绝不能明文上线（它经中转）');
      await channel.close();
    });

    test('回执带电脑侧给的原因时如实抛（用户要看到那句话）', () async {
      final (channel, _) = await open(
        commitFailure: <String, Object?>{
          'ok': false,
          'reason': '配对码已过期，请在电脑上重新出码',
        },
      );
      await expectLater(
        channel.commit(code),
        throwsA(
          isA<ProtocolException>()
              .having((e) => e.code, 'code', ErrorCode.notPaired)
              .having((e) => e.message, 'message', '配对码已过期，请在电脑上重新出码'),
        ),
      );
      await channel.close();
    });

    test('提交两次：第二次拒（一次配对只提交一次）', () async {
      final (channel, _) = await open();
      await channel.commit(code);
      await expectLater(
        channel.commit(code),
        throwsA(isA<ProtocolException>()),
      );
      await channel.close();
    });

    test('连接关掉之后提交：如实抛错，不静默假装成功', () async {
      final (channel, pc) = await open();
      await channel.close();
      await expectLater(
        channel.commit(code),
        throwsA(isA<ProtocolException>()),
      );
      expect(pc.commitPayload, isNull);
    });
  });

  group('关连接', () {
    test('close 幂等（配对是短交互，收口路径可能被调两次）', () async {
      final (channel, _) = await open();
      await channel.close();
      await channel.close();
    });

    test('关掉之后收到帧不再改任何结论（不给已死的通道记账）', () async {
      final (channel, pc) = await open();
      await channel.close();
      // 替身再多发几帧：不该抛、也不该把错误算到调用方头上。
      expect(pc.lines, isNotEmpty);
      await expectLater(
        pc.receive('${jsonEncode({'v': 1, 't': 'pong', 'fc': 9})}\n'),
        completes,
      );
    });
  });

  group('传输层断开', () {
    test('对端断开时握手失败要如实冒出来（不是静默挂住）', () async {
      final candidate = offer.candidate(phone, '我的手机');
      final pc = FakePc(pcSeedHex: _pcSeed, offer: offer, candidate: candidate);
      final channel = PairingChannel(
        transport: pc,
        offer: offer,
        identity: phone,
        candidate: candidate,
        devId: await candidate.deviceId(),
      );
      final pending = channel.open();
      await pc.close();
      await expectLater(pending, throwsA(isA<TransportException>()));
    });
  });
}
