/// 握手派生、HKDF、AEAD、`fc` 计数器（契约 §4）。
///
/// 移植源是电脑侧 `connector/src/protocol/crypto.ts` 与
/// `protocol/tools/vectors-core.mjs`（**已知答案向量的生成方**）。
///
/// 为什么本层要单独跑已知答案向量：协议 fixtures 有意不测加密（那边的 `seal`
/// 是可逆占位），但两侧实现各自实现 X25519 / Ed25519 / HKDF / AEAD 时极易漂移 ——
/// 而漂移的表现是"连不上"，不是"断言失败"。所以 `protocol/vectors/` 给出
/// 固定输入 → 期望输出，两侧都必须跑通同一批。
///
/// ## 三条不可协商的规则
///
/// 1. **nonce = `fc` 的 96 位大端**，`fc` 从 0 开始每帧 +1、**不重用**（契约 §4.2）。
///    不用随机 nonce：唯一性由计数器保证，不依赖随机数质量，也省掉每帧一次系统调用。
/// 2. **每次握手必须新生成临时密钥对**，不得跨连接复用。复用会让 `fc` 从 0 重数
///    ⇒ nonce 重用 ⇒ 直接破掉 AEAD。握手失败后的重试同样要重新生成。
/// 3. **AAD 用 `frame.dart` 的 [aadOf]**，两端必须字节一致；不要在这里另拼一份。
///
/// 算法已核实（`protocol/vectors/aead.json` 写死）：**AES-256-GCM**
/// （96 位 nonce、16 字节 tag）。Dart 侧用 `cryptography` 包的 [AesGcm.with256bits]。
///
/// **曾经是 ChaCha20-Poly1305** —— 换成 AES-GCM 的原因是**电脑侧**：
/// Electron 的 crypto 不提供 ChaCha20（整族都没有），而插件跑在 Electron 里。
/// 详见 [SealedBox] 上方 `_aead` 的说明。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'errors.dart';
import 'frame.dart';

/// 会话密钥派生的 `info` 前缀（契约 §4.1）。实际传给 HKDF 的是
/// `` `${KEY_INFO}|${pairingId}` `` —— 配对标识参与派生，所以两端必须用同一个。
const String keyInfo = 'dsh-mobile/v1/keys';

/// 身份派生的两个 `info` 串（契约 §4.1）。改一个字就是另一套长期密钥。
const String identityInfoSign = 'id-sign';
const String identityInfoDh = 'id-dh';

/// 认证标签字节数（契约 §3）。
const int aeadTagBytes = 16;

/// 主密钥字节数（契约 §4.1：64）。
const int masterKeyBytes = 64;

/// 握手签名与 DH 密钥的原始长度。
const int rawKeyBytes = 32;

/// AEAD 算法（契约 §4.2）：**AES-256-GCM**。
///
/// 曾是 `Chacha20.poly1305Aead()`，被真机逼着换掉：**Electron 的 crypto 不提供
/// `chacha20-poly1305`**（整族都没有），而电脑侧插件跑在 Electron 里 ——
/// 症状是"握手成功、第一帧业务请求就断"。
///
/// Dart 这一侧两种算法都可用（`cryptography` 包都实现了），所以换它不影响手机端能力：
/// 变的是**两端必须一致的那一个算法名**。nonce 规则、AAD 拼串、密钥派生、箱容器全都没变。
///
/// Note: 为什么换、以及"选型必须查电脑侧运行时"这条教训 —— 见
/// `.agents/notes/implemented/2026-10-07-electron-lacks-chacha20.md`
final AesGcm _aead = AesGcm.with256bits();

final X25519 _x25519 = X25519();
final Ed25519 _ed25519 = Ed25519();

final Sha256 _sha256 = Sha256();

// ---------------------------------------------------------------------------
// 十六进制 / 字节工具
// ---------------------------------------------------------------------------

/// 字节 → 小写十六进制。
String toHex(List<int> bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// 小写十六进制 → 字节。奇数长度或非十六进制字符即抛。
Uint8List fromHex(String hex) {
  if (hex.length.isOdd) {
    throw ProtocolException(ErrorCode.badFrame, '十六进制长度必须是偶数：${hex.length}');
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i += 1) {
    final byte = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) {
      throw ProtocolException(ErrorCode.badFrame, '不是合法十六进制：$hex');
    }
    out[i] = byte;
  }
  return out;
}

