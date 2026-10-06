/// 箱：业务帧的 AEAD 封装与解封（契约 §3、§4.2）。
///
/// 握手只把密钥谈出来；从握手完成到"手机看到一句话"之间，还差**每一帧的封箱与解封**。
///
/// ## 三条不可协商的规则
///
/// 1. **每一个 `fc` 只封一次箱**。`fc` 就是 nonce（§4.2），同一个 `fc` 封两次即 nonce 重用，
///    而 nonce 重用会**直接破掉 AEAD**（可恢复明文、可伪造）。分配权在连接层，
///    本文件只多设一道绊线：单调性被破坏就抛，而不是默默再封一次。
/// 2. **先验签，后推进重放窗口**。窗口只在 AEAD 校验通过后前进 —— 否则未认证的 `fc`
///    就能替对端"提前"推进窗口，把后续合法帧全判成重放（§4.2）。
/// 3. **方向由角色决定，不由调用方决定**。`kA2B` / `kB2A` 是两条方向的两把密钥，
///    映射写反了**不会报错**，只会两侧都解不开 —— 所以映射写在协议层一处。
///
/// ## 控制帧为什么也封箱
///
/// `ping` / `pong` / `credit` / `persisted` 的载荷是空串，但它们的 `fc` 在 AAD 里。
/// 不认证就等于让未认证的数字驱动重放窗口，也让 `credit`（放宽发送窗口）与
/// `persisted`（允许裁剪增量缓冲）变成中继可伪造的状态变更。代价是 16 字节标签。
///
/// 移植源：`connector/src/protocol/box.ts`（行为基准）。
library;

import 'crypto.dart';
import 'errors.dart';
import 'frame.dart';

/// 认证标签长度（ChaCha20-Poly1305）。
const int tagBytes = 16;

/// 线上箱 → 密文与标签。
///
/// **严格校验而不是"尽力解码"**：base64 解码器会静默丢弃非法字符，于是 `"!!!"`
/// 会解出一个空缓冲、再被 AEAD 判成认证失败 —— 错误信息指向"认证失败"，
/// 而真正的问题是"这一帧根本不是箱"。所以先查字母表与长度，再查规范化。
SealedBox unpackBoxStrict(String box) {
  if (!RegExp(r'^[A-Za-z0-9_-]*$').hasMatch(box)) {
    throw const ProtocolException(ErrorCode.badFrame, '箱不是 base64url 文本');
  }
  final raw = base64UrlToBytes(box);
  if (raw.length < tagBytes) {
    throw ProtocolException(
      ErrorCode.badFrame,
      '箱只有 ${raw.length} 字节，连认证标签（$tagBytes 字节）都不够',
    );
  }
  if (base64UrlNoPad(raw) != box) {
    // 非规范编码：同一串字节可以有多个字符串表示，放行只会让"两端各写一遍"时对不上账。
    throw const ProtocolException(
      ErrorCode.badFrame,
      '箱不是规范的 base64url（请用无填充编码）',
    );
  }
  final split = raw.length - tagBytes;
  return SealedBox(
    ciphertextHex: toHex(raw.sublist(0, split)),
    tagHex: toHex(raw.sublist(split)),
  );
}

/// 业务帧的封箱/解箱（**每连接一个实例**，因为它持有重放窗口与 nonce 绊线）。
class BoxCodec {
  /// [role] 是本端角色：`initiator` = 手机 = A，`responder` = 电脑 = B ——
  /// 与 [deriveSessionKeys] 用同一套词汇，避免两处各有一套"谁是谁"。
  BoxCodec({required this.keys, required this.role});

  final SessionKeys keys;
  final HandshakeRole role;

  final ReplayGuard _guard = ReplayGuard();

  /// 上一次封箱用过的 `fc`（nonce 重用的绊线）。
  int _lastSealedFc = -1;

  /// 发出去用"本端 → 对端"那把；收进来用"对端 → 本端"那把。
  String get _outboundKey =>
      role == HandshakeRole.initiator ? keys.kA2B : keys.kB2A;
  String get _inboundKey =>
      role == HandshakeRole.initiator ? keys.kB2A : keys.kA2B;

  /// 已经收到并验证过的最大 `fc`（指标与调试用）。
  int get maxFc => _guard.maxFc;

  /// 用这一帧的头（含**已分配**的 `fc`）封箱。
  ///
  /// 抛 [ProtocolException] `internal`：走到"同一个 fc 封两次"说明装配错了，
  /// 而那不是对端的错 —— 所以不能报成 `bad-frame`（那会让调用方去重连对端）。
  Future<String> sealFrame(Map<String, Object?> frame, String plaintext) async {
    final fc = _fcOf(frame);
    if (fc <= _lastSealedFc) {
      // 那等于重用 nonce，AEAD 直接失效。正常路径不会发生（分配权在连接层且单调），
      // 所以这是**绊线**而不是校验。
      throw ProtocolException(
        ErrorCode.internal,
        'fc=$fc 不大于已封过的 $_lastSealedFc：拒绝用同一个 nonce 再封一次',
      );
    }
    final sealed = await seal(
      keyHex: _outboundKey,
      fc: fc,
      aadFields: aadFieldsOf(frame),
      plaintext: plaintext,
    );
    _lastSealedFc = fc;
    return packBox(sealed);
  }

  /// 解箱。
  ///
  /// 抛 [ProtocolException]：`badFrame`（不是箱 / 认证失败）、`replay`（`fc` 不单调）。
  Future<String> openFrame(Map<String, Object?> frame, String box) async {
    final fc = _fcOf(frame);
    // 便宜的单调性预检：重放/重复投递在这里就出局，**不推进任何状态**。
    // 注意它只读不写 —— 窗口的前进在下面认证通过之后。
    if (fc <= _guard.maxFc) {
      throw ProtocolException(
        ErrorCode.replay,
        'fc=$fc 不大于已见最大 ${_guard.maxFc}',
      );
    }
    final unpacked = unpackBoxStrict(box);
    // 认证失败会抛（可能来自 `crypto.open` 的 auth 失败，也可能来自上面的容器校验）。
    final plaintext = await open(
      keyHex: _inboundKey,
      fc: fc,
      aadFields: aadFieldsOf(frame),
      ciphertextHex: unpacked.ciphertextHex,
      tagHex: unpacked.tagHex,
    );
    // **先验后进**：只有走到这里，这个 fc 才算被接受。
    _guard.accept(fc);
    return plaintext;
  }
}

/// 取 `fc`；没有 `fc` 的帧不该走到这里（握手帧、配对帧与 `presence` 是明文）。
int _fcOf(Map<String, Object?> frame) {
  final fc = frame['fc'];
  if (fc is! int) {
    throw ProtocolException(ErrorCode.badFrame, '${frame['t']} 帧没有 fc，不该封箱');
  }
  return fc;
}
