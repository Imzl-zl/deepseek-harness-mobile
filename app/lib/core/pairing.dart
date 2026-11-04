/// 首配 v2：公开邀请不含授权秘密，电脑身份只来自二维码。
library;

import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'crypto.dart';
import 'endpoint.dart';
import 'errors.dart';

const int pairingPayloadVersion = 2;
const String pairingIdInfo = 'dsh-mobile/v1/pairing';
const String pairingKeyInfo = 'dsh-mobile/v2/pairing-keys|';
const String sasInfo = 'dsh-mobile/v1/sas';
const int maxDeviceNameBytes = 256;
final _token = RegExp(r'^[A-Za-z0-9_-]{22}$');
final _publicKey = RegExp(r'^[0-9a-f]{64}$');

class PairingOffer {
  const PairingOffer({
    required this.relayUrl,
    required this.pcId,
    required this.pcSignPubHex,
    required this.pcDhPubHex,
    required this.offerId,
    required this.code,
    this.lanUrls = const [],
    this.lanOnly = false,
  });

  factory PairingOffer.fromQrPayload(
    String payload, {
    bool allowInsecureLocal = false,

    /// 公网明文（用户自部署中转）：**只由"用户看过电脑身份并确认"的那一步**
    /// 传 true（配对页的确认按钮），不是全局默认。
    bool allowInsecurePublic = false,
  }) {
    final Object? parsed;
    try {
      parsed = jsonDecode(payload);
    } catch (_) {
      throw const ProtocolException(ErrorCode.notPaired, '二维码不是合法 JSON');
    }
    if (parsed is! Map<String, Object?>) {
      throw const ProtocolException(ErrorCode.notPaired, '二维码内容不是对象');
    }
    if (parsed['v'] != pairingPayloadVersion) {
      throw const ProtocolException(
        ErrorCode.unsupportedVersion,
        '请升级客户端并在电脑重新生成 v2 配对码',
      );
    }
    final relay = _requireString(parsed, 'relay');
    checkedRelayUri(
      relay,
      allowInsecureLocal: allowInsecureLocal,
      allowInsecurePublic: allowInsecurePublic,
    );
    final pcId = _requireString(parsed, 'pcId');
    final pcEd = _requireString(parsed, 'pcPubEd');
    final pcDh = _requireString(parsed, 'pcPubDh');
    final offerId = _requireString(parsed, 'offerId');
    final code = _requireString(parsed, 'code');
    if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(pcId) ||
        !_publicKey.hasMatch(pcEd) ||
        !_publicKey.hasMatch(pcDh) ||
        !_token.hasMatch(offerId) ||
        !_token.hasMatch(code) ||
        offerId == code) {
      throw const ProtocolException(ErrorCode.notPaired, '二维码身份、邀请或秘密的格式不合法');
    }
    return PairingOffer(
      relayUrl: relay,
      pcId: pcId,
      pcSignPubHex: pcEd,
      pcDhPubHex: pcDh,
      offerId: offerId,
      code: code,
      lanUrls: _lanUrlsOf(
        parsed['lan'],
        allowInsecureLocal: allowInsecureLocal,
        allowInsecurePublic: allowInsecurePublic,
      ),
      // **降级标**（契约 §12.1）：电脑侧出码时向中转登记失败，这张码只有局域网那条路。
      // 只认字面 `true`：别的值（缺、字符串、0）一律当"没这个标记"—— 不猜。
      lanOnly: parsed['lanOnly'] == true,
    );
  }

  final String relayUrl;
  final String pcId;
  final String pcSignPubHex;
  final String pcDhPubHex;
  final String offerId;

  /// 仅在用户确认后的加密提交中使用，不登记到中转。
  final String code;

  /// 电脑侧报的**局域网直连地址**（`ws://<ip>:<port>`，不带路径/参数）。
  ///
  /// 空 = 老载荷（电脑侧没开监听面、或那份连接器还不报这一格）：只能走中转换票。
  /// 顺序即偏好（电脑侧把默认路由那张网卡的地址排在前面），拨号时再按同网段重排。
  ///
  // Note: 为什么二维码里带局域网地址 —— 见
  // `.agents/notes/implemented/2026-11-03-pairing-without-relay.md`
  final List<String> lanUrls;

  /// 这张码**只有局域网那一条路**（电脑侧出码时向中转登记失败）。
  ///
  /// 载荷里是 `lanOnly: true`（契约 §12.1）。它不改变配对流程，只改变两件事：
  /// 配对页**显式提示**「此码只能在同一 Wi-Fi 下使用」，以及拨号时**不去试中转**
  /// （那条路这次注定换不到票，多试一次只是让用户多等一个超时）。
  ///
  /// 老载荷没有这一格读成 `false` —— 与改造前逐字一致。
  ///
  // Note: 为什么降级必须可见 —— 见
  // `.agents/notes/implemented/2026-11-04-pairing-degradation-is-visible.md`
  final bool lanOnly;

  Future<String> codeHash() => sha256Hex(code);
  Future<String> pairingId() async => base64UrlNoPad(
    await hkdf(
      ikm: utf8.encode(await codeHash()),
      salt: const [],
      info: utf8.encode(pairingIdInfo),
      length: rawKeyBytes,
    ),
  );

  PairingCandidate candidate(IdentityKeys identity, String name) {
    if (name.trim().isEmpty || utf8.encode(name).length > maxDeviceNameBytes) {
      throw const ProtocolException(ErrorCode.badFrame, '设备名称为空或过长');
    }
    return PairingCandidate(
      offerId: offerId,
      devPubEdHex: identity.sign.publicKeyHex,
      devPubDhHex: identity.dh.publicKeyHex,
      name: name,
    );
  }
}

