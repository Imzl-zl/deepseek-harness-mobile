/// 配对链客户端的单测（契约 §2 的连接建立、§12.1 的首配）。
///
/// ## 这一组钉住的是"客户端动作"
///
/// 配对链上有几种失败，**用户该做的事完全不同**（重新出码 / 重新配对 / 查网络），
/// 而它们的区别只体现在**状态码**上。所以这里逐码断言
/// `ClientAction`，而不是笼统地"抛了个错"——
/// 报错类别错了用户就永远卡在重试上（本项目已经踩过一次：
/// `not-paired` 被报成 `bad-frame`）。
///
/// ## 为什么这组不需要中转
///
/// `HttpSender` 是注入的缝，所以"中转回了 409"这种场景用一个假实现就能构造 ——
/// 而它恰恰是最难在真机上复现的一类（要等配对码过期，或抢在认领之前）。
library;

import 'dart:convert';

import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/pairing.dart';
import 'package:dsh_mobile/core/pairing_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记账用的假 HTTP：记下每一次调用，按脚本回响应。
class _FakeHttp {
  _FakeHttp(this.responses);

  /// 按顺序取响应；用完之后一直返回最后一个。
  final List<HttpResult> responses;
  final List<HttpCall> calls = [];

  Future<HttpResult> call(HttpCall request) async {
    calls.add(request);
    final index = calls.length - 1;
    return responses[index < responses.length ? index : responses.length - 1];
  }
}

/// 一份固定的候选身份（首配换票用它）。
const _candidate = PairingCandidate(
  offerId: 'abL3sSH5gLJpTBBsqPUzJg',
  devPubEdHex:
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
  devPubDhHex:
      'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210',
  name: '我的手机',
);

