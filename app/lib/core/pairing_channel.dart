/// 首配的**受限通道**（契约 §12.1；规格 `docs/subsystems/pairing-v2.md` §4–5）。
///
/// ## 它不是"另一套密码学"
///
/// 握手、封箱、分帧全部复用业务连接那一套实现（`handshake_driver` / `box` / `frame`）。
/// 与业务连接的差别只有三条，而三条都是**授权边界**，不是加密细节：
///
/// | 差别 | 为什么 |
/// |---|---|
/// | 派生域 `pairingKeyInfo` + 临时配对标识 `offerId` | 候选通道的密钥与正式设备的密钥不可能撞上 |
/// | `transcriptContext` 进被签的字节 | 中转换掉候选公钥、或把 A 的 `confirm` 挪给 B，都在验签处失败 |
/// | 只允许保活/流控与 `pair-commit` | 握手成功只表示"配对加密可用"，**不等于授权** |
///
/// 第三条由电脑侧那条连接自己收口（`connector/src/connection-scope.ts:100-103`：
/// 候选连接收到别的帧即 `protocol/not-paired`），本文件的收帧分支与它逐条对齐 ——
/// 两侧对"这一阶段允许什么"必须只有一个答案。
///
/// ## 秘密只在 [commit] 里出去
///
/// 配对码是整条链上**唯一一次**把带外秘密交给电脑的动作，所以它单独是一个方法：
/// [open] 只把通道建起来（此刻电脑侧还没有任何有效设备记录，也没有签发任何令牌），
/// 用户确认之后才 [commit]。把两者合成一个函数，就没有地方插进"用户确认"这一步了。
///
/// Note: 为什么首配要区分「候选」与「正式设备」两个身份 —— 见
/// `.agents/notes/implemented/2026-10-08-pairing-v2-and-device-connections.md`；
/// 手机侧为什么做成"两段"（受限通道先建、秘密后发）见
/// `.agents/notes/implemented/2026-10-09-app-pairing-v2-two-phase.md`。
library;

import 'dart:async';
import 'dart:convert' show jsonEncode;

import 'box.dart';
import 'crypto.dart';
import 'errors.dart';
import 'frame.dart';
import 'handshake_driver.dart';
import 'pairing.dart';
import 'pairing_exchange.dart';
import 'transport.dart';

/// 握手三帧走完的时限（契约 §4.1 参数表同量级）。
///
/// 它不是"网络慢"的兜底，而是**判据**：对端没在时限内走完三帧，说明它要么死了、
/// 要么在等我们 —— 两种情况下关掉这条连接都是唯一有意义的动作。
const Duration pairingHandshakeTimeout = Duration(seconds: 15);

/// 等 `pair-result` 的时限。
///
/// 同样不是兜底：`pair-commit` 没有回执，说明电脑侧没接住这一跳
/// （配对登记不可用、写库失败、或者对端行为不对）。没有它，用户看到的是配对页一直转圈。
const Duration pairingCommitTimeout = Duration(seconds: 15);

/// 首配的受限通道（**每台候选一条**，用完即走）。
///
/// 生命周期：`open()` → （用户确认）→ `commit()` → `close()`。
class PairingChannel {
  PairingChannel({
    required this.transport,
    required this.offer,
    required this.identity,
    required this.candidate,
    required this.devId,
    String Function()? newFrameIdHex,
    String Function()? newEphemeralSeedHex,
    String Function()? newNonceHex,
    this.handshakeTimeout = pairingHandshakeTimeout,
    this.commitTimeout = pairingCommitTimeout,
  }) : _newFrameIdHex =
           newFrameIdHex ?? (() => newFrameId(randomBytes(frameIdBytes))),
       _newEphemeralSeedHex =
           newEphemeralSeedHex ?? (() => toHex(randomBytes(32))),
       _newNonceHex = newNonceHex ?? (() => toHex(randomBytes(32))) {
    // 配对是**用户可能中途放弃**的流程：没人 await 的错误 Future 会以
    // "未处理异常"的形式炸出来，而现象与真因毫无关系。`ignore()` 只标记"这个错误有人管"，
    // [commit] 里那次 await 照样会收到它。
    _ack.future.ignore();
  }

  /// 已经带票的传输（实现由装配层注入：`platform/websocket_transport.dart`）。
  final ChannelTransport transport;

  /// 二维码里的全部可信输入。**电脑公钥只来自它**（契约 §12.1 的硬规则）。
  final PairingOffer offer;

  /// 本机身份（主种子派生）。
  final IdentityKeys identity;

  /// 本机作为候选的自报身份。它与 `pair-commit` 载荷里的自报身份**不是**一回事：
  /// 电脑侧只认这条连接握手时的候选（`pairing-v2.md` §5）。
  final PairingCandidate candidate;

  /// 本机设备 id（进 `hello`，因而参与 transcript）。
  final String devId;

  final Duration handshakeTimeout;
  final Duration commitTimeout;

