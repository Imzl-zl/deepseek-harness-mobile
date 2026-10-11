/// 握手驱动（**发起方** / 手机侧）：把 §4.1 的三条消息走完，并把结论交给连接层。
///
/// ```text
/// 手机 → 电脑   hello      { ephPubA, devId, nonceA }        发起方生成临时密钥
/// 电脑 → 手机   hello-ack  { ephPubB, pcId, nonceB, sigB }   验 sigB → 派生密钥
/// 手机 → 电脑   confirm    { sigA, transcriptHash }          进 serving
/// ```
///
/// ## 顺序：发起方**先发** `hello`
///
/// 这是与电脑侧驱动（应答方）最大的差别：应答方等 `hello` 上门，发起方必须自己开这个头。
/// 所以本驱动的会话**一建好就发 `hello`**，而不是等一个"开始"信号 ——
/// 少写这一步的症状是"两边都安静地等对方"，而连接停在 `handshake` 直到超时。
///
/// ## 为什么只有发起方这一半
///
/// 发起方**永远是手机**（`hello` 由它发），电脑侧永远只应答 —— 不是"暂时没写另一半"。
/// 所以这里没有 `role` 分支：加一个永远不被走到的 responder 分支，
/// 只会在将来被误当成"协议支持双向发起"。
///
/// ## 失败一律是关闭，不是重试
///
/// §4.1：「握手失败不计入业务重试次数」。所以本文件不重试、不降级、不"先收着"：
/// 任何一步不通过都调 `context.failed()`，由连接层关掉这条连接（随后按退避重连，
/// 而重连会换一套临时密钥与 `fc` 计数器 —— 这正是重试安全的来源）。
///
/// ## 密钥只在验签通过之后才派生
///
/// 顺序不能颠倒：先派生再校验，等于让一个没通过认证的对端参与密钥计算。
/// 发起方的两道校验是：**验 `sigB`**（本文件）+ **对端比对 `confirm` 的 `transcriptHash`**
/// （对方那侧做，我方负责算出来并回带）。
///
/// 移植源：`connector/src/protocol/handshake-driver.ts`（**应答方**那一半）与
/// `connector/tests/support/phone.ts`（发起方的行为基准）。
library;

import 'dart:async';

import 'crypto.dart';
import 'errors.dart';
import 'frame.dart';
import 'handshake.dart';

/// 握手超时（契约 §4.1 参数表：10 s）。
const int handshakeTimeoutMs = 10000;

/// 本端身份（手机）。
class HandshakeIdentity {
  const HandshakeIdentity({
    required this.staticKeys,
    required this.signSeedHex,
    required this.devId,
  });

  /// 静态 DH 密钥对（参与 §4.1 的三份共享密钥）。
  final KeyPair staticKeys;

  /// Ed25519 身份签名种子（签 transcript）。
  final String signSeedHex;

  /// 本机设备 id（进 `hello` 的 `devId`，因而参与 transcript）。
  final String devId;
}

/// 对端（电脑）的身份 —— **只来自二维码**。
///
/// §12.1 的硬规则：手机**只信任二维码里带出的电脑公钥**，不接受任何网络下发的电脑公钥。
/// 所以这个对象只能由扫码路径构造，不能由帧内容构造。
class PeerIdentity {
  const PeerIdentity({
    required this.pcSignPubHex,
    required this.pcDhPubHex,
    required this.pcId,
    required this.pairingId,
  });

  /// 电脑侧 Ed25519 公钥（验 `sigB`）。**扫码得到**。
  final String pcSignPubHex;

  /// 电脑侧 X25519 静态公钥（参与密钥派生）。**扫码得到**。
  final String pcDhPubHex;

  /// 电脑侧标识（进 transcript）。
  final String pcId;

  /// 配对标识（§12.1）：参与 HKDF 的 `info`，两端必须相同。
  final String pairingId;
}

/// 握手成功后的产物。
class HandshakeEstablishment {
  const HandshakeEstablishment({required this.devId, required this.keys});

  final String devId;
  final SessionKeys keys;
}

/// 握手上下文（由连接层提供）。
class HandshakeContext {
  const HandshakeContext({
    required this.send,
    required this.established,
    required this.failed,
    required this.schedule,
  });

  /// 握手阶段发一帧。连接层保证这条路径只能出握手帧。
  final void Function(Map<String, Object?> frame) send;

