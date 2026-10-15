/// `EndpointTransport` 的回落行为单测。
///
/// ## 为什么要单独钉这几条
///
/// 回落策略的三个性质都**只能在失败时观察**，而失败在真机上最难复现：
///
/// 1. **一轮里每个端点只试一次** —— 重试刚失败的那个会让每次建连耗时乘以 N，
///    而单测里它表现为"工厂被调用了 2 次同一个端点"。
/// 2. **不降权** —— 这是最容易写错的一条：直觉上"失败过的排后面"很合理，
///    但它会让"出门一次回落中转"变成**永久**回不到直连（直连是会恢复的）。
///    判据是"下一次 `connect()` 仍按原顺序拨"。
/// 3. **只吞传输层错误** —— 工厂里的 bug 必须照旧抛出去。吞掉它会让
///    "代码写错了"表现成"网络不通"，而那正是最难查的一类。
library;

import 'dart:async';

import 'package:dsh_mobile/core/endpoint.dart';
import 'package:dsh_mobile/core/endpoint_transport.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// 可配置成败的假传输。
class _FakeTransport implements ChannelTransport {
  _FakeTransport(this.endpoint, {this.failWith});

  final Endpoint endpoint;
  final TransportException? failWith;
  int closeCount = 0;

  @override
  Future<Stream<TransportEvent>> connect() async {
    if (failWith != null) throw failWith!;
    return const Stream<TransportEvent>.empty();
  }

  @override
  bool send(String line) => true;

  @override
  Future<void> close() async {
    closeCount++;
  }
}

