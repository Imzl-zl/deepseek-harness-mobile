/// 加密配对结果的边界解析；不再提供明文 pair 编码入口。
library;

import 'dart:convert';
import 'errors.dart';

class PairingAck {
  const PairingAck({
    required this.devId,
    required this.sas,
    required this.pcId,
    required this.deviceToken,
    required this.refreshToken,
  });
  final String devId;
  final String sas;
  final String pcId;
  final String deviceToken;
  final String refreshToken;
}

/// `pair-result` 里各字段的形状（与电脑侧签发的形状同一份）。
///
/// 分开逐个查、并且**报出是哪个字段**：合并成一句"格式不合法"会把"令牌短了"
/// 与"pcId 有问题"混在一起，而两者的下一步动作不同（前者要重新配对，
/// 后者是回执坏了）—— 本项目已经吃过一次"报错类别错了用户就永远卡在重试上"。
final RegExp _token22 = RegExp(r'^[A-Za-z0-9_-]{22}$');
final RegExp _sas6 = RegExp(r'^\d{6}$');
final RegExp _pcIdShape = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

/// 形状不符即拒，并**点名**是哪个字段。
///
/// 不带字段值：`deviceToken` / `refreshToken` 是长期凭据，错误信息会进日志。
void _requireShape(String field, String value, RegExp pattern, String shape) {
  if (!pattern.hasMatch(value)) {
    throw ProtocolException(
      ErrorCode.badFrame,
      'pair-result 的 $field 不是$shape',
    );
  }
}

PairingAck parsePairAck(String plaintext) {
  final Object? parsed;
  try {
    parsed = jsonDecode(plaintext);
  } catch (_) {
    throw const ProtocolException(ErrorCode.badFrame, 'pair-result 不是合法 JSON');
  }
  if (parsed is! Map<String, Object?>) {
    throw const ProtocolException(ErrorCode.badFrame, 'pair-result 不是 JSON 对象');
  }
  final payload = parsed;
  if (payload['ok'] != true) {
    final reason = payload['reason'];
    throw ProtocolException(
      payload['registered'] == true
          ? ErrorCode.relayOffline
          : ErrorCode.notPaired,
      reason is String && reason.isNotEmpty ? reason : '配对被拒绝',
    );
  }
  String require(String field) {
    final value = payload[field];
    if (value is! String || value.isEmpty) {
      throw ProtocolException(ErrorCode.badFrame, 'pair-result 缺少字段 $field');
    }
    return value;
  }

  final ack = PairingAck(
    devId: require('devId'),
    sas: require('sas'),
    pcId: require('pcId'),
    deviceToken: require('deviceToken'),
    refreshToken: require('refreshToken'),
  );
  _requireShape('devId', ack.devId, _token22, '22 字符的 base64url 标识');
  _requireShape('sas', ack.sas, _sas6, '6 位数字（它是给人照着念的）');
  _requireShape('pcId', ack.pcId, _pcIdShape, '合法的电脑标识');
  _requireShape(
    'deviceToken',
    ack.deviceToken,
    _token22,
    '22 字符的 base64url 令牌',
  );
  _requireShape(
    'refreshToken',
    ack.refreshToken,
    _token22,
    '22 字符的 base64url 令牌',
  );
  return ack;
}
