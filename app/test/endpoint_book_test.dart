/// 端点表的行为钉子（批 G3 重构前的**特征用例**）。
///
/// 这一组在搬 `EndpointBook` **之前**写：先把"合并 / 剪枝 / 上限 / 记忆 / 删除"
/// 的现行行为钉住，搬完必须仍然全绿 —— 否则那是一次行为变化，不是重构。
///
/// 规则出处：`app/lib/core/endpoint.dart` 的 `mergeEndpoints` / `dialOrder`，
/// 以及 `AppModel` 里 2026-10-17 真机事故留下的剪枝三条
/// （"只增不删的表 + IPv6 轮换 = 冷启动 30 秒连不上"）。
///
/// Note: 收窄计划见 `.agents/notes/proposed/2026-10-27-appmodel-narrowing.md`。
library;

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/endpoint.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

class _IdleClient extends FakeSyncClient {
  @override
  conn.ConnectionState get state => conn.ConnectionState.idle;
  @override
  Stream<conn.ConnectionState> get connection => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> reconnect() async {}
  @override
  Future<void> setAppState(AppState state) async {}
  @override
  Future<void> close() async {}
  @override
  Stream<JobFrame> get jobUpdates => const Stream.empty();
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();
  @override
  Future<void> unsubscribe(String sid) async {}
  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async => throw const ProtocolException(ErrorCode.relayOffline, '不该调');
}

Endpoint _ep(
  String url, {
  String label = '',
  bool manual = false,
  EndpointKind kind = EndpointKind.direct,
}) => Endpoint(url: url, label: label, manual: manual, kind: kind);

