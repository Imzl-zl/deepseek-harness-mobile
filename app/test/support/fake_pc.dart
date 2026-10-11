/// **电脑侧替身**（只用于测试）：说应答方那半边协议，用来驱动 Dart 的候选通道。
///
/// ## 它为什么存在
///
/// 候选通道的发起方是手机，所以"手机这半边写得对不对"只有在**真的对上一个应答方**
/// 时才看得出来：握手三帧的形状、`fc` 从 0 起、上下文进 transcript、
/// `pair-commit` 的载荷形状 —— 这些在只测自己内部状态的单测里全是盲区。
///
/// ## 它不是跨端证据
///
/// 电脑侧的真实实现在 TS（`connector/src/protocol/handshake-driver.ts`、
/// `connector/src/connection-scope.ts`），Dart 单测里跑不了它。所以这份替身只用来验
/// "**手机侧的行为符合契约**"；跨端证据在
/// `connector/tests/pairing-e2e.test.ts`（真中转 + 真握手 + TS 手机替身）
/// 与真机集成用例（`app/integration_test/channel_e2e_test.dart`）里。
///
/// 判断依据是"两侧各算一遍"那条纪律：这里算的 transcript / 会话密钥如果与手机侧
/// 算的不同，握手就会当场失败 —— 也就是它**能**抓住"我这半边写错了"，
/// 抓不住的是"两侧一起想错了"（那由跨端向量与真机验）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dsh_mobile/core/box.dart';
import 'package:dsh_mobile/core/crypto.dart';
import 'package:dsh_mobile/core/frame.dart';
import 'package:dsh_mobile/core/handshake.dart';
import 'package:dsh_mobile/core/pairing.dart';
import 'package:dsh_mobile/core/transport.dart';

/// 电脑侧签发的令牌形状：22 字符 base64url。
///
/// 手机侧按这个格式校验（`^[A-Za-z0-9_-]{22}$`），所以替身随手给一个 `tok-1`
/// 会被拒 —— 那是**对的**（短/空令牌拿下去换票必然 401，而那时没人会想到根因在回执）。
String testToken(String prefix) => prefix.padRight(22, '0');

/// 回执的默认成功载荷（形状与电脑侧 `PairingReply` 一致）。
Map<String, Object?> defaultPairingReply({
  required String devId,
  String sas = '123456',
  String pcId = 'conn-1',
  String? deviceToken,
  String? refreshToken,
}) => <String, Object?>{
  'ok': true,
  'devId': devId,
  'sas': sas,
  'pcId': pcId,
  'deviceToken': deviceToken ?? testToken('tok'),
  'refreshToken': refreshToken ?? testToken('ref'),
};

/// 一次候选连接的电脑侧。
class FakePc implements ChannelTransport {
  FakePc({
    required this.pcSeedHex,
    required this.offer,
    required this.candidate,
    Map<String, Object?>? reply,
    this.commitFailure,
  }) : reply = reply ?? defaultPairingReply(devId: '');

  /// 电脑侧身份种子（测试固定值）。
  final String pcSeedHex;

  /// 这次配对的可信输入（测试里就是"二维码里的东西"）。
  final PairingOffer offer;

  /// 中转告知的候选身份（电脑侧由此知道该验谁的签名）。
  final PairingCandidate candidate;

  Map<String, Object?> reply;

  /// 想让它"拒绝提交"时给一句原因（模拟 `pair-result` 里 `ok:false`）。
  final Map<String, Object?>? commitFailure;

  /// 收到的全部原始行（断言帧形状用）。
  final List<String> lines = <String>[];

  /// `pair-commit` 解密后的载荷（断言"秘密只在密文里"用）。
  Map<String, Object?>? commitPayload;

  /// 电脑侧算出的 transcript（与手机侧比对用）。
  List<int>? transcript;

  /// 会话密钥是否谈成（谈成了才允许提交）。
  bool established = false;

  final StreamController<TransportEvent> _events =
      StreamController<TransportEvent>();

  IdentityKeys? _identity;
  KeyPair? _ephemeral;
  String? _nonceB;
  HelloFields? _hello;
  BoxCodec? _codec;
  int _fc = 0;
  int _received = 0;

  @override
  Future<Stream<TransportEvent>> connect() async => _events.stream;

  /// 手机侧发出的一帧（相当于"中转把它送到了电脑侧"）。
  ///
  /// **必须按序处理**：真电脑侧的密钥派生是同步的（`node:crypto`），所以它收到
  /// `confirm` 时就已经"握手完成"，下一帧 `pair-commit` 才可能被接住。Dart 侧的
  /// 密码学是 `Future`，不排队的话 `pair-commit` 会插到 `confirm` 前面 ——
  /// 那是**替身的时序 bug**，会伪装成"手机侧提交得太早"。
  ///
  /// 替身自己的错误（帧形状不对、验签不过）走**流错误**回给手机侧 ——
  /// 与真电脑侧"握手失败即关连接"同一形态，而不是抛进测试的调用栈里。
  @override
  bool send(String line) {
    _inbox = _inbox.then((_) => receive(line)).catchError((Object error) {
      if (!_events.isClosed) _events.addError(error);
    });
    return true;
  }

