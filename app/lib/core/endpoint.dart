/// 中转地址的统一边界：生产 WSS，显式调试仅允许回环 WS。
library;

import 'errors.dart';

Uri checkedRelayUri(
  String value, {
  bool allowInsecureLocal = false,
  bool allowQuery = false,
}) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      (!allowQuery && uri.hasQuery)) {
    throw const ProtocolException(ErrorCode.badFrame, '中转地址不合法，不能包含凭据或额外参数');
  }
  final loopback = const ['localhost', '127.0.0.1', '::1'].contains(uri.host);
  if (uri.scheme != 'wss' &&
      !(allowInsecureLocal && loopback && uri.scheme == 'ws')) {
    throw const ProtocolException(
      ErrorCode.badFrame,
      '中转必须使用 WSS；明文仅限显式开启的本机调试',
    );
  }
  return uri;
}

/// 设备升级 URL：`<根>/ws/device?ticket=<票>`（契约 §2 的连接建立）。
///
/// 票**进 URL** 是刻意的：它是为进 URL 而生的一次性凭据（60 秒有效、用过即废），
/// 所以"URL 会进日志"这条风险被压到最小；而设备令牌与主种子**绝不进 URL**。
///
/// `relayUrl` 来自二维码，形如 `ws://host:port`（**不带路径**）。万一带了路径
/// （配置里写过 `/ws/connector`，那是电脑侧拨号用的那条），这里只取 scheme + authority
/// —— 与 [httpBaseOf] 同一条纪律。两处都"丢掉路径"，否则会拼出
/// `/ws/connector/ws/device`（404，而中转对 404 只 `log?.debug`，手机侧看起来像"连不上"）。
String deviceUpgradeUrl(String relayUrl, String ticket) {
  final uri = Uri.parse(relayUrl);
  return '${uri.scheme}://${uri.authority}/ws/device'
      '?ticket=${Uri.encodeQueryComponent(ticket)}';
}
