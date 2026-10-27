/// 选择记忆的**默认值回落**（批 D）。
///
/// ## 判据出处
///
/// 桌面 `ui-model-selection/src/client/directory.ts:162,180`：
/// `projected.next ?? catalog.value.default` —— 会话没有记录选择时，
/// 有效选择就是**宿主默认**；等级也一样（`:163-164`
/// `intended.reasoningEffort ?? reasoning.defaultEffort`）。
///
/// 而会话在创建/恢复时**活跟随**默认（`api/session-controller/src/agent.ts:464-472`），
/// 所以"新会话没有模型"在桌面上是不存在的状态；手机不该显示「请选择模型」。
///
/// Note: 归属与被否方案见 `.agents/notes/proposed/2026-10-27-ui-state-design.md` §T2。
library;

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 一份真形状的目录（`buildModelCatalog` 的返回，`catalog.ts:20-72`）。
Map<String, Object?> _catalogReply({
  String provider = 'lightvela-free',
  String model = 'auto',
  String? effort = 'high',
}) => {
  'available': true,
  'catalog': {
    'default': {
      'provider': provider,
      'model': model,
      'reasoningEffort': ?effort,
    },
    'routableProviders': [provider],
    'groups': [
      {
        'id': provider,
        'name': 'LightVela',
        'models': [
          {
            'id': model,
            'name': '自动',
            'reasoning': {
              'efforts': [
                {'id': 'low', 'name': '低'},
                {'id': 'high', 'name': '高'},
              ],
              'defaultEffort': 'low',
            },
          },
        ],
      },
    ],
    'failures': <Object?>[],
  },
};

Map<String, Object?> _row(String sid, {Map<String, Object?>? model}) => {
  'sid': sid,
  'updatedAt': 2,
  'running': false,
  'blank': false,
  'subagent': false,
  'model': ?model,
};

class _CatalogClient extends FakeSyncClient {
  _CatalogClient({this.rows = const [], this.catalog});

  final List<Object?> rows;
  final Object? catalog;

  @override
  conn.ConnectionState get state => conn.ConnectionState.serving;
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
  Future<SessionAnchor> subscribe(String sid, {required int since}) async =>
      const SessionAnchor(since: 0, hasMore: false);

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    switch (method) {
      case 'session.list':
        return {'sessions': rows} as T;
      case 'session.modelCatalog':
        return catalog as T;
      default:
        // 其余一律"没连上"：这几条用例只关心会话清单与模型目录。
        throw const ProtocolException(ErrorCode.relayOffline, '测试不连');
    }
  }
}

void main() {
  test('目录的 default 要带 reasoningEffort（桌面 `default` 就是整个选择）', () {
    final catalog = parseModelCatalogValue(
      (_catalogReply()['catalog'])! as Map,
    );
    expect(catalog, isNotNull);
    expect(catalog!.defaultSelection.provider, 'lightvela-free');
    expect(catalog.defaultSelection.model, 'auto');
    expect(
      catalog.defaultSelection.reasoningEffort,
      'high',
      reason: '丢了这个字段，推理等级就只能在选过一次之后才显示',
    );
  });

  test('会话没记录选择 → currentModel 回落宿主默认', () async {
    final app = AppModel(
      client: _CatalogClient(rows: [_row('s1')], catalog: _catalogReply()),
    );
    addTearDown(app.dispose);
    await app.refreshSessions();
    await app.openSession('s1');

    expect(app.currentModel, isNotNull, reason: '新会话不该是「请选择模型」');
    expect(app.currentModel!.provider, 'lightvela-free');
    expect(app.currentModel!.model, 'auto');
    expect(app.currentModel!.reasoningEffort, 'high');
  });

  test('会话有记录选择 → 以会话为准（默认只是兜底）', () async {
    final app = AppModel(
      client: _CatalogClient(
        rows: [
          _row('s1', model: {'provider': 'other', 'model': 'picked'}),
        ],
        catalog: _catalogReply(),
      ),
    );
    addTearDown(app.dispose);
    await app.refreshSessions();
    await app.openSession('s1');

    expect(app.currentModel!.provider, 'other');
    expect(app.currentModel!.model, 'picked');
  });

  test('目录拿不到 ⇒ 仍是 null（显示"拿不到"，不编一个）', () async {
    final app = AppModel(
      client: _CatalogClient(rows: [_row('s1')], catalog: {'available': false}),
    );
    addTearDown(app.dispose);
    await app.refreshSessions();
    await app.openSession('s1');

    expect(app.currentModel, isNull);
  });
}
