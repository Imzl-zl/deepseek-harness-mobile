/// 配对（契约 §12.1）—— 手机侧。
///
/// ## 这一步在解决什么
///
/// 在配对之前，手机**没有任何可信的电脑身份**：它不知道电脑的公钥，
/// 因此不能建立密钥、不能认证任何一帧。配对是"把可信身份从**带外**搬进来"的那一步。
///
/// ## 两条硬规则（契约 §12.1，这一层负责守住）
///
/// 1. **只信任二维码里带出的电脑公钥**，不接受任何网络下发的公钥。
///    所以 [PairingOffer.fromQrPayload] 是**唯一**的电脑公钥入口 ——
///    没有任何"从 `presence` 或 `res` 里读公钥"的路径。
/// 2. **配对请求里带的是 `codeHash`，不是配对码本身**（请求要经中转）。
///
/// ## 为什么派生规则写在这里而不是散在两处
///
/// `pairingId` 的派生（契约 §12.1）两端必须**逐字一致**：
/// `base64url(HKDF-SHA256(ikm = sha256Hex(code) 的 UTF-8 字节, salt = 空,
/// info = "dsh-mobile/v1/pairing", L = 32))`。
/// 差一个字节的表现是"配上了但永远连不上"（master 不同 → 箱解不开），
/// 而那时排查会从"网络"开始找 —— 所以它只该有一处实现，且与电脑侧对齐。
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'crypto.dart';
import 'errors.dart';

/// 二维码载荷的版本（契约 §12.1 第 1 步的 `v`）。
const int pairingPayloadVersion = 1;

/// `pairingId` 派生用的域名分隔串（**与电脑侧逐字一致**）。
const String pairingIdInfo = 'dsh-mobile/v1/pairing';

/// 短指纹（SAS）的域名分隔串（同上）。
const String sasInfo = 'dsh-mobile/v1/sas';

/// 扫码得到的那份配对邀约（**电脑公钥的唯一来源**）。
class PairingOffer {
  const PairingOffer({
    required this.relayUrl,
    required this.pcSignPubHex,
    required this.pcDhPubHex,
    required this.code,
  });

  /// 从二维码里的字符串解析。
  ///
  /// ## 为什么这里校验得这么细
  ///
  /// 二维码是**外部输入**，而且它是"信任的起点"——一个字段错的二维码
  /// 如果被接受，症状会出现在**后面很远的地方**（握手失败 / 箱解不开 /
  /// 连上但一直重连），那时没人会想到是二维码的问题。
  /// 所以宁可在这里就用明确的原因拒掉。
  factory PairingOffer.fromQrPayload(String payload) {
    final Object? parsed;
    try {
      parsed = jsonDecode(payload);
    } catch (error) {
      throw ProtocolException(ErrorCode.notPaired, '二维码不是合法 JSON：$error');
    }
    if (parsed is! Map) {
      throw const ProtocolException(ErrorCode.notPaired, '二维码内容不是对象');
    }

    final version = parsed['v'];
    if (version != pairingPayloadVersion) {
      // **不猜、不向后兼容**：版本不符时按旧格式硬解析，会用错误的字段建密钥，
      // 而症状是"连不上"而不是"版本不对"。
      //
      // 用 `unsupported-version` 而不是 `not-paired`：两者对用户的动作不同 ——
      // 前者是"升级 App"（重扫同一张码也没用），后者是"回去重新扫码"。
      throw ProtocolException(
        ErrorCode.unsupportedVersion,
        '二维码版本不支持（期望 $pairingPayloadVersion，收到 $version）',
      );
    }

    final relay = _requireString(parsed, 'relay');
    final pcPubEd = _requireString(parsed, 'pcPubEd');
    final pcPubDh = _requireString(parsed, 'pcPubDh');
    final code = _requireString(parsed, 'code');

    _requireHex(pcPubEd, 'pcPubEd');
    _requireHex(pcPubDh, 'pcPubDh');

    return PairingOffer(
      relayUrl: relay,
      pcSignPubHex: pcPubEd,
      pcDhPubHex: pcPubDh,
      code: code,
    );
  }