/// base64url（**无填充**）。
///
/// 契约 §3 的箱容器与 §12.1 的 `pairingId` 都用它。Dart 的 [base64Url] 默认
/// **带** `=` 填充，而电脑侧的 `Buffer.toString('base64url')` 不带 ——
/// 差一个 `=` 就是"解不开"，所以这里统一去掉。
String base64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// base64url（**容忍填充**）→ 字节。
///
/// 解码侧两种都收：向量与线上是产品自己产出的（无填充），但手写的测试数据
/// 可能带 `=`。宽容在这里没有安全代价（长度由后续校验决定）。
Uint8List base64UrlToBytes(String text) {
  final padded = text.padRight(text.length + ((4 - text.length % 4) % 4), '=');
  return Uint8List.fromList(base64Url.decode(padded));
}

// ---------------------------------------------------------------------------
// 密钥对
// ---------------------------------------------------------------------------

/// 一个密钥对：私钥（`cryptography` 的 `SimpleKeyPair`）+ 32 字节原始公钥。
class KeyPair {
  KeyPair(this.keyPair, this.publicKeyHex);

  final SimpleKeyPair keyPair;

  /// 32 字节原始公钥的十六进制。
  final String publicKeyHex;
}

/// 从 32 字节种子构造 X25519 密钥对。
///
/// 设备身份是**一个 32 字节主种子**，经 HKDF 派生身份签名密钥与静态 DH 密钥
/// （契约 §4.1）—— 只存一个 secret，三端安全存储才统一得起来。
Future<KeyPair> x25519FromSeed(String seedHex) async {
  final seed = fromHex(seedHex);
  if (seed.length != rawKeyBytes) {
    throw ArgumentError('X25519 种子必须是 $rawKeyBytes 字节，收到 ${seed.length}');
  }
  final pair = await _x25519.newKeyPairFromSeed(seed);
  final publicKey = await pair.extractPublicKey();
  return KeyPair(pair, toHex(publicKey.bytes));
}

/// 从 32 字节种子构造 Ed25519 密钥对。
Future<KeyPair> ed25519FromSeed(String seedHex) async {
  final seed = fromHex(seedHex);
  if (seed.length != rawKeyBytes) {
    throw ArgumentError('Ed25519 种子必须是 $rawKeyBytes 字节，收到 ${seed.length}');
  }
  final pair = await _ed25519.newKeyPairFromSeed(seed);
  final publicKey = await pair.extractPublicKey();
  return KeyPair(pair, toHex(publicKey.bytes));
}

/// 从 32 字节原始公钥构造 [SimplePublicKey]。
///
/// 线上传的是**裸公钥**，而算法层只接受带类型的公钥对象 —— 少了这一层包装，
/// `sharedSecretKey` 会直接抛，症状是"握手莫名其妙失败"。
SimplePublicKey rawPublicKey(String publicKeyHex) {
  final bytes = fromHex(publicKeyHex);
  if (bytes.length != rawKeyBytes) {
    throw ArgumentError('公钥必须是 $rawKeyBytes 字节，收到 ${bytes.length}');
  }
  return SimplePublicKey(bytes, type: KeyPairType.x25519);
}

// ---------------------------------------------------------------------------
// nonce 与 AEAD
// ---------------------------------------------------------------------------

/// nonce = `fc` 的 96 位大端（契约 §4.2）。
///
/// **不是随机 nonce**：唯一性由计数器保证。`writeBigUInt64BE` 的等价写法 ——
/// 高 4 字节保持 0，低 8 字节写 `fc` 的大端。
Uint8List nonceOf(int fc) {
  if (fc < 0) throw ArgumentError('fc 必须是非负整数');
  final buffer = ByteData(12);
  // `setUint64` 在 web 上不可靠，所以拆成两个 32 位写；`fc` 超过 2^53 本就非法。
  buffer.setUint32(4, (fc ~/ 0x100000000) & 0xffffffff);
  buffer.setUint32(8, fc & 0xffffffff);
  return buffer.buffer.asUint8List();
}

/// 封箱结果：密文与认证标签分开（契约 §3 的容器是 `密文 ‖ tag`）。
class SealedBox {
  const SealedBox({required this.ciphertextHex, required this.tagHex});

