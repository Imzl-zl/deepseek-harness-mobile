/// 配对凭据的持久化（系统安全存储）。
///
/// ## 存什么、为什么
///
/// 配对一次要存下这些东西，它们的**敏感度不同**，所以分开看待：
///
/// | 字段 | 敏感度 | 丢了会怎样 |
/// |---|---|---|
/// | `masterSeedHex` | **设备身份本体**（32 字节主种子） | 电脑侧认不出这台设备，得重新配对 |
/// | `deviceToken` | **长期凭据**（换票用它） | 连不上；而配对码是一次性的，**只能重新配对** |
/// | `refreshToken` | 长期凭据（轮换设备令牌用） | 同上（轮换流程本期未实现，见 `device-token` 侧记录） |
/// | `pairingId` | 配对标识（码的 HKDF 输出） | `master` 算不出来 → 连不上 |
/// | `pcSignPubHex` / `pcDhPubHex` | 公钥 | 同上；而它**必须只来自二维码**（契约 §12.1） |
/// | `relayUrl` / `pcId` / `devId` | 不敏感 | 连不上 |
/// | `endpoints` | **不敏感**（路由表，非秘密） | 连不上；而它会随连接器自报刷新 |
///
/// **端点表为什么单独一列**：它不是凭据，是"能从哪些地址拨到这台电脑"的有序表
/// （序即偏好）。与凭据同批保存只是图省事 —— 它的刷新频率高得多（每次经中转
/// 连上都会拉一次 `endpoint.describe`），所以另开一个只写它的入口
/// （[PairingStore.saveEndpoints]），免得每次刷新都把主种子重写一遍。
///
/// **`deviceToken` 为什么与主种子同级**：它是设备之后**每次重连的唯一凭据**
/// （配对码在配对那一刻就用掉了）。所以它进系统密钥库，与主种子同一条纪律。
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
import '../core/endpoint.dart';

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
    required this.deviceToken,
    required this.refreshToken,
    this.endpoints = const [],
    this.endpointMeta = const EndpointMeta(),
    this.pcId = '',
    this.devId = '',
  });

  /// 中转地址。
  ///
  /// **它只是"配对那一刻走的那条中转"**，不是拨号的唯一依据 ——
  /// 拨号看 [endpoints]（有序端点表，序即偏好）。留着这个字段是因为
  /// 配对回执给的就是它，而它是端点表的种子。
  final String relayUrl;

  /// 有序端点表。**序即偏好**：`connect()` 按这个顺序拨，第一个通的赢。
  ///
  /// 空列表表示"只有配对时那一条中转"（老凭据迁移后的形状）。
  final List<Endpoint> endpoints;

  /// 端点表的附属状态（记住的那条 / 隐藏集 / 成功过的集）。
  ///
  /// **不含秘密**（就是地址与集合），与 [endpoints] 一并落盘就够。
  final EndpointMeta endpointMeta;

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

  /// 设备令牌（**每次重连换票用它**）。配对回执给的那一次之后，中转只剩它的摘要。
  final String deviceToken;

  /// 刷新令牌（轮换设备令牌用；本期未实现轮换端点，如实记录）。
  final String refreshToken;

  /// 电脑侧给本机分配的 pc 标识（**握手 transcript 的 `pcId`**，配对回执里给）。
  ///
  /// 它**不在二维码里**：二维码只带公钥（契约 §12.1 的硬规则），
  /// 而 `pcId` 是电脑侧在对回执时给出的。空串表示"还没拿到"。
  final String pcId;

  /// 电脑侧给这台设备分配的设备 id（`hello` 里要带它）。
  ///
  /// 回执里给的是权威值（`devId`）；没有它时用 [deviceId] 本地推导同一个值。
  final String devId;

  /// 本地推导的设备标识（电脑侧用 `devPubDh` 的哈希前 16 字节推导，
  /// 见 `connector/src/pairing.ts` 的 `deviceIdOf`）。
  ///
  /// 它与回执里的 `devId` **必然是同一个值**（两端同一算式）——
  /// 留这条路径是为了"回执里没有 `devId`"的旧凭据仍能连上。
  ///
  /// 是方法而不是 getter：推导要算 sha256，而 `cryptography` 的 API 是异步的。
  /// 做成同步 getter 就得把摘要缓存进字段，而那是"同一个值有两个来源"的开端。
  Future<String> derivedDeviceId() => deriveDeviceId(devDhPubHex);

  /// `hello` 里要带的设备 id：**优先用电脑侧给的那个**（它是权威），
  /// 没有才本地推导。
  Future<String> helloDeviceId() async =>
      devId.isNotEmpty ? devId : derivedDeviceId();
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
  static const endpoints = 'dsh.endpoints';
  static const endpointMeta = 'dsh.endpoint_meta';
  static const pcSignPub = 'dsh.pc_sign_pub';
  static const pcDhPub = 'dsh.pc_dh_pub';
  static const pairingId = 'dsh.pairing_id';
  static const masterSeed = 'dsh.master_seed';
  static const devSignPub = 'dsh.dev_sign_pub';
  static const devDhPub = 'dsh.dev_dh_pub';
  static const pcId = 'dsh.pc_id';
  static const devId = 'dsh.dev_id';
  static const deviceToken = 'dsh.device_token';
  static const refreshToken = 'dsh.refresh_token';
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
  /// **不完整就当没有**：缺任一字段都用不了（缺 `pairingId` 算不出 `master`，
  /// 缺 `deviceToken` 换不到票），而"部分可用"会让失败发生在很后面 ——
  /// 那时没人会想到是存储缺字段。
  ///
  /// **端点表的一次性迁移**：2026-10-14 之前存的凭据只有 `dsh.relay_url`，
  /// 没有 `dsh.endpoints`。那时拨号地址就是 relayUrl 一个，所以从它造一条
  /// relay 端点即可 —— 这不是"猜一个默认值"，而是把旧形状读成新形状。
  /// 下次 `save` 就落成端点表，迁移只发生一次。
  static Future<PairedCredentials?> load() async {
    final values = await _storage.readAll();
    final relayUrl = values[_Keys.relayUrl];
    final pcSignPub = values[_Keys.pcSignPub];
    final pcDhPub = values[_Keys.pcDhPub];
    final pairingId = values[_Keys.pairingId];
    final masterSeed = values[_Keys.masterSeed];
    final devSignPub = values[_Keys.devSignPub];
    final devDhPub = values[_Keys.devDhPub];
    final deviceToken = values[_Keys.deviceToken];
    final refreshToken = values[_Keys.refreshToken];

    if (relayUrl == null ||
        pcSignPub == null ||
        pcDhPub == null ||
        pairingId == null ||
        masterSeed == null ||
        devSignPub == null ||
        devDhPub == null ||
        deviceToken == null ||
        refreshToken == null) {
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
      deviceToken: deviceToken,
      refreshToken: refreshToken,
      endpoints: _decodeEndpoints(values[_Keys.endpoints], relayUrl),
      endpointMeta: _decodeEndpointMeta(values[_Keys.endpointMeta]),
      pcId: values[_Keys.pcId] ?? '',
      devId: values[_Keys.devId] ?? '',
    );
  }

  /// 解端点表的附属状态。缺或坏都退化成"空的记忆"（**不猜**）：
  /// 丢的只是"上次连哪条"这类优化信息，拨号照样能work。
  static EndpointMeta _decodeEndpointMeta(String? raw) {
    if (raw == null || raw.isEmpty) return const EndpointMeta();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const EndpointMeta();
      final remembered = decoded['remembered'];
      final hidden = decoded['hidden'];
      final succeeded = decoded['succeeded'];
      return EndpointMeta(
        rememberedEndpointUrl: remembered is String && remembered.isNotEmpty
            ? remembered
            : null,
        hiddenEndpointIds: hidden is List
            ? hidden.whereType<String>().toSet()
            : const <String>{},
        succeededEndpointIds: succeeded is List
            ? succeeded.whereType<String>().toSet()
            : const <String>{},
      );
    } on FormatException {
      return const EndpointMeta();
    }
  }

  /// 解端点表。缺表时从 `relayUrl` 造一条 relay 端点（一次性迁移，见 [load]）。
  ///
  /// **解不出的条目直接丢**：一个拨不出去的端点会让整条链在很后面才失败，
  /// 而那时没人会想到是存储里躺着一条废条目。
  static List<Endpoint> _decodeEndpoints(String? raw, String relayUrl) {
    if (raw == null || raw.isEmpty) {
      return [Endpoint(kind: EndpointKind.relay, url: relayUrl, label: '中转')];
    }
    final List<dynamic> decoded;
    try {
      decoded = jsonDecode(raw) as List<dynamic>;
    } on FormatException {
      return [Endpoint(kind: EndpointKind.relay, url: relayUrl, label: '中转')];
    }
    final out = <Endpoint>[];
    for (final entry in decoded) {
      final endpoint = endpointFromJson(entry);
      if (endpoint != null) out.add(endpoint);
    }
    // 整表都解不出来时退回迁移形状：空表会让 `EndpointTransport` 抛
    // "没有可拨的端点"，而用户看到的是"连不上"而不是"存储坏了"。
    return out.isEmpty
        ? [Endpoint(kind: EndpointKind.relay, url: relayUrl, label: '中转')]
        : out;
  }

  /// 写入凭据（**先写全部再算成功**：半份凭据比没有更糟）。
  static Future<void> save(PairedCredentials credentials) async {
    await _storage.write(key: _Keys.relayUrl, value: credentials.relayUrl);
    await _storage.write(
      key: _Keys.endpoints,
      value: jsonEncode(credentials.endpoints.map(endpointToJson).toList()),
    );
    await saveEndpointMeta(credentials.endpointMeta);
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
    await _storage.write(
      key: _Keys.deviceToken,
      value: credentials.deviceToken,
    );
    await _storage.write(
      key: _Keys.refreshToken,
      value: credentials.refreshToken,
    );
    if (credentials.pcId.isNotEmpty) {
      await _storage.write(key: _Keys.pcId, value: credentials.pcId);
    }
    if (credentials.devId.isNotEmpty) {
      await _storage.write(key: _Keys.devId, value: credentials.devId);
    }
  }

  /// 只更新端点表。
  ///
  /// **不重写整份凭据**：端点表的刷新频率远高于凭据（每次经中转连上都会拉一次
  /// `endpoint.describe`），而主种子与设备令牌也在同一批键里 —— 每次刷新都把
  /// 它们重写一遍，既浪费也给"写一半"多一次机会。
  static Future<void> saveEndpoints(List<Endpoint> endpoints) async {
    await _storage.write(
      key: _Keys.endpoints,
      value: jsonEncode(endpoints.map(endpointToJson).toList()),
    );
  }

  /// 只更新端点表的附属状态（记住的那条 / 隐藏集 / 成功过的集）。
  ///
  /// 与 [saveEndpoints] 分开：**每次拨通都会改"记住的那条"**，
  /// 而整张表不需要跟着重写。
  static Future<void> saveEndpointMeta(EndpointMeta meta) async {
    await _storage.write(
      key: _Keys.endpointMeta,
      value: jsonEncode(<String, Object?>{
        if (meta.rememberedEndpointUrl != null)
          'remembered': meta.rememberedEndpointUrl,
        'hidden': meta.hiddenEndpointIds.toList(),
        'succeeded': meta.succeededEndpointIds.toList(),
      }),
    );
  }

  /// 清空（吊销 / 重新配对时用）。
  static Future<void> clear() => _storage.deleteAll();
}
