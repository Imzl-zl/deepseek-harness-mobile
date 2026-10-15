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

  test('modelCatalog：按 provider 分组摊平，available=false 时不设', () async {
    final client = _ModelClient(
      onCall: (m, p) => m == 'session.modelCatalog'
          ? {
              'available': true,
              'catalog': [
                {
                  'provider': 'lightvela-free',
                  'models': [
                    {'id': 'auto'},
                    {'id': 'glm-5.3-flash'},
                  ],
                },
                {
                  'provider': 'deepseek-official',
                  'models': [
                    {'id': 'deepseek-chat'},
                  ],
                },
              ],
            }
          : null,
    );
    final app = AppModel(client: client);
    await app.start();
    await app.refreshSessions();

    expect(app.modelCatalog?.map((m) => '${m.provider}/${m.model}').toList(), [
      'lightvela-free/auto',
      'lightvela-free/glm-5.3-flash',
      'deepseek-official/deepseek-chat',
    ]);
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
}
