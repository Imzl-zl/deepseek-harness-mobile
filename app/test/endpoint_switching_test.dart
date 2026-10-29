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

  group('mergeEndpoints：已知原位更新，未知**追加到末尾**', () {
    test('第一次发现直连：追加到末尾，不插队（用户的首选不许被冲掉）', () {
      // 曾经 direct 被插到第一个 relay 之前 —— 于是"用户把中转设为首选"
      // 会在连接器报出一个新直连时被悄悄挤到第二位。
      // "同一 WiFi 优先直连"这个意图现在由 `dialOrder` 在**拨号时**按真实
      // 网段判断（见下面的 dialOrder 组），不需要靠插入位置表达。
      final stored = [_relay('wss://relay.example', label: '中转')];
      final discovered = [
        _direct('ws://192.168.1.5:8788', label: '同一 WiFi'),
        _relay('wss://relay.example', label: '中转'),
      ];
      expect(mergeEndpoints(stored, discovered).map((e) => e.url).toList(), [
        'wss://relay.example',
        'ws://192.168.1.5:8788',
      ]);
    });

    test('手填标记在合并后保留（否则它会被剪枝规则误删）', () {
      const stored = [
        Endpoint(
          kind: EndpointKind.direct,
          url: 'ws://192.168.1.5:8788',
          manual: true,
        ),
      ];
      final discovered = [_direct('ws://192.168.1.5:8788', label: '同一 WiFi')];
      final merged = mergeEndpoints(stored, discovered);
      expect(merged.single.manual, isTrue, reason: '连接器报了一次不等于用户没手填过');
      expect(merged.single.label, '同一 WiFi', reason: 'label 要刷新');
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

    test('空 stored：整份采用，顺序照发现结果', () {
      final discovered = [
        _relay('wss://relay.example'),
        _direct('ws://192.168.1.5:8788'),
      ];
      expect(mergeEndpoints(const [], discovered).map((e) => e.url).toList(), [
        'wss://relay.example',
        'ws://192.168.1.5:8788',
      ]);
    });

    test('dialOrder：记住的先试 → 同网段的次之 → 其余按用户顺序', () {
      final relay = _relay('wss://relay.example');
      final home = _direct('ws://192.168.1.5:8788');
      final office = _direct('ws://10.0.1.9:8788');
      final table = [relay, office, home];

      // 在家：记住的是公司那条（上次在公司连的），但它拨不通 →
      // 同网段的 home 必须排上来。
      expect(
        dialOrder(
          table,
          myIpv4: '192.168.1.29',
          rememberedEndpointUrl: office.url,
        ).map((e) => e.url).toList(),
        [office.url, home.url, relay.url],
        reason: '记住的排第一；它失败之后同网段那条紧跟',
      );

      // 拿不到本机 IP（移动网络）→ 退化成"记住的 + 用户顺序"，不猜网段。
      expect(
        dialOrder(
          table,
          rememberedEndpointUrl: office.url,
        ).map((e) => e.url).toList(),
        [office.url, relay.url, home.url],
      );

      // 没有记忆 → 同网段优先，其余按用户顺序。
      expect(dialOrder(table, myIpv4: '10.0.1.44').map((e) => e.url).toList(), [
        office.url,
        relay.url,
        home.url,
      ]);
    });

    test('dialOrder：192.168.1.x 与 192.168.2.x **不算**同网段', () {
      // 本机同时有这两块网卡（WiFi 1.x / 以太网 2.x）。按 /16 判会把它们
      // 当成同一网段，于是"在 WiFi 上却先去拨以太网那条" —— 正是要避免的。
      expect(sameSubnet('192.168.1.29', 'ws://192.168.1.4:8790'), isTrue);
      expect(sameSubnet('192.168.1.29', 'ws://192.168.2.41:8790'), isFalse);
      expect(sameSubnet('192.168.1.29', 'wss://relay.example'), isFalse);
      expect(sameSubnet('192.168.1.29', 'ws://[::1]:8790'), isFalse);
      expect(subnetScore('192.168.1.29', 'ws://192.168.1.4:8790'), 3);
      expect(subnetScore('192.168.1.29', 'ws://192.168.2.41:8790'), 2);
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

    // -------------------------------------------------------------------------
    // 冷却与"按电脑排序"：真实体验是远程/换网，死地址不该每轮都占一次超时。
    // 规则见 `core/endpoint.dart` 的 `isCooling` / `dialOrder`。
    // -------------------------------------------------------------------------
    final now = DateTime.now().millisecondsSinceEpoch;

    test('dialOrder：刚失败过的排最后，**连记住的那条也不例外**', () {
      final relay = _relay('wss://relay.example');
      final lan = _direct('ws://192.168.1.5:8788');
      final dead = _direct('ws://192.168.40.1:8790');
      final table = [dead, relay, lan];

      expect(
        dialOrder(
          table,
          rememberedEndpointUrl: dead.url,
          attempts: {
            dead.url: EndpointAttempt(
              ok: false,
              reason: '超时',
              atMs: now - 5000,
            ),
          },
          nowMs: now,
        ).map((e) => e.url).toList(),
        [relay.url, lan.url, dead.url],
        reason: '记住的那条刚失败 → 它也要排队尾，不再首试',
      );
    });

    test('dialOrder：冷却窗口一过就回到原位（**不永久降权**）', () {
      final relay = _relay('wss://relay.example');
      final dead = _direct('ws://192.168.40.1:8790');
      final attempt = EndpointAttempt(
        ok: false,
        reason: '超时',
        atMs: now - kEndpointCooldown.inMilliseconds - 1000,
      );

      expect(isCooling(attempt, nowMs: now), isFalse);
      expect(
        dialOrder(
          [dead, relay],
          rememberedEndpointUrl: dead.url,
          attempts: {dead.url: attempt},
          nowMs: now,
        ).map((e) => e.url).toList(),
        [dead.url, relay.url],
        reason: '窗口过了，记住的那条重新排第一',
      );
    });

    test('dialOrder：成功过 / 没有时间戳的记录都不算冷却', () {
      final a = _direct('ws://a:1');
      final b = _direct('ws://b:2');
      expect(
        isCooling(EndpointAttempt(ok: true, atMs: now - 1000), nowMs: now),
        isFalse,
        reason: '成功即清',
      );
      expect(
        isCooling(
          const EndpointAttempt(ok: false, reason: '旧的记录没有时间'),
          nowMs: now,
        ),
        isFalse,
        reason: '不知道什么时候失败的 → 不猜、不冷却',
      );
      expect(
        dialOrder(
          [a, b],
          attempts: {
            a.url: EndpointAttempt(ok: true, atMs: now - 1000),
            b.url: const EndpointAttempt(ok: false, reason: '没时间戳'),
          },
          nowMs: now,
        ).map((e) => e.url).toList(),
        [a.url, b.url],
        reason: '两条都不冷却，顺序照旧',
      );
    });

    test('dialOrder：别的电脑报的排在**当前电脑之后**，冷却的排更后', () {
      final mine = _relay('wss://mine');
      final other = _relay('wss://other').withHost('pc-other');
      final mineDead = _direct('ws://mine-dead:1').withHost('pc-mine');
      final table = [other, mineDead, mine];

      expect(
        dialOrder(
          table,
          currentHostId: 'pc-mine',
          attempts: {
            mineDead.url: EndpointAttempt(
              ok: false,
              reason: '超时',
              atMs: now - 1000,
            ),
          },
          nowMs: now,
        ).map((e) => e.url).toList(),
        [mine.url, other.url, mineDead.url],
        reason: '当前电脑的 → 别的电脑的 → 冷却的',
      );
    });

    test('dialOrder：全都冷却时仍然全都返回（不会"没得拨"）', () {
      final a = _direct('ws://a:1');
      final b = _direct('ws://b:2');
      final attempt = EndpointAttempt(ok: false, reason: '超时', atMs: now - 1);
      expect(
        dialOrder(
          [a, b],
          attempts: {a.url: attempt, b.url: attempt},
          nowMs: now,
        ).map((e) => e.url).toList(),
        [a.url, b.url],
        reason: '全冷却也照原序试一遍，避免把自己锁死',
      );
    });
  });
}