  final String ciphertextHex;
  final String tagHex;
}

/// 封箱（契约 §4.2）。
Future<SealedBox> seal({
  required String keyHex,
  required int fc,
  required AadFields aadFields,
  required String plaintext,
}) async {
  final box = await _aead.encrypt(
    utf8.encode(plaintext),
    secretKey: SecretKey(fromHex(keyHex)),
    nonce: nonceOf(fc),
    aad: aadOf(aadFields),
  );
  return SealedBox(
    ciphertextHex: toHex(box.cipherText),
    tagHex: toHex(box.mac.bytes),
  );
}

/// 解封。**AAD 或 `fc` 不匹配时抛 `protocol/bad-frame`** —— 这正是 nonce 与 AAD
/// 规则的负向证据，调用方不得把异常吞成"内容为空"（那等于把篡改当成合法帧）。
///
/// 两段错误处理刻意分开（与电脑侧同一个口径）：
/// - **初始化失败**（密钥/nonce 形状不对）→ 抛 [ArgumentError]：那些值是我们自己
///   算出来的，出错说明本地装配有问题，不是对端的错；
/// - **解密失败** → [ProtocolException] `protocol/bad-frame`：这一帧来自对端且不该被接受。
///   不包这一层的话，包的裸异常会漏到协议层调用方 —— 调用方只能按错误码判类型，
///   于是认证失败会被当成"未知内部错误"，而这正是**闭合错误码**要避免的。
Future<String> open({
  required String keyHex,
  required int fc,
  required AadFields aadFields,
  required String ciphertextHex,
  required String tagHex,
}) async {
  final List<int> clear;
  try {
    clear = await _aead.decrypt(
      SecretBox(
        fromHex(ciphertextHex),
        nonce: nonceOf(fc),
        mac: Mac(fromHex(tagHex)),
      ),
      secretKey: SecretKey(fromHex(keyHex)),
      aad: aadOf(aadFields),
    );
  } on SecretBoxAuthenticationError catch (error) {
    throw ProtocolException(ErrorCode.badFrame, '解箱失败（AAD、fc 或密文不符）：$error');
  }
  return utf8.decode(clear);
}

/// 箱的容器格式（契约 §3）：`base64url(密文 ‖ tag)`，**无填充**。
///
/// 它是**线上格式的一部分**，所以和曲线/AEAD 一样进向量：两端各自拼一遍再比对 ——
/// 各写各的容器（一个用十六进制、一个带分隔符）在单侧测试里都是绿的，
/// 只有真机互通时才断，而那时的症状是"解不开"。
///
/// 注意**不要**用 `SecretBox.concatenation()`：那个是 `nonce ‖ 密文 ‖ tag`，
/// 而我们的 nonce 由 `fc` 派生、**不上线**。
String packBox(SealedBox box) => base64UrlNoPad(<int>[
  ...fromHex(box.ciphertextHex),
  ...fromHex(box.tagHex),
]);

/// 箱 → 密文与标签。长度不足即抛（调用方按 `protocol/bad-frame` 处理）。
SealedBox unpackBox(String box) {
  final raw = base64UrlToBytes(box);
  if (raw.length < aeadTagBytes) {
    throw ProtocolException(
      ErrorCode.badFrame,
      '箱只有 ${raw.length} 字节，不足一个认证标签',
    );
  }
  final split = raw.length - aeadTagBytes;
  return SealedBox(
    ciphertextHex: toHex(raw.sublist(0, split)),
    tagHex: toHex(raw.sublist(split)),
  );
}

// ---------------------------------------------------------------------------
// HKDF
// ---------------------------------------------------------------------------

/// HKDF-SHA256（RFC 5869）。
///
/// `salt` 为空数组时与 RFC 5869 的"盐缺省即全零"等价 —— 身份派生就是这么用的。
Future<Uint8List> hkdf({
  required List<int> ikm,
  required List<int> salt,
  required List<int> info,
  required int length,
}) async {
  final algorithm = Hkdf(hmac: Hmac.sha256(), outputLength: length);
  final derived = await algorithm.deriveKey(
    secretKey: SecretKey(ikm),
    // `cryptography` 把 HKDF 的 salt 叫 `nonce`（KDF 的通用参数名）。
    nonce: salt,
    info: info,
  );
  return Uint8List.fromList(await derived.extractBytes());
}

