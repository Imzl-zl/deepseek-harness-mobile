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
import '../core/frame.dart' show randomBytes;

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

/// 安全存储的窄缝：本文件只用到"整份读 / 单键写 / 单键删 / 全清"。
///
/// 有它，分槽与迁移的判据（**写次数**、槽隔离）才能在纯 Dart 单测里驱动；
/// 真实现是 [FlutterSecureStore]（系统密钥库）。缝留在 `platform/`：
/// `core/` 与 `data/` 只认识 [PairedCredentials] 这个值类型。
abstract interface class SecureStore {
  Future<Map<String, String>> readAll();

  Future<void> write(String key, String value);

  Future<void> delete(String key);

  Future<void> deleteAll();
}

/// 系统密钥库（安卓 Keystore / iOS Keychain）上的 [SecureStore]。
class FlutterSecureStore implements SecureStore {
  const FlutterSecureStore([
    this._storage = const FlutterSecureStorage(
      // 安卓：v11 的默认构造就是强加密（**已核实包源码**
      // `lib/options/android_options.dart`）：AES-GCM 存数据 + RSA-OAEP 包裹密钥，
      // 要求 API 23+。所以**不需要**再传选项 ——
      // 早期版本那个 `encryptedSharedPreferences: true` 在 v11 已不存在
      //（写它是**编译错误**，这比"静默不生效"好）。
      //
      // iOS：`afterFirstUnlockThisDeviceOnly` —— 锁屏也能读（后台收推送时要读），
      // 但**不随备份迁移到新设备**（设备身份不该被备份复制，契约 §12.2）。
      aOptions: AndroidOptions(resetOnError: false),
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock_this_device,
      ),
    ),
  ]);

  final FlutterSecureStorage _storage;

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<void> deleteAll() => _storage.deleteAll();
}

/// 配对凭据的读写：**一台电脑一个槽**。
///
/// 键的形状 `dsh.pairing.<hostId>.<field>`，外加 `dsh.pairing.active`（当前那台）。
/// `hostId` 是那台电脑的 Ed25519 公钥（`pcSignPubHex`，配对时钉死、不可改）——
/// 所以配对第二台是**新增一个槽**，不是覆盖第一台（`proposed/2026-10-29-one-phone-many-computers.md`
/// 决策 3）。
///
/// 凭据主体存单个 v2 JSON，完整已发版分槽 v1 在读取时相邻迁移。
/// 旧平铺键 `dsh.<field>` 不识别；坏 v2 明确报错，不拿 v1 字段补半份。
/// 取舍见 `.agents/notes/implemented/2026-10-30-drop-legacy-compat.md`。
class PairingStore {
  PairingStore(this._secure);

  final SecureStore _secure;

  static const String keyPrefix = 'dsh.pairing.';

  /// 当前那台电脑（`hostId`）。
  static const String activeKey = '${keyPrefix}active';

  // Note: 安装码/定位信息与凭据分离，凭据 v1→v2 原子迁移。
  // .agents/notes/implemented/2026-11-24-stable-device-code-and-pairing-continuity.md
  static const String deviceCodeKey = 'dsh.device_code';
  static const String hintPrefix = 'dsh.pairing_hint.';
  static const String credentialsField = 'credentials_v2';
  static const List<String> _credentialFields = [
    'relay_url',
    'pc_sign_pub',
    'pc_dh_pub',
    'pairing_id',
    'master_seed',
    'dev_sign_pub',
    'dev_dh_pub',
    'device_token',
    'refresh_token',
    'pc_id',
    'dev_id',
  ];
  Future<String>? _deviceCodeWork;
  Future<void> _operations = Future<void>.value();
  static final RegExp _deviceCodePattern = RegExp(r'^[A-Za-z0-9_-]{22}$');

  /// 迁移和保存共享一个写入口；错误只结算控制队列，原调用仍然失败。
  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  /// 应用安全存储生命周期内稳定的展示/定位码，不参与持钥鉴权。
  /// 缺值才创建；读错或已有坏值明确报错，绝不重铸。
  Future<String> getOrCreateDeviceCode() => _deviceCodeWork ??= _enqueue(
    _readDeviceCodeUnlocked,
  ).whenComplete(() => _deviceCodeWork = null);

