/// `core/` 里**不依赖外部规格**的那些判据（契约 §3、§4.3、§5.2、§5.4）。
///
/// 为什么还需要这一组：`crypto_vectors_test.dart` 跑的是"已知答案"（值与值比对），
/// `fixtures_test.dart` 跑的是"场景回放"（端到端结论）。两者都**不直接**点名单个判据，
/// 于是下面这些一旦写错，可能只在某个很远的场景里显形（或者根本不显形）：
///
/// - `itemIdOf`：**不得用 `seq` 当主键**（不变量 I9）—— 退化成 `<type>:<seq>` 时
///   fixtures 里恰好没有那条事件，于是"条目随读路径换 id"这个 bug 不会被抓到；
/// - `needsBox` / `isPreKeysPlaintextFrame`：写错的表现是**某一类帧悄悄明文上线**
///   （fixtures 与向量都测不到"谁该封箱"）；
/// - `assertHandshakePhase`：握手门禁是**攻击面**（密钥没建好就塞业务帧）；
/// - `decideRecovery`：契约 §5.4 的判定顺序（重排不会报错，只会给出错误的恢复方式）；
/// - `SendWindow` / `credit` 编解码：满窗时压错帧会**死锁**（压住 `res` 让对端永远等）；
/// - 握手三帧的编解码往返：校验不对称会让坏值在本地放行、到对端才炸。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_mobile/core/crypto.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/flow.dart';
import 'package:dsh_mobile/core/frame.dart';
import 'package:dsh_mobile/core/handshake.dart';
import 'package:dsh_mobile/core/items.dart';
import 'package:dsh_mobile/core/recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('itemIdOf：itemId 由事件自身推导（契约 §5.2，不变量 I9）', () {
    test('四类消息事件取 message.id，且 user/message 的载荷就是消息本身', () {
      // `user/message` 是特例：载荷本身就是消息（其余在 `data.message` 上）。
      expect(
        itemIdOf(
          const EventLike(type: 'user/message', seq: 1, data: {'id': 'msg-1'}),
        ),
        'm:msg-1',
      );
      for (final type in const [
        'system/message',
        'developer/message',
        'assistant/message',
      ]) {
        expect(
          itemIdOf(
            EventLike(
              type: type,
              seq: 2,
              data: {
                'message': {'id': 'msg-2'},
              },
            ),
          ),
          'm:msg-2',
          reason: '$type 的 id 在 data.message.id 上',
        );
      }
    });

    test(
      'tool/call 取 callId；tool/result 取 message.toolCallId（两者共用同一个 itemId）',
      () {
        expect(
          itemIdOf(
            const EventLike(type: 'tool/call', seq: 3, data: {'callId': 'c1'}),
          ),
          't:c1',
        );
        // 结果与调用配对：同一个 callId ⇒ 同一个 itemId（后者覆盖前者）。
        expect(
          itemIdOf(
            const EventLike(
              type: 'tool/result',
              seq: 4,
              data: {
                'message': {'toolCallId': 'c1'},
              },
            ),
          ),
          't:c1',
        );
      },
    );

    test('审批的 ask 与 outcome 共用 itemId（后者覆盖前者即「已决定」）', () {
      expect(
        itemIdOf(
          const EventLike(type: 'approval/asked', seq: 5, data: {'id': 'a1'}),
        ),
        'i:a1',
      );
      expect(
        itemIdOf(
          const EventLike(type: 'approval/decided', seq: 6, data: {'id': 'a1'}),
        ),
        'i:a1',
      );
    });

    test('未知类型才用 <type>:<seq> 兜底（规格许可的那一档）', () {
      expect(
        itemIdOf(const EventLike(type: 'usage/update', seq: 7, data: null)),
        'usage/update:7',
      );
    });

    test('已知类型缺身份字段时**抛错**，不静默退化成 <type>:<seq>', () {
      // 退化会让一条本该稳定的条目随读路径换 id —— 正是 I9 要防的形态。
      // 宁可让这一帧失败，也不要静默造出一个会漂移的身份。
      expect(
        () => itemIdOf(
          const EventLike(type: 'user/message', seq: 1, data: {'id': ''}),
        ),
        throwsStateError,
      );
      expect(
        () => itemIdOf(const EventLike(type: 'tool/call', seq: 2, data: {})),
        throwsStateError,
      );
      expect(
        () =>
            itemIdOf(const EventLike(type: 'approval/asked', seq: 3, data: {})),
        throwsStateError,
      );
    });

    test('itemId 与 seq 无关：同一条消息换 seq 仍是同一个 itemId', () {
      final first = itemIdOf(
        const EventLike(
          type: 'assistant/message',
          seq: 10,
          data: {
            'message': {'id': 'x'},
          },
        ),
      );
      final second = itemIdOf(
        const EventLike(
          type: 'assistant/message',
          seq: 99,
          data: {
            'message': {'id': 'x'},
          },
        ),
      );
      expect(first, second, reason: 'I9：不得用 seq 当主键');
    });
  });

  group('封箱判据（契约 §3）', () {
    test('只有握手三帧、配对两帧与 presence 是明文，其余都要封箱', () {
      for (final type in handshakeFrameTypes) {
        expect(needsBox(type), isFalse, reason: '$type 是握手帧（密钥还没建立）');
        expect(isPreKeysPlaintextFrame(type), isTrue);
      }
      for (final type in pairingFrameTypes) {
        expect(needsBox(type), isFalse, reason: '$type 是配对帧（密钥还没建立）');
        expect(isPreKeysPlaintextFrame(type), isTrue);
      }
      expect(needsBox('presence'), isFalse, reason: 'presence 由中继合成，必须能原样转发');
      expect(
        isPreKeysPlaintextFrame('presence'),
        isFalse,
        reason: 'presence 不是"密钥前"的帧',
      );
    });

    test('控制帧**也要**封箱：买到的不是保密而是认证', () {
      // `fc` 在 AAD 里，不认证就等于让未认证的数字驱动重放窗口；
      // `credit` / `persisted` 还会改对端状态（放宽窗口 / 允许裁剪缓冲）。
      for (final type in const [
        'ping',
        'pong',
        'credit',
        'persisted',
        'ev',
        'live',
        'job',
        'req',
        'res',
      ]) {
        expect(needsBox(type), isTrue, reason: '$type 必须封箱');
      }
    });

    test('帧类型清单是封闭的：清单外的类型不封箱也不放行（走未知帧分支）', () {
      expect(frameTypes.contains('future-frame'), isFalse);
      // `needsBox` 对未知类型返回 true（保守方向：宁可要求封箱）。
      expect(needsBox('future-frame'), isTrue);
    });
  });

  group('握手门禁（契约 §2.2）', () {
    test('未完成握手时只放行握手帧与配对帧', () {
      for (final type in [...handshakeFrameTypes, ...pairingFrameTypes]) {
        expect(
          () => assertHandshakePhase({'t': type}, handshakeDone: false),
          returnsNormally,
          reason: '$type 在握手期必须放行',
        );
      }
    });

    test('未完成握手时业务帧一律拒（这是攻击面，不是风格问题）', () {
      for (final type in const ['req', 'ev', 'credit', 'persisted', 'ping']) {
        expect(
          () => assertHandshakePhase({'t': type}, handshakeDone: false),
          throwsA(
            isA<ProtocolException>().having(
              (e) => e.code,
              'code',
              ErrorCode.badFrame,
            ),
          ),
          reason: '$type 不该在握手期出现',
        );
      }
    });

    test('握手完成后不再拦（配对帧仍允许，它可能在重连后重发）', () {
      expect(
        () => assertHandshakePhase({'t': 'req'}, handshakeDone: true),
        returnsNormally,
      );
      expect(
        () => assertHandshakePhase({'t': 'hello'}, handshakeDone: true),
        returnsNormally,
      );
    });
  });

  group('恢复判定（契约 §5.4）—— 判据顺序不能重排', () {
    const covered = WindowState(trimmedTo: 0, covered: true);

    test('会话不存在 → 快照 no-session', () {
      final decided = decideRecoveryWithReason(
        since: 5,
        latest: null,
        window: covered,
      );
      expect(decided.outcome, RecoveryOutcome.snapshot);
      expect(decided.reason, SnapshotReason.noSession);
      expect(
        decideRecovery(since: 5, latest: null, window: covered),
        RecoveryOutcome.snapshot,
      );
    });

    test('since 大于最新 → 快照 revision-newer（手机手里的水位比我们还新）', () {
      final decided = decideRecoveryWithReason(
        since: 9,
        latest: 5,
        window: covered,
      );
      expect(decided.outcome, RecoveryOutcome.snapshot);
      expect(decided.reason, SnapshotReason.revisionNewer);
    });

    test('窗口裁过了 since → 快照 window-missed', () {
      final decided = decideRecoveryWithReason(
        since: 2,
        latest: 10,
        window: const WindowState(trimmedTo: 5, covered: true),
      );
      expect(decided.outcome, RecoveryOutcome.snapshot);
      expect(decided.reason, SnapshotReason.windowMissed);
    });

    test('覆盖不到（空洞）→ 快照 window-missed，不是"没有新事件"', () {
      // 混起来的表现是"手机永远停在旧内容上"，最难查。
      final decided = decideRecoveryWithReason(
        since: 2,
        latest: 10,
        window: const WindowState(trimmedTo: 0, covered: false),
      );
      expect(decided.outcome, RecoveryOutcome.snapshot);
      expect(decided.reason, SnapshotReason.windowMissed);
    });

    test('其余 → 增量，且**没有**原因（增量不带 reason）', () {
      final decided = decideRecoveryWithReason(
        since: 2,
        latest: 10,
        window: covered,
      );
      expect(decided.outcome, RecoveryOutcome.delta);
      expect(decided.reason, isNull);
    });

    test('顺序敏感：since == latest 且已裁到 latest 时，先判"裁过"而不是"对齐"', () {
      // `since < trimmedTo` 不成立（相等），所以这一档仍是增量（没有新内容）。
      expect(
        decideRecovery(
          since: 5,
          latest: 5,
          window: const WindowState(trimmedTo: 5, covered: true),
        ),
        RecoveryOutcome.delta,
      );
      // 但裁到 6 就覆盖不到了。
      expect(
        decideRecovery(
          since: 5,
          latest: 5,
          window: const WindowState(trimmedTo: 6, covered: true),
        ),
        RecoveryOutcome.snapshot,
      );
    });

    test('快照原因与线上字符串一一对应，非法值抛错（不静默降级）', () {
      for (final entry in snapshotReasonWire.entries) {
        expect(snapshotReasonOf(entry.value), entry.key);
      }
      expect(() => snapshotReasonOf('made-up'), throwsArgumentError);
    });
  });

  group('流控窗口（契约 §4.3）', () {
    test('保活帧不占额度（占的话满窗时双方互等超时）', () {
      final window = SendWindow();
      for (var i = 0; i < sendWindowFrames; i += 1) {
        window.onSent(i, 'ev');
      }
      expect(window.unacked, sendWindowFrames);
      // 满窗：可补帧被压住……
      expect(window.canSend('ev'), isFalse);
      expect(window.canSend('live'), isFalse);
      expect(window.canSend('job'), isFalse);
      // ……但保活与不可暂停的帧照发（压住它们会死锁）。
      expect(window.canSend('ping'), isTrue);
      expect(window.canSend('pong'), isTrue);
      expect(window.canSend('res'), isTrue);
      expect(window.canSend('credit'), isTrue);
      expect(window.canSend('persisted'), isTrue);
    });

    test('credit 只前进不后退（乱序或迟到的 ack 不该把窗口放大）', () {
      final window = SendWindow();
      window.onSent(0, 'ev');
      window.onSent(1, 'ev');
      window.onSent(2, 'ev');
      expect(window.unacked, 3);
      window.onCredit(2);
      expect(window.unacked, 0);
      // 迟到的旧 ack：不该把已确认的状态"退回去"。
      window.onCredit(0);
      expect(window.unacked, 0);
    });

    test('credit 自己不再回 credit（否则两端互刷 ack 停不下来）', () {
      expect(elicitsCredit('credit'), isFalse);
      for (final type in const [
        'ev',
        'req',
        'res',
        'ping',
        'pong',
        'persisted',
        'live',
        'job',
      ]) {
        expect(elicitsCredit(type), isTrue, reason: '$type 要回 credit');
      }
    });

    test('只有 ev / live / job 可暂停；ping/pong 不占额度', () {
      for (final type in const ['ev', 'live', 'job']) {
        expect(pausable(type), isTrue);
      }
      for (final type in const [
        'req',
        'res',
        'credit',
        'persisted',
        'presence',
      ]) {
        expect(pausable(type), isFalse);
      }
      expect(consumesCredit('ping'), isFalse);
      expect(consumesCredit('pong'), isFalse);
      expect(consumesCredit('ev'), isTrue);
    });

    test('credit 载荷往返；坏值抛 protocol/bad-frame', () {
      expect(encodeCredit(0), '{"ack":0}');
      expect(decodeCredit(encodeCredit(42)), 42);
      expect(
        () => decodeCredit('not json'),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.badFrame,
          ),
        ),
      );
      for (final bad in const ['{}', '{"ack":-1}', '{"ack":"1"}', '[]']) {
        expect(
          () => decodeCredit(bad),
          throwsA(isA<ProtocolException>()),
          reason: '坏载荷必须抛：对端发了个读不懂的 ack',
        );
      }
    });
  });

  group('握手三帧的编解码往返（契约 §4.1）', () {
    final eph = 'a' * 64;
    final nonce = 'b' * 64;
    final sig = 'c' * 128;

    test('hello 往返', () {
      final box = encodeHello(
        HelloFields(ephPubA: eph, devId: 'dev-1', nonceA: nonce),
      );
      final parsed = parseHello(box);
      expect(parsed.ephPubA, eph);
      expect(parsed.devId, 'dev-1');
      expect(parsed.nonceA, nonce);
    });

    test('hello-ack 往返（含 sigB）', () {
      final box = encodeHelloAck(
        HelloAckFields(ephPubB: eph, pcId: 'pc-1', nonceB: nonce),
        sig,
      );
      final parsed = parseHelloAck(box);
      expect(parsed.fields.ephPubB, eph);
      expect(parsed.fields.pcId, 'pc-1');
      expect(parsed.sigB, sig);
    });

    test('confirm 往返', () {
      final box = encodeConfirm(
        ConfirmFields(sigA: sig, transcriptHash: 'd' * 16),
      );
      final parsed = parseConfirm(box);
      expect(parsed.sigA, sig);
      expect(parsed.transcriptHash, 'd' * 16);
    });

    test('校验在编解码两侧对称：坏值**两边都**拒', () {
      // 只校验一侧会让坏值在本地被放行、到对端才炸 —— 而那时的错误信息指向对端。
      expect(
        () => encodeHello(
          HelloFields(ephPubA: 'short', devId: 'dev-1', nonceA: nonce),
        ),
        throwsA(isA<ProtocolException>()),
      );
      expect(
        () => parseHello(
          jsonEncode({'ephPubA': 'short', 'devId': 'dev-1', 'nonceA': nonce}),
        ),
        throwsA(isA<ProtocolException>()),
      );
      // devId 必须是 ASCII 安全字符集（它是 AAD/transcript 的组成部分）。
      expect(
        () => encodeHello(
          HelloFields(ephPubA: eph, devId: 'dev/1', nonceA: nonce),
        ),
        throwsA(isA<ProtocolException>()),
      );
      // 不是 JSON 对象。
      expect(() => parseHello('[1,2,3]'), throwsA(isA<ProtocolException>()));
      expect(() => parseHello('not json'), throwsA(isA<ProtocolException>()));
    });

    test('transcript 从字段拼，顺序是协议的一部分', () {
      final bytes = transcriptFromFields(
        HelloFields(ephPubA: eph, devId: 'dev-1', nonceA: nonce),
        HelloAckFields(ephPubB: eph, pcId: 'pc-1', nonceB: nonce),
      );
      expect(
        utf8.decode(bytes),
        'dsh-mobile/v1|hello|$eph|dev-1|$nonce|hello-ack|$eph|pc-1|$nonce',
      );
      // 换顺序不会报错，只会让两侧算出不同的 transcript（症状是"公钥被替换"）。
      final swapped = transcriptFromFields(
        HelloFields(ephPubA: eph, devId: 'dev-1', nonceA: nonce),
        HelloAckFields(ephPubB: eph, pcId: 'pc-2', nonceB: nonce),
      );
      expect(utf8.decode(swapped), isNot(utf8.decode(bytes)));
    });
  });

  group('fc 计数器与 transcriptHash（契约 §4.1、§4.2）', () {
    test('fc 从 0 开始、每帧 +1、不回退', () {
      final counter = SendCounter();
      expect(counter.value, 0);
      expect(counter.next(), 0);
      expect(counter.next(), 1);
      expect(counter.value, 2);
    });

    test('transcriptHash = SHA-256 的前 8 字节（16 个十六进制字符）', () async {
      final hash = await transcriptHashOf(utf8.encode('dsh-mobile/v1|hello'));
      expect(hash.length, 16, reason: '8 字节 = 16 个十六进制字符');
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(hash), isTrue);
      // 确定性：同一段字节必须得到同一个摘要。
      expect(await transcriptHashOf(utf8.encode('dsh-mobile/v1|hello')), hash);
    });

    test('verifyConfirm：摘要不符即 protocol/not-paired', () async {
      final transcript = utf8.encode(
        'dsh-mobile/v1|hello|x|y|z|hello-ack|p|q|r',
      );
      final good = await transcriptHashOf(transcript);
      await expectLater(
        verifyConfirm(transcript: transcript, transcriptHash: good),
        completes,
      );
      await expectLater(
        verifyConfirm(transcript: transcript, transcriptHash: '0' * 16),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.notPaired,
          ),
        ),
      );
    });

    test('验签：别人的签名必须被拒（抗中间人的全部依据）', () async {
      final transcript = utf8.encode('dsh-mobile/v1|hello|...');
      final seed = 'a1' * 32;
      final other = 'b2' * 32;
      final signature = await signTranscript(seed, transcript);
      final publicKey = (await ed25519FromSeed(seed)).publicKeyHex;

      // 正确的签名通过。
      await expectLater(
        verifySignature(
          transcript: transcript,
          publicKeyHex: publicKey,
          signatureHex: signature,
          role: '测试',
        ),
        completes,
      );
      // 换了 transcript 就验不过（签的是另一段字节）。
      await expectLater(
        verifySignature(
          transcript: utf8.encode('dsh-mobile/v1|hello|...|tampered'),
          publicKeyHex: publicKey,
          signatureHex: signature,
          role: '测试',
        ),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.notPaired,
          ),
        ),
      );
      // 换了公钥也验不过（"这一端不是我以为的那一端"）。
      await expectLater(
        verifySignature(
          transcript: transcript,
          publicKeyHex: (await ed25519FromSeed(other)).publicKeyHex,
          signatureHex: signature,
          role: '测试',
        ),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.notPaired,
          ),
        ),
      );
      // 公钥长度不对同样是 not-paired（不暴露内部分支）。
      await expectLater(
        verifySignature(
          transcript: transcript,
          publicKeyHex: 'short',
          signatureHex: signature,
          role: '测试',
        ),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.notPaired,
          ),
        ),
      );
    });

    test('坏十六进制也归 not-paired，**不能漏出 bad-frame**', () async {
      // 这一条是被 bug 逼出来的：`fromHex` 原本在 try 之外，于是"公钥不是合法十六进制"
      // 会漏出 `protocol/bad-frame`。而手机按错误码决定下一步 ——
      // `not-paired` 是"清除本地凭据、回配对页"，`bad-frame` 是"这一帧格式不对、重试"。
      // 把身份问题报成格式问题，会让用户永远卡在重试上。
      final transcript = utf8.encode('dsh-mobile/v1|hello|...');
      final signature = await signTranscript('a1' * 32, transcript);
      for (final bad in const ['abc', 'zz', '']) {
        await expectLater(
          verifySignature(
            transcript: transcript,
            publicKeyHex: bad,
            signatureHex: signature,
            role: '测试',
          ),
          throwsA(
            isA<ProtocolException>().having(
              (e) => e.code,
              'code',
              ErrorCode.notPaired,
            ),
          ),
          reason: '公钥 "$bad" 不是合法十六进制，仍必须报 not-paired',
        );
      }
      // 签名坏掉同理（它也在 try 里）。
      await expectLater(
        verifySignature(
          transcript: transcript,
          publicKeyHex: (await ed25519FromSeed('a1' * 32)).publicKeyHex,
          signatureHex: 'zz',
          role: '测试',
        ),
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

  group('十六进制与 base64url 工具', () {
    test('toHex / fromHex 往返，奇数长度与非十六进制字符都抛', () {
      expect(toHex(<int>[0, 1, 255]), '0001ff');
      expect(fromHex('0001ff'), <int>[0, 1, 255]);
      expect(() => fromHex('abc'), throwsA(isA<ProtocolException>()));
      expect(() => fromHex('zz'), throwsA(isA<ProtocolException>()));
    });

    test('base64UrlNoPad 不带填充（与电脑侧一致），解码容忍填充', () {
      expect(base64UrlNoPad(<int>[1]), 'AQ');
      expect(base64UrlNoPad(<int>[1, 2]), 'AQI');
      expect(base64UrlToBytes('AQ'), <int>[1]);
      expect(base64UrlToBytes('AQ=='), <int>[1]);
    });

    test('箱容器的长度下限：不足一个认证标签即抛', () {
      // 16 字节 tag ⇒ 至少要 16 字节；15 字节的箱是坏值。
      final tooShort = base64UrlNoPad(Uint8List(15));
      expect(
        () => unpackBox(tooShort),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.badFrame,
          ),
        ),
      );
      // 正好 16 字节：密文为空、标签 16 字节（合法）。
      final exact = unpackBox(base64UrlNoPad(Uint8List(16)));
      expect(exact.ciphertextHex, '');
      expect(exact.tagHex.length, 32);
    });
  });

  group('DeviceSession 的接收规则（契约 §5.4 规则 5）', () {
    test('重复帧丢弃并计数；前向空洞不入库并计数', () {
      final session = DeviceSession();
      session.receive('s1', 'm1', '一', 1);
      expect(session.itemsOf('s1'), {'m1': '一'});
      expect(session.received['s1'], 1);

      // 重复（seq <= 水位）。
      session.receive('s1', 'm1', '一', 1);
      expect(session.duplicates['s1'], 1);
      expect(session.received['s1'], 1, reason: '重复帧不得推进水位');

      // 前向空洞（seq > 水位 + 1）。
      session.receive('s1', 'm3', '三', 3);
      expect(session.gaps['s1'], 1);
      expect(session.itemsOf('s1').containsKey('m3'), isFalse, reason: '空洞不入库');
      expect(session.received['s1'], 1);

      // 接着的那条正常入库。
      session.receive('s1', 'm2', '二', 2);
      expect(session.received['s1'], 2);
    });

    test('upsert-only：同 itemId 覆盖，不新增条目', () {
      final session = DeviceSession();
      session.receive('s1', 'm1', '旧', 1);
      session.receive('s1', 'm1', '新', 2);
      expect(session.itemsOf('s1'), {'m1': '新'});
      expect(session.itemsOf('s1').length, 1);
    });

    test('commit 只前进（落盘水位不回退）', () {
      final session = DeviceSession();
      session.commit('s1', 5);
      expect(session.sinceOf('s1'), 5);
      session.commit('s1', 3);
      expect(session.sinceOf('s1'), 5, reason: '旧的 commit 不该把水位拉回去');
    });

    test('快照分页期间 ev 只缓存不落库；收口时按 seq 合并', () {
      final session = DeviceSession();
      // 第一页（hasMore = true）：此时不落库。
      session.applyAnswer(
        const RecoveryAnswer(
          sid: 's1',
          source: 'bridge',
          outcome: RecoveryOutcome.snapshot,
          reason: SnapshotReason.windowMissed,
          asOfSeq: 2,
          hasMore: true,
          items: [ItemRecord(itemId: 'm1', text: '一', seq: 1)],
          transient: {},
        ),
      );
      expect(session.hasOpenSnapshot('s1'), isTrue);
      expect(session.itemsOf('s1'), isEmpty, reason: '分页期间不渲染、不落盘');

      // 分页期间到达的增量：只缓存。
      session.receive('s1', 'm3', '三', 3);
      expect(session.itemsOf('s1'), isEmpty);
      expect(session.received['s1'], isNull);

      // 收口：合并两页 + 缓存。
      session.applyAnswer(
        const RecoveryAnswer(
          sid: 's1',
          source: 'bridge',
          outcome: RecoveryOutcome.snapshot,
          reason: SnapshotReason.windowMissed,
          asOfSeq: 2,
          hasMore: false,
          items: [ItemRecord(itemId: 'm2', text: '二', seq: 2)],
          transient: {},
        ),
      );
      expect(session.hasOpenSnapshot('s1'), isFalse);
      expect(session.itemsOf('s1'), {'m1': '一', 'm2': '二', 'm3': '三'});
      expect(session.received['s1'], 3);
      expect(session.sinceOf('s1'), 3, reason: '收口后落盘水位跟上');
    });

    test('增量应答：逐条 upsert 并把已收到水位推到 to', () {
      final session = DeviceSession();
      session.applyAnswer(
        const RecoveryAnswer(
          sid: 's1',
          source: 'relay',
          outcome: RecoveryOutcome.delta,
          from: 1,
          to: 2,
          items: [
            ItemRecord(itemId: 'm1', text: '一', seq: 1),
            ItemRecord(itemId: 'm2', text: '二', seq: 2),
          ],
          transient: {'computerOnline': true},
        ),
      );
      expect(session.itemsOf('s1'), {'m1': '一', 'm2': '二'});
      expect(session.received['s1'], 2);
      expect(session.transientOf('s1'), {'computerOnline': true});
      // **落盘水位不跟着走**：收到 ≠ 落盘（要显式 commit）。
      expect(session.sinceOf('s1'), 0);
    });

    test('瞬时事实无条件回带（不变量 I4），且带来源标记', () {
      final session = DeviceSession();
      session.applyAnswer(
        const RecoveryAnswer(
          sid: 's1',
          source: 'relay',
          outcome: RecoveryOutcome.delta,
          from: 1,
          to: 1,
          items: [ItemRecord(itemId: 'm1', text: '一', seq: 1)],
          transient: {'pendingApprovals': 2},
        ),
      );
      expect(session.transientOf('s1'), {'pendingApprovals': 2});
      // 中转补课的增量，瞬时事实仍必须来自电脑侧（I4）。
      expect(session.answers.single.transientSource, 'bridge');
    });

    test('convergedWith：条目表一致才算收敛', () {
      final session = DeviceSession();
      session.receive('s1', 'm1', '一', 1);
      expect(session.convergedWith('s1', {'m1': '一'}), isTrue);
      expect(session.convergedWith('s1', {'m1': '二'}), isFalse);
      expect(session.convergedWith('s1', {'m1': '一', 'm2': '二'}), isFalse);
    });
  });

  group('orderedItems：按 itemId 最后出现的 seq 排序（契约 §5.2）', () {
    test('upsert-only ⇒ 顺序取**最后**出现的修订号，不是首次', () {
      final log = [
        const LogEntry(seq: 1, itemId: 'a', text: 'a1'),
        const LogEntry(seq: 2, itemId: 'b', text: 'b1'),
        const LogEntry(seq: 3, itemId: 'a', text: 'a2'), // a 的最后一次是 3
      ];
      final items = {'a': 'a2', 'b': 'b1'};
      final ordered = orderedItems(log, items);
      expect(ordered.map((r) => r.itemId).toList(), [
        'b',
        'a',
      ], reason: 'b(2) 在 a(3) 之前');
      expect(ordered.last.seq, 3);
    });

    test('日志里没有的条目 seq 取 0（排在前面）', () {
      final ordered = orderedItems(const [], {'x': '1'});
      expect(ordered.single.seq, 0);
    });
  });

  group('帧解码的边界（契约 §3）', () {
    test('未知类型无 id → 忽略；有 id → 要回错（沉默会让对端永远挂着）', () {
      expect(decodeFrame('{"v":1,"t":"future"}'), isA<IgnoredFrame>());
      final unsupported = decodeFrame('{"v":1,"t":"future","id":"r1"}');
      expect(unsupported, isA<UnsupportedFrame>());
      expect((unsupported as UnsupportedFrame).id, 'r1');
    });

    test('版本不符 / 非 JSON / 非对象 / 缺 t 都要抛', () {
      expect(
        () => decodeFrame('{"v":2,"t":"ping"}'),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.unsupportedVersion,
          ),
        ),
      );
      for (final bad in const [
        'not json',
        '[1,2]',
        '"str"',
        '{"v":1}',
        'null',
      ]) {
        expect(
          () => decodeFrame(bad),
          throwsA(isA<ProtocolException>()),
          reason: '坏输入：$bad',
        );
      }
    });

    test('id / sid 的字符集限制在解码处拦（它们是 AAD 的组成部分）', () {
      for (final bad in const ['a+b', 'a/b', 'a=b', 'a b', '中文']) {
        expect(
          () => decodeFrame('{"v":1,"t":"req","id":"$bad","fc":0,"box":""}'),
          throwsA(
            isA<ProtocolException>().having(
              (e) => e.code,
              'code',
              ErrorCode.badFrame,
            ),
          ),
          reason: 'id=$bad 不是 ASCII 安全字符集',
        );
      }
      // 合法的照过。
      expect(
        decodeFrame('{"v":1,"t":"req","id":"a-b_C9","fc":0,"box":""}'),
        isA<DecodedFrame>(),
      );
    });

    test('分帧器：一次喂一片半行 + 多行', () {
      final splitter = LineSplitter();
      expect(splitter('{"a":1}\n{"b"'), ['{"a":1}']);
      expect(splitter(':2}\n{"c":3}\n'), ['{"b":2}', '{"c":3}']);
      // 空行跳过（`\n\n`）。
      expect(splitter('\n\n'), isEmpty);
    });
  });

  group('newFrameId：base64url 且落在 ASCII 安全字符集里', () {
    test('16 字节随机 → 22 字符 base64url（无填充），且能过 ID_PATTERN', () {
      final bytes = Uint8List.fromList(
        List<int>.generate(16, (i) => i * 7 % 256),
      );
      final id = newFrameId(bytes);
      expect(id.length, 22, reason: '16 字节 base64url 无填充是 22 字符');
      expect(id.endsWith('='), isFalse);
      expect(idPattern.hasMatch(id), isTrue, reason: 'id 必须落在 AAD 允许的字符集里');
    });
  });

  group('aadFieldsOf：从帧取 AAD 字段（契约 §3）', () {
    test('缺字段就不放进 map（交给 aadOf 用空串占位，于是「缺」只有一种表达）', () {
      final fields = aadFieldsOf({
        'v': 1,
        't': 'ev',
        'sid': 's1',
        'seq': 3,
        'fc': 7,
        'box': 'x',
      });
      expect(fields.t, 'ev');
      expect(fields.sid, 's1');
      expect(fields.seq, 3);
      expect(fields.fc, 7);
      expect(fields.id, isNull, reason: '没有 id 就不放进去（与显式写空串等价）');
    });

    test('与显式空串规范化成同一个串（这正是"两种写法都收"的依据）', () {
      final omitted = aadFieldsOf({'v': 1, 't': 'ping', 'fc': 1});
      final explicit = aadFieldsOf({
        'v': 1,
        't': 'ping',
        'id': '',
        'sid': '',
        'seq': '',
        'fc': 1,
      });
      expect(toHex(aadOf(omitted)), toHex(aadOf(explicit)));
    });
  });
}