// ---------------------------------------------------------------------------
// 身份派生
// ---------------------------------------------------------------------------

/// 设备身份（契约 §4.1）：**一个 32 字节主种子**经 HKDF 分成两把长期密钥。
///
/// 为什么只存一个 secret：三端的安全存储（HUKS / Keychain / Keystore）只认"一把密钥"
/// 这件事最好统一；分成两把再各存一次，等于把同一份风险抄两遍。
///
/// 两个 `info` 是**域分隔**：少了它，签名密钥与 DH 密钥会是同一把
/// （`verify-vectors.mjs` 专门断言这个）。
class IdentityKeys {
  const IdentityKeys({
    required this.signSeedHex,
    required this.dhSeedHex,
    required this.sign,
    required this.dh,
  });

  /// 派生出的 Ed25519 种子。
  final String signSeedHex;

  /// 派生出的 X25519 种子。
  final String dhSeedHex;

  /// Ed25519 身份签名密钥对：签/验 transcript。
  final KeyPair sign;

  /// X25519 静态 DH 密钥对：参与 §4.1 的三份共享密钥。
  final KeyPair dh;
}

/// 从主种子派生设备身份。**与 `protocol/tools/vectors-core.mjs` 的 `deriveIdentity`
/// 必须逐字节一致**（向量里就是这条）。
Future<IdentityKeys> deriveIdentity(String masterSeedHex) async {
  final seed = fromHex(masterSeedHex);
  if (seed.length != rawKeyBytes) {
    throw ArgumentError('主种子必须是 $rawKeyBytes 字节，收到 ${seed.length}');
  }
  Future<String> derive(String info) async {
    final out = await hkdf(
      ikm: seed,
      salt: const <int>[], // 空盐 ≡ 全零盐（RFC 5869）
      info: utf8.encode(info),
      length: rawKeyBytes,
    );
    return toHex(out);
  }

  final signSeedHex = await derive(identityInfoSign);
  final dhSeedHex = await derive(identityInfoDh);
  return IdentityKeys(
    signSeedHex: signSeedHex,
    dhSeedHex: dhSeedHex,
    sign: await ed25519FromSeed(signSeedHex),
    dh: await x25519FromSeed(dhSeedHex),
  );
}

// ---------------------------------------------------------------------------
// 会话密钥派生
// ---------------------------------------------------------------------------

/// 三份共享密钥与由它们派生的会话密钥（契约 §4.1）。
class SessionKeys {
  const SessionKeys({
    required this.ss1,
    required this.ss2,
    required this.ss3,
    required this.master,
    required this.kA2B,
    required this.kB2A,
  });

  final String ss1;
  final String ss2;
  final String ss3;
  final String master;

  /// 手机 → 电脑方向的 AEAD 密钥。
  final String kA2B;

  /// 电脑 → 手机方向。
  final String kB2A;
}

/// 本端在握手里的角色。
///
/// **这个参数是必需的，不是冗余信息**：`ss1` 的定义是「发起方临时 × 应答方静态」，
/// 而同一个 DH 表达式 `DH(自己的临时, 对端的静态)` 在两侧算出的分别是 `ss1` 与 `ss2`。
/// 不告诉函数角色，就无从决定拼接顺序 —— 而顺序错了**不会报错**，
/// 只会让两侧主密钥不同（症状：握手看起来走完，AEAD 永远解不开）。
enum HandshakeRole { initiator, responder }

