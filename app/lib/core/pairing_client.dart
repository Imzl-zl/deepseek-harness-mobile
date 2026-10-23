/// 候选发现和正式设备换票；公开请求绝不包含 code/codeHash。
library;

import 'dart:convert';
import 'endpoint.dart';
import 'errors.dart';
import 'pairing.dart';

class HttpCall {
  const HttpCall({
    required this.method,
    required this.url,
    this.headers = const {},
    this.body,
  });
  final String method;
  final String url;
  final Map<String, String> headers;
  final String? body;
}

class HttpResult {
  const HttpResult({required this.status, required this.body});
  final int status;
  final String body;
  bool get ok => status >= 200 && status < 300;
}

typedef HttpSender = Future<HttpResult> Function(HttpCall call);

String httpBaseOf(String relayUrl, {bool allowInsecureLocal = false}) {
  final uri = checkedRelayUri(relayUrl, allowInsecureLocal: allowInsecureLocal);
  return '${uri.scheme == 'wss' ? 'https' : 'http'}://${uri.authority}';
}

class Ticket {
  const Ticket({required this.ticket, required this.expiresAt});
  final String ticket;
  final int expiresAt;
}

class PairingClient {
  const PairingClient({
    required this.relayUrl,
    required this.send,
    this.allowInsecureLocal = false,
  });
  final String relayUrl;
  final HttpSender send;
  final bool allowInsecureLocal;

  /// 重连换票（**已配对**设备，凭设备令牌）。
  ///
  /// 这条路上的 401 **不是终态**：中转能说的只有"我的名册里没有这个摘要"，而名册是
  /// **电脑推上去的**（`relay/src/device-registry.ts:88`）—— 中转重启后它是空的，等电脑
  /// 连上来重新灌一遍。把它读成"你被停用了"会**清掉用户凭据**，而真正"被停用"的信号是
  /// 电脑侧在握手层明说（关闭码 4003 + `protocol/not-paired`，见 `core/sync_client_impl.dart`）。
  /// 见 `.agents/notes/implemented/2026-10-24-terminal-identity-from-pc.md`。
  Future<Ticket> ticketByDeviceToken(String deviceToken) => _ticket(
    paired: true,
    HttpCall(
      method: 'POST',
      url:
          '${httpBaseOf(relayUrl, allowInsecureLocal: allowInsecureLocal)}/ws-ticket',
      headers: {
        'authorization': 'Bearer $deviceToken',
        'content-type': 'application/json',
      },
      body: '{}',
    ),
  );

  /// 首配换票（凭**公开邀请**，本机还没有设备身份）。
  ///
  /// 这里的 401 / 409 就是"邀请不对 / 登记不可用" ⇒ 回配对页（让电脑重新出码）。
  Future<Ticket> ticketByOffer(PairingCandidate candidate) => _ticket(
    paired: false,
    HttpCall(
      method: 'POST',
      url:
          '${httpBaseOf(relayUrl, allowInsecureLocal: allowInsecureLocal)}/ws-ticket',
      headers: {'content-type': 'application/json'},
      body: jsonEncode(candidate.toWire()),
    ),
  );

  Future<Ticket> _ticket(HttpCall call, {required bool paired}) async {
    final response = await send(call);
    if (!response.ok) {
      throw ProtocolException(switch (response.status) {
        400 => ErrorCode.badFrame,
        // 401 的含义**取决于这是哪一跳**：首配是"邀请不对"（终态），已配对是
        // "中转名册里没有你"（可恢复 —— 名册由电脑推、重启后为空）。
        401 || 409 => paired ? ErrorCode.relayOffline : ErrorCode.notPaired,
        426 => ErrorCode.unsupportedVersion,
        429 => ErrorCode.rateLimited,
        _ => ErrorCode.relayOffline,
      }, '换票被拒（HTTP ${response.status}）');
    }
    final Object? parsed;
    try {
      parsed = jsonDecode(response.body);
    } catch (_) {
      throw const ProtocolException(ErrorCode.relayOffline, '换票响应不是合法 JSON');
    }
    if (parsed is! Map<String, Object?>) {
      throw const ProtocolException(ErrorCode.relayOffline, '换票响应不是对象');
    }
    final ticket = parsed['ticket'];
    final expiresAt = parsed['expiresAt'];
    if (ticket is! String ||
        ticket.isEmpty ||
        expiresAt is! int ||
        expiresAt <= 0) {
      throw const ProtocolException(
        ErrorCode.relayOffline,
        '换票响应缺少 ticket 或有效期',
      );
    }
    return Ticket(ticket: ticket, expiresAt: expiresAt);
  }
}
