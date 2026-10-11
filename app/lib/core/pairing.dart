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
  });

  factory PairingOffer.fromQrPayload(
    String payload, {
    bool allowInsecureLocal = false,
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
    checkedRelayUri(relay, allowInsecureLocal: allowInsecureLocal);
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
    );
  }

  final String relayUrl;
  final String pcId;
  final String pcSignPubHex;
  final String pcDhPubHex;
  final String offerId;

  /// 仅在用户确认后的加密提交中使用，不登记到中转。
  final String code;

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

String _requireString(Map<String, Object?> value, String field) {
  final text = value[field];
  if (text is! String || text.isEmpty) {
    throw ProtocolException(ErrorCode.notPaired, '二维码缺少字段 $field');
  }
  return text;
}
