/// `AppModel` 的端点发现与偏好序（跨层：`endpoint.describe` → 端点表 → 落盘）。
///
/// ## 为什么要单独一组
///
/// 发现这条链有三处**只能靠断言盯住**的性质：
///
/// 1. **合并不覆盖**：覆盖会抹掉用户手动排的偏好序，而症状只是"设了没用"。
/// 2. **没有变化就不落盘**：每次重连都写一次存储，既浪费也让"写一半"多一次机会。
/// 3. **老连接器没有这个方法时不当故障**：那是能力不存在，不是错误。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/endpoint.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fake_sync_client.dart';

class _FakeClient extends FakeSyncClient {
  _FakeClient({this.onCall, List<ConnectionState> states = const []})
    : _configured = states;

  final Object? Function(String method, Map<String, Object?> params)? onCall;
  final List<ConnectionState> _configured;
  final _states = StreamController<ConnectionState>.broadcast();

  final List<String> called = [];

  @override
  ConnectionState get state => ConnectionState.serving;

  @override
  Stream<ConnectionState> get connection => _states.stream;

  @override
  Future<void> start() async {
    // 把配置好的状态推出去：`AppModel.start()` 会订阅它，
    // 于是"进 serving 就拉端点表"这条路是被**真驱动**的，不是靠测试钩子。
    for (final state in _configured) {
      _states.add(state);
    }
  }

  @override
  Future<void> reconnect() => start();

  @override
  Future<void> setAppState(AppState state) async {}

  @override
  Future<void> close() async {}

  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();

  @override
  Future<void> unsubscribe(String sid) async {}

  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    called.add(method);
    final result = onCall?.call(method, params);
    return result as T;
  }
}

const _relay = Endpoint(
  kind: EndpointKind.relay,
  url: 'wss://relay.example',
  label: '中转',
);
const _direct = Endpoint(
  kind: EndpointKind.direct,
  url: 'ws://192.168.1.5:8788',
  label: 'Wi-Fi',
);

