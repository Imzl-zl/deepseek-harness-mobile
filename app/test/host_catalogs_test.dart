/// `HostCatalogs` 的纯 Dart 用例（收窄计划的准入门槛之一：
/// 新类必须能脱离 `AppModel` 直接构造与断言）。
///
/// Note: 收窄计划见 `.agents/notes/proposed/2026-10-27-appmodel-narrowing.md`。
library;

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/host_catalogs.dart';
import 'package:dsh_mobile/model/permission.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

class _Client extends FakeSyncClient {
  _Client({this.model, this.permission, this.presets, this.fail = false});

  final Object? model;
  final Object? permission;
  final Object? presets;
  final bool fail;

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
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (fail) throw const ProtocolException(ErrorCode.relayOffline, '断线');
    return switch (method) {
      'session.modelCatalog' => model as T,
      'permission.catalog' => permission as T,
      'agentPresets.list' => presets as T,
      _ => throw const ProtocolException(ErrorCode.relayOffline, '不该调'),
    };
  }
}

Map<String, Object?> _modelCatalog() => {
  'available': true,
  'catalog': {
    'default': {'provider': 'p', 'model': 'm'},
    'routableProviders': ['p'],
    'groups': [
      {
        'id': 'p',
        'name': 'P',
        'models': [
          {'id': 'm', 'name': 'M'},
        ],
      },
    ],
    'failures': <Object?>[],
  },
};

void main() {
  test('三个目录各自刷新、各自读回；onChange 每次变化调用一次', () async {
    var changes = 0;
    final catalogs = HostCatalogs(
      client: _Client(
        model: _modelCatalog(),
        // 真实形状要三样都齐（`parsePermissionCatalog`：options / defaultOptions /
        // defaultPreset 缺一个就整份认不出）。
        permission: {
          'available': true,
          'catalog': {
            'options': [
              {'value': 'workspace-write', 'name': '工作区内可改'},
            ],
            'defaultOptions': <Object?>[],
            'defaultPreset': 'workspace-write',
          },
        },
        presets: {
          'available': true,
          'roster': {
            'presets': [
              {'id': 'standard', 'isDefault': true},
            ],
          },
        },
      ),
      onChange: () => changes += 1,
    );

    expect(catalogs.modelCatalog, isNull);
    await catalogs.refreshModels();
    await catalogs.refreshPermissions();
    await catalogs.refreshPresets();

    expect(catalogs.modelCatalog?.defaultSelection.model, 'm');
    expect(catalogs.permissionCatalog?.options, isNotEmpty);
    expect(catalogs.agentPresetRoster?.defaultId, 'standard');
    expect(changes, 3, reason: '每个目录各通知一次');
  });

  test('拉失败 → 保持 null、不抛（目录是附属信息）', () async {
    final catalogs = HostCatalogs(client: _Client(fail: true), onChange: () {});
    await catalogs.refreshModels();
    await catalogs.refreshPermissions();
    await catalogs.refreshPresets();
    expect(catalogs.modelCatalog, isNull);
    expect(catalogs.permissionCatalog, isNull);
    expect(catalogs.agentPresetRoster, isNull);
  });

  test('同一份权限目录重复 set 只通知一次（同值幂等）', () {
    var changes = 0;
    final catalogs = HostCatalogs(
      client: _Client(),
      onChange: () => changes += 1,
    );
    const catalog = PermissionCatalog(
      options: [],
      defaultOptions: [],
      defaultPreset: 'workspace-write',
    );
    catalogs.setPermissionCatalog(catalog);
    catalogs.setPermissionCatalog(catalog);
    expect(changes, 1, reason: '同一个对象第二次 set 不该再通知');
  });
}