  /// 中转地址（`wss://…`）。
  final String relayUrl;

  /// 电脑侧 Ed25519 公钥（十六进制）。**只来自二维码。**
  final String pcSignPubHex;

  /// 电脑侧 X25519 静态公钥（十六进制）。**只来自二维码。**
  final String pcDhPubHex;

  /// 配对码（明文，只在扫码那一刻存在于内存里）。
  ///
  /// 它**不进日志、不落盘**（落盘的是 [codeHash]）。理由：
  /// 码是"能配上一台新设备"的凭据，而配对请求要经中转 —— 泄漏即被抢配。
  final String code;

  /// 配对码的哈希（十六进制）。**落盘与上报都用它，不用码本身。**
  Future<String> codeHash() => sha256Hex(code);

  /// 配对标识（`pairingId`，契约 §12.1）。base64url 无填充。
  ///
  /// 输入的 ikm 是**码的哈希的 UTF-8 字节**（即十六进制字符串本身），不是码。
  /// 这一点最容易写错：直接用码的字节也能算出一个值，而且两端各自自洽 ——
  /// 只有在两端对上时才会发现不一样。
  Future<String> pairingId() async {
    final ikm = utf8.encode(await codeHash());
    final out = await hkdf(
      ikm: ikm,
      salt: const <int>[], // 空盐 ≡ 全零盐（RFC 5869）
      info: utf8.encode(pairingIdInfo),
      length: rawKeyBytes,
    );
    return base64UrlNoPad(out);
  }

  /// 配对请求载荷（契约 §12.1 第 2 步）。
  ///
  /// **带 `codeHash` 而不是 `code`** —— 这个请求要经中转。
  Future<Map<String, Object?>> requestPayload({
    required String devPubEdHex,
    required String devPubDhHex,
    required String deviceName,
  }) async => <String, Object?>{
    'codeHash': await codeHash(),
    'devPubEd': devPubEdHex,
    'devPubDh': devPubDhHex,
    'name': deviceName,
  };
}

/// 短指纹（SAS，契约 §12.1）：用户两端对照的 6 位数字。
///
/// 定义固定为 `sha256("dsh-mobile/v1/sas|" + pcPubEd + "|" + devPubEd)` 的
/// **前 4 字节按大端读成整数后 `mod 1000000`，补零成 6 位**。
///
/// 用公钥而非密钥材料，是因为它在**配对之前**就要能显示 —— 那时还没有任何共享密钥。
Future<String> sasOf({
  required String pcSignPubHex,
  required String devSignPubHex,
}) async {
  final material = utf8.encode('$sasInfo|$pcSignPubHex|$devSignPubHex');
  final digest = await Sha256().hash(material);
  final bytes = digest.bytes;
  // 前 4 字节，大端。
  final value =
      (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];
  // `mod 1000000` 后补零到 6 位：不补零会让 `000123` 显示成 `123`，
  // 而两端对照时"位数不一样"会让人以为算错了。
  return (value % 1000000).toString().padLeft(6, '0');
}

/// `sha256` 的十六进制小写（与电脑侧 `sha256Hex` 对齐）。
Future<String> sha256Hex(String text) async {
  final digest = await Sha256().hash(utf8.encode(text));
  return toHex(digest.bytes);
}

String _requireString(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is! String || value.isEmpty) {
    // `not-paired` 的动作是"回到配对页" —— 正是这种情况该做的（重扫一张码）。
    throw ProtocolException(ErrorCode.notPaired, '二维码缺少字段 $key');
  }
  return value;
}

void _requireHex(String value, String field) {
  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(value) || value.length.isOdd) {
    throw ProtocolException(ErrorCode.notPaired, '二维码字段 $field 不是合法的十六进制公钥');
  }
}