void main() {
  const direct = Endpoint(
    kind: EndpointKind.direct,
    url: 'ws://192.168.1.5:8788',
  );
  const relay = Endpoint(kind: EndpointKind.relay, url: 'wss://relay.example');

  /// 记下每次工厂调用，并按 url 决定成败。
  late List<Endpoint> log;
  EndpointTransport build(
    List<Endpoint> endpoints, {
    Set<String> failing = const {},
    void Function(Endpoint)? onActivated,
  }) {
    log = <Endpoint>[];
    return EndpointTransport(
      endpointsOf: () => endpoints,
      onActivated: onActivated,
      factory: (endpoint) {
        log.add(endpoint);
        return _FakeTransport(
          endpoint,
          failWith: failing.contains(endpoint.url)
              ? TransportException('拨不通 ${endpoint.url}')
              : null,
        );
      },
    );
  }

  test('第一个端点就通：只用它，onActivated 报它', () async {
    Endpoint? activated;
    final transport = build([direct, relay], onActivated: (e) => activated = e);

    await transport.connect();

    expect(log, [direct], reason: '第一个通了就不该再试第二个');
    expect(activated, direct);
    expect(transport.activeEndpoint, direct);
  });

  test('第一个拨不通：自动换下一个', () async {
    final transport = build(
      [direct, relay],
      failing: {'ws://192.168.1.5:8788'},
    );

    await transport.connect();

    expect(log, [direct, relay], reason: '必须按顺序试到第一个通的');
    expect(transport.activeEndpoint, relay);
  });

  test('一轮里每个端点只试一次（不重试刚失败的那个）', () async {
    final transport = build(
      [direct, relay],
      failing: {'ws://192.168.1.5:8788'},
    );

    await transport.connect();
    expect(log.where((e) => e.url == direct.url).length, 1);
  });

  test('全拨不通：抛错且带上最后一个原因', () async {
    final transport = build(
      [direct, relay],
      failing: {'ws://192.168.1.5:8788', 'wss://relay.example'},
    );

    await expectLater(
      transport.connect(),
      throwsA(
        isA<TransportException>()
            .having(
              (e) => e.message,
              'message',
              contains('拨不通 wss://relay.example'),
            )
            .having((e) => e.message, 'message', contains('共 2 个')),
      ),
    );
    expect(log, [direct, relay]);
  });

  test('**不降权**：同一个实例的下一轮仍先试失败过的端点（直连恢复后能回去）', () async {
    // 连接层会在**同一个** transport 上反复调 `connect()`（退避重连），
    // 所以"降权"若存在，它是跨调用持续的 —— 必须用同一个实例验。
    // 换一个实例测等于没测（变异校验就是这么抓到一条恒真断言的）。
    final failing = <String>{direct.url};
    final seen = <Endpoint>[];
    final table = <Endpoint>[direct, relay];
    final transport = EndpointTransport(
      endpointsOf: () => table,
      factory: (endpoint) {
        seen.add(endpoint);
        return _FakeTransport(
          endpoint,
          failWith: failing.contains(endpoint.url)
              ? TransportException('拨不通 ${endpoint.url}')
              : null,
        );
      },
    );

    // 第一轮：直连不通 → 走中转。
    await transport.connect();
    expect(transport.activeEndpoint, relay);
    expect(seen, [direct, relay]);

    // 第二轮：直连恢复了（移出 failing）。必须**还先试直连**。
    seen.clear();
    failing.clear();
    await transport.connect();
    expect(seen.first, direct, reason: '降权会让人出一次门就永久回不到直连');
    expect(transport.activeEndpoint, direct);
  });

  test('没有端点：如实抛，不静默', () async {
    final transport = build(const []);
    await expectLater(transport.connect(), throwsA(isA<TransportException>()));
  });

  test('**终态错误不再换端点**：换票被拒（notPaired）直接抛出并保留码', () async {
    // 议题 2：身份不被认时换下一个端点只会把"为什么连不上"弄丢 ——
    // 直连要到握手处才失败，reason 变成 close 4003，而 401 那个
    // "电脑不认本机"的信号会被掩盖。必须**直接抛出**，让连接层判终态。
    final seen = <Endpoint>[];
    final transport = EndpointTransport(
      endpointsOf: () => [relay, direct],
      factory: (endpoint) {
        seen.add(endpoint);
        if (endpoint.kind == EndpointKind.relay) {
          return _FakeTransport(
            endpoint,
            failWith: const TransportException(
              '换票失败：换票被拒（HTTP 401）',
              code: ErrorCode.notPaired,
            ),
          );
        }
        return _FakeTransport(endpoint);
      },
    );

    await expectLater(
      transport.connect(),
      throwsA(
        isA<TransportException>().having(
          (e) => e.code,
          'code',
          ErrorCode.notPaired,
        ),
      ),
    );
    expect(seen, [relay], reason: '终态时不该再去试 direct（那会掩盖 401）');
  });

  test('非终态的带码错误照旧换端点；全失败时保留最后一个码', () async {
    // 限流（rateLimited）不是终态：该按顺序试到最后一个，且把码带上去 ——
    // 连接层据此判"退避重试"而不是"回配对页"。
    final transport = EndpointTransport(
      endpointsOf: () => [direct, relay],
      factory: (endpoint) => _FakeTransport(
        endpoint,
        failWith: const TransportException('被限流', code: ErrorCode.rateLimited),
      ),
    );

    await expectLater(
      transport.connect(),
      throwsA(
        isA<TransportException>().having(
          (e) => e.code,
          'code',
          ErrorCode.rateLimited,
        ),
      ),
    );
  });

  test('工厂抛的不是传输层错误：照旧抛出（不吞）', () async {
    final transport = EndpointTransport(
      endpointsOf: () => [direct],
      factory: (_) => throw StateError('工厂写错了'),
    );
    await expectLater(transport.connect(), throwsA(isA<StateError>()));
  });

  test('send / close 委托给当前活跃的那个', () async {
    final inner = _FakeTransport(direct);
    final transport = EndpointTransport(
      endpointsOf: () => [direct],
      factory: (_) => inner,
    );

    expect(transport.send('line'), isFalse, reason: '没连上时发不出去');
    await transport.connect();
    expect(transport.send('line'), isTrue);
    await transport.close();
    expect(inner.closeCount, 1);
  });

  test('重连前先收干净上一条（否则 send 会委托给已断的 socket）', () async {
    final first = _FakeTransport(direct);
    final second = _FakeTransport(direct);
    var call = 0;
    final transport = EndpointTransport(
      endpointsOf: () => [direct],
      factory: (_) => call++ == 0 ? first : second,
    );

    await transport.connect();
    await transport.connect();

    expect(first.closeCount, 1, reason: '上一条必须被关掉');
    expect(second.closeCount, 0, reason: '当前这条不该被关');
  });

  test('没连过就 close：安全且幂等', () async {
    final transport = build([direct]);
    await transport.close();
    await transport.close();
    expect(log, isEmpty, reason: 'close 不该触发拨号');
  });

  test('端点表**现读**：装配后改列表，下一次 connect 就用新的', () async {
    // 这正是"发现直连"能立刻生效的原因：连接器只在连上之后才自报地址，
    // 构造时定格会让它必须等重启 App。
    final mutable = <Endpoint>[direct];
    final transport = build(mutable);

    mutable.add(relay);
    await transport.connect();
    expect(log, [direct], reason: '这一次只有 direct');

    // 再连一次：表变了，顺序也变了。
    log.clear();
    mutable.insert(0, relay);
    await transport.connect();
    expect(log.first, relay, reason: '现读要用上新的顺序');
  });

  test('表被清空：如实抛"没有可拨的端点"，不静默', () async {
    final mutable = <Endpoint>[direct];
    final transport = build(mutable);
    mutable.clear();
    await expectLater(
      transport.connect(),
      throwsA(
        isA<TransportException>().having(
          (e) => e.message,
          'message',
          contains('没有可拨的端点'),
        ),
      ),
    );
  });
}
