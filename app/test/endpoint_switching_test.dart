/// 端点作为一等公民的单测（`Endpoint` / 编解码 / 合并 / 私网判定）。
///
/// ## 为什么私网判定要逐条边界值钉
///
/// 它是**唯一**决定"明文 `ws://` 能拨给谁"的判据。写宽一格不会报错，
/// 只会让一条"以为加密了"的链路真的走明文 —— 而那时没有任何测试会红。
/// 所以每个 CIDR 的**内边界与外边界**各有一条：只验内侧等于没验边界。
///
/// ## 合并规则为什么也要钉
///
/// "已知原位更新、未知按 kind 插"这条规则一旦漂移，症状是**用户手动排的偏好序
/// 被静默抹掉**（每次连接都重排），而那在界面上只是"设了没用"。
library;

import 'package:dsh_mobile/core/endpoint.dart';
import 'package:flutter_test/flutter_test.dart';

Endpoint _direct(String url, {String label = ''}) =>
    Endpoint(kind: EndpointKind.direct, url: url, label: label);

Endpoint _relay(String url, {String label = ''}) =>
    Endpoint(kind: EndpointKind.relay, url: url, label: label);

void main() {
  group('isPrivateOrLoopback：明文 ws 的放行范围', () {
    test('回环', () {
      for (final host in const [
        '127.0.0.1',
        '127.0.0.0',
        '127.255.255.254',
        'localhost',
        '::1',
        '::',
      ]) {
        expect(isPrivateOrLoopback(host), isTrue, reason: '$host 是回环');
      }
    });

    test('私网 10/8', () {
      expect(isPrivateOrLoopback('10.0.0.1'), isTrue);
      expect(isPrivateOrLoopback('10.255.255.255'), isTrue);
      // 外边界：9 与 11 都不是私网
      expect(isPrivateOrLoopback('9.255.255.255'), isFalse);
      expect(isPrivateOrLoopback('11.0.0.1'), isFalse);
    });

    test('私网 172.16/12', () {
      expect(isPrivateOrLoopback('172.16.0.1'), isTrue);
      expect(isPrivateOrLoopback('172.31.255.255'), isTrue);
      // 外边界：172.15 与 172.32 都不在 /12 里
      expect(isPrivateOrLoopback('172.15.255.255'), isFalse);
      expect(isPrivateOrLoopback('172.32.0.1'), isFalse);
    });

    test('私网 192.168/16', () {
      expect(isPrivateOrLoopback('192.168.0.1'), isTrue);
      expect(isPrivateOrLoopback('192.168.255.255'), isTrue);
      expect(isPrivateOrLoopback('192.169.0.1'), isFalse);
    });

    test('CGNAT 100.64/10（Tailscale 用它）', () {
      expect(isPrivateOrLoopback('100.64.0.1'), isTrue);
      expect(isPrivateOrLoopback('100.127.255.255'), isTrue);
      expect(isPrivateOrLoopback('100.63.255.255'), isFalse);
      expect(isPrivateOrLoopback('100.128.0.1'), isFalse);
    });

    test('link-local 169.254/16', () {
      expect(isPrivateOrLoopback('169.254.1.1'), isTrue);
      expect(isPrivateOrLoopback('169.253.1.1'), isFalse);
    });

    test('IPv6：fe80::/10 与 fc00::/7', () {
      expect(isPrivateOrLoopback('fe80::1'), isTrue);
      // /10 覆盖 fe80..febf
      expect(isPrivateOrLoopback('febf::1'), isTrue);
      expect(isPrivateOrLoopback('fec0::1'), isFalse);
      expect(isPrivateOrLoopback('fc00::1'), isTrue);
      expect(isPrivateOrLoopback('fd12:3456::1'), isTrue);
      expect(isPrivateOrLoopback('fe00::1'), isFalse);
      // 公网 IPv6
      expect(isPrivateOrLoopback('2001:db8::1'), isFalse);
      expect(isPrivateOrLoopback('2400:cb00::1'), isFalse);
    });

    test('IPv4-mapped 按里面的 IPv4 判（安卓会报这种地址）', () {
      expect(isPrivateOrLoopback('::ffff:192.168.1.1'), isTrue);
      expect(isPrivateOrLoopback('::ffff:127.0.0.1'), isTrue);
      expect(isPrivateOrLoopback('::ffff:8.8.8.8'), isFalse);
    });

    test('公网地址一律拒', () {
      for (final host in const [
        '8.8.8.8',
        '1.1.1.1',
        '203.0.113.9',
        'relay.example',
        'example.com',
        '',
      ]) {
        expect(isPrivateOrLoopback(host), isFalse, reason: '$host 是公网');
      }
    });
  });

  group('checkedRelayUri：明文放行随私网判定一起扩', () {
    test('私网主机在显式开启后放行', () {
      expect(
        checkedRelayUri('ws://192.168.1.5:8787', allowInsecureLocal: true).host,
        '192.168.1.5',
      );
      expect(
        checkedRelayUri('ws://100.100.1.2:8787', allowInsecureLocal: true).host,
        '100.100.1.2',
      );
    });

    test('公网主机仍然拒（哪怕显式开启）', () {
      expect(
        () => checkedRelayUri('ws://8.8.8.8:8787', allowInsecureLocal: true),
        throwsA(isA<Exception>()),
      );
      expect(
        () => checkedRelayUri('ws://relay.example', allowInsecureLocal: true),
        throwsA(isA<Exception>()),
      );
    });

    test('wss 对任何主机都行（不放宽也不收紧）', () {
      expect(checkedRelayUri('wss://relay.example').host, 'relay.example');
      expect(checkedRelayUri('wss://8.8.8.8').host, '8.8.8.8');
    });
  });

  group('端点编解码：两端共用一个形状', () {
    test('roundtrip', () {
      for (final endpoint in [
        _direct('ws://192.168.1.5:8788', label: '同一 WiFi'),
        _relay('wss://relay.example'),
      ]) {
        final json = endpointToJson(endpoint);
        expect(endpointFromJson(json), endpoint, reason: '$endpoint 要能原样还原');
      }
    });

    test('label 可缺（它不是身份）', () {
      final json = endpointToJson(_direct('ws://10.0.0.2:8788'));
      expect(json.containsKey('label'), isFalse);
      expect(endpointFromJson(json)!.label, '');
    });

    test('认不出的一律 null，不猜', () {
      for (final raw in const [
        null,
        'not a map',
        <String, Object?>{'kind': 'direct'},
        <String, Object?>{'url': 'ws://10.0.0.2:8788'},
        <String, Object?>{'kind': 'direct', 'url': ''},
        <String, Object?>{'kind': 'carrier-pigeon', 'url': 'ws://h:1'},
        <String, Object?>{'kind': 'direct', 'url': 42},
      ]) {
        expect(endpointFromJson(raw), isNull, reason: '$raw 不该被解析成端点');
      }
    });

    test('id 就是 url（同一个地址只有一个端点）', () {
      expect(_direct('ws://a:1').id, 'ws://a:1');
      expect(_relay('wss://b').id, 'wss://b');
      // 同 url 不同 kind 仍算同一个端点：url 是身份，kind 只是拨法。
      expect(_direct('ws://a:1'), _relay('ws://a:1'));
    });
  });

  group('mergeEndpoints：已知原位更新，未知按 kind 插', () {
    test('第一次发现直连：插在 relay 前面（同 kind 原序，direct 整体先于 relay）', () {
      final stored = [_relay('wss://relay.example', label: '中转')];
      final discovered = [
        _direct('ws://192.168.1.5:8788', label: '同一 WiFi'),
        _relay('wss://relay.example', label: '中转'),
      ];
      expect(mergeEndpoints(stored, discovered).map((e) => e.url).toList(), [
        'ws://192.168.1.5:8788',
        'wss://relay.example',
      ]);
    });

    test('已知条目只更新字段，**不挪位**（用户手排的偏好序不许被抹掉）', () {
      // 用户刻意把中转放第一位。
      final stored = [
        _relay('wss://relay.example', label: '中转'),
        _direct('ws://192.168.1.5:8788', label: '旧名字'),
      ];
      final discovered = [
        _direct('ws://192.168.1.5:8788', label: '新名字'),
        _relay('wss://relay.example', label: '中转'),
      ];
      final merged = mergeEndpoints(stored, discovered);
      expect(merged.map((e) => e.url).toList(), [
        'wss://relay.example',
        'ws://192.168.1.5:8788',
      ], reason: '顺序必须与 stored 一致');
      expect(merged[1].label, '新名字', reason: 'label 要刷新');
    });

    test('同 kind 的新条目按发现顺序追加', () {
      final stored = [_relay('wss://a')];
      final discovered = [_relay('wss://b'), _relay('wss://c')];
      expect(mergeEndpoints(stored, discovered).map((e) => e.url).toList(), [
        'wss://a',
        'wss://b',
        'wss://c',
      ]);
    });

    test('空 stored：整份采用，direct 仍先于 relay', () {
      final discovered = [
        _relay('wss://relay.example'),
        _direct('ws://192.168.1.5:8788'),
      ];
      expect(mergeEndpoints(const [], discovered).map((e) => e.url).toList(), [
        'ws://192.168.1.5:8788',
        'wss://relay.example',
      ]);
    });

    test('发现结果为空：表原样不动（连接器少报不删手机里的条目）', () {
      final stored = [
        _direct('ws://192.168.1.5:8788'),
        _relay('wss://relay.example'),
      ];
      expect(mergeEndpoints(stored, const []), stored);
    });

    test('重复发现同一条不产生重复项', () {
      final stored = [_relay('wss://a')];
      final discovered = [_relay('wss://a'), _relay('wss://a')];
      expect(mergeEndpoints(stored, discovered).length, 1);
    });
  });
}