/// 配对成功后要种进端点表的条目：**局域网直连在前，中转在后**。
///
/// 顺序即偏好。直连在前是因为这次配对很可能就是走它成功的，而中转那条在
/// "关掉中转的机器"上根本拨不通 —— 把它排前面等于每次冷启动先等一个超时。
///
/// `hostId` 盖的是**配对钉死的电脑公钥**（`pcSignPubHex`）：端点身份是
/// `hostId|url`（`core/endpoint.dart` 的 `endpointIdOf`），不盖的话连接器第一次
/// 自报同一条地址会认不出"这是同一条"而追加出重复项。
///
/// 老载荷（没有 `lan`）只会得到中转那一条 —— 与改造前逐字一致。
///
// Note: 为什么配对成功就要把局域网地址种进端点表 —— 见
// `.agents/notes/implemented/2026-11-03-pairing-without-relay.md`
List<Endpoint> pairingEndpoints(PairingOffer offer) => [
  for (final url in offer.lanUrls)
    Endpoint(
      kind: EndpointKind.direct,
      url: url,
      label: '局域网',
      hostId: offer.pcSignPubHex,
    ),
  Endpoint(
    kind: EndpointKind.relay,
    url: offer.relayUrl,
    label: '中转',
    hostId: offer.pcSignPubHex,
  ),
];

class PairingCandidate {
  const PairingCandidate({
    required this.offerId,
    required this.devPubEdHex,
    required this.devPubDhHex,
    required this.name,
  });
  final String offerId;
  final String devPubEdHex;
  final String devPubDhHex;
  final String name;

  Map<String, Object?> toWire() => {
    'v': pairingPayloadVersion,
    'offerId': offerId,
    'devPubEd': devPubEdHex,
    'devPubDh': devPubDhHex,
    'name': name,
  };
  Future<String> deviceId() => pairingDeviceId(devPubDhHex);
  Future<String> handshakeContext(PairingOffer offer) async => [
    'dsh-mobile/pairing/v2',
    offerId,
    offer.pcId,
    offer.pcSignPubHex,
    offer.pcDhPubHex,
    await deviceId(),
    devPubEdHex,
    devPubDhHex,
    await sha256Hex(name),
  ].join('|');
}

Future<String> pairingDeviceId(String dhPubHex) async {
  final digest = await Sha256().hash(utf8.encode(dhPubHex));
  return base64UrlNoPad(digest.bytes.sublist(0, 16));
}

/// 辅助指纹，不是授权判据。
Future<String> sasOf({
  required String pcSignPubHex,
  required String devSignPubHex,
}) async {
  final digest = await Sha256().hash(
    utf8.encode('$sasInfo|$pcSignPubHex|$devSignPubHex'),
  );
  final bytes = digest.bytes;
  final value =
      (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  return (value % 1000000).toString().padLeft(6, '0');
}

Future<String> sha256Hex(String text) async =>
    toHex((await Sha256().hash(utf8.encode(text))).bytes);

/// 局域网配对要拨的地址：`<lan>?pair=<offerId>&cand=<候选>`。
///
/// 与连接器 `connector/src/pairing-lan.ts` 的 `pairingDialUrl` **同一套字段**：
/// `pair` 是触发参数（电脑侧据此把这条连接按"配对候选"建），`cand` 是候选身份
/// （握手第一步就要用它验签，而 `hello` 帧里没有公钥 —— 见那里的说明）。
///
/// `cand` 是**无填充** base64url 的 JSON：候选里只有公钥与设备名，都不是秘密，
/// 但它是 URL 的一部分，所以不塞 `=`（有些代理会吃掉它）。
String pairingDialUrl(String lanUrl, PairingCandidate candidate) {
  final uri = Uri.parse(lanUrl);
  final encoded = base64Url
      .encode(utf8.encode(jsonEncode(candidate.toWire())))
      .replaceAll('=', '');
  return uri
      .replace(
        // 空路径补成 `/`：与电脑侧 `new URL(lanUrl)` 的规范形一致（`ws://h:p/?pair=`）。
        path: uri.path.isEmpty ? '/' : uri.path,
        queryParameters: {'pair': candidate.offerId, 'cand': encoded},
      )
      .toString();
}

/// 解析载荷里的 `lan` 那一格。
///
/// **认不出的条目直接丢，不让整张码作废**：中转那条路照样能用，而一张因为多了一条
/// 坏地址就整张扫不了的码，代价远大于收益。空/缺/不是数组 ⇒ 空表（老载荷）。
List<String> _lanUrlsOf(
  Object? raw, {
  required bool allowInsecureLocal,
  required bool allowInsecurePublic,
}) {
  if (raw is! List) return const [];
  final out = <String>[];
  for (final entry in raw) {
    if (entry is! String || entry.isEmpty || out.contains(entry)) continue;
    try {
      // 与中转地址同一道边界（`checkedRelayUri`）：局域网明文要显式放行，
      // 公网明文要用户确认过。地址里不许带凭据/参数/片段。
      checkedRelayUri(
        entry,
        allowInsecureLocal: allowInsecureLocal,
        allowInsecurePublic: allowInsecurePublic,
      );
    } on ProtocolException {
      continue;
    }
    out.add(entry);
  }
  return out;
}

String _requireString(Map<String, Object?> value, String field) {
  final text = value[field];
  if (text is! String || text.isEmpty) {
    throw ProtocolException(ErrorCode.notPaired, '二维码缺少字段 $field');
  }
  return text;
}
