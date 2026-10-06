/// 配对凭据的持久化（系统安全存储）。
///
/// ## 存什么、为什么
///
/// 配对一次要存下四样东西，它们的**敏感度不同**，所以分开看待：
///
/// | 字段 | 敏感度 | 丢了会怎样 |
/// |---|---|---|
/// | `masterSeedHex` | **设备身份本体**（32 字节主种子） | 电脑侧认不出这台设备，得重新配对 |
/// | `pairingId` | 配对标识（码的 HKDF 输出） | `master` 算不出来 → 连不上 |
/// | `pcSignPubHex` / `pcDhPubHex` | 公钥 | 同上；而它**必须只来自二维码**（契约 §12.1） |
/// | `relayUrl` | 不敏感 | 连不上 |
///
/// ## 为什么主种子绝不落 preferences（契约 §12.2 明令）
///
/// 主种子是**唯一**的设备身份秘密：拿到它就能冒充这台设备。
/// 所以它进系统密钥库（安卓 Keystore 强绑定 / iOS Keychain
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` / 鸿蒙 HUKS）。
/// **绝不接受"降级成明文 preferences"** —— 契约的原话是
/// "绝不回落成明文 preferences"，那是设计里写死的下限。
///
/// ## 这一层为什么住在 `platform/`
///
/// 系统密钥库是三端各一份的能力（`app-platform-boundaries.md` §1 的 `packages/secure_store_*`），
/// 而"选哪个实现"只该发生在装配层。`core/` 与 `data/` 只认识 [PairedCredentials]
/// 这个值类型，不认识它从哪来。
///
/// ## 已知缺口（如实记录）
///
/// 三端能力包（`packages/secure_store_ios|android|ohos`）**还没做**，所以这里先用
/// `flutter_secure_storage`：它在安卓走 Keystore/EncryptedSharedPreferences、
/// 在 iOS 走 Keychain，**满足当前安卓阶段的要求**。
/// 鸿蒙那端它不够（契约 §12.2 要求自写 platform channel 接 HUKS，
/// 且明确"适配清单里的 ohos fork 未见 HUKS 说明，不能推断密钥由 HUKS 保护"）——
/// 那条等鸿蒙开工时按 `secure_store_ohos` 做，本文件的接口不变。
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/crypto.dart';

/// 配对得到的凭据（**值类型**：可安全地在各层之间传递，它不是秘密的"容器"）。
class PairedCredentials {
  const PairedCredentials({
    required this.relayUrl,
    required this.pcSignPubHex,
    required this.pcDhPubHex,
    required this.pairingId,
    required this.masterSeedHex,
    required this.devSignPubHex,
    required this.devDhPubHex,
    this.pcId = '',
  });

  /// 中转地址。
  final String relayUrl;

  /// 电脑侧 Ed25519 公钥（**只来自二维码**，契约 §12.1 硬规则）。
  final String pcSignPubHex;

  /// 电脑侧 X25519 静态公钥（同上）。
  final String pcDhPubHex;

  /// 配对标识（参与 §4.1 的 `info`，两端必须一致）。
  final String pairingId;

  /// 设备主种子（32 字节十六进制）。**这是设备身份本体。**
  final String masterSeedHex;

  /// 本机 Ed25519 公钥（配对时上报给电脑侧的那个）。
  final String devSignPubHex;

  /// 本机 X25519 静态公钥。
  final String devDhPubHex;

  /// 电脑侧给本机分配的 pc 标识（握手帧里要带；配对回执里给）。
  ///
  /// 空串表示"还没从配对回执里拿到" —— 那时握手会用空值，
  /// 而 AAD 里它也参与拼串（契约 §3），所以**不可能是长期状态**。
  final String pcId;

  /// 设备标识（电脑侧用 `devPubDh` 的哈希前 16 字节推导，见 `connector/src/pairing.ts`）。
  ///
  /// 这里**本地推导同一个值**，而不是等电脑侧下发：
  /// 握手的 `hello` 里要带 `devId`，而那时还没收到任何回执。
  ///
  /// 是方法而不是 getter：推导要算 sha256，而 `cryptography` 的 API 是异步的。
  /// 做成同步 getter 就得把摘要缓存进字段，而那是"同一个值有两个来源"的开端。
  Future<String> deviceId() => deriveDeviceId(devDhPubHex);
}

/// 与电脑侧 `deviceIdOf` **逐字一致**：
/// `base64url(sha256(devPubDh 的 UTF-8 字节)[0..16])`（无填充）。
///
/// 两端必须一致，否则电脑侧收到 `hello` 时会当作一台**没见过的设备** ——
/// 而症状是"配对成功了但连不上"，排查会从密钥开始找。
/// 电脑侧实现在 `connector/src/pairing.ts` 的 `deviceIdOf`：
///
/// ```ts
/// base64url(createHash('sha256').update(request.devPubDh, 'utf8').digest().subarray(0, 16))
/// ```
///
/// 注意它哈希的是**十六进制字符串的 UTF-8 字节**（不是公钥的原始 32 字节）——
/// 两者都能算出一个值，只在两端对上时才发现不一样。
Future<String> deriveDeviceId(String devDhPubHex) async {
  final digest = await Sha256().hash(utf8.encode(devDhPubHex));
  return base64UrlNoPad(digest.bytes.sublist(0, 16));
}

