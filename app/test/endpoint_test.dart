/// 中转地址边界的单测（契约 §2、§12.2）。
///
/// ## 为什么要单独一组
///
/// 这里的两件事**都只能靠断言盯住**，而且失败方式都很差：
///
/// 1. **升级 URL 的形状**：`<根>/ws/device?ticket=<票>`。写错的表现是"连不上、
///    日志里没有原因"——中转对未知路径只回 404 并 `log?.debug`。根地址带路径
///    （配置里常见的 `/ws/connector`，那是**电脑侧拨号**用的那条）时必须丢掉路径，
///    否则拼出 `/ws/connector/ws/device`。
/// 2. **生产必须 WSS**：明文只在显式开启的**非公网**调试里放行。放行范围写宽了
///    不会报错，只会让"以为加密了"的链路真的走明文。
///
/// 端点作为一等公民的那部分（`Endpoint` / `mergeEndpoints` / 私网判定）
/// 在 `endpoint_switching_test.dart`。
library;

import 'package:dsh_mobile/core/endpoint.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('deviceUpgradeUrl：路径在根上，票进 URL', () {
    test('不带路径的根地址', () {
      expect(
        deviceUpgradeUrl('ws://127.0.0.1:8787', 'T1'),
        'ws://127.0.0.1:8787/ws/device?ticket=T1',
      );
    });

    test('根地址带路径时**丢掉路径**（否则会拼出 /ws/connector/ws/device）', () {
      expect(
        deviceUpgradeUrl('ws://127.0.0.1:8787/ws/connector', 'T1'),
        'ws://127.0.0.1:8787/ws/device?ticket=T1',
      );
    });

    test('票值做 URL 转义（括号与斜杠不许裸奔）', () {
      expect(
        deviceUpgradeUrl('ws://h:1', 'a+b/c='),
        'ws://h:1/ws/device?ticket=a%2Bb%2Fc%3D',
      );
    });

    test('wss 原样保留（手机上恒为 wss，契约 §2）', () {
      expect(
        deviceUpgradeUrl('wss://relay.example', 'T1'),
        'wss://relay.example/ws/device?ticket=T1',
      );
    });
  });

  group('checkedRelayUri：生产只认 WSS', () {
    test('wss 通过', () {
      expect(checkedRelayUri('wss://relay.example').authority, 'relay.example');
    });

    test('明文在默认设置下被拒（哪怕它是回环）', () {
      expect(
        () => checkedRelayUri('ws://127.0.0.1:8787'),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.badFrame,
          ),
        ),
      );
    });

    test('显式开启本机调试后，非公网 ws 才放行', () {
      expect(
        checkedRelayUri('ws://127.0.0.1:8787', allowInsecureLocal: true).host,
        '127.0.0.1',
      );
      // 明文放行只给**非公网**地址（回环 / 私网 / CGNAT / link-local / ULA）：
      // 给一台公网主机就是真的走明文了。范围从"仅回环"扩到私网的取舍见
      // `.agents/notes/implemented/2026-10-14-endpoint-switching-lan-direct.md`。
      expect(
        () => checkedRelayUri('ws://relay.example', allowInsecureLocal: true),
        throwsA(isA<ProtocolException>()),
      );
    });

    test('带凭据、片段或额外参数的地址一律拒（它们是"地址"以外的东西）', () {
      for (final value in const [
        'wss://user:pass@relay.example',
        'wss://relay.example#frag',
        'wss://relay.example?x=1',
      ]) {
        expect(
          () => checkedRelayUri(value),
          throwsA(isA<ProtocolException>()),
          reason: '$value 不该被当成合法中转地址',
        );
      }
    });

    // -------------------------------------------------------------------------
    // 公网明文（用户自部署中转、暂无域名/证书）：**只认显式确认的那一档**。
    // -------------------------------------------------------------------------
    test('公网 ws 默认被拒；只有 allowInsecurePublic 才放行', () {
      expect(
        () => checkedRelayUri('ws://203.0.113.7:8787'),
        throwsA(isA<ProtocolException>()),
        reason: '公网明文不是默认能力',
      );
      expect(
        checkedRelayUri(
          'ws://203.0.113.7:8787',
          allowInsecurePublic: true,
        ).host,
        '203.0.113.7',
        reason: '用户确认过的自部署中转放行',
      );
      // 自部署也可以用自己的域名 + 明文
      expect(
        checkedRelayUri('ws://relay.example', allowInsecurePublic: true).host,
        'relay.example',
      );
    });

    test('两档互不越界：非公网开关不覆盖公网，公网开关覆盖两者', () {
      expect(
        checkedRelayUri(
          'ws://192.168.1.4:8790',
          allowInsecurePublic: true,
        ).host,
        '192.168.1.4',
        reason: '用户确认过的明文同样适用于局域网地址',
      );
      expect(
        () =>
            checkedRelayUri('ws://203.0.113.7:8787', allowInsecureLocal: true),
        throwsA(isA<ProtocolException>()),
        reason: '只开非公网那一档时，公网仍然拒',
      );
      // wss 任何主机都放行（域名与 IP 都行）
      expect(checkedRelayUri('wss://203.0.113.7').host, '203.0.113.7');
    });
  });
}
