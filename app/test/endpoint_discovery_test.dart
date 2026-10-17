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

class _FakeClient implements SyncClient {
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
  Future<void> setAppState(AppState state) async {}

  @override
  Future<void> close() async {}

  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();

  @override
  Future<void> subscribe(String sid, {required int since}) async {}

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

    expect(app.endpoints.map((e) => e.url).toList(), [
      'ws://192.168.1.5:8788',
      'wss://relay.example',
    ], reason: '第一次发现直连时它自动成为首选');
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
}