void main() {
  group('httpBaseOf：与电脑侧逐字一致', () {
    // 两端对同一个 relayUrl 必须算出同一个 HTTP 根：一端登记、另一端换票，
    // 算得不一样的表现是"配对总是失败"，而日志里只有一条连接错误。
    test('wss → https，且**丢掉路径**（HTTP 端点不在 WS 那条路径上）', () {
      expect(httpBaseOf('wss://relay.example/ws'), 'https://relay.example');
      // 带 `/ws/connector` 是最常见的形状（配置里写的就是它）——
      // 不丢路径会拼出 `/ws/connector/ws-ticket`，那是 404。
      expect(
        httpBaseOf('wss://relay.example/ws/connector'),
        'https://relay.example',
      );
    });

    test('本机调试的明文 ws 必须**显式开启**才放行，且只给回环', () {
      expect(
        httpBaseOf('ws://127.0.0.1:8787', allowInsecureLocal: true),
        'http://127.0.0.1:8787',
      );
      expect(
        httpBaseOf(
          'ws://127.0.0.1:8787/ws/connector',
          allowInsecureLocal: true,
        ),
        'http://127.0.0.1:8787',
      );
      // 默认（生产）拒明文：不显式开启时它不该被当成"地址可用"。
      expect(
        () => httpBaseOf('ws://127.0.0.1:8787'),
        throwsA(isA<ProtocolException>()),
      );
      // 放行**只**给回环：给一台公网主机就是真的走明文了。
      expect(
        () => httpBaseOf('ws://relay.example', allowInsecureLocal: true),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('带额外参数/凭据/片段的地址一律拒（它们不是"地址"）', () {
      for (final value in const [
        'wss://relay.example?x=1',
        'wss://user:pass@relay.example',
        'wss://relay.example#frag',
      ]) {
        expect(
          () => httpBaseOf(value),
          throwsA(isA<ProtocolException>()),
          reason: '$value 不该被当成合法中转地址',
        );
      }
    });
  });

  group('首配：凭公开邀请 + 候选公钥换票（不带头、不带秘密）', () {
    test('POST /ws-ticket，body 是候选身份，且**不带 Authorization**', () async {
      final http = _FakeHttp([
        const HttpResult(status: 201, body: '{"ticket":"T1","expiresAt":123}'),
      ]);
      final client = PairingClient(
        relayUrl: 'ws://127.0.0.1:8787/ws/connector',
        send: http.call,
        allowInsecureLocal: true,
      );

      final ticket = await client.ticketByOffer(_candidate);

      expect(ticket.ticket, 'T1');
      expect(ticket.expiresAt, 123);
      expect(http.calls, hasLength(1));
      final call = http.calls.single;
      expect(call.method, 'POST');
      // **路径在根上**，不是 `/ws/connector/ws-ticket`（那会 404）。
      expect(call.url, 'http://127.0.0.1:8787/ws-ticket');
      expect(call.headers.containsKey('authorization'), isFalse);
      // v2：换票只报公开邀请与自己的公钥 —— 秘密（配对码）不参与这一步，
      // 它只在受限通道建立之后的 `pair-commit` 里以密文出现（§5）。
      expect(jsonDecode(call.body!), _candidate.toWire());
      expect(call.body, isNot(contains('code')));
    });
  });

  group('重连：凭设备令牌换票（带头，不带 codeHash）', () {
    test('Authorization: Bearer，body 为空对象', () async {
      final http = _FakeHttp([
        const HttpResult(status: 201, body: '{"ticket":"T2","expiresAt":9}'),
      ]);
      final client = PairingClient(
        relayUrl: 'ws://127.0.0.1:8787',
        send: http.call,
        // 本机调试的中转是明文 `ws://`：**必须显式开启**（生产只认 wss）。
        allowInsecureLocal: true,
      );

      await client.ticketByDeviceToken('device-token-1');

      final call = http.calls.single;
      expect(call.headers['authorization'], 'Bearer device-token-1');
      // 重连**不带** codeHash：配对码是一次性的，早就用掉了。
      expect(jsonDecode(call.body!), isEmpty);
    });
  });

  group('状态码 → 客户端动作（每个码一条，因为动作不同）', () {
    Future<ProtocolException> failureFor(int status) async {
      final http = _FakeHttp([HttpResult(status: status, body: '{}')]);
      final client = PairingClient(
        relayUrl: 'ws://127.0.0.1:8787',
        send: http.call,
        // 本机调试的中转是明文 `ws://`：**必须显式开启**（生产只认 wss）。
        allowInsecureLocal: true,
      );
      try {
        await client.ticketByOffer(_candidate);
      } on ProtocolException catch (error) {
        return error;
      }
      fail('HTTP $status 应当抛 ProtocolException');
    }

    test('401 凭据不对 → 回配对页（不是重试）', () async {
      final error = await failureFor(401);
      expect(error.code, ErrorCode.notPaired);
      expect(error.clientAction, ClientAction.rePair);
    });

    test('409 邀请登记不可用 → 回配对页（让电脑重新出码）', () async {
      final error = await failureFor(409);
      expect(error.code, ErrorCode.notPaired);
      expect(error.clientAction, ClientAction.rePair);
    });

    test('426 旧版明文配对 → 升级（不是重扫、也不是重试）', () async {
      // v2 的中转对带 `codeHash` 的旧请求直接回 426：这是**版本**问题，
      // 而它的动作是"去电脑上升级插件、重新出码"。报成 not-paired 会让用户
      // 拿同一张 v1 码反复重扫 —— 永远扫不过。
      final error = await failureFor(426);
      expect(error.code, ErrorCode.unsupportedVersion);
      expect(error.clientAction, ClientAction.upgradeRequired);
    });

    test('429 被限流 → 退避重试（不是永久失败）', () async {
      final error = await failureFor(429);
      expect(error.code, ErrorCode.rateLimited);
      expect(error.clientAction, ClientAction.backoffRetry);
    });

    test('5xx 中转坏了 → 显示离线态', () async {
      final error = await failureFor(503);
      expect(error.code, ErrorCode.relayOffline);
      expect(error.clientAction, ClientAction.showOffline);
    });
  });

  group('响应形状坏掉时不静默降级', () {
    test('201 但没给 ticket：如实报错，而不是拿一张空票去升级', () async {
      // 空票会在升级处变成一个 401 —— 而那时没人会想到根因在换票。
      final http = _FakeHttp([const HttpResult(status: 201, body: '{}')]);
      final client = PairingClient(
        relayUrl: 'ws://127.0.0.1:8787',
        send: http.call,
        // 本机调试的中转是明文 `ws://`：**必须显式开启**（生产只认 wss）。
        allowInsecureLocal: true,
      );
      await expectLater(
        client.ticketByOffer(_candidate),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.message,
            'message',
            contains('缺少 ticket'),
          ),
        ),
      );
    });

    test('响应不是 JSON：归 relay/offline（"对端给的东西不可用"）', () async {
      final http = _FakeHttp([
        const HttpResult(status: 201, body: '<html>gateway</html>'),
      ]);
      final client = PairingClient(
        relayUrl: 'ws://127.0.0.1:8787',
        send: http.call,
        // 本机调试的中转是明文 `ws://`：**必须显式开启**（生产只认 wss）。
        allowInsecureLocal: true,
      );
      await expectLater(
        client.ticketByOffer(_candidate),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.relayOffline,
          ),
        ),
      );
    });
  });
}