  Future<String> _readDeviceCodeUnlocked() async {
    final values = await _secure.readAll();
    final stored = values[deviceCodeKey];
    if (stored != null) {
      if (!_deviceCodePattern.hasMatch(stored)) {
        throw StateError('安全存储中的设备码不合法，未覆盖或重置');
      }
      return stored;
    }
    // 覆盖升级缺安装码时，以当前完整配对的实际展示 ID 相邻迁移。
    // 非当前槽不参与 canonical 选择；后续鉴权轮换不再重写设备码。
    final active = values[activeKey];
    final current = active == null || active.isEmpty
        ? null
        : await _loadSlotUnlocked(values, active);
    final code = current == null
        ? base64UrlNoPad(randomBytes(16))
        : await current.helloDeviceId();
    if (!_deviceCodePattern.hasMatch(code)) {
      throw StateError('当前配对设备标识不合法，未生成或覆盖设备码');
    }
    await _secure.write(deviceCodeKey, code);
    return code;
  }

  /// 按二维码里的目标公钥读旧标识；路由 pcId 也须一致。
  /// 清配对后只读非凭据定位信息，不恢复任何身份秘密。
  Future<String?> previousPairingIdFor({
    required String pcSignPubHex,
    required String pcId,
  }) => _enqueue(() async {
    final values = await _secure.readAll();
    final credentials = await _loadSlotUnlocked(values, pcSignPubHex);
    if (credentials != null) {
      return credentials.pcId == pcId ? credentials.pairingId : null;
    }
    final raw = values['$hintPrefix$pcSignPubHex'];
    if (raw == null) return null;
    final hint = jsonDecode(raw);
    if (hint is! Map<String, dynamic> ||
        hint['pcId'] is! String ||
        hint['pairingId'] is! String ||
        (hint['pairingId'] as String).isEmpty) {
      throw const FormatException('安全存储中的旧配对定位信息不合法');
    }
    return hint['pcId'] == pcId ? hint['pairingId'] as String : null;
  });

  static Set<String> _slotIds(Map<String, String> values) => {
    for (final key in values.keys)
      if (key.startsWith(keyPrefix) &&
          key != activeKey &&
          key.substring(keyPrefix.length).contains('.'))
        key.substring(keyPrefix.length).split('.').first,
  };

  static String _encodeCredentials(PairedCredentials c) => jsonEncode({
    'v': 2,
    'relay_url': c.relayUrl,
    'pc_sign_pub': c.pcSignPubHex,
    'pc_dh_pub': c.pcDhPubHex,
    'pairing_id': c.pairingId,
    'master_seed': c.masterSeedHex,
    'dev_sign_pub': c.devSignPubHex,
    'dev_dh_pub': c.devDhPubHex,
    'device_token': c.deviceToken,
    'refresh_token': c.refreshToken,
    'pc_id': c.pcId,
    'dev_id': c.devId,
  });

  Future<void> _rememberHint(
    PairedCredentials c,
    Map<String, String> values,
  ) async {
    if (c.pcId.isEmpty || c.pairingId.isEmpty) return;
    final key = '$hintPrefix${c.pcSignPubHex}';
    final raw = jsonEncode({'pcId': c.pcId, 'pairingId': c.pairingId});
    if (values[key] != raw) await _secure.write(key, raw);
  }

  Future<void> _deleteLegacyCredentials(
    String hostId,
    Map<String, String> values,
  ) async {
    for (final field in _credentialFields) {
      final key = slotKey(hostId, field);
      if (values.containsKey(key)) await _secure.delete(key);
    }
  }

  Future<PairedCredentials?> _loadSlotUnlocked(
    Map<String, String> values,
    String hostId,
  ) async {
    final credentials = _decodeSlot(values, hostId);
    if (credentials == null) return null;
    final hasLegacy = _credentialFields.any(
      (f) => values.containsKey(slotKey(hostId, f)),
    );
    if (!values.containsKey(slotKey(hostId, credentialsField))) {
      // 完整已发版分槽（v1）→v2：先原子写，成功后才删旧秘密。
      await _write(hostId, credentialsField, _encodeCredentials(credentials));
    }
    if (hasLegacy) {
      await _rememberHint(credentials, values);
      await _deleteLegacyCredentials(hostId, values);
    }
    return credentials;
  }

  /// 一台电脑的一个字段键。
  static String slotKey(String hostId, String field) =>
      '$keyPrefix$hostId.$field';