  /// 三帧走完、密钥已派生。连接层据此进 `serving`。
  final void Function(HandshakeEstablishment result) established;

  /// 握手失败。连接层应关闭这条连接。
  final void Function(ErrorCode reason, Object? error) failed;

  /// `setTimeout` 语义。**调用它得到取消函数**（`schedule(fn, ms)()` 取消）。
  final void Function() Function(void Function() fn, int ms) schedule;
}

/// 一次握手会话（每次建连一个）。
abstract interface class HandshakeSession {
  /// 收到一帧握手帧。握手完成后连接层不再往这里投递。
  void onFrame(Map<String, Object?> frame);

  /// 连接结束或主动停止：取消在途超时。
  void dispose();
}

/// 每次建连调用一次，得到该连接的握手会话（**它会立刻发出 `hello`**）。
typedef HandshakeDriver = HandshakeSession Function(HandshakeContext context);

/// 发起方握手驱动。
///
/// [newEphemeralSeedHex] / [newNonceHex] / [newFrameIdHex] 注入是为了让测试确定化；
/// **生产里每次建连都必须重新生成临时密钥**（§4.1：复用会让 `fc` 从 0 重数 ⇒ nonce 重用）。
HandshakeDriver createHandshakeDriver({
  required HandshakeIdentity identity,
  required PeerIdentity peer,
  required String Function() newEphemeralSeedHex,
  required String Function() newNonceHex,
  required String Function() newFrameIdHex,
  String info = keyInfo,
  String? transcriptContext,
  int timeout = handshakeTimeoutMs,
}) {
  return (context) => _InitiatorSession(
    identity: identity,
    peer: peer,
    info: info,
    transcriptContext: transcriptContext,
    context: context,
    timeout: timeout,
    newEphemeralSeedHex: newEphemeralSeedHex,
    newNonceHex: newNonceHex,
    newFrameIdHex: newFrameIdHex,
  );
}

class _InitiatorSession implements HandshakeSession {
  _InitiatorSession({
    required this.identity,
    required this.peer,
    required this.info,
    required this.transcriptContext,
    required this.context,
    required this.timeout,
    required this.newEphemeralSeedHex,
    required this.newNonceHex,
    required this.newFrameIdHex,
  }) {
    _begin();
  }

  final HandshakeIdentity identity;
  final PeerIdentity peer;
  final String info;
  final String? transcriptContext;
  final HandshakeContext context;
  final int timeout;
  final String Function() newEphemeralSeedHex;
  final String Function() newNonceHex;
  final String Function() newFrameIdHex;

  bool _settled = false;
  void Function()? _cancelTimeout;

  /// 发出 `hello` 之后、收到 `hello-ack` 之前要留住的东西。
  HelloFields? _helloFields;

  /// 已经收到 `hello-ack`（再收到一次就是重复投递）。
  bool _acked = false;

  void _settle() {
    _settled = true;
    _cancelTimeout?.call();
    _cancelTimeout = null;
  }

  void _fail(ErrorCode reason, [Object? error]) {
    if (_settled) return;
    _settle();
    context.failed(reason, error);
  }

  /// 发起方开这个头：生成临时密钥 → 发 `hello` → 起超时。
  ///
  /// **临时密钥在这里生成**（每连接一次，§4.1）—— 不是在收到 `hello-ack` 时：
  /// 那时 `hello` 已经发出去了，而 transcript 要用 `ephPubA`。
  void _begin() {
    _cancelTimeout = context.schedule(() {
      // 对端没在时限内把三条消息走完。不发任何协议帧：对端要么已经死了，
      // 要么在等我们 —— 两种情况下关掉连接都是唯一有意义的动作。
      _fail(ErrorCode.internal, 'handshake-timeout');
    }, timeout);

    // 异步：从种子建密钥对是 `await` 的。
    // `unawaited` 是**刻意的**：`_begin` 由构造函数调用，不能是 async；
    // 而失败必须走 `_fail`（关连接），不是抛给调用方。
    unawaited(
      _sendHello().catchError((Object error) {
        _fail(
          error is ProtocolException ? error.code : ErrorCode.internal,
          error,
        );
      }),
    );
  }