  /// 收帧队列（见 [send]）。
  Future<void> _inbox = Future<void>.value();

  /// 等替身把手上的帧处理完。
  ///
  /// 断言替身的**内部状态**（`established` / `commitPayload`）之前必须先等它 ——
  /// 手机侧"发完 confirm 就认为自己握手完成"，而替身那边还在异步派生密钥。
  /// 不等的话断言会随机器快慢时红时绿（那是测试的竞态，不是实现的）。
  Future<void> drain() => _inbox;

  @override
  Future<void> close() async {
    if (!_events.isClosed) await _events.close();
  }

  /// 喂一行进来（相当于"中转把手机的一帧送到了电脑侧"）。
  Future<void> receive(String line) async {
    lines.add(line);
    _received += 1;
    final decoded = decodeFrame(line);
    if (decoded is! DecodedFrame) return;
    final frame = decoded.frame;
    switch ('${frame['t']}') {
      case 'hello':
        await _onHello(frame);
      case 'confirm':
        await _onConfirm(frame);
      case 'pair-commit':
        await _onCommit(frame);
      case 'pong':
        return;
      default:
        throw StateError('电脑侧收到不该出现的帧：${frame['t']}');
    }
  }

  Future<void> _onHello(Map<String, Object?> frame) async {
    final identity = _identity ??= await deriveIdentity(pcSeedHex);
    final hello = parseHello('${frame['box']}');
    _hello = hello;
    // 真电脑侧在这一步查设备表：候选的 `devId` 必须等于它自己派生的那个
    // （`deviceIdOf(devPubDh)`）。对不上就当作"没见过这台设备"。
    if (hello.devId != await candidate.deviceId()) {
      throw StateError('hello 的 devId 与候选不一致：${hello.devId}');
    }
    final ephemeral = _ephemeral ??= await x25519FromSeed('e1' * 32);
    final nonceB = _nonceB ??= 'b2' * 32;
    final ack = HelloAckFields(
      ephPubB: ephemeral.publicKeyHex,
      pcId: offer.pcId,
      nonceB: nonceB,
    );
    final transcript = transcriptFromFields(
      hello,
      ack,
      await candidate.handshakeContext(offer),
    );
    this.transcript = transcript;
    _emit(<String, Object?>{
      'v': wireVersion,
      't': 'hello-ack',
      'id': frame['id'], // **回显请求的 id**（契约 §3）
      'box': encodeHelloAck(
        ack,
        await signTranscript(identity.signSeedHex, transcript),
      ),
    });
  }

  Future<void> _onConfirm(Map<String, Object?> frame) async {
    final identity = _identity!;
    final hello = _hello!;
    final ephemeral = _ephemeral!;
    final confirm = parseConfirm('${frame['box']}');
    // 两道校验，与电脑侧驱动同序：先验签，再比对双方算出的 transcript 是不是同一段。
    await verifySignature(
      transcript: transcript!,
      publicKeyHex: candidate.devPubEdHex,
      signatureHex: confirm.sigA,
      role: '手机侧',
    );
    await verifyConfirm(
      transcript: transcript!,
      transcriptHash: confirm.transcriptHash,
    );
    final keys = await deriveSessionKeys(
      role: HandshakeRole.responder,
      ownStaticPrivate: identity.dh.keyPair,
      ownEphemeralPrivate: ephemeral.keyPair,
      peerStaticPublicHex: candidate.devPubDhHex,
      peerEphemeralPublicHex: hello.ephPubA,
      nonceA: hello.nonceA,
      nonceB: _nonceB!,
      info: pairingKeyInfo,
      pairingId: offer.offerId,
    );
    _codec = BoxCodec(keys: keys, role: HandshakeRole.responder);
    established = true;
  }

  Future<void> _onCommit(Map<String, Object?> frame) async {
    final codec = _codec;
    if (codec == null) {
      throw StateError('握手还没完成就收到了 pair-commit');
    }
    commitPayload =
        jsonDecode(await codec.openFrame(frame, '${frame['box']}'))
            as Map<String, Object?>;
    final id = '${frame['id']}';
    final payload =
        commitFailure ??
        (reply['devId'] == ''
            ? defaultPairingReply(devId: await candidate.deviceId())
            : reply);
    final header = <String, Object?>{
      'v': wireVersion,
      't': 'pair-result',
      'id': id, // **回显请求的 id**
      'fc': _fc,
    };
    _fc += 1;
    _emit(<String, Object?>{
      ...header,
      'box': await codec.sealFrame(header, jsonEncode(payload)),
    });
  }

  void _emit(Map<String, Object?> frame) {
    _events.add(TransportMessage(encodeFrame(frame)));
  }

  /// 电脑侧一共收到几帧（断言"握手期一帧都不多发"用）。
  int get receivedFrames => _received;
}