/// 会话密钥派生（契约 §4.1）—— **两侧各自调用这一个函数**。
///
/// ```text
/// ss1 = 发起方临时 × 应答方静态        // 手机 eph × 电脑 static
/// ss2 = 发起方静态 × 应答方临时        // 手机 static × 电脑 eph
/// ss3 = 双方临时                       // 与角色无关（前向保密的来源）
/// ```
///
/// 方向约定（`kA2B` / `kB2A`）只与 `nonceA||nonceB` 的顺序有关，**与角色无关**，
/// 所以两侧必须用同一个顺序，否则会派生出互为反向的两把密钥。
Future<SessionKeys> deriveSessionKeys({
  required HandshakeRole role,
  required SimpleKeyPair ownStaticPrivate,
  required SimpleKeyPair ownEphemeralPrivate,
  required String peerStaticPublicHex,
  required String peerEphemeralPublicHex,
  required String nonceA,
  required String nonceB,
  required String info,
  required String pairingId,
}) async {
  final peerStatic = rawPublicKey(peerStaticPublicHex);
  final peerEphemeral = rawPublicKey(peerEphemeralPublicHex);

  /// 自己的临时 × 对端的静态。
  ///
  /// **注意它的绝对含义是角色相关的**：在发起方它等于协议里的 `ss1`，
  /// 在应答方它等于 `ss2`（因为"谁的临时"换了人）。命名按表达式、不按协议编号，
  /// 免得把位置当成了编号 —— 下面显式做角色调整。
  final ephOwnStaticPeer = await _x25519.sharedSecretKey(
    keyPair: ownEphemeralPrivate,
    remotePublicKey: peerStatic,
  );

  /// 自己的静态 × 对端的临时。含义同上，与上一条恰好互补。
  final staticOwnEphPeer = await _x25519.sharedSecretKey(
    keyPair: ownStaticPrivate,
    remotePublicKey: peerEphemeral,
  );

  /// 双方临时（与角色无关）。
  final ephEph = await _x25519.sharedSecretKey(
    keyPair: ownEphemeralPrivate,
    remotePublicKey: peerEphemeral,
  );

  final ephOwnStaticPeerBytes = await ephOwnStaticPeer.extractBytes();
  final staticOwnEphPeerBytes = await staticOwnEphPeer.extractBytes();
  final ss3Bytes = await ephEph.extractBytes();

  // **角色调整**：协议里的 `ss1` 定义是「发起方临时 × 应答方静态」，
  // 所以应答方要把上面两条对调。调整后的 `ss1`/`ss2` 才是**绝对**协议值，
  // 也才是这个函数该返回的东西（返回位置值会让应答方的 `ss1` 变成 `ss2`）。
  final ss1Bytes = role == HandshakeRole.initiator
      ? ephOwnStaticPeerBytes
      : staticOwnEphPeerBytes;
  final ss2Bytes = role == HandshakeRole.initiator
      ? staticOwnEphPeerBytes
      : ephOwnStaticPeerBytes;

  final ikm = <int>[...ss1Bytes, ...ss2Bytes, ...ss3Bytes];
  final salt = <int>[...fromHex(nonceA), ...fromHex(nonceB)];
  final master = await hkdf(
    ikm: ikm,
    salt: salt,
    info: utf8.encode('$info|$pairingId'),
    length: masterKeyBytes,
  );

  return SessionKeys(
    ss1: toHex(ss1Bytes),
    ss2: toHex(ss2Bytes),
    ss3: toHex(ss3Bytes),
    master: toHex(master),
    kA2B: toHex(master.sublist(0, 32)),
    kB2A: toHex(master.sublist(32, 64)),
  );
}

// ---------------------------------------------------------------------------
// 签名
// ---------------------------------------------------------------------------

/// 用 Ed25519 身份密钥对 transcript 签名。
Future<String> signTranscript(String edSeedHex, List<int> transcript) async {
  final pair = await ed25519FromSeed(edSeedHex);
  final signature = await _ed25519.sign(transcript, keyPair: pair.keyPair);
  return toHex(signature.bytes);
}

