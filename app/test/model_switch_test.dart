/// 模型切换这条链的回归（`session/select-model` → 会话模型）。
///
/// ## 为什么单独一组
///
/// 2026-10-15 之前 picker 里是**四个手抄的模型名**，`selected` 写死
/// （第一个恒为 true），点完只弹 toast **不切任何东西**。
///
/// 而"能切"这个结论是**翻案**得来的：我曾写"`session/select-model` 有全局
/// 副作用，不要用"—— 那是把一条**测试纪律**（测试 profile 与日常 profile
/// 共用 `~/.dsh/`）错升成了**产品约束**。核实后：
/// - Web 调的就是这一个方法（`ui-model-selection/src/client/directory.ts:98`）；
/// - `agent-default-model/src/index.ts:82-94` + README：**当前会话**立即生效、
///   **以后新建的** agent 默认跟随、**不改别的会话**，且没有 configEditor 时
///   第二步是 no-op。
/// 所以"新会话默认跟随"是 Web 一直有的行为，不是副作用。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:flutter_test/flutter_test.dart';

class _ModelClient implements SyncClient {
  _ModelClient({this.onCall});

  final Object? Function(String method, Map<String, Object?> params)? onCall;
  final List<Map<String, Object?>> calls = [];
  final _jobs = StreamController<JobFrame>.broadcast();

  @override
  ConnectionState get state => ConnectionState.serving;
  @override
  Stream<ConnectionState> get connection => const Stream.empty();
  @override
  Stream<JobFrame> get jobUpdates => _jobs.stream;
  @override
  Future<void> start() async {}

  @override
  Future<void> reconnect() => start();

  @override
  Future<void> setAppState(AppState state) async {}
  @override
  Future<void> close() async {}
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
    calls.add({'method': method, 'params': params, 'requestId': requestId});
    final result = onCall?.call(method, params);
    return result as T;
  }
}

/// 取某次方法调用的记录（切完会重拉 `session.list`，所以不能拿 `last`）。
Map<String, Object?> _lastCall(_ModelClient client, String method) =>
    client.calls.lastWhere((c) => c['method'] == method);