  /// 读出已存的凭据；没有或不完整时返回 `null`。
  ///
  /// [hostId] 为空 = 当前那台（`dsh.pairing.active`）。给 [hostId] 是为了
  /// "切回另一台"与用例读指定槽 —— 它不改变 `active`。
  ///
  /// **不完整就当没有**：缺任一必填字段都用不了（缺 `pairingId` 算不出 `master`，
  /// 缺 `deviceToken` 换不到票），而"部分可用"会让失败发生在很后面 ——
  /// 那时没人会想到是存储缺字段。
  ///
  /// 没有 `active` 也没有指定 [hostId] 时回 `null`（**不猜哪一台**）。
  Future<PairedCredentials?> load({String? hostId}) => _enqueue(() async {
    final values = await _secure.readAll();
    final target = hostId == null || hostId.isEmpty
        ? values[activeKey]
        : hostId;
    if (target == null || target.isEmpty) return null;
    return _loadSlotUnlocked(values, target);
  });

  /// 解一个槽。**槽里必须齐**（必填字段缺一个就回 `null`，不拼半份）。
  PairedCredentials? _decodeSlot(Map<String, String> values, String hostId) {
    Map<String, dynamic>? blob;
    final raw = values[slotKey(hostId, credentialsField)];
    if (raw != null) {
      Object? decoded;
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        // 原始 blob 含秘密，异常不能把 source 带给界面或诊断日志。
        throw const FormatException('配对凭据 v2 JSON 无法解析，未回落旧键');
      }
      if (decoded is! Map<String, dynamic> || decoded['v'] != 2) {
        throw const FormatException('配对凭据 v2 格式不合法，未回落旧键');
      }
      for (final field in _credentialFields) {
        final value = decoded[field];
        if (value is! String ||
            (value.isEmpty && field != 'pc_id' && field != 'dev_id')) {
          throw FormatException('配对凭据 v2 缺少合法字段 $field，未回落旧键');
        }
      }
      if (decoded['pc_sign_pub'] != hostId) {
        throw const FormatException('配对凭据 v2 与目标电脑公钥不一致');
      }
      blob = decoded;
    }
    String? read(String field) =>
        blob == null ? values[slotKey(hostId, field)] : blob[field] as String?;
    final relayUrl = read('relay_url');
    final pcSignPub = read('pc_sign_pub');
    final pcDhPub = read('pc_dh_pub');
    final pairingId = read('pairing_id');
    final masterSeed = read('master_seed');
    final devSignPub = read('dev_sign_pub');
    final devDhPub = read('dev_dh_pub');
    final deviceToken = read('device_token');
    final refreshToken = read('refresh_token');

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

