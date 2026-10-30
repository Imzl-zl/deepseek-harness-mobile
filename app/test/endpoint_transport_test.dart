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

/// 可配置成败与"什么时候连上"的假传输。
class _FakeTransport implements ChannelTransport {
  _FakeTransport(this.endpoint, {this.failWith, this.gate});

  final Endpoint endpoint;
  final TransportException? failWith;

  /// 等它完成才算"连接建立"（在飞期间用于竞速用例）。
  final Future<void>? gate;
  int closeCount = 0;

  bool get closed => closeCount > 0;

  @override
  Future<Stream<TransportEvent>> connect() async {
    if (gate != null) await gate;
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
  late Map<String, _FakeTransport> created;
  EndpointTransport build(
    List<Endpoint> endpoints, {
    Set<String> failing = const {},
    Map<String, Future<void>> gates = const {},
    void Function(Endpoint)? onActivated,
    void Function(Endpoint, EndpointAttempt)? onAttempt,
    Duration totalBudget = const Duration(seconds: 15),
  }) {
    log = <Endpoint>[];
    created = <String, _FakeTransport>{};
    return EndpointTransport(
      // 竞速用例默认零错开：断言的是"同时启动"，不是 250ms 的节拍。
      dialStagger: Duration.zero,
      totalBudget: totalBudget,
      endpointsOf: () => endpoints,
      onActivated: onActivated,
      onAttempt: onAttempt,
      factory: (endpoint) {
        log.add(endpoint);
        final transport = _FakeTransport(
          endpoint,
          failWith: failing.contains(endpoint.url)
              ? TransportException('拨不通 ${endpoint.url}')
              : null,
          gate: gates[endpoint.url],
        );
        created[endpoint.url] = transport;
        return transport;
      },
    );
  }

  test('第一个先通：它是赢家；其余连上也不进握手、立刻关', () async {
    // 用两条直连：relay 有闸（第一条同步、第二条排队），直连之间才是真正的并发。
    const second = Endpoint(
      kind: EndpointKind.direct,
      url: 'ws://192.168.2.9:8788',
    );
    Endpoint? activated;
    final transport = build([
      direct,
      second,
    ], onActivated: (e) => activated = e);

    await transport.connect();

    // **竞速**：两条都启动了（零错开），但只有先到的那条被采用。
    expect(log, [direct, second]);
    expect(activated, direct);
    expect(transport.activeEndpoint, direct);
    expect(created[direct.url]!.closed, isFalse, reason: '赢家要留着');
    expect(created[second.url]!.closed, isTrue, reason: '输家必须立刻关，不留半开');
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

  test('**15 s 总预算**：全都不通时到点给结论，之后连上的输家立刻关', () async {
    // 方案决策 7："15 s 是硬上限（不许 N 条 × 单条上限全交给用户等）"。
    // 三个端点都"永远连不上"（既不通也不报错）—— 那正是慢网 / 半死的形状。
    const second = Endpoint(kind: EndpointKind.direct, url: 'ws://x:1');
    const third = Endpoint(kind: EndpointKind.direct, url: 'ws://y:2');
    final g1 = Completer<void>();
    final g2 = Completer<void>();
    final g3 = Completer<void>();
    final transport = build(
      [direct, second, third],
      gates: {
        direct.url: g1.future,
        second.url: g2.future,
        third.url: g3.future,
      },
      totalBudget: const Duration(milliseconds: 200),
    );

    final started = DateTime.now();
    await expectLater(
      transport.connect(),
      throwsA(
        isA<TransportException>()
            .having((e) => e.message, 'message', contains('没有端点拨通'))
            .having((e) => e.message, 'message', contains('共 3 个')),
      ),
      reason: '到点必须给结论，而不是继续等',
    );
    expect(
      DateTime.now().difference(started).inMilliseconds,
      lessThan(2000),
      reason: '总预算到点即收口（不随端点条数线性增长）',
    );
    // 结论之后仪表上不该挂着"当前走哪条"。
    expect(transport.activeEndpoint, isNull);

    // 到点之后才"连上"的那几条：看到结论已出就立刻关，**不进握手、不留半开**。
    g1.complete();
    g2.complete();
    g3.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    for (final endpoint in [direct, second, third]) {
      expect(
        created[endpoint.url]?.closed,
        isTrue,
        reason: '${endpoint.url} 在结论之后才连上，必须立刻关',
      );
    }
    expect(transport.activeEndpoint, isNull, reason: '它们不是这一轮的连接');
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

  // -------------------------------------------------------------------------
  // 拨号结果上报（`onAttempt`）—— 设置页"通不通"的唯一数据来源
  // -------------------------------------------------------------------------

  test('拨通了：onAttempt 报 ok=true', () async {
    final attempts = <(Endpoint, EndpointAttempt)>[];
    final transport = build([
      direct,
      relay,
    ], onAttempt: (e, a) => attempts.add((e, a)));

    await transport.connect();

    expect(attempts, [
      (direct, const EndpointAttempt(ok: true)),
    ], reason: '只有拨通的那个端点该被报 ok');
  });

  test('回落时：失败的那个带原因报出，赢的那个报 ok', () async {
    // 这是"为什么走了中转"的判据：没有失败记录，界面只会显示
    // "当前连接：中转"，用户不知道直连怎么没了。
    final attempts = <(Endpoint, EndpointAttempt)>[];
    final transport = build(
      [direct, relay],
      failing: {direct.url},
      onAttempt: (e, a) => attempts.add((e, a)),
    );

    await transport.connect();

    // 竞速下"失败"与"赢"的到达顺序不保证；判据是**内容**而不是次序。
    expect(attempts.map((r) => r.$1.url).toSet(), {direct.url, relay.url});
    final failed = attempts.firstWhere((r) => !r.$2.ok);
    final won = attempts.firstWhere((r) => r.$2.ok);
    expect(failed.$1.url, direct.url);
    expect(failed.$2.reason, contains('拨不通 ${direct.url}'));
    expect(won.$1.url, relay.url);
  });

  test('终态错误也报拨号结果（它是事实），然后照旧抛出', () async {
    final attempts = <(Endpoint, EndpointAttempt)>[];
    final transport = EndpointTransport(
      endpointsOf: () => [relay, direct],
      onAttempt: (e, a) => attempts.add((e, a)),
      factory: (endpoint) => _FakeTransport(
        endpoint,
        failWith: endpoint.kind == EndpointKind.relay
            ? const TransportException(
                '换票失败：换票被拒（HTTP 401）',
                code: ErrorCode.notPaired,
              )
            : null,
      ),
    );

    await expectLater(transport.connect(), throwsA(isA<TransportException>()));
    expect(attempts, hasLength(1));
    expect(attempts.single.$2.ok, isFalse);
    expect(attempts.single.$2.reason, contains('401'));
  });

  test('没拨过（没调 connect）就没有记录：不猜', () async {
    final attempts = <(Endpoint, EndpointAttempt)>[];
    build([direct], onAttempt: (e, a) => attempts.add((e, a)));
    expect(attempts, isEmpty);
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
    // 竞速下 direct 也会被启动（零错开），但终态一结算就不再等它：
    // `activeEndpoint` 仍是空的，错误码是 401 那一档。
    expect(seen, contains(relay));
    expect(transport.activeEndpoint, isNull, reason: '终态时不该把任何一条当赢家');
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
    // 竞速把两条都启动了；直的先连上，所以赢的仍是 direct。
    expect(log, [direct, relay]);
    expect(transport.activeEndpoint, direct);

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

  // ---------------------------------------------------------------------------
  // 竞速：并行建 socket、赢家才进握手、输家立刻关（准入门槛 8d）
  // ---------------------------------------------------------------------------

  group('拨号竞速', () {
    test('两条死端点不再拖累：慢的那条还在飞时，赢家已经返回', () async {
      const dead1 = Endpoint(kind: EndpointKind.direct, url: 'ws://dead-1:1');
      const dead2 = Endpoint(kind: EndpointKind.direct, url: 'ws://dead-2:1');
      final slow1 = Completer<void>();
      final slow2 = Completer<void>();
      final attempts = <(Endpoint, EndpointAttempt)>[];
      final transport = build(
        [dead1, dead2, direct],
        gates: {dead1.url: slow1.future, dead2.url: slow2.future},
        onAttempt: (e, a) => attempts.add((e, a)),
      );

      final stream = await transport.connect();

      expect(stream, isNotNull);
      expect(transport.activeEndpoint, direct, reason: '第二条还在飞也不影响赢家');
      expect(log, [dead1, dead2, direct], reason: '零错开时三条都会启动');
      // 慢的两条此刻还没结算：只有赢家被报 ok。
      expect(attempts.map((r) => r.$1.url), [direct.url]);

      // 收尾：让在飞的死端点"失败"，它们会被关掉且不会被当成赢家。
      slow1.complete();
      slow2.complete();
      await Future<void>.delayed(Duration.zero);
      expect(transport.activeEndpoint, direct, reason: '迟到的成功不能换掉赢家');
      expect(created[dead1.url]!.closed, isTrue);
      expect(created[dead2.url]!.closed, isTrue);
    });

    test('输家连上：立刻关，且不报 ok（它不是这一轮的连接）', () async {
      const second = Endpoint(
        kind: EndpointKind.direct,
        url: 'ws://192.168.2.9:8788',
      );
      final attempts = <(Endpoint, EndpointAttempt)>[];
      final transport = build([
        direct,
        second,
      ], onAttempt: (e, a) => attempts.add((e, a)));

      await transport.connect();
      await Future<void>.delayed(Duration.zero);

      expect(created[second.url]!.closed, isTrue);
      expect(
        attempts.where((r) => r.$2.ok).map((r) => r.$1.url),
        [direct.url],
        reason: '输家也是"连上了"的 socket，但它不是这一轮的连接，不该报 ok',
      );
    });

    test('中转端点串行：前一条 relay 还在飞时，下一条 relay 不开始', () async {
      const relay2 = Endpoint(kind: EndpointKind.relay, url: 'wss://relay-2');
      final slowRelay = Completer<void>();
      final slowDirect = Completer<void>();
      final attempts = <(Endpoint, EndpointAttempt)>[];
      final transport = build(
        [relay, relay2, direct],
        failing: {relay.url},
        gates: {relay.url: slowRelay.future, direct.url: slowDirect.future},
        onAttempt: (e, a) => attempts.add((e, a)),
      );

      final connecting = transport.connect();
      await Future<void>.delayed(Duration.zero);

      // 第一条 relay 与 direct 都在飞；**第二条 relay 还没被造出来**。
      expect(log, [relay, direct]);
      expect(created.containsKey(relay2.url), isFalse);
      expect(transport.activeEndpoint, isNull);

      // 第一条 relay 失败（非终态）⇒ 让出闸，第二条 relay 才开始并先连上。
      slowRelay.complete();
      await connecting;

      expect(log, [
        relay,
        direct,
        relay2,
      ], reason: '第二条 relay 在闸放开之后才被造出来（它在队尾）');
      expect(transport.activeEndpoint, relay2);
      expect(attempts.first.$2.ok, isFalse, reason: '第一条 relay 的失败照实报');

      // direct 晚到：赢家已经定了，它连上也要立刻关。
      slowDirect.complete();
      await Future<void>.delayed(Duration.zero);
      expect(transport.activeEndpoint, relay2);
      expect(created[direct.url]!.closed, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // 点名连接（用户"用这个连"，与自动队列是两个功能）
  // ---------------------------------------------------------------------------

  group('点名连接', () {
    test('点名的那条在表里：**只试它**，不顺延到表里的其它', () async {
      final transport = build([direct, relay]);
      transport.requestEndpoint(relay);

      await transport.connect();

      expect(log, [relay], reason: '点名就是"只试这一个"，不许偷偷顺延');
      expect(transport.activeEndpoint, relay);
    });

    test('点名的那条**不在表里**也照样试（用户手填的 / 刚被藏的）', () async {
      // 这是刻意的：点名是用户此刻的意图，比"表里有什么"更权威。
      // 挡掉它会让"我刚填了地址点了连接"变成点了没反应。
      final transport = build([direct]);
      transport.requestEndpoint(relay);

      await transport.connect();

      expect(log, [relay]);
    });

    test('点名失败：如实抛，**不顺延**（回到自动是调用方的事）', () async {
      final transport = build(
        [direct, relay],
        failing: {'wss://relay.example'},
      );
      transport.requestEndpoint(relay);

      await expectLater(
        transport.connect(),
        throwsA(isA<TransportException>()),
      );
      expect(log, [relay], reason: '失败也不试 direct —— 顺延会让"我选了中转"变成"其实走了直连"');
    });

    test('清掉点名后回到自动队列（按表顺序顺延）', () async {
      final transport = build(
        [direct, relay],
        failing: {'ws://192.168.1.5:8788'},
      );
      transport.requestEndpoint(relay);
      transport.requestEndpoint(null);

      await transport.connect();

      expect(log, [direct, relay], reason: '自动队列：按顺序试到第一个通的');
    });
  });
}
