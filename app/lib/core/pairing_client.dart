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

  Future<Ticket> ticketByDeviceToken(String deviceToken) => _ticket(
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

  Future<Ticket> ticketByOffer(PairingCandidate candidate) => _ticket(
    HttpCall(
      method: 'POST',
      url:
          '${httpBaseOf(relayUrl, allowInsecureLocal: allowInsecureLocal)}/ws-ticket',
      headers: {'content-type': 'application/json'},
      body: jsonEncode(candidate.toWire()),
    ),
  );

  Future<Ticket> _ticket(HttpCall call) async {
    final response = await send(call);
    if (!response.ok) {
      throw ProtocolException(switch (response.status) {
        400 => ErrorCode.badFrame,
        401 || 409 => ErrorCode.notPaired,
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
