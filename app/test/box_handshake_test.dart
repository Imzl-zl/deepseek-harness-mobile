/// 封箱/解箱与握手驱动（契约 §3、§4.1、§4.2）。
///
/// 这一组是**安全关键**的：握手的两道校验是"抗中间人"的全部依据，
/// 而封箱的方向映射与 nonce 单调性是"两端能互相解开"的全部依据。
/// 它们写错的表现都不是报错，而是"看起来正常但不再安全"或"永远解不开"。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_mobile/core/box.dart';
import 'package:dsh_mobile/core/crypto.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/handshake.dart';
import 'package:dsh_mobile/core/handshake_driver.dart';
import 'package:flutter_test/flutter_test.dart';

const _seedA = 'a1';
const _seedB = 'b2';

Future<SessionKeys> _keysForBothSides() async {
  final staticA = await x25519FromSeed(_seedA * 32);
  final staticB = await x25519FromSeed(_seedB * 32);
  final ephA = await x25519FromSeed('c3' * 32);
  final ephB = await x25519FromSeed('d4' * 32);
  return deriveSessionKeys(
    role: HandshakeRole.initiator,
    ownStaticPrivate: staticA.keyPair,
    ownEphemeralPrivate: ephA.keyPair,
    peerStaticPublicHex: staticB.publicKeyHex,
    peerEphemeralPublicHex: ephB.publicKeyHex,
    nonceA: '11' * 32,
    nonceB: '22' * 32,
    info: keyInfo,
    pairingId: 'pair-1',
  );
}