/// 验签：`transcript` 是不是 `publicKeyHex` 对应的私钥签的。
///
/// 失败一律是 `protocol/not-paired`（与电脑侧同一个口径）—— 契约 §4.1 明写
/// 「中继替换公钥无法通过验签」，也就是说**端到端加密的抗中间人能力完全落在这里**。
/// 对手机端来说这些失败是同一件事：**这一端不是我以为的那一端**，该回配对页。
Future<void> verifySignature({
  required List<int> transcript,
  required String publicKeyHex,
  required String signatureHex,
  required String role,
}) async {
  // **整段都归一到 `protocol/not-paired`**：`fromHex` 对坏十六进制抛的是
  // `protocol/bad-frame`，但"公钥/签名的字节不对"与"验签不过"对手机是同一件事
  // （这一端不是我以为的那一端，该回配对页）。让 `bad-frame` 从这里漏出去，
  // 会让手机把"设备身份不对"归到"这一帧格式不对"—— 两件事的下一步动作完全不同
  // （一个回配对页，一个重试），报错类别错了用户就永远卡在重试上。
  //
  // 实现上不用 `try/on ProtocolException/rethrow`：那样会把 `fromHex` 的 `bad-frame`
  // 一起放行（`ProtocolException` 是同一个类型）。所以这里显式只认 `not-paired`。
  final List<int> publicBytes;
  final List<int> signatureBytes;
  try {
    publicBytes = fromHex(publicKeyHex);
    signatureBytes = fromHex(signatureHex);
  } on ProtocolException catch (error) {
    throw ProtocolException(
      ErrorCode.notPaired,
      '$role 的公钥或签名不是合法十六进制：${error.message}',
    );
  }

  if (publicBytes.length != rawKeyBytes) {
    throw ProtocolException(
      ErrorCode.notPaired,
      '$role 的 Ed25519 公钥应为 $rawKeyBytes 字节，收到 ${publicBytes.length}',
    );
  }

  final bool ok;
  try {
    ok = await _ed25519.verify(
      transcript,
      signature: Signature(
        signatureBytes,
        publicKey: SimplePublicKey(publicBytes, type: KeyPairType.ed25519),
      ),
    );
  } catch (error) {
    // 构造公钥失败也归到"不是我以为的那一端"，不暴露内部分支。
    throw ProtocolException(ErrorCode.notPaired, '$role 验签无法进行：$error');
  }

  if (!ok) {
    throw ProtocolException(
      ErrorCode.notPaired,
      '$role 的签名对不上 transcript（中继可能替换了公钥）',
    );
  }
}

/// `transcriptHash` = SHA-256(transcript) 的前 8 字节，十六进制（契约 §4.1）。
///
/// 取 8 字节不是为了密码学强度，而是让「双方的 transcript 是不是同一个」这件事
/// 有一个便宜的比对值 —— 真正的认证由两个签名承担。
Future<String> transcriptHashOf(List<int> transcript) async {
  final digest = await _sha256.hash(transcript);
  return toHex(digest.bytes.sublist(0, 8));
}

/// 校验 `confirm` 里的 transcript 摘要。
///
/// 它防的是「双方各自算出了不同的 transcript 却都没发现」—— 单靠签名验不过这一关，
/// 因为签名只能证明"对方持有私钥"，不能证明"我们签的是同一段字节"。
Future<void> verifyConfirm({
  required List<int> transcript,
  required String transcriptHash,
}) async {
  final expected = await transcriptHashOf(transcript);
  if (transcriptHash != expected) {
    throw ProtocolException(
      ErrorCode.notPaired,
      'confirm 的 transcriptHash 不匹配（期望 $expected，收到 $transcriptHash）',
    );
  }
}

// ---------------------------------------------------------------------------
// fc 计数器与重放守卫
// ---------------------------------------------------------------------------

/// 发送方向的帧计数器（契约 §4.2）。
class SendCounter {
  int _next = 0;

  /// 取下一个 `fc` 并推进。**它是 nonce 的来源，绝不能回退或重用。**
  int next() => _next++;

  /// 已经发出去多少帧。
  int get value => _next;
}

/// 接收方向的重放防护（契约 §4.2）。
///
/// 接收方维护 `maxFc`：
/// - `fc < maxFc` → 重放，拒绝；
/// - `fc == maxFc` → 只可能来自重复投递，**同样拒绝**；
/// - `fc > maxFc` → 接受并推进。
///
/// 本层不允许乱序（单 TCP 流本来就保序），任何乱序都按攻击或故障处理。
/// **顺序是硬规则：先验签、后推进 `maxFc`** —— 反过来，一帧伪造的 `fc=10^9`
/// 就能把后续所有合法帧判成重放（症状是连接被自己人反复关闭）。
class ReplayGuard {
  int _maxFc = -1;

  /// 接受一个 `fc`；重放或重复投递时抛 `protocol/replay`。
  void accept(int fc) {
    if (fc < 0) {
      throw ProtocolException(ErrorCode.badFrame, 'fc 必须是非负整数，收到 $fc');
    }
    if (fc <= _maxFc) {
      throw ProtocolException(ErrorCode.replay, 'fc=$fc 不大于已见最大 $_maxFc');
    }
    _maxFc = fc;
  }

  int get maxFc => _maxFc;
}