void main() {
  /// 建一个"已经在服务态"的 AppModel，并把端点发现跑完。
  ///
  /// 状态是**推**进去的（`_FakeClient.start` 里发 serving），所以
  /// `_onConnectionChanged` 那条路是被真驱动的。
  Future<AppModel> serving({
    Object? Function(String method, Map<String, Object?> params)? onCall,
    List<Endpoint> endpoints = const [_relay],
    List<List<Endpoint>>? persisted,
  }) async {
    final client = _FakeClient(
      onCall: onCall,
      states: const [ConnectionState.serving],
    );
    final app = AppModel(
      client: client,
      endpoints: endpoints,
      onEndpointsChanged: (list) async {
        persisted?.add(list);
      },
    );
    await app.start();
    // 让 `unawaited(_discoverEndpoints())` 与 `refreshSessions` 跑完。
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    return app;
  }

  test('发现到直连：插在 relay 前面，且落盘', () async {
    final persisted = <List<Endpoint>>[];
    final app = await serving(
      onCall: (method, _) => method == 'endpoint.describe'
          ? {
              'endpoints': [
                {
                  'kind': 'direct',
                  'url': 'ws://192.168.1.5:8788',
                  'label': 'Wi-Fi',
                },
                {'kind': 'relay', 'url': 'wss://relay.example', 'label': '中转'},
              ],
            }
          : null,
      persisted: persisted,
    );

    expect(
      app.endpoints.map((e) => e.url).toList(),
      ['wss://relay.example', 'ws://192.168.1.5:8788'],
      reason: '新发现的追加到末尾 —— 用户排好的首选不许被自动发现冲掉',
    );
    expect(persisted, hasLength(1), reason: '表变了要落盘');
    app.dispose();
  });

  test('没有变化：不落盘、不通知', () async {
    final client = _FakeClient(
      onCall: (method, _) => method == 'endpoint.describe'
          ? {
              'endpoints': [
                {'kind': 'relay', 'url': 'wss://relay.example', 'label': '中转'},
              ],
            }
          : null,
      states: const [ConnectionState.serving],
    );
    final app = AppModel(
      client: client,
      endpoints: const [_relay],
      onEndpointsChanged: (_) async {
        throw StateError('没有变化不该落盘');
      },
    );
    await app.start();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(app.endpoints, [_relay]);
    app.dispose();
  });

  test('老连接器没有这个方法：不当故障', () async {
    final app = await serving(
      // 只让 `endpoint.describe` 抛；`session.list` 照常回空 ——
      // 否则这条用例测的是"别的方法也失败"，不是"能力不存在"。
      onCall: (method, _) => switch (method) {
        'endpoint.describe' => throw const ProtocolException(
          ErrorCode.connectorUnsupported,
          'endpoint.describe 尚未实现',
        ),
        _ => {'sessions': const []},
      },
    );
    expect(app.endpoints, [_relay], reason: '端点表原样不动');
    expect(app.lastError, isNull, reason: '能力不存在不是错误');
    app.dispose();
  });

  test('应答解不出东西：原样不动，也不报错', () async {
    final app = await serving(onCall: (method, _) => {'endpoints': '不是数组'});
    expect(app.endpoints, [_relay]);
    expect(app.lastError, isNull);
    app.dispose();
  });

  test('手动挑一个端点当首选：只改顺序，不删条目', () async {
    final persisted = <List<Endpoint>>[];
    final app = await serving(
      onCall: (method, _) => null,
      endpoints: const [_direct, _relay],
      persisted: persisted,
    );

    await app.preferEndpoint(_relay);

    expect(app.endpoints.map((e) => e.url).toList(), [
      'wss://relay.example',
      'ws://192.168.1.5:8788',
    ], reason: '两条都还在，只是换了顺序');
    expect(persisted, hasLength(1));
    app.dispose();
  });

  test('reportActiveEndpoint：同一个端点不重复通知', () async {
    final app = await serving(onCall: (method, _) => null);
    var notifications = 0;
    app.addListener(() => notifications++);

    app.reportActiveEndpoint(_direct);
    final afterFirst = notifications;
    app.reportActiveEndpoint(_direct);

    expect(app.activeEndpoint, _direct);
    expect(notifications, afterFirst, reason: '同一个端点不该再通知一次');
    app.dispose();
  });

  // -------------------------------------------------------------------------
  // 剪枝（2026-10-17 真机：三个拨不通的 IPv6 地址把冷启动拖成 30 秒）
  // -------------------------------------------------------------------------

  test('连接器不再报、且拨过的地址：失败过就删掉（表不能只增不删）', () async {
    // IPv6 隐私地址每次轮换都是新的一条，旧的永远留在表里 ——
    // 每个死地址一次冷启动等满超时。剪枝判据两个条件同时成立。
    const stale = Endpoint(
      kind: EndpointKind.direct,
      url: 'ws://[2408:8220:711a:9444:a45e:d058:f3bf:c149]:8790',
      label: 'Wi-Fi',
    );
    final persisted = <List<Endpoint>>[];
    final app = await serving(
      onCall: (method, _) => null,
      endpoints: [_direct, _relay, stale],
      persisted: persisted,
    );
    app.reportEndpointAttempt(
      stale,
      const EndpointAttempt(ok: false, reason: '建连超时（3s）'),
    );

    // 连接器这次只报这两条（stale 不在内）。
    await app.mergeDiscoveredEndpoints(const [_direct, _relay]);

    expect(app.endpoints.map((e) => e.url).toList(), [
      _direct.url,
      _relay.url,
    ], reason: '不再被自报、且拨过的死地址必须删');
    expect(persisted, hasLength(1), reason: '删了也要落盘');
    app.dispose();
  });

  test('连接器不再报、但从没拨过：不删（可能是刚发现、还没轮到）', () async {
    const fresh = Endpoint(
      kind: EndpointKind.direct,
      url: 'ws://192.168.2.99:8790',
      label: 'Wi-Fi',
    );
    final app = await serving(
      onCall: (method, _) => null,
      endpoints: [_direct, _relay, fresh],
    );

    await app.mergeDiscoveredEndpoints(const [_direct, _relay]);

    expect(
      app.endpoints.map((e) => e.url).toList(),
      [_direct.url, _relay.url, fresh.url],
      reason: '没拨过的条目不删——删了就成了"覆盖"，丢用户手动排的序',
    );
    app.dispose();
  });

  // -------------------------------------------------------------------------
  // 拨号结果记账（`attemptOf` / `reportEndpointAttempt`）
  // -------------------------------------------------------------------------

  test('拨号结果按端点 id 记账，界面据此显示"通不通"', () async {
    final app = await serving(onCall: (method, _) => null);

    app.reportEndpointAttempt(
      _direct,
      const EndpointAttempt(ok: false, reason: '连不上'),
    );
    app.reportEndpointAttempt(_relay, const EndpointAttempt(ok: true));

    expect(app.attemptOf(_direct)?.ok, isFalse);
    expect(app.attemptOf(_direct)?.reason, '连不上');
    expect(app.attemptOf(_relay)?.ok, isTrue);
    app.dispose();
  });

  test('没拨过的端点没有结论：attemptOf 是 null（不猜）', () async {
    final app = await serving(onCall: (method, _) => null);
    expect(app.attemptOf(_direct), isNull);
    app.dispose();
  });

  test('同一个拨号结果不重复通知（退避重连每轮都会重报）', () async {
    final app = await serving(onCall: (method, _) => null);
    app.reportEndpointAttempt(
      _direct,
      const EndpointAttempt(ok: false, reason: '连不上'),
    );
    var notifications = 0;
    app.addListener(() => notifications++);

    app.reportEndpointAttempt(
      _direct,
      const EndpointAttempt(ok: false, reason: '连不上'),
    );
    expect(notifications, 0, reason: '结果没变不该通知，否则界面每隔几秒重建一次');

    app.reportEndpointAttempt(_direct, const EndpointAttempt(ok: true));
    expect(notifications, 1, reason: '结果变了要通知');
    app.dispose();
  });

  test('换端点不抹掉拨号记录：记录按 url 认，不在表里的地址也有据可查', () async {
    // 手动 prefer 只改顺序不删条目，而记录是跨连接保留的 ——
    // 直连恢复后"拨通过"要能更新掉之前那条"拨不通"。
    final app = await serving(
      onCall: (method, _) => null,
      endpoints: const [_direct, _relay],
    );

    app.reportEndpointAttempt(
      _direct,
      const EndpointAttempt(ok: false, reason: '超时'),
    );
    await app.preferEndpoint(_relay);

    expect(app.endpoints.first, _relay, reason: 'prefer 只改顺序');
    expect(app.attemptOf(_direct)?.reason, '超时', reason: '记录不因重排丢失');
    app.dispose();
  });

  // ---------------------------------------------------------------------------
  // 多地点保留（家 ⇄ 公司）与用户管理
  // ---------------------------------------------------------------------------

  group('多地点：换地点不许把另一个地点的地址删掉', () {
    test('成功过的地址留着（在家连过 → 在公司它也还在）', () async {
      const home = Endpoint(
        kind: EndpointKind.direct,
        url: 'ws://192.168.1.5:8788',
        label: 'Wi-Fi',
      );
      const office = Endpoint(
        kind: EndpointKind.direct,
        url: 'ws://10.0.1.9:8788',
        label: '办公网',
      );
      final app = await serving(
        onCall: (method, _) => method == 'endpoint.describe'
            ? {
                'endpoints': [
                  {'kind': 'direct', 'url': office.url, 'label': '办公网'},
                  {'kind': 'relay', 'url': _relay.url, 'label': '中转'},
                ],
              }
            : null,
        endpoints: const [home, _relay],
      );
      // 在家连过（成功过）。
      app.reportActiveEndpoint(home);
      // 到了公司：home 拨不通。
      app.reportEndpointAttempt(
        home,
        const EndpointAttempt(ok: false, reason: 'Network is unreachable'),
      );
      // 公司地址被发现。
      await app.mergeDiscoveredEndpoints(const [office, _relay]);

      expect(
        app.endpoints.map((e) => e.url),
        contains(home.url),
        reason: '成功过的地址只是"此刻不在那个网络"，删了回老家就得再扫码',
      );
      expect(app.rememberedEndpointId, home.id, reason: '记住上次连上的那条');
      app.dispose();
    });

    test('手填的地址永不被自动删（哪怕从没连上、连接器也不报）', () async {
      const manual = Endpoint(
        kind: EndpointKind.direct,
        url: 'ws://192.168.1.77:8788',
        label: '手填',
        manual: true,
      );
      final app = await serving(
        onCall: (method, _) => method == 'endpoint.describe'
            ? {
                'endpoints': [
                  {'kind': 'relay', 'url': _relay.url, 'label': '中转'},
                ],
              }
            : null,
        endpoints: const [manual, _relay],
      );
      app.reportEndpointAttempt(
        manual,
        const EndpointAttempt(ok: false, reason: '超时'),
      );
      await app.mergeDiscoveredEndpoints(const [_relay]);

      expect(app.endpoints.map((e) => e.url), contains(manual.url));
      app.dispose();
    });

    test('从没成功过、连接器也不再报、且拨过失败 → 删（IPv6 轮换垃圾）', () async {
      const stale = Endpoint(
        kind: EndpointKind.direct,
        url: 'ws://[2001:db8::99]:8788',
        label: '旧 IPv6',
      );
      final app = await serving(
        onCall: (method, _) => method == 'endpoint.describe'
            ? {
                'endpoints': [
                  {'kind': 'relay', 'url': _relay.url, 'label': '中转'},
                ],
              }
            : null,
        endpoints: const [stale, _relay],
      );
      app.reportEndpointAttempt(
        stale,
        const EndpointAttempt(ok: false, reason: '超时'),
      );
      await app.mergeDiscoveredEndpoints(const [_relay]);

      expect(
        app.endpoints.map((e) => e.url),
        isNot(contains(stale.url)),
        reason: '轮换出来的旧 IPv6 永远回不来，留着只会让冷启动每个等满超时',
      );
      app.dispose();
    });
  });

  group('用户管理', () {
    test('删自报端点 → 进隐藏集，下次 describe 不加回来', () async {
      final app = await serving(
        onCall: (method, _) => method == 'endpoint.describe'
            ? {
                'endpoints': [
                  {'kind': 'direct', 'url': _direct.url, 'label': 'Wi-Fi'},
                  {'kind': 'relay', 'url': _relay.url, 'label': '中转'},
                ],
              }
            : null,
        endpoints: const [_relay, _direct],
      );
      await app.removeEndpoint(_direct);
      expect(app.endpoints.map((e) => e.url), isNot(contains(_direct.url)));
      expect(app.hiddenEndpointIds, contains(_direct.url));

      // 连接器又报了一次：不许加回来。
      await app.mergeDiscoveredEndpoints(const [_direct, _relay]);
      expect(
        app.endpoints.map((e) => e.url),
        isNot(contains(_direct.url)),
        reason: '删了又被加回来等于删了白删',
      );

      // 用户想放回来时能放回来。
      await app.unhideEndpoint(_direct.url);
      await app.mergeDiscoveredEndpoints(const [_direct, _relay]);
      expect(app.endpoints.map((e) => e.url), contains(_direct.url));
      app.dispose();
    });

    test('手填端点：进表、标 manual、解除同名隐藏', () async {
      final app = await serving(
        onCall: (method, _) => null,
        endpoints: const [_relay, _direct],
      );
      await app.removeEndpoint(_direct); // 自报端点删除 = 进隐藏集
      expect(app.hiddenEndpointIds, contains(_direct.url));

      await app.addManualEndpoint(
        const Endpoint(kind: EndpointKind.direct, url: 'ws://192.168.1.5:8788'),
      );
      final added = app.endpoints.firstWhere((e) => e.url == _direct.url);
      expect(added.manual, isTrue);
      expect(
        app.hiddenEndpointIds,
        isNot(contains(_direct.url)),
        reason: '用户明确要它，顺手解除隐藏',
      );
      app.dispose();
    });

    test('拖动换位置：顺序变了并落盘（顺序即自动拨号的优先级）', () async {
      final persisted = <List<Endpoint>>[];
      const third = Endpoint(
        kind: EndpointKind.direct,
        url: 'ws://192.168.1.9:8788',
        label: '第三条',
      );
      final app = await serving(
        onCall: (method, _) => null,
        endpoints: const [_relay, _direct, third],
        persisted: persisted,
      );

      // 把最后一条拖到最前（`ReorderableListView` 的"插入位置"已由 UI 换算成目标下标）。
      await app.moveEndpoint(2, 0);

      expect(app.endpoints.map((e) => e.url).toList(), [
        third.url,
        _relay.url,
        _direct.url,
      ], reason: '拖动的结果就是新顺序');
      expect(persisted, hasLength(1), reason: '顺序变了要落盘，重启后还是这个顺序');
      app.dispose();
    });

    test('拖动换位置：原地不动 / 越界一律忽略，不落盘不通知', () async {
      final persisted = <List<Endpoint>>[];
      var notified = 0;
      final app = await serving(
        onCall: (method, _) => null,
        endpoints: const [_relay, _direct],
        persisted: persisted,
      );
      app.addListener(() => notified++);

      await app.moveEndpoint(0, 0); // 原地
      await app.moveEndpoint(-1, 1); // 越界
      await app.moveEndpoint(0, 5); // 目标越界
      await app.moveEndpoint(9, 0); // 源越界

      expect(app.endpoints.map((e) => e.url).toList(), [
        _relay.url,
        _direct.url,
      ], reason: '表不该被这些非法拖动改掉');
      expect(persisted, isEmpty, reason: '没变化不落盘');
      expect(notified, 0, reason: '没变化不通知');
      app.dispose();
    });
  });
}