void main() {
  group('箱：封箱与解箱（契约 §3、§4.2）', () {
    test('手机封、电脑解（方向由角色决定，不由调用方决定）', () async {
      final keys = await _keysForBothSides();
      // 手机 = 发起方；电脑 = 应答方。
      final phone = BoxCodec(keys: keys, role: HandshakeRole.initiator);
      final pc = BoxCodec(keys: keys, role: HandshakeRole.responder);

      final frame = <String, Object?>{
        'v': 1,
        't': 'req',
        'id': 'r1',
        'fc': 0,
        'box': '',
      };
      final box = await phone.sealFrame(frame, '{"method":"repo.info"}');
      // 电脑侧解得出，且明文一致。
      expect(await pc.openFrame(frame, box), '{"method":"repo.info"}');
    });

    test('反方向同理（电脑封、手机解）', () async {
      final keys = await _keysForBothSides();
      final phone = BoxCodec(keys: keys, role: HandshakeRole.initiator);
      final pc = BoxCodec(keys: keys, role: HandshakeRole.responder);

      final frame = <String, Object?>{
        'v': 1,
        't': 'res',
        'id': 'r1',
        'fc': 0,
        'box': '',
      };
      final box = await pc.sealFrame(frame, '{"ok":true}');
      expect(await phone.openFrame(frame, box), '{"ok":true}');
    });

    test('方向写反就解不开（映射写错不会报错，只会两侧都解不开）', () async {
      final keys = await _keysForBothSides();
      // 两个都是发起方 = 方向映射反了。
      final a = BoxCodec(keys: keys, role: HandshakeRole.initiator);
      final b = BoxCodec(keys: keys, role: HandshakeRole.initiator);
      final frame = <String, Object?>{
        'v': 1,
        't': 'ev',
        'sid': 's1',
        'seq': 1,
        'fc': 0,
        'box': '',
      };
      final box = await a.sealFrame(frame, 'x');
      await expectLater(
        b.openFrame(frame, box),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.badFrame,
          ),
        ),
        reason: '同向自解必须失败（否则"方向"这件事没有任何东西在盯着）',
      );
    });

    test('篡改密文 / AAD / fc 都解不开（认证失败转成协议错误码）', () async {
      final keys = await _keysForBothSides();
      final phone = BoxCodec(keys: keys, role: HandshakeRole.initiator);
      final pc = BoxCodec(keys: keys, role: HandshakeRole.responder);
      final frame = <String, Object?>{
        'v': 1,
        't': 'ev',
        'sid': 's1',
        'seq': 1,
        'fc': 0,
        'box': '',
      };
      final box = await phone.sealFrame(frame, '原文');

      // 改 AAD 的 seq。
      await expectLater(
        pc.openFrame(<String, Object?>{...frame, 'seq': 2}, box),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.badFrame,
          ),
        ),
      );
      // 改 fc（等于 nonce 变了）。
      await expectLater(
        pc.openFrame(<String, Object?>{...frame, 'fc': 1}, box),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.badFrame,
          ),
        ),
      );
      // 改密文本身（换一个字节）。
      final raw = base64UrlToBytes(box);
      raw[0] = raw[0] ^ 0xff;
      await expectLater(
        pc.openFrame(frame, base64UrlNoPad(raw)),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.badFrame,
          ),
        ),
      );
    });

    test('nonce 绊线：同一个 fc 不许封两次（重用 nonce 直接破 AEAD）', () async {
      final keys = await _keysForBothSides();
      final phone = BoxCodec(keys: keys, role: HandshakeRole.initiator);
      final frame = <String, Object?>{
        'v': 1,
        't': 'ev',
        'sid': 's1',
        'seq': 1,
        'fc': 5,
        'box': '',
      };
      await phone.sealFrame(frame, 'a');
      await expectLater(
        phone.sealFrame(frame, 'b'),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.internal,
          ),
        ),
        reason: '这是装配错误（不是对端的错），所以归 internal 而不是 bad-frame',
      );
    });

    test('重放：先验后进 —— 同一个 fc 第二次被拒，且不推进窗口', () async {
      final keys = await _keysForBothSides();
      final phone = BoxCodec(keys: keys, role: HandshakeRole.initiator);
      final pc = BoxCodec(keys: keys, role: HandshakeRole.responder);
      final frame = <String, Object?>{
        'v': 1,
        't': 'ev',
        'sid': 's1',
        'seq': 1,
        'fc': 0,
        'box': '',
      };
      final box = await phone.sealFrame(frame, 'x');
      expect(await pc.openFrame(frame, box), 'x');
      expect(pc.maxFc, 0);
      await expectLater(
        pc.openFrame(frame, box),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.replay,
          ),
        ),
      );
      expect(pc.maxFc, 0, reason: '被拒的那一帧不得推进窗口');
    });

    test('伪造的 fc 推不动窗口（先验后进的反向证据）', () async {
      final keys = await _keysForBothSides();
      final phone = BoxCodec(keys: keys, role: HandshakeRole.initiator);
      final pc = BoxCodec(keys: keys, role: HandshakeRole.responder);
      // 一帧伪造的 fc=1000：解箱必然失败（AAD 里的 fc 与真实的不符）。
      final real = <String, Object?>{
        'v': 1,
        't': 'ev',
        'sid': 's1',
        'seq': 1,
        'fc': 0,
        'box': '',
      };
      final box = await phone.sealFrame(real, 'x');
      await expectLater(
        pc.openFrame(<String, Object?>{...real, 'fc': 1000}, box),
        throwsA(isA<ProtocolException>()),
      );
      expect(pc.maxFc, -1, reason: '未认证的 fc 绝不能推进窗口（否则后续合法帧全被判重放）');
      // 真实的 fc=0 仍然收得下。
      expect(await pc.openFrame(real, box), 'x');
    });

    test('箱容器严格校验：非 base64url / 太短 / 非规范编码都拒', () async {
      // 非 base64url 字母表。
      expect(
        () => unpackBoxStrict('!!!'),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.badFrame,
          ),
        ),
      );
      // 太短（不足 16 字节 tag）。
      expect(
        () => unpackBoxStrict(base64UrlNoPad(Uint8List(15))),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.badFrame,
          ),
        ),
      );
      // 非规范编码（带填充）——同一串字节可以有多个字符串表示，放行会让两端对不上账。
      expect(
        () => unpackBoxStrict('${base64UrlNoPad(Uint8List(16))}='),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.badFrame,
          ),
        ),
      );
    });

    test('没有 fc 的帧不该封箱（握手帧、配对帧、presence 是明文）', () async {
      final keys = await _keysForBothSides();
      final phone = BoxCodec(keys: keys, role: HandshakeRole.initiator);
      await expectLater(
        phone.sealFrame(<String, Object?>{
          'v': 1,
          't': 'hello',
          'id': 'h1',
          'box': '',
        }, 'x'),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.badFrame,
          ),
        ),
      );
    });
  });

  group('握手驱动（发起方；契约 §4.1）', () {
    /// 一套固定的握手材料（种子与 nonce 都注入，所以是确定性的）。
    Future<({HandshakeIdentity identity, PeerIdentity peer, KeyPair pcDh})>
    materials() async {
      final phoneStatic = await x25519FromSeed(_seedA * 32);
      final pcDh = await x25519FromSeed(_seedB * 32);
      final phoneSign = await deriveIdentity('e5' * 32);
      return (
        identity: HandshakeIdentity(
          staticKeys: phoneStatic,
          signSeedHex: phoneSign.signSeedHex,
          devId: 'dev-1',
        ),
        peer: PeerIdentity(
          pcSignPubHex: phoneSign.sign.publicKeyHex, // 测试里让"电脑"用同一把签名密钥
          pcDhPubHex: pcDh.publicKeyHex,
          pcId: 'pc-1',
          pairingId: 'pair-1',
        ),
        pcDh: pcDh,
      );
    }

    test('建好就发 hello（发起方必须自己开这个头）', () async {
      final m = await materials();
      final sent = <Map<String, Object?>>[];
      var seq = 0;
      final driver = createHandshakeDriver(
        identity: m.identity,
        peer: m.peer,
        newEphemeralSeedHex: () => 'c3' * 32,
        newNonceHex: () => '11' * 32,
        newFrameIdHex: () => 'h${seq++}',
      );
      driver(
        HandshakeContext(
          send: sent.add,
          established: (_) {},
          failed: (_, _) {},
          schedule: (fn, ms) => () {},
        ),
      );
      // `_begin` 是异步的（要从种子建密钥对），让微任务跑完。
      await Future<void>.delayed(Duration.zero);
      expect(sent.length, 1);
      expect(sent.single['t'], 'hello');
      expect(sent.single['id'], 'h0');
      expect(sent.single.containsKey('fc'), isFalse, reason: '握手帧不盖 fc（§3）');
    });

    test('收到 hello-ack → 验签 → 发 confirm → established', () async {
      final m = await materials();
      final sent = <Map<String, Object?>>[];
      HandshakeEstablishment? established;
      var ids = 0;
      final driver = createHandshakeDriver(
        identity: m.identity,
        peer: m.peer,
        newEphemeralSeedHex: () => 'c3' * 32,
        newNonceHex: () => '11' * 32,
        newFrameIdHex: () => 'id${ids++}',
      );
      final session = driver(
        HandshakeContext(
          send: sent.add,
          established: (result) => established = result,
          failed: (reason, error) => fail('不该失败：$reason $error'),
          schedule: (fn, ms) => () {},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      // 电脑侧（测试里扮演应答方）：按 hello 的字段算 transcript 并签名。
      final hello = parseHello(sent.single['box']! as String);
      final pcSign = await deriveIdentity('e5' * 32);
      final ackFields = HelloAckFields(
        ephPubB: (await x25519FromSeed('d4' * 32)).publicKeyHex,
        pcId: m.peer.pcId,
        nonceB: '22' * 32,
      );
      final transcript = transcriptFromFields(hello, ackFields);
      final sigB = await signTranscript(pcSign.signSeedHex, transcript);

      session.onFrame({
        'v': 1,
        't': 'hello-ack',
        'id': 'a1',
        'box': encodeHelloAck(ackFields, sigB),
      });
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(established, isNotNull, reason: '两道校验都过了才 established');
      expect(established!.devId, 'dev-1');
      // 发出去了 confirm，且带 transcriptHash。
      final confirmFrame = sent.firstWhere((f) => f['t'] == 'confirm');
      final confirm = parseConfirm(confirmFrame['box']! as String);
      expect(confirm.transcriptHash, await transcriptHashOf(transcript));
      expect(confirm.sigA.length, 128);
      expect(confirmFrame.containsKey('fc'), isFalse);
    });

    test('验签不过 → failed(notPaired)，且**不** established', () async {
      final m = await materials();
      final sent = <Map<String, Object?>>[];
      ErrorCode? failedWith;
      var establishedCount = 0;
      final driver = createHandshakeDriver(
        identity: m.identity,
        peer: m.peer,
        newEphemeralSeedHex: () => 'c3' * 32,
        newNonceHex: () => '11' * 32,
        newFrameIdHex: () => 'id',
      );
      final session = driver(
        HandshakeContext(
          send: sent.add,
          established: (_) => establishedCount += 1,
          failed: (reason, _) => failedWith = reason,
          schedule: (fn, ms) => () {},
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final hello = parseHello(sent.single['box']! as String);
      final ackFields = HelloAckFields(
        ephPubB: (await x25519FromSeed('d4' * 32)).publicKeyHex,
        pcId: m.peer.pcId,
        nonceB: '22' * 32,
      );
      final transcript = transcriptFromFields(hello, ackFields);
      // **别人签的**：用另一把种子签 —— 等于中继替换了公钥。
      final wrongSig = await signTranscript('ff' * 32, transcript);

      session.onFrame({
        'v': 1,
        't': 'hello-ack',
        'id': 'a1',
        'box': encodeHelloAck(ackFields, wrongSig),
      });
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(failedWith, ErrorCode.notPaired, reason: '手机据此清除凭据、回配对页');
      expect(establishedCount, 0, reason: '验签不过绝不能派生密钥');
      expect(
        sent.any((f) => f['t'] == 'confirm'),
        isFalse,
        reason: '验签不过不该发 confirm',
      );
    });

    test('超时 → failed（对端没在时限内走完三条消息）', () async {
      final m = await materials();
      void Function()? fire;
      ErrorCode? failedWith;
      final driver = createHandshakeDriver(
        identity: m.identity,
        peer: m.peer,
        newEphemeralSeedHex: () => 'c3' * 32,
        newNonceHex: () => '11' * 32,
        newFrameIdHex: () => 'id',
      );
      driver(
        HandshakeContext(
          send: (_) {},
          established: (_) => fail('不该 established'),
          failed: (reason, _) => failedWith = reason,
          schedule: (fn, ms) {
            fire = fn;
            return () {};
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(fire, isNotNull, reason: '握手必须起超时');
      fire!();
      expect(failedWith, ErrorCode.internal);
    });

    test('第一步收到非 hello-ack → failed(badFrame)', () async {
      final m = await materials();
      ErrorCode? failedWith;
      final driver = createHandshakeDriver(
        identity: m.identity,
        peer: m.peer,
        newEphemeralSeedHex: () => 'c3' * 32,
        newNonceHex: () => '11' * 32,
        newFrameIdHex: () => 'id',
      );
      final session = driver(
        HandshakeContext(
          send: (_) {},
          established: (_) => fail('不该 established'),
          failed: (reason, _) => failedWith = reason,
          schedule: (fn, ms) => () {},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      session.onFrame({'v': 1, 't': 'confirm', 'id': 'c1', 'box': '{}'});
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(failedWith, ErrorCode.badFrame);
    });

    test('dispose 之后不再处理帧（也不再有回调）', () async {
      final m = await materials();
      var callbacks = 0;
      final driver = createHandshakeDriver(
        identity: m.identity,
        peer: m.peer,
        newEphemeralSeedHex: () => 'c3' * 32,
        newNonceHex: () => '11' * 32,
        newFrameIdHex: () => 'id',
      );
      final session = driver(
        HandshakeContext(
          send: (_) {},
          established: (_) => callbacks += 1,
          failed: (_, _) => callbacks += 1,
          schedule: (fn, ms) => () {},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      session.dispose();
      session.onFrame({
        'v': 1,
        't': 'hello-ack',
        'id': 'a',
        'box': jsonEncode({}),
      });
      await Future<void>.delayed(Duration.zero);
      expect(callbacks, 0);
    });
  });
}