void main() {
  test('合并：已知的原位更新、未知的追加；表不变时不落盘不通知', () async {
    var saves = 0;
    final app = AppModel(
      client: _IdleClient(),
      endpoints: [_ep('ws://a:1', kind: EndpointKind.relay)],
      onEndpointsChanged: (_) async => saves += 1,
    );
    addTearDown(app.dispose);
    var notified = 0;
    app.addListener(() => notified += 1);

    await app.mergeDiscoveredEndpoints([
      _ep('ws://a:1', label: '电脑', kind: EndpointKind.relay),
      _ep('ws://b:2'),
    ]);

    expect(app.endpoints.map((e) => e.url), ['ws://a:1', 'ws://b:2']);
    expect(app.endpoints.first.label, '电脑', reason: '原位更新');
    expect(saves, 1);
    final after = notified;

    // 再来一次同样内容：不落盘、不通知。
    await app.mergeDiscoveredEndpoints([
      _ep('ws://a:1', label: '电脑', kind: EndpointKind.relay),
      _ep('ws://b:2'),
    ]);
    expect(saves, 1, reason: '表没变就不写盘');
    expect(notified, after, reason: '表没变就不通知');
  });

  test('剪枝：连接器不再报、本机拨过且失败、没成功过 → 删', () async {
    final app = AppModel(
      client: _IdleClient(),
      endpoints: [_ep('ws://a:1'), _ep('ws://dead:9')],
    );
    addTearDown(app.dispose);
    // 先让它"拨过且失败"。
    app.reportEndpointAttempt(
      _ep('ws://dead:9'),
      const EndpointAttempt(ok: false, reason: '超时'),
    );

    await app.mergeDiscoveredEndpoints([_ep('ws://a:1')]);

    expect(app.endpoints.map((e) => e.url), ['ws://a:1'], reason: '失效地址被剪掉');
  });

  test('剪枝：**成功过**的永不删（回老家还要靠它）', () async {
    final app = AppModel(
      client: _IdleClient(),
      endpoints: [_ep('ws://home:1')],
    );
    addTearDown(app.dispose);
    app.reportActiveEndpoint(_ep('ws://home:1'));
    app.reportEndpointAttempt(
      _ep('ws://home:1'),
      const EndpointAttempt(ok: false, reason: '不在这个网络'),
    );

    await app.mergeDiscoveredEndpoints([]);

    expect(app.endpoints.map((e) => e.url), ['ws://home:1']);
  });

  test('剪枝：手填的永不自动删', () async {
    final app = AppModel(
      client: _IdleClient(),
      endpoints: [_ep('ws://mine:1', manual: true)],
    );
    addTearDown(app.dispose);
    app.reportEndpointAttempt(
      _ep('ws://mine:1', manual: true),
      const EndpointAttempt(ok: false, reason: '超时'),
    );

    await app.mergeDiscoveredEndpoints([]);

    expect(app.endpoints, hasLength(1));
  });

  test('上下限：超过 12 条时从末尾淘汰"没成功过且非手填"的', () async {
    final app = AppModel(
      client: _IdleClient(),
      endpoints: [
        for (var i = 0; i < 14; i += 1) _ep('ws://e$i:1', label: 'e$i'),
        _ep('ws://keep:1', manual: true, label: '手填'),
      ],
    );
    addTearDown(app.dispose);

    await app.mergeDiscoveredEndpoints([
      for (var i = 0; i < 14; i += 1) _ep('ws://e$i:1', label: 'e$i'),
      _ep('ws://keep:1', manual: true, label: '手填'),
    ]);

    expect(app.endpoints.length, AppModel.maxEndpoints);
    expect(
      app.endpoints.any((e) => e.url == 'ws://keep:1'),
      isTrue,
      reason: '手填的豁免',
    );
    expect(app.endpoints.first.url, 'ws://e0:1', reason: '淘汰从末尾走，前面用户的顺序不动');
  });

  test('报一条拨通的端点 ⇒ 记住它 + 加进成功集', () async {
    EndpointMeta? saved;
    final app = AppModel(
      client: _IdleClient(),
      onEndpointsMetaChanged: (meta) async => saved = meta,
    );
    addTearDown(app.dispose);

    app.reportActiveEndpoint(_ep('ws://a:1'));

    expect(app.rememberedEndpointId, _ep('ws://a:1').id);
    expect(saved?.rememberedEndpointId, _ep('ws://a:1').id);
    expect(saved?.succeededEndpointIds, contains(_ep('ws://a:1').id));
  });

  test('删一条：自报的进隐藏集，手填的不进；成功集与记忆一起清', () async {
    final app = AppModel(
      client: _IdleClient(),
      endpoints: [_ep('ws://a:1'), _ep('ws://mine:1', manual: true)],
    );
    addTearDown(app.dispose);
    app.reportActiveEndpoint(_ep('ws://a:1'));

    await app.removeEndpoint(_ep('ws://a:1'));
    expect(app.hiddenEndpointIds, contains(_ep('ws://a:1').id));
    expect(app.rememberedEndpointId, isNull);
    expect(app.endpoints.map((e) => e.url), ['ws://mine:1']);

    await app.removeEndpoint(_ep('ws://mine:1', manual: true));
    expect(app.hiddenEndpointIds, isNot(contains(_ep('ws://mine:1').id)));
    expect(app.endpoints, isEmpty);
  });

  test('藏掉的端点不会被 describe 再加回来；放回来后才进来', () async {
    final app = AppModel(client: _IdleClient());
    addTearDown(app.dispose);
    await app.mergeDiscoveredEndpoints([_ep('ws://a:1')]);
    await app.removeEndpoint(_ep('ws://a:1'));

    await app.mergeDiscoveredEndpoints([_ep('ws://a:1')]);
    expect(app.endpoints, isEmpty, reason: '删了白删是最容易犯的错');

    await app.unhideEndpoint(_ep('ws://a:1').id);
    await app.mergeDiscoveredEndpoints([_ep('ws://a:1')]);
    expect(app.endpoints, hasLength(1));
  });

  test('手填：解除隐藏、原位刷成手填、新地址追加', () async {
    final app = AppModel(
      client: _IdleClient(),
      endpoints: [_ep('ws://a:1')],
      hiddenEndpointIds: {_ep('ws://b:2').id},
    );
    addTearDown(app.dispose);

    await app.addManualEndpoint(_ep('ws://a:1'));
    expect(app.endpoints.single.manual, isTrue);

    await app.addManualEndpoint(_ep('ws://b:2'));
    expect(app.endpoints.map((e) => e.url), ['ws://a:1', 'ws://b:2']);
    expect(app.hiddenEndpointIds, isNot(contains(_ep('ws://b:2').id)));
  });

  test('移动与设为首选：只改顺序、不删条目', () async {
    final app = AppModel(
      client: _IdleClient(),
      endpoints: [_ep('ws://a:1'), _ep('ws://b:2'), _ep('ws://c:3')],
    );
    addTearDown(app.dispose);

    await app.moveEndpoint(0, 2);
    expect(app.endpoints.map((e) => e.url), [
      'ws://b:2',
      'ws://c:3',
      'ws://a:1',
    ]);

    await app.preferEndpoint(_ep('ws://a:1'));
    expect(app.endpoints.map((e) => e.url), [
      'ws://a:1',
      'ws://b:2',
      'ws://c:3',
    ]);

    // 越界即忽略。
    await app.moveEndpoint(-1, 0);
    await app.moveEndpoint(0, 99);
    expect(app.endpoints, hasLength(3));
  });

  test('拨号结果：同值不重复通知；失败才刷新本机 LAN', () async {
    var lanReads = 0;
    final app = AppModel(
      client: _IdleClient(),
      myLanIpv4Of: () async {
        lanReads += 1;
        return '192.168.1.9';
      },
    );
    addTearDown(app.dispose);
    var notified = 0;
    app.addListener(() => notified += 1);

    app.reportEndpointAttempt(
      _ep('ws://a:1'),
      const EndpointAttempt(ok: true, reason: null),
    );
    final afterOk = notified;
    app.reportEndpointAttempt(
      _ep('ws://a:1'),
      const EndpointAttempt(ok: true, reason: null),
    );
    expect(notified, afterOk, reason: '同值不重复通知');

    app.reportEndpointAttempt(
      _ep('ws://a:1'),
      const EndpointAttempt(ok: false, reason: '超时'),
    );
    await Future<void>.delayed(Duration.zero);
    expect(lanReads, 1, reason: '拨不通那一拍才查本机 IP');
    expect(app.myLanIpv4, '192.168.1.9');
  });

  // ---------------------------------------------------------------------------
  // 端点的"归属"：同一台电脑换地址要留，换了一台电脑要剪。
  // 真实场景是**远程**（公网中转 / 换网络）：旧电脑报过的地址永远拨不通
  // （对端身份不同，握手必被 not-paired 拒），而"曾经成功过"恰恰是最容易
  // 把它们永远留在表里的理由。
  // ---------------------------------------------------------------------------

  test('换一台电脑：旧电脑报的地址被剪掉（即使成功过），手填的保留', () async {
    var host = 'pc-A';
    final app = AppModel(
      client: _IdleClient(),
      endpoints: [_ep('ws://mine:7', manual: true)],
      hostIdOf: () => host,
    );
    addTearDown(app.dispose);

    // 第一台电脑自报一条，并且**成功过**（旧规则下它会永远留在表里）。
    await app.mergeDiscoveredEndpoints([
      _ep('ws://pc-a:1', kind: EndpointKind.relay),
    ]);
    expect(app.endpoints.map((e) => e.url), ['ws://mine:7', 'ws://pc-a:1']);
    expect(app.endpoints.last.hostId, 'pc-A', reason: '合并时盖上当前电脑身份');
    // 报的就是表里那条（带归属）—— 传输层 `onActivated` 传的也是表里的对象。
    app.reportActiveEndpoint(app.endpoints.last);

    // 换成第二台电脑：它只报自己的地址。
    host = 'pc-B';
    await app.mergeDiscoveredEndpoints([
      _ep('ws://pc-b:2', kind: EndpointKind.relay),
    ]);

    expect(app.endpoints.map((e) => e.url), [
      'ws://mine:7',
      'ws://pc-b:2',
    ], reason: '别的电脑报的剪掉；手填的永不自动删；新电脑的并进来');
    expect(app.endpoints.last.hostId, 'pc-B');
  });

  test('剪掉"记住的那条"时，可拨记忆一并清空并落盘', () async {
    var host = 'pc-A';
    var metaSaves = 0;
    final app = AppModel(
      client: _IdleClient(),
      endpoints: [],
      hostIdOf: () => host,
      onEndpointsMetaChanged: (_) async => metaSaves += 1,
    );
    addTearDown(app.dispose);

    await app.mergeDiscoveredEndpoints([
      _ep('ws://pc-a:1', kind: EndpointKind.relay),
    ]);
    app.reportActiveEndpoint(app.endpoints.last);
    expect(app.rememberedEndpointId, app.endpoints.last.id);
    final before = metaSaves;

    host = 'pc-B';
    await app.mergeDiscoveredEndpoints([
      _ep('ws://pc-b:2', kind: EndpointKind.relay),
    ]);

    expect(app.rememberedEndpointId, isNull, reason: '记住的条目已不在表里');
    expect(metaSaves, before + 1, reason: '记忆变了要落盘');
  });

  test('同一 URL 属于两台电脑：成功集与"记住的那条"都不继承', () async {
    var host = 'pc-A';
    const url = 'ws://192.168.1.5:8790';
    final app = AppModel(client: _IdleClient(), hostIdOf: () => host);
    addTearDown(app.dispose);

    await app.mergeDiscoveredEndpoints([_ep(url)]);
    final onA = app.endpoints.single;
    expect(onA.id, endpointIdOf(url, hostId: 'pc-A'));
    app.reportActiveEndpoint(onA); // A 成功过一次
    expect(app.rememberedEndpointId, onA.id);

    // 同一个地址，另一台电脑：它们是两条记录。
    host = 'pc-B';
    await app.mergeDiscoveredEndpoints([_ep(url)]);
    final onB = app.endpoints.single;
    expect(onB.hostId, 'pc-B');
    expect(onB.id, isNot(onA.id), reason: '身份带归属，不共用一条记录');
    expect(app.rememberedEndpointId, isNull, reason: 'B 不继承 A 的"记住的那条"');

    // B 这条没成功过：给一次失败，再让连接器"不再报它" ⇒ 必须被剪掉。
    // 若"成功过"仍按 url 记账（旧形状），B 会继承 A 的成功而永远留着。
    app.reportEndpointAttempt(
      onB,
      const EndpointAttempt(ok: false, reason: '超时'),
    );
    await app.mergeDiscoveredEndpoints(const []);
    expect(app.endpoints, isEmpty);
  });
}
