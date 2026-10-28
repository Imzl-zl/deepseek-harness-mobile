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

  /// 从中转的错误体里取 `error` 字段（不是合法 JSON / 没有该字段 ⇒ `null`）。
  ///
  /// **只读、不猜**：拿不到就按最保守的那句说，绝不把"没见过"当成"被停用"。
  static String? _errorOf(String body) {
    try {
      final parsed = jsonDecode(body);
      if (parsed is Map<String, Object?>) {
        final error = parsed['error'];
        if (error is String && error.isNotEmpty) return error;
      }
    } catch (_) {
      // 非 JSON 错误体：交给调用方的兜底措辞。
    }
    return null;
  }

  Future<Ticket> _ticket(HttpCall call, {required bool paired}) async {
    final response = await send(call);
    if (!response.ok) {
      // **401 的含义取决于这是哪一跳，而且中转现在会给出原因**（`device-unknown` /
      // `device-revoked`，`relay/src/http-face.ts`）。按原因说不同的话、给不同动作：
      // - 首配（未配对）：邀请不对/过期 ⇒ 终态，让电脑重新出码；
      // - 已配对 + `device-revoked`：电脑停用了本机 ⇒ 终态，去解禁或重扫；
      // - 已配对 + `device-unknown`：中转还没收到名册 ⇒ **可恢复**，重试即可。
      // 中间那一档以前和最后一档混成一句"可能已停用，或凭据已失效"，用户只能重扫。
      if (response.status == 401 || response.status == 409) {
        if (!paired) {
          throw ProtocolException(
            ErrorCode.notPaired,
            response.status == 409
                ? '配对码尚未在中转登记成功，请让电脑重新出码'
                : '配对码无效或已过期，请让电脑重新出码',
          );
        }
        final reason = _errorOf(response.body);
        if (reason == 'device-revoked') {
          throw const ProtocolException(
            ErrorCode.revoked,
            '本机已被这台电脑停用（在电脑的「已配对设备」里解禁，或重新扫码配对）',
          );
        }
        throw ProtocolException(
          ErrorCode.relayOffline,
          reason == 'device-unknown'
              ? '中转还没收到这台电脑的设备名册（电脑刚启动或名册未同步），稍后重试即可，不必重新配对'
              : '换票被拒（HTTP ${response.status}）',
        );
      }
      throw ProtocolException(switch (response.status) {
        400 => ErrorCode.badFrame,
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