  final String Function() _newFrameIdHex;
  final String Function() _newEphemeralSeedHex;
  final String Function() _newNonceHex;

  final Completer<BoxCodec> _ready = Completer<BoxCodec>();
  final Completer<PairingAck> _ack = Completer<PairingAck>();
  final LineSplitter _splitter = LineSplitter();

  StreamSubscription<TransportEvent>? _events;
  HandshakeSession? _handshake;
  BoxCodec? _codec;
  int _fc = 0;
  String? _commitId;
  bool _committed = false;
  bool _closed = false;
  Exception? _failure;

  /// 建连 + 受限握手。**不发任何秘密**（电脑侧此刻仍没有这台设备的记录）。
  Future<void> open() async {
    // 上下文先算：它只依赖本地输入，而下面一旦订阅了帧流，就必须保证
    // `_handshake` 已经就位 —— 否则一个早到的 `hello-ack` 会被静默丢掉（表现为握手超时）。
    final transcriptContext = await candidate.handshakeContext(offer);
    final events = await transport.connect();
    _events = events.listen(
      _onEvent,
      onError: (Object error) => _fail(TransportException('配对连接出错：$error')),
      onDone: () => _fail(const TransportException('配对连接被对端关闭')),
    );

    final context = HandshakeContext(
      send: (frame) => transport.send(encodeFrame(frame)),
      established: (result) {
        // 只有走到这里，"配对加密可用"才成立 —— 而它**不是**业务授权。
        final codec = BoxCodec(
          keys: result.keys,
          role: HandshakeRole.initiator,
        );
        _codec = codec;
        if (!_ready.isCompleted) _ready.complete(codec);
      },
      failed: (code, error) =>
          _fail(ProtocolException(code, '配对握手失败：${error ?? '对端未在时限内走完三帧'}')),
      schedule: (fn, ms) {
        final timer = Timer(Duration(milliseconds: ms), fn);
        return timer.cancel;
      },
    );

    _handshake = createHandshakeDriver(
      identity: HandshakeIdentity(
        staticKeys: identity.dh,
        signSeedHex: identity.signSeedHex,
        devId: devId,
      ),
      peer: PeerIdentity(
        pcSignPubHex: offer.pcSignPubHex,
        pcDhPubHex: offer.pcDhPubHex,
        pcId: offer.pcId,
        // 临时配对标识就是 `offerId`：正式设备的 `pairingId` 要等配对成功才派生得出
        // （它来自电脑侧的秘密），而候选这一刻不能知道它。
        pairingId: offer.offerId,
      ),
      info: pairingKeyInfo,
      transcriptContext: transcriptContext,
      newEphemeralSeedHex: _newEphemeralSeedHex,
      newNonceHex: _newNonceHex,
      newFrameIdHex: _newFrameIdHex,
      timeout: handshakeTimeout.inMilliseconds,
    )(context);

    await _ready.future;
  }

  /// 提交秘密（配对码）。**整条链上唯一一次把码发出去。**
  ///
  /// 返回电脑侧的回执（含设备令牌与辅助 SAS）。结果不确定时**如实抛错**，
  /// 绝不假装"没配对过" —— 断开不等于写入回滚（`pairing-v2.md` §1）。
  Future<PairingAck> commit(String code) async {
    if (_committed) {
      throw const ProtocolException(ErrorCode.internal, '这次配对已经提交过了');
    }
    _committed = true;

    final failure = _failure;
    if (failure != null) throw failure;
    if (_closed) {
      // **关闭是终态**：页面退掉之后可能还有一个 `_commit` 在飞（`dispose` 与
      // 用户点按之间没有原子性）。此时既不能发帧、也不能假装成功 ——
      // 电脑侧有没有登记上这台设备是个**未知**，界面必须如实说"结果待确认"。
      throw const ProtocolException(
        ErrorCode.internal,
        '配对通道已经关闭：这次提交没有发出去，去电脑上核对这台设备是否已登记',
      );
    }
    if (_codec == null) {
      throw const ProtocolException(ErrorCode.internal, '配对通道还没就绪就提交');
    }

    final id = _newFrameIdHex();
    _commitId = id;
    await _sendBoxed(
      'pair-commit',
      jsonEncode(<String, Object?>{
        'v': pairingPayloadVersion,
        'offerId': offer.offerId,
        'code': code,
      }),
      id: id,
    );
    return _ack.future.timeout(
      commitTimeout,
      onTimeout: () => throw const ProtocolException(
        ErrorCode.internal,
        '等待配对回执超时：电脑侧没接住这一跳，请在电脑上核对配对状态',
      ),
    );
  }