void main() {
  test('selectModel：带 sid / provider / model 与幂等键', () async {
    final client = _ModelClient(
      onCall: (m, p) => switch (m) {
        'session.list' => {'sessions': const []},
        'session.modelCatalog' => {'available': false},
        'session.select-model' => {
          'selected': {'provider': 'lightvela-free', 'model': 'auto'},
        },
        _ => null,
      },
    );
    final app = AppModel(client: client);
    await app.start();
    await app.openSession('sid_A');

    final picked = await app.selectModel(
      provider: 'lightvela-free',
      model: 'auto',
    );

    expect(picked?.model, 'auto');
    final call = client.calls.lastWhere(
      (c) => c['method'] == 'session.select-model',
    );
    expect(call['params'], {
      'sid': 'sid_A',
      'provider': 'lightvela-free',
      'model': 'auto',
    });
    // **必须带幂等键**：切模型是用户指令，重发不该切两次。
    expect(call['requestId'], isA<String>());
    expect((call['requestId'] as String).isNotEmpty, isTrue);
    app.dispose();
  });

  test('reasoningEffort 给了才进请求体（缺省走 adapter 默认）', () async {
    final client = _ModelClient(
      onCall: (m, p) => switch (m) {
        'session.list' => {'sessions': const []},
        'session.modelCatalog' => {'available': false},
        'session.select-model' => {
          'selected': {'provider': 'p', 'model': 'm'},
        },
        _ => null,
      },
    );
    final app = AppModel(client: client);
    await app.start();
    await app.openSession('sid_A');

    await app.selectModel(provider: 'p', model: 'm');
    // 按方法取：切完会重拉一次 `session.list`，`calls.last` 是它而不是本次切换。
    final params = _lastCall(client, 'session.select-model')['params'] as Map;
    expect(
      params.containsKey('reasoningEffort'),
      isFalse,
      reason: '不给 effort 时不该塞字段 —— 空串会被当成"显式选空"而拒',
    );

    await app.selectModel(provider: 'p', model: 'm', reasoningEffort: 'high');
    expect(
      (_lastCall(client, 'session.select-model')['params']
          as Map)['reasoningEffort'],
      'high',
    );
    app.dispose();
  });

  test('切完重拉一次清单（输入栏的模型名走 session.list 的 model 字段）', () async {
    final client = _ModelClient(
      onCall: (m, p) => switch (m) {
        'session.list' => {
          'sessions': [
            {
              'sid': 'sid_A',
              'updatedAt': 1,
              'model': {'provider': 'lightvela-free', 'model': 'auto'},
            },
          ],
        },
        'session.modelCatalog' => {'available': false},
        'session.select-model' => {
          'selected': {'provider': 'p', 'model': 'm2'},
        },
        _ => null,
      },
    );
    final app = AppModel(client: client);
    await app.start();
    await app.openSession('sid_A');
    // 基线：`openSession` 自己不拉清单（只有进 serving 与手动刷新才拉）。
    final before = client.calls
        .where((c) => c['method'] == 'session.list')
        .length;

    await app.selectModel(provider: 'p', model: 'm2');

    final after = client.calls
        .where((c) => c['method'] == 'session.list')
        .length;
    expect(after, before + 1, reason: '切完要重拉，否则模型名要等下一次自然刷新');
    app.dispose();
  });

  test('没开会话：返回 null，不发请求', () async {
    final client = _ModelClient(onCall: (m, p) => null);
    final app = AppModel(client: client);
    await app.start();

    expect(await app.selectModel(provider: 'p', model: 'm'), isNull);
    expect(
      client.calls.where((c) => c['method'] == 'session.select-model'),
      isEmpty,
    );
    app.dispose();
  });

  test('失败：留声并返回 null（不静默假装切了）', () async {
    final client = _ModelClient(
      onCall: (m, p) => m == 'session.select-model'
          ? throw const ProtocolException(
              ErrorCode.sessionModelUnavailable,
              '这条渠道没有这个模型',
            )
          : null,
    );
    final app = AppModel(client: client);
    await app.start();
    await app.openSession('sid_A');

    expect(await app.selectModel(provider: 'p', model: 'm'), isNull);
    expect(app.lastError, isNotNull, reason: '失败必须留声');
    app.dispose();
  });

  // **回归 2026-10-17 真机**：模型目录在生产里一次都没解析成功过。
  //
  // 根因：解析器认的是一个**臆想形状**（`List<{provider, models:[{id}]}>`），
  // 而连接器原样过线的是 DSH `buildModelCatalog` 的返回值
  // （`packages/api/session-controller/src/catalog.ts:20-72`）——
  // 顶层是**对象** `{default, routableProviders, groups, failures}`，
  // 于是 `catalog is! List` 直接静默返回，picker 永远说"拿不到目录"。
  // 连接器自己的夹具（`connector/tests/models-face.test.ts`）从头到尾
  // 都是真形状 —— 两边各测各的，中间那一跳没人测。
  //
  // 下面这条用例的形状逐字复刻连接器夹具的 `CATALOG`（那就是 DSH 的真形状）。
  test('modelCatalog：按 DSH 真形状解析（groups/efforts/failures）', () async {
    final client = _ModelClient(
      onCall: (m, p) => m == 'session.modelCatalog'
          ? {
              'available': true,
              'catalog': {
                'default': {'provider': 'lightvela-free', 'model': 'auto'},
                'routableProviders': ['lightvela-free', 'deepseek-official'],
                'groups': [
                  {
                    'id': 'lightvela-free',
                    'name': 'Lightvela (free)',
                    'models': [
                      {'id': 'auto', 'name': 'Auto'},
                      {'id': 'glm-5.3-flash', 'name': 'GLM-5.3-Flash'},
                    ],
                  },
                  {
                    'id': 'deepseek-official',
                    'name': 'DeepSeek',
                    'models': [
                      {
                        'id': 'deepseek-flash',
                        'name': 'DeepSeek-V41-Flash',
                        'reasoning': {
                          'efforts': [
                            {'id': 'low', 'name': 'Low'},
                            {'id': 'high', 'name': 'High'},
                          ],
                          'defaultEffort': 'high',
                        },
                      },
                    ],
                  },
                ],
                'failures': [
                  {
                    'id': 'broken-provider',
                    'name': 'Broken',
                    'message': 'API key not configured',
                  },
                ],
              },
            }
          : null,
    );
    final app = AppModel(client: client);
    await app.start();
    await app.refreshSessions();

    final catalog = app.modelCatalog;
    expect(catalog, isNotNull, reason: '真形状必须解析得出来');
    expect(catalog!.allEntries.map((e) => e.id).toList(), [
      'auto',
      'glm-5.3-flash',
      'deepseek-flash',
    ]);
    // 展示名用目录里的 name，不是 id。
    expect(
      catalog.displayNameOf(
        provider: 'deepseek-official',
        model: 'deepseek-flash',
      ),
      'DeepSeek-V41-Flash',
    );
    // 目录里没有的（provider, model）退到 id，不猜。
    expect(catalog.displayNameOf(provider: 'p', model: 'm'), 'm');
    // effort 展示名：给了 id 翻成 name；没给退到 defaultEffort 的 name。
    expect(
      catalog.effortNameOf(
        provider: 'deepseek-official',
        model: 'deepseek-flash',
        effort: 'low',
      ),
      'Low',
    );
    expect(
      catalog.effortNameOf(
        provider: 'deepseek-official',
        model: 'deepseek-flash',
        effort: null,
      ),
      'High',
      reason: '没带 effort 时生效档是 provider 默认（Web 的 effectiveEffort）',
    );
    // 没有推理档的模型：空串（界面据此显示"默认"）。
    expect(
      catalog.effortNameOf(
        provider: 'lightvela-free',
        model: 'auto',
        effort: null,
      ),
      '',
    );
    // 失败分组必须留着：静默丢掉 = "key 没配"在手机上毫无痕迹。
    expect(catalog.failures.single.id, 'broken-provider');
    app.dispose();
  });

  test('modelCatalog 形状不对：当没有，不抛', () async {
    final client = _ModelClient(
      onCall: (m, p) => m == 'session.modelCatalog'
          ? {'available': true, 'catalog': 'x'}
          : null,
    );
    final app = AppModel(client: client);
    await app.start();
    await app.refreshSessions();
    expect(app.modelCatalog, isNull);
    app.dispose();
  });

  test('modelCatalog available=false：当没有，不摆空列表', () async {
    // 空目录会被读成"没有可用模型"，而真实原因可能是 key 没配 ——
    // 与连接器同一条纪律（`models-face.test.ts` 的 `{available:false}`）。
    final client = _ModelClient(
      onCall: (m, p) =>
          m == 'session.modelCatalog' ? {'available': false} : null,
    );
    final app = AppModel(client: client);
    await app.start();
    await app.refreshSessions();
    expect(app.modelCatalog, isNull);
    app.dispose();
  });
}
