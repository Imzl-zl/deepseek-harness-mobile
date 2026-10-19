/// 权限档这条链的回归（`permission.catalog` → 目录 / `permissions` 投影 → 当前值 /
/// `permission.switch` → 切换）。
///
/// ## 为什么单独一组
///
/// 2026-10-15 之前输入栏的权限档是**三档手抄**：`dsh_composer.dart` 里一个
/// `AccessMode` 枚举，点完只改本地字段 —— 既与电脑侧无关，也不会真的切。
/// 用户无法分辨"我切了"和"我什么都没切"，这是假数据最坏的地方。
///
/// 所以这里钉的不只是"能切"，而是四件事：
///
/// 1. 目录与当前值都来自电脑侧，**形状认不出时不猜**（空目录 / 未知档位）；
/// 2. 切换必须**真的发到电脑侧**（`permission.switch`），不是改本地字段；
/// 3. "电脑侧没有 `/permission` 命令"与"预设名不对"是两件事，文案分开；
/// 4. 失败留声（`AppModel.lastError`），不静默。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/permission.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fake_sync_client.dart';

class _ProjClient extends FakeSyncClient {
  _ProjClient({this.onCall});

  final Object? Function(String method, Map<String, Object?> params)? onCall;
  final List<String> called = [];
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

/// 一份够真的目录：三个部署预设，`name` 回显键本身
/// （DSH 的 base 配置没配 `name`，`optionOf` 于是回显键，
/// `packages/interaction/permission-presets/src/index.ts:389`）。
Map<String, Object?> _catalogReply() => {
  'available': true,
  'catalog': {
    'options': [
      {'value': 'read-only', 'name': 'read-only'},
      {'value': 'workspace-write', 'name': 'workspace-write'},
      {
        'value': 'danger-full-access',
        'name': 'danger-full-access',
        'description': 'Full file access without approval prompts.',
      },
    ],
    'defaultOptions': [
      {'value': 'read-only', 'name': 'read-only'},
      {'value': 'workspace-write', 'name': 'workspace-write'},
      {'value': 'danger-full-access', 'name': 'danger-full-access'},
    ],
    'defaultPreset': 'workspace-write',
  },
};

void main() {
  group('parsePermissionCatalog：形状认不出就不给，不造空目录', () {
    test('完整形状：三项 + 默认值都解出来', () {
      final catalog = parsePermissionCatalog(_catalogReply());
      expect(catalog, isNotNull);
      expect(catalog!.options.map((o) => o.value).toList(), [
        'read-only',
        'workspace-write',
        'danger-full-access',
      ]);
      expect(catalog.defaultPreset, 'workspace-write');
      expect(catalog.defaultOptions.length, 3);
      // 说明来自 host；没有配置的项没有说明（不自己编一句）。
      expect(
        catalog.optionOf('danger-full-access')?.description,
        'Full file access without approval prompts.',
      );
      expect(catalog.optionOf('read-only')?.description, isNull);
    });

    test('available 不为 true：返回 null（不把"拿不到"显示成"没有预设"）', () {
      expect(parsePermissionCatalog({'available': false}), isNull);
      expect(parsePermissionCatalog({'available': true}), isNull);
      expect(
        parsePermissionCatalog({'available': true, 'catalog': 'x'}),
        isNull,
      );
      expect(parsePermissionCatalog(null), isNull);
    });

    test('缺字段的项跳过；缺 defaultPreset 整份不要', () {
      final catalog = parsePermissionCatalog({
        'available': true,
        'catalog': {
          'options': [
            {'value': 'ok', 'name': 'ok'},
            {'name': 'no value'},
            {'value': 'no name'},
            'not a map',
          ],
          'defaultOptions': [],
          // 缺 defaultPreset —— 形状不对，整份退回 null。
        },
      });
      expect(catalog, isNull, reason: '缺一个必填字段就整份退回，不要半份目录');
    });

    test('optionOf 认不出返回 null（custom 不在可切目标里）', () {
      final catalog = parsePermissionCatalog(_catalogReply())!;
      expect(
        catalog.optionOf('custom'),
        isNull,
        reason: 'custom 是 DSH 的派生显示态，catalog 的 options 里没有它',
      );
      expect(catalog.optionOf('workspace-write')?.name, 'workspace-write');
    });
  });

  group('parsePermissionValue：当前档位只从投影取', () {
    test('认得出就用它', () {
      expect(
        parsePermissionValue({
          'permissions': {'currentValue': 'read-only'},
        }),
        'read-only',
      );
    });

    test('认不出就是 null，不猜一个档位', () {
      expect(
        parsePermissionValue({
          'permissions': {'currentValue': ''},
        }),
        isNull,
      );
      expect(parsePermissionValue({'permissions': 'x'}), isNull);
      expect(parsePermissionValue({'permissions': {}}), isNull);
      expect(parsePermissionValue(null), isNull);
      expect(
        parsePermissionValue({'tokenUsage': {}}),
        isNull,
        reason: '投影没注册（这台电脑没装权限插件）时与"这一帧没有这个键"同罪',
      );
    });
  });

  group('parsePermissionSwitch：三种结论分开', () {
    test('success：matched + kind + DSH 原文', () {
      final result = parsePermissionSwitch({
        'matched': true,
        'execution': {
          'commandId': 'cmd-1-1',
          'result': {'kind': 'success', 'text': 'preset danger-full-access'},
        },
      });
      expect(result, isNotNull);
      expect(result!.matched, isTrue);
      expect(result.succeeded, isTrue);
      expect(result.text, 'preset danger-full-access');
    });

    test('error：matched 但 kind 是 error（预设名不对，原文照显）', () {
      final result = parsePermissionSwitch({
        'matched': true,
        'execution': {
          'commandId': 'cmd-1-2',
          'result': {
            'kind': 'error',
            'text':
                'unknown preset "yolo" (available: read-only, workspace-write)',
          },
        },
      });
      expect(result!.matched, isTrue);
      expect(result.succeeded, isFalse);
      expect(result.text, contains('unknown preset'));
    });

    test('matched 为 false：这台电脑没有 /permission 命令', () {
      final result = parsePermissionSwitch({'matched': false});
      expect(result!.matched, isFalse);
      expect(result.succeeded, isFalse);
      expect(result.kind, isNull);
      expect(result.text, isNull);
    });

    test('形状不对：返回 null（调用方按失败留声）', () {
      expect(parsePermissionSwitch(null), isNull);
      expect(parsePermissionSwitch({}), isNull);
      expect(parsePermissionSwitch({'matched': 'yes'}), isNull);
      // matched 却缺 execution —— 那是电脑侧实现不对，不能读成成功。
      expect(parsePermissionSwitch({'matched': true}), isNull);
    });
  });

  group('展示映射：已知键用本地文案，认不出不硬套', () {
    test('needsRiskGate 口径照 Web：danger-full-access 与 auto', () {
      final catalog = parsePermissionCatalog(_catalogReply())!;
      expect(catalog.optionOf('danger-full-access')!.needsRiskGate, isTrue);
      expect(catalog.optionOf('workspace-write')!.needsRiskGate, isFalse);
      expect(catalog.optionOf('read-only')!.needsRiskGate, isFalse);
      // `auto` 不在这个部署的目录里，但判据本身要知道它。
      expect(
        const PermissionPreset(value: 'auto', name: 'auto').needsRiskGate,
        isTrue,
      );
    });

    test('displayPresetName：host 没给标签时用本地文案', () {
      final catalog = parsePermissionCatalog(_catalogReply())!;
      expect(displayPresetName(catalog.optionOf('read-only')!), '只读');
      expect(displayPresetName(catalog.optionOf('workspace-write')!), '工作区内可改');
      expect(
        displayPresetName(catalog.optionOf('danger-full-access')!),
        '完全权限',
      );
    });

    test('displayPresetName：host 给了标签就用它（部署自己的措辞）', () {
      const option = PermissionPreset(value: 'read-only', name: '仅查看不允许写入');
      expect(displayPresetName(option), '仅查看不允许写入');
    });

    test('permissionChipOf：三个内置档各有专用图标，未知值不硬套', () {
      final catalog = parsePermissionCatalog(_catalogReply())!;
      final chip = permissionChipOf(
        value: 'danger-full-access',
        catalog: catalog,
      );
      expect(chip.icon, 'permissionFullAccess');
      expect(chip.label, '完全权限');
      expect(chip.warn, isTrue);

      final write = permissionChipOf(
        value: 'workspace-write',
        catalog: catalog,
      );
      expect(write.icon, 'permissionWorkspaceWrite');
      expect(write.warn, isFalse);

      // `custom` 是派生态：没有专用图标，用中性的 + 电脑侧给的名字。
      final custom = permissionChipOf(value: 'custom', catalog: catalog);
      expect(custom.icon, 'shield');
      expect(custom.warn, isFalse);
    });

    test('permissionChipOf：拿不到当前值时显示未知，不猜一个档位', () {
      expect(permissionChipOf(value: null, catalog: null).label, '未知');
      // 没有目录时用原始值，而不是把"不知道"显示成"只读"。
      expect(
        permissionChipOf(value: 'some-deploy-preset', catalog: null).label,
        'some-deploy-preset',
      );
    });
  });

  group('AppModel：目录随清单拉、切换真的发出去', () {
    test('refreshSessions 顺带拉一次权限目录', () async {
      final client = _ProjClient(
        onCall: (m, p) => switch (m) {
          'session.list' => {'sessions': []},
          'session.modelCatalog' => {'available': false},
          'permission.catalog' => _catalogReply(),
          _ => null,
        },
      );
      final app = AppModel(client: client);
      await app.start();
      await app.refreshSessions();

      expect(client.called, contains('permission.catalog'));
      expect(app.permissionCatalog?.options.length, 3);
      app.dispose();
    });

    test('目录拉不到：permissionCatalog 是 null（界面说"拿不到"）', () async {
      final client = _ProjClient(
        onCall: (m, p) => switch (m) {
          'session.list' => {'sessions': []},
          'session.modelCatalog' => {'available': false},
          _ => null,
        },
      );
      final app = AppModel(client: client);
      await app.start();
      await app.refreshSessions();

      expect(
        app.permissionCatalog,
        isNull,
        reason: 'null 让界面说"拿不到目录"；空目录会被读成"这台电脑没有预设"',
      );
      app.dispose();
    });

    test('切换：带 sid 与 preset 与幂等键，成功后重读投影', () async {
      const Object projectionsReply = {
        'permissions': {'currentValue': 'workspace-write'},
      };
      final client = _ProjClient(
        onCall: (m, p) => switch (m) {
          'permission.switch' => {
            'matched': true,
            'execution': {
              'commandId': 'cmd-1-1',
              'result': {'kind': 'success', 'text': 'preset read-only'},
            },
          },
          'session.projections' => projectionsReply,
          _ => null,
        },
      );
      final app = AppModel(client: client);
      await app.start();
      await app.openSession('sid_A');
      expect(app.permissionValue, 'workspace-write');

      final result = await app.switchPermission('read-only');

      expect(result!.succeeded, isTrue);
      expect(client.called.where((m) => m == 'permission.switch').length, 1);
      expect(
        client.called.where((m) => m == 'session.projections').length,
        2,
        reason: '切完必须重读投影 —— 当前值只在开会话时拉过一次',
      );
      app.dispose();
    });

    test('切换失败：留声并返回 null，不假装切成功', () async {
      final client = _ProjClient(
        onCall: (m, p) => switch (m) {
          'permission.switch' => throw const ProtocolException(
            ErrorCode.connectorUnsupported,
            'permission.switch 尚未实现',
          ),
          _ => null,
        },
      );
      final app = AppModel(client: client);
      await app.start();
      await app.openSession('sid_A');

      final result = await app.switchPermission('read-only');

      expect(result, isNull);
      expect(app.lastError, isNotNull, reason: '失败必须留声');
      expect(app.lastError!.message, contains('permission.switch'));
      app.dispose();
    });

    test('没有选中会话：不发切换（发了也没有目标）', () async {
      final client = _ProjClient(onCall: (m, p) => null);
      final app = AppModel(client: client);
      await app.start();

      expect(await app.switchPermission('read-only'), isNull);
      expect(client.called, isNot(contains('permission.switch')));
      app.dispose();
    });
  });
}