  /// 关掉这条短连接。**幂等**。
  ///
  /// 配对是一次短交互：完成后 App 会用正式传输重新连（那一次才是长期连接），
  /// 留着这条 socket 只会让中转上多出一条谁也不用的连接。
  Future<void> close() async {
    if (_closed) return; // 幂等：收口路径可能被调两次（`dispose` 与用户放弃）
    _closed = true;
    final events = _events;
    _events = null;
    _handshake?.dispose();
    _handshake = null;
    // `cancel()` 返回的 Future 只表示"清理完成"，事件在调它的那一刻就不再投递了 ——
    // 收口路径 await 它只会多一个窗口，让别的回调在那期间再进来一次。
    if (events != null) {
      unawaited(events.cancel().catchError((Object _) {}));
    }
    await transport.close();
  }

  /// 第一个原因才是真因，后面的多半是它的回声（关闭回调、取消订阅都会再来一次）。
  void _fail(Exception failure) {
    if (_failure != null) return;
    _failure = failure;
    if (!_ready.isCompleted) _ready.completeError(failure);
    if (_committed && !_ack.isCompleted) _ack.completeError(failure);
  }

  void _onEvent(TransportEvent event) {
    switch (event) {
      case TransportMessage(:final chunk):
        for (final line in _splitter(chunk)) {
          final Object? decoded;
          try {
            decoded = decodeFrame(line);
          } on ProtocolException catch (error) {
            _fail(error);
            return;
          }
          // 未知帧类型：不是配对阶段的东西（向前兼容的那条规则在这里不适用，
          // 因为候选连接对"允许什么"是封闭的）。
          if (decoded is! DecodedFrame) continue;
          unawaited(
            _onFrame(decoded.frame).catchError((Object error) {
              _fail(
                error is ProtocolException
                    ? error
                    : ProtocolException(ErrorCode.internal, '配对通道出错：$error'),
              );
            }),
          );
        }
      case TransportClosed(:final code, :final reason):
        _fail(TransportException('配对连接被关闭：${reason ?? code ?? '对端断开'}'));
    }
  }

  Future<void> _onFrame(Map<String, Object?> frame) async {
    final codec = _codec;
    if (codec == null) {
      // 握手还没完成：只有握手帧能进来，其余由驱动判成 `bad-frame` 并关掉连接。
      _handshake?.onFrame(frame);
      return;
    }

    switch ('${frame['t']}') {
      case 'pair-result':
        final box = frame['box'];
        if (box is! String) {
          _fail(
            const ProtocolException(ErrorCode.badFrame, 'pair-result 缺少 box'),
          );
          return;
        }
        // 回帧必须回显我们那一跳的 `id`（没有 `sid` 的帧在链路上只能靠它定向）：
        // 对不上说明这条回帧不是给我们这次提交的。
        if (frame['id'] != _commitId) {
          _fail(
            ProtocolException(
              ErrorCode.badFrame,
              'pair-result 的 id 对不上这一跳提交：${frame['id']}',
            ),
          );
          return;
        }
        if (!_ack.isCompleted) {
          _ack.complete(parsePairAck(await codec.openFrame(frame, box)));
        }
      case 'ping':
        // 回显请求的 `id`：没有 `sid` 的帧靠它定向。
        //
        // 这一条是**必需**的，不是礼貌：用户可能对着确认卡想上一分钟，而电脑侧的半开判据是
        // "任一方向连续两个心跳周期无帧" —— 不回 `pong` 的话，那条候选连接会在用户
        // 还没点确认时就被电脑关掉，而用户看到的只是"提交失败"。
        await _sendBoxed('pong', '', id: '${frame['id']}');
      case 'pong':
      case 'credit':
      case 'presence':
        // 保活回执与流控记账：候选通道没有发送窗口要放宽，也没有增量缓冲要裁剪。
        return;
      default:
        // **不静默丢弃**：配对阶段收到业务帧说明对端搞错了阶段，而"发出去没人管"
        // 是最难查的一类故障（电脑侧同一处也是硬失败）。
        _fail(
          ProtocolException(ErrorCode.badFrame, '配对通道不该收到 ${frame['t']} 帧'),
        );
    }
  }

  /// 封箱 + 发帧。**`fc` 的分配与封箱紧挨着**（§4.2）：分开写就会出现
  /// "封的时候用了另一个 `fc`"，而同一个 `fc` 封两次就是 nonce 重用，直接破 AEAD。
  Future<void> _sendBoxed(String type, String plaintext, {String? id}) async {
    if (_closed) {
      throw ProtocolException(ErrorCode.internal, '配对通道已关闭，$type 没有发出去');
    }
    final codec = _codec;
    if (codec == null) {
      throw ProtocolException(ErrorCode.internal, '握手还没完成就想发 $type 帧');
    }
    final wire = <String, Object?>{
      'v': wireVersion,
      't': type,
      // 空值标记写在**值**上：`id` 为 null 时这一项整个不出现（AAD 里就是空串占位）。
      'id': ?id,
      'fc': _fc,
    };
    _fc += 1;
    final box = await codec.sealFrame(wire, plaintext);
    transport.send(encodeFrame(<String, Object?>{...wire, 'box': box}));
  }
}