/// 安全存储的键（**前缀化**：同一个存储里将来还会有别的键）。
abstract final class _Keys {
  static const relayUrl = 'dsh.relay_url';
  static const pcSignPub = 'dsh.pc_sign_pub';
  static const pcDhPub = 'dsh.pc_dh_pub';
  static const pairingId = 'dsh.pairing_id';
  static const masterSeed = 'dsh.master_seed';
  static const devSignPub = 'dsh.dev_sign_pub';
  static const devDhPub = 'dsh.dev_dh_pub';
  static const pcId = 'dsh.pc_id';
}

/// 配对凭据的读写。
abstract final class PairingStore {
  static const _storage = FlutterSecureStorage(
    // 安卓：v11 的默认构造就是强加密（**已核实包源码**
    // `lib/options/android_options.dart`）：AES-GCM 存数据 + RSA-OAEP 包裹密钥，
    // 要求 API 23+。所以**不需要**再传选项 ——
    // 早期版本那个 `encryptedSharedPreferences: true` 在 v11 已不存在
    //（写它是**编译错误**，这比"静默不生效"好）。
    //
    // iOS：`afterFirstUnlockThisDeviceOnly` —— 锁屏也能读（后台收推送时要读），
    // 但**不随备份迁移到新设备**（设备身份不该被备份复制，契约 §12.2）。
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  /// 读出已存的凭据；没有或不完整时返回 `null`。
  ///
  /// **不完整就当没有**：缺任一字段都用不了（缺 `pairingId` 算不出 `master`），
  /// 而"部分可用"会让失败发生在握手阶段 —— 那时没人会想到是存储缺字段。
  static Future<PairedCredentials?> load() async {
    final values = await _storage.readAll();
    final relayUrl = values[_Keys.relayUrl];
    final pcSignPub = values[_Keys.pcSignPub];
    final pcDhPub = values[_Keys.pcDhPub];
    final pairingId = values[_Keys.pairingId];
    final masterSeed = values[_Keys.masterSeed];
    final devSignPub = values[_Keys.devSignPub];
    final devDhPub = values[_Keys.devDhPub];

    if (relayUrl == null ||
        pcSignPub == null ||
        pcDhPub == null ||
        pairingId == null ||
        masterSeed == null ||
        devSignPub == null ||
        devDhPub == null) {
      return null;
    }

    return PairedCredentials(
      relayUrl: relayUrl,
      pcSignPubHex: pcSignPub,
      pcDhPubHex: pcDhPub,
      pairingId: pairingId,
      masterSeedHex: masterSeed,
      devSignPubHex: devSignPub,
      devDhPubHex: devDhPub,
      pcId: values[_Keys.pcId] ?? '',
    );
  }

  /// 写入凭据（**先写全部再算成功**：半份凭据比没有更糟）。
  static Future<void> save(PairedCredentials credentials) async {
    await _storage.write(key: _Keys.relayUrl, value: credentials.relayUrl);
    await _storage.write(key: _Keys.pcSignPub, value: credentials.pcSignPubHex);
    await _storage.write(key: _Keys.pcDhPub, value: credentials.pcDhPubHex);
    await _storage.write(key: _Keys.pairingId, value: credentials.pairingId);
    await _storage.write(
      key: _Keys.masterSeed,
      value: credentials.masterSeedHex,
    );
    await _storage.write(
      key: _Keys.devSignPub,
      value: credentials.devSignPubHex,
    );
    await _storage.write(key: _Keys.devDhPub, value: credentials.devDhPubHex);
    if (credentials.pcId.isNotEmpty) {
      await _storage.write(key: _Keys.pcId, value: credentials.pcId);
    }
  }

  /// 清空（吊销 / 重新配对时用）。
  static Future<void> clear() => _storage.deleteAll();
}