  Future<void> _sendHello() async {
    final ephKeys = await x25519FromSeed(newEphemeralSeedHex());
    final fields = HelloFields(
      ephPubA: ephKeys.publicKeyHex,
      devId: identity.devId,
      nonceA: newNonceHex(),
    );
    _helloFields = fields;
    _ephemeralKeys = ephKeys;
    context.send({
      'v': wireVersion,
      't': 'hello',
      'id': newFrameIdHex(),
      'box': encodeHello(fields),
    });
  }

  KeyPair? _ephemeralKeys;

  @override
  void onFrame(Map<String, Object?> frame) {
    if (_settled) return;
    // 异步：验签与派生都是 `await` 的，而收帧路径不能阻塞
    //（同一条 socket 上还有 `credit` 与保活要走）。
    unawaited(
      _handle(frame).catchError((Object error) {
        _fail(
          error is ProtocolException ? error.code : ErrorCode.internal,
          error,
        );
      }),
    );
  }

  Future<void> _handle(Map<String, Object?> frame) async {
    final type = frame['t'];
    if (type != 'hello-ack') {
      // 发起方的第一步回应必须是 hello-ack（hello 由我方发出，不该收到它）。
      throw ProtocolException(
        ErrorCode.badFrame,
        '握手第一步应收到 hello-ack，收到 $type',
      );
    }
    if (_acked) {
      // 重复投递：`hello-ack` 只能收一次（两次会让两次派生用不同的 nonceB）。
      throw const ProtocolException(ErrorCode.badFrame, '重复的 hello-ack');
    }
    _acked = true;

    final helloFields = _helloFields;
    final ephKeys = _ephemeralKeys;
    if (helloFields == null || ephKeys == null) {
      // 只可能是"hello 还没发出去就收到了 ack"—— 装配或时序错了。
      throw const ProtocolException(
        ErrorCode.internal,
        '还没发出 hello 就收到了 hello-ack',
      );
    }

    final box = frame['box'];
    if (box is! String) {
      throw const ProtocolException(ErrorCode.badFrame, 'hello-ack 缺少 box');
    }
    final ack = parseHelloAck(box);

    // 两侧各拼一遍同一段字节：手机用**它自己发出的 hello 字段** + **收到的 ack 字段**。
    //
    // `transcriptContext` 是**配对用途**的绑定（正常业务为 null）：它把
    // 「这次握手是给哪个邀请、哪个候选身份用的」钉进被签的字节里，于是中转
    // 替换候选公钥、或把 A 设备的 confirm 挪给 B 邀请，都会在验签处失败。
    // 电脑侧同一处见 `connector/src/protocol/handshake-driver.ts:176`。
    final transcript = transcriptFromFields(
      helloFields,
      ack.fields,
      transcriptContext,
    );

    // 第一道校验：**验 sigB**。契约 §4.1 明写「中继替换公钥无法通过验签」——
    // 也就是说端到端加密的抗中间人能力完全落在这里。
    // 验不过就抛 `not-paired`（手机据此清除凭据、回配对页）。
    await verifySignature(
      transcript: transcript,
      publicKeyHex: peer.pcSignPubHex,
      signatureHex: ack.sigB,
      role: '电脑侧',
    );

    final keys = await deriveSessionKeys(
      role: HandshakeRole.initiator,
      ownStaticPrivate: identity.staticKeys.keyPair,
      ownEphemeralPrivate: ephKeys.keyPair,
      peerStaticPublicHex: peer.pcDhPubHex,
      peerEphemeralPublicHex: ack.fields.ephPubB,
      nonceA: helloFields.nonceA,
      nonceB: ack.fields.nonceB,
      info: info,
      pairingId: peer.pairingId,
    );

    // 第二道校验在**对端**（它比对 confirm 里的 transcriptHash）。
    // 我方负责把摘要算出来并回带 —— 它防的是"双方各自算出了不同的 transcript
    // 却都没发现"：单靠签名只能证明"对方持有私钥"，不能证明"我们签的是同一段字节"。
    final transcriptHash = await transcriptHashOf(transcript);

    context.send({
      'v': wireVersion,
      't': 'confirm',
      'id': newFrameIdHex(),
      'box': encodeConfirm(
        ConfirmFields(
          sigA: await signTranscript(identity.signSeedHex, transcript),
          transcriptHash: transcriptHash,
        ),
      ),
    });

    _settle();
    context.established(
      HandshakeEstablishment(devId: identity.devId, keys: keys),
    );
  }

  @override
  void dispose() => _settle();
}