    // **端点归属在读取时补齐**：这份凭据就是这一台电脑的（`pcSignPub` 是它的身份），
    // 所以表里没有 `hostId` 的条目（升级前落的 / 配对种子）都归它。
    // 端点身份是 `hostId|url`（`core/endpoint.dart` 的 `endpointIdOf`）。
    final endpoints = _decodeEndpoints(
      values[slotKey(hostId, 'endpoints')],
      relayUrl,
      pcSignPub,
    );

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
      endpoints: endpoints,
      // id 一律是 `hostId|url`（`endpointIdOf`），**不做旧形状识别**。
      endpointMeta: _decodeEndpointMeta(
        values[slotKey(hostId, 'endpoint_meta')],
        endpoints: endpoints,
      ),
      pcId: read('pc_id') ?? '',
      devId: read('dev_id') ?? '',
    );
  }

  /// 解端点表的附属状态。缺或坏都退化成"空的记忆"（**不猜**）：
  /// 丢的只是"上次连哪条"这类优化信息，拨号照样能work。
  ///
  /// 三份集合里存的都是 `Endpoint.id`（`hostId|url`）**原样**，不在读取时补前缀 ——
  /// 没有"裸 url 的旧形状"需要识别（协议没发版）。
  static EndpointMeta _decodeEndpointMeta(
    String? raw, {
    required List<Endpoint> endpoints,
  }) {
    if (raw == null || raw.isEmpty) return const EndpointMeta();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const EndpointMeta();
      final remembered = decoded['remembered'];
      final hidden = decoded['hidden'];
      final succeeded = decoded['succeeded'];
      final rememberedId = remembered is String && remembered.isNotEmpty
          ? remembered
          : null;
      return EndpointMeta(
        // 记住的那条若已不在表里，留着只会让 `dialOrder` 白找一次 —— 直接丢。
        rememberedEndpointId:
            rememberedId != null && endpoints.any((e) => e.id == rememberedId)
            ? rememberedId
            : null,
        hiddenEndpointIds: hidden is List
            ? {for (final id in hidden.whereType<String>()) id}
            : const <String>{},
        succeededEndpointIds: succeeded is List
            ? {for (final id in succeeded.whereType<String>()) id}
            : const <String>{},
      );
    } on FormatException {
      return const EndpointMeta();
    }
  }

  /// 解端点表。缺表 / 坏表时从 `relayUrl` 造一条 relay 端点（**唯一**的种子，
  /// 不是"旧数据迁移"：空表会让 `EndpointTransport` 抛"没有可拨的端点"）。
  ///
  /// **解不出的条目直接丢**：一个拨不出去的端点会让整条链在很后面才失败，
  /// 而那时没人会想到是存储里躺着一条废条目。
  static List<Endpoint> _decodeEndpoints(
    String? raw,
    String relayUrl,
    String hostId,
  ) {
    Endpoint stamp(Endpoint endpoint) =>
        endpoint.hostId.isEmpty && hostId.isNotEmpty
        ? endpoint.withHost(hostId)
        : endpoint;
    if (raw == null || raw.isEmpty) {
      return [
        stamp(Endpoint(kind: EndpointKind.relay, url: relayUrl, label: '中转')),
      ];
    }
    final List<dynamic> decoded;
    try {
      decoded = jsonDecode(raw) as List<dynamic>;
    } on FormatException {
      return [
        stamp(Endpoint(kind: EndpointKind.relay, url: relayUrl, label: '中转')),
      ];
    }
    final out = <Endpoint>[];
    for (final entry in decoded) {
      final endpoint = endpointFromJson(entry);
      if (endpoint != null) out.add(stamp(endpoint));
    }
    // 整表都解不出来时退回迁移形状：空表会让 `EndpointTransport` 抛
    // "没有可拨的端点"，而用户看到的是"连不上"而不是"存储坏了"。
    return out.isEmpty
        ? [
            stamp(
              Endpoint(kind: EndpointKind.relay, url: relayUrl, label: '中转'),
            ),
          ]
        : out;
  }

  /// 先单次写入完整身份/令牌/配对上下文，再写独立路由与 active。
  /// 同 host 更新中断只会留下完整旧或新身份，不会混合新旧密钥。
  Future<void> save(PairedCredentials credentials) => _enqueue(() async {
    final hostId = credentials.pcSignPubHex;
    final values = await _secure.readAll();
    // 同 host 更新只在这一次安全存储写中替换全部身份/令牌/配对上下文。
    await _write(hostId, credentialsField, _encodeCredentials(credentials));
    await _deleteLegacyCredentials(hostId, values);
    await _write(
      hostId,
      'endpoints',
      jsonEncode(credentials.endpoints.map(endpointToJson).toList()),
    );
    await _write(
      hostId,
      'endpoint_meta',
      _encodeMeta(credentials.endpointMeta),
    );
    await _rememberHint(credentials, values);
    await _secure.write(activeKey, hostId);
  });

  Future<void> _write(String hostId, String field, String value) =>
      _secure.write(slotKey(hostId, field), value);

  /// 只更新**这一台**的端点表。
  ///
  /// **不重写整份凭据**：端点表的刷新频率远高于凭据（每次经中转连上都会拉一次
  /// `endpoint.describe`），而主种子与设备令牌也在同一个槽里 —— 每次刷新都把
  /// 它们重写一遍，既浪费也给"写一半"多一次机会。
  Future<void> saveEndpoints({
    required String hostId,
    required List<Endpoint> endpoints,
  }) => _write(
    hostId,
    'endpoints',
    jsonEncode(endpoints.map(endpointToJson).toList()),
  );

  /// 只更新**这一台**端点表的附属状态（记住的那条 / 隐藏集 / 成功过的集）。
  ///
  /// 与 [saveEndpoints] 分开：**每次拨通都会改"记住的那条"**，
  /// 而整张表不需要跟着重写。
  Future<void> saveEndpointMeta({
    required String hostId,
    required EndpointMeta meta,
  }) => _write(hostId, 'endpoint_meta', _encodeMeta(meta));

  String _encodeMeta(EndpointMeta meta) => jsonEncode(<String, Object?>{
    // **是 id（`hostId|url`）不是裸 url**，读取端原样用（没有旧形状要识别）。
    if (meta.rememberedEndpointId != null)
      'remembered': meta.rememberedEndpointId,
    'hidden': meta.hiddenEndpointIds.toList(),
    'succeeded': meta.succeededEndpointIds.toList(),
  });

  /// 槽里缓存电脑**自报的名字**（展示值：可改、可伪造、会重名）。
  ///
  /// 它不属于凭据（缺了照样连得上），所以**不放进 [fields]**：那一组是"必填槽字段"，
  /// 加进去等于让升级前的槽全部判成不完整。切换电脑的列表用它显示"这是哪台"，
  /// 读不到就退回 hostId 短码（`PairedHost.label`）。
  static const String hostNameField = 'host_name';

  Future<void> saveHostName(String hostId, String name) async {
    if (name.isEmpty) return;
    await _secure.write(slotKey(hostId, hostNameField), name);
  }

  /// 列出**所有能用的槽**（切换电脑用）。槽不完整（缺必填字段）的不列。
  ///
  /// 顺序：**当前那台最前**，其余按 hostId 字典序 —— 那台是"我正连着的"，
  /// 用户在列表里第一眼要找的就是它。
  Future<List<PairedHost>> hosts() => _enqueue(() async {
    final values = await _secure.readAll();
    final active = values[activeKey] ?? '';
    final rows = <PairedHost>[];
    for (final id in _slotIds(values)) {
      if (await _loadSlotUnlocked(values, id) != null) {
        rows.add(
          PairedHost(hostId: id, name: values[slotKey(id, hostNameField)]),
        );
      }
    }
    rows.sort((a, b) {
      if (a.hostId == active) return -1;
      if (b.hostId == active) return 1;
      return a.hostId.compareTo(b.hostId);
    });
    return rows;
  });

  /// 把**当前槽**切到 [hostId]：只写 `active`，不重写槽、不动别的电脑。
  ///
  /// 槽不完整时抛（调用方本该先 `load` 成功）：让一个半个槽变成当前，
  /// 换来的是启动时"有 active、却读不出凭据"——那种状态没有任何出路。
  Future<void> activate(String hostId) => _enqueue(() async {
    final values = await _secure.readAll();
    if (await _loadSlotUnlocked(values, hostId) == null) {
      throw StateError('这台电脑的配对凭据不完整：$hostId');
    }
    await _secure.write(activeKey, hostId);
  });

  /// **删这一台**（[hostId] 为空 = 当前那台）：只删这个槽。
  ///
  /// 键集合从整份存储里现扫（前缀 `dsh.pairing.<hostId>.`），所以将来加字段
  /// 不会漏删。删的是**当前那台**时顺手清 `active`（其余槽仍可被切回）；
  /// 别的电脑的槽一律不碰。
  Future<void> clear({String? hostId}) => _enqueue(() async {
    final values = await _secure.readAll();
    final target = hostId ?? values[activeKey];
    if (target == null || target.isEmpty) return;
    final credentials = _decodeSlot(values, target);
    if (credentials != null) await _rememberHint(credentials, values);
    final prefix = '$keyPrefix$target.';
    for (final key in values.keys.where((k) => k.startsWith(prefix)).toList()) {
      await _secure.delete(key);
    }
    if (values[activeKey] == target) await _secure.delete(activeKey);
  });

  /// 清全部配对秘密；安装级设备码、非凭据定位信息与其他安全记录保留。
  Future<void> clearAll() => _enqueue(() async {
    final values = await _secure.readAll();
    for (final id in _slotIds(values)) {
      final credentials = _decodeSlot(values, id);
      if (credentials != null) await _rememberHint(credentials, values);
    }
    for (final key in values.keys.where((k) => k.startsWith(keyPrefix))) {
      await _secure.delete(key);
    }
  });
}

/// 一台**已配对电脑**的展示信息（切换电脑的列表用）。
///
/// [hostId] 是那台电脑的 Ed25519 公钥（`pcSignPubHex`，配对时钉死、不可改）；
/// [name] 是电脑自报的展示名（缓存，可能已过期 / 没学到）。
///
/// **名字从不参与判据**：两台同名时靠 [shortCode] 区分（Syncthing 显示 Device ID
/// 的同一种做法），切换本身只认 [hostId]。
class PairedHost {
  const PairedHost({required this.hostId, this.name});

  final String hostId;
  final String? name;

  /// hostId 的短码（前 6 + 后 4）：名字可改可重名，短码不会。
  String get shortCode => hostId.length >= 10
      ? '${hostId.substring(0, 6)}…${hostId.substring(hostId.length - 4)}'
      : hostId;

  /// 列表里显示的那一行：有名字用名字，没有就用短码。
  String get label => (name == null || name!.isEmpty) ? shortCode : name!;

  @override
  bool operator ==(Object other) =>
      other is PairedHost && other.hostId == hostId;

  @override
  int get hashCode => hostId.hashCode;
}

/// 真实现（装配层与真机用例共用这一份）。
final PairingStore pairingStore = PairingStore(const FlutterSecureStore());
