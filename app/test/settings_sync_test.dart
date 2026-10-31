/// 电脑侧设置（`settings.describe` / `settings.update`）的手机端接线。
///
/// 守四件事：
///
/// 1. **读到的值按 ns 落表**，字段用 `settingsValue(ns, path)` 取；拿不到就说"未读到"。
/// 2. **写只发新值**：请求体是 `{ns, path:[…], value, expectedRevision}`，
///    `expectedRevision` 来自上一次 describe（乐观锁），不是编的。
/// 3. `settings/conflict` ⇒ 返回 false **并重读一次**（下一次点击带新 revision）。
/// 4. 设置页三行：值来自电脑侧；目录 / 名册没拿到时**行在但点不动**（不摆假入口）。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/permission.dart';
import 'package:dsh_mobile/model/theme_mode.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

const _sections = {
  'sections': [
    {
      'ns': 'permission',
      'revision': 'rev-1',
      'values': {'defaultPreset': 'workspace-write'},
      'secrets': [
        {
          'path': ['apiKey'],
          'set': true,
        },
      ],
    },
    {
      'ns': 'agent-preset-registry',
      'revision': 'rev-2',
      'values': {'selectedDefault': 'standard'},
      'secrets': <Object?>[],
    },
    {
      'ns': 'session-log-deepseek',
      'revision': 'rev-3',
      'values': {'enabled': false},
      'secrets': <Object?>[],
    },
  ],
};

class _Client extends FakeSyncClient {
  _Client({this.conflictOnUpdate = false, this.includeSessionLog = true});

  final bool conflictOnUpdate;

  /// `false` = 电脑侧**没回** `session-log-deepseek` 这个 ns（读面缺失）。
  /// 用来钉"没读到不等于关"：那一行既不许出开关，也不许把值说成 `false`。
  final bool includeSessionLog;
  final calls =
      <({String method, Map<String, Object?> params, String? requestId})>[];
  var describes = 0;

  @override
  conn.ConnectionState get state => conn.ConnectionState.serving;
  @override
  Stream<conn.ConnectionState> get connection => const Stream.empty();
  @override
  Stream<JobFrame> get jobUpdates => const Stream.empty();
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
    calls.add((method: method, params: params, requestId: requestId));
    switch (method) {
      case 'settings.describe':
        describes += 1;
        if (!includeSessionLog) {
          final copy = Map<String, Object?>.from(_sections);
          copy['sections'] = (_sections['sections']! as List)
              .where((s) => (s as Map)['ns'] != 'session-log-deepseek')
              .toList();
          return copy as T;
        }
        return _sections as T;
      case 'repo.info':
        // 电脑侧 DSH 版本（`repo.info.dshVersion`）：宿主运行时真值。
        // **`caps` 必须给**：它是连接器无条件写出的键，少了它整条应答解不出来
        // （`wire/rpc/repo.dart`），版本号也就跟着丢。
        return {
              'protocol': 1,
              'caps': <String, Object?>{},
              'dshVersion': '0.2.1-rc.2',
              'hostName': 'build-machine',
            }
            as T;
      case 'settings.update':
        if (conflictOnUpdate) {
          throw const ProtocolException(ErrorCode.settingsConflict, '设置已被改动');
        }
        final ns = params['ns'];
        final path = (params['path'] as List).first as String;
        return {
              'section': {
                'ns': ns,
                'revision': 'rev-new',
                'values': {path: params['value']},
                'secrets': <Object?>[],
              },
            }
            as T;
      case 'session.projections':
        return <String, Object?>{} as T;
      default:
        return <String, Object?>{} as T;
    }
  }
}

void main() {
  test('refreshRepoInfo：读电脑侧 DSH 版本与电脑名；没读到就是 null（不编）', () async {
    final client = _Client();
    final app = AppModel(client: client);
    addTearDown(app.dispose);
    expect(app.dshVersion, isNull);
    expect(app.hostName, isNull, reason: '还没读到，不编一个名字');
    await app.refreshRepoInfo();
    expect(app.dshVersion, '0.2.1-rc.2');
    expect(app.hostName, 'build-machine');
    final call = client.calls.firstWhere((c) => c.method == 'repo.info');
    expect(call.requestId, isNull, reason: '读方法不带幂等键');
  });

  test('refreshSettings：按 ns 落表，字段用 settingsValue 取', () async {
    final client = _Client();
    final app = AppModel(client: client);
    addTearDown(app.dispose);

    await app.refreshSettings();
    expect(app.settingsValue('permission', 'defaultPreset'), 'workspace-write');
    expect(app.settingsValue('session-log-deepseek', 'enabled'), false);
    expect(
      app.settingsValue('agent-preset-registry', 'selectedDefault'),
      'standard',
    );
    // **读方法不带幂等键**（契约 §5.7）。
    final describe = client.calls.firstWhere(
      (c) => c.method == 'settings.describe',
    );
    expect(describe.requestId, isNull);
    expect(describe.params['namespaces'], AppModel.kSettingsNamespaces);
  });

  test('updateSetting：只发新值 + 上一轮的 revision；返回后本地的值也更新', () async {
    final client = _Client();
    final app = AppModel(client: client);
    addTearDown(app.dispose);
    await app.refreshSettings();

    final ok = await app.updateSetting(
      'agent-preset-registry',
      'selectedDefault',
      'ptc',
    );
    expect(ok, isTrue);
    final update = client.calls.firstWhere(
      (c) => c.method == 'settings.update',
    );
    expect(update.params['ns'], 'agent-preset-registry');
    expect(update.params['path'], ['selectedDefault']);
    expect(update.params['value'], 'ptc');
    expect(
      update.params['expectedRevision'],
      'rev-2',
      reason: '乐观锁来自上一次 describe',
    );
    expect(update.requestId, isNotNull, reason: '写方法带幂等键');

    expect(
      app.settingsValue('agent-preset-registry', 'selectedDefault'),
      'ptc',
    );
  });

  test('updateSetting：冲突 ⇒ false + 重读一次（不重试这次写）', () async {
    final client = _Client(conflictOnUpdate: true);
    final app = AppModel(client: client);
    addTearDown(app.dispose);
    await app.refreshSettings();
    final before = client.describes;

    final ok = await app.updateSetting(
      'permission',
      'defaultPreset',
      'full-access',
    );
    expect(ok, isFalse);
    expect(app.lastError?.code, ErrorCode.settingsConflict);
    expect(client.describes, before + 1, reason: '冲突后重读一次');
    expect(
      client.calls.where((c) => c.method == 'settings.update').length,
      1,
      reason: '只发了一次 —— 不盲目重试',
    );
  });

  group('设置页三行', () {
    Widget host(AppModel app) => MaterialApp(
      theme: DshTheme.dark(),
      home: SettingsPage(
        app: app,
        theme: ThemeController(),
        onThemeMode: (_) async {},
        onSurfaceAlpha: (_) async {},
        hasWallpaper: false,
        onPickWallpaper: () async {},
        onClearWallpaper: () async {},
      ),
    );

    testWidgets('值来自电脑侧；目录没拿到时行在但点不动', (tester) async {
      final app = AppModel(client: _Client());
      addTearDown(app.dispose);
      await app.refreshSettings();
      await tester.pumpWidget(host(app));
      await tester.pumpAndSettle();

      expect(find.text('新会话默认权限'), findsOneWidget);
      // 权限档的显示名：目录没拿到 ⇒ 照**原值**显示（不翻译、不猜中文名）。
      // **在这一行还看得见的时候断言**（下面要往下滚，滚走的行会被回收）。
      expect(find.text('workspace-write'), findsOneWidget);
      // 点不动：`ListTile.enabled == false`。
      final tile = tester.widget<ListTile>(
        find.ancestor(
          of: find.text('新会话默认权限'),
          matching: find.byType(ListTile),
        ),
      );
      expect(tile.enabled, isFalse);

      // **列表是懒建的**：2026-10-31 加了「背景 / 通透度」两行之后，
      // "新任务默认模式"与"上传 Session Log"都落到首屏之外 ——
      // 不滚过去它们根本不在树里（那是视口问题，不是行没了）。逐行滚、逐行断言。
      await tester.scrollUntilVisible(
        find.text('新任务默认模式'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('新任务默认模式'), findsOneWidget);
      // 名册没拿到 ⇒ 原样显示 id。
      expect(find.text('standard'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('上传 Session Log'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('上传 Session Log'), findsOneWidget);
      // 读到了就**照常出开关**（对照组：证明下面那条不是"开关永远不出"）。
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('上传 Session Log'),
            matching: find.byType(ListTile),
          ),
          matching: find.byType(Switch),
        ),
        findsOneWidget,
      );
    });

    testWidgets('没读到那个 ns：不画开关，写"未读到"（不许画成"关"）', (tester) async {
      final app = AppModel(client: _Client(includeSessionLog: false));
      addTearDown(app.dispose);
      await app.refreshSettings();
      await tester.pumpWidget(host(app));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('上传 Session Log'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      final row = find.ancestor(
        of: find.text('上传 Session Log'),
        matching: find.byType(ListTile),
      );
      // 值本身在模型层是 `null`（不是 `false`）—— 界面这里只负责别撒谎。
      expect(app.settingsValue('session-log-deepseek', 'enabled'), isNull);
      expect(
        find.descendant(of: row, matching: find.byType(Switch)),
        findsNothing,
        reason: '没读到不许画成一个具体状态（"关"）',
      );
      expect(
        find.descendant(of: row, matching: find.text('未读到')),
        findsOneWidget,
      );
    });

    testWidgets('目录在：显示目录里的名字，点开是选择器', (tester) async {
      final app = AppModel(client: _Client());
      addTearDown(app.dispose);
      app.setPermissionCatalog(
        const PermissionCatalog(
          options: [
            PermissionPreset(
              value: 'workspace-write',
              name: '工作区内修改',
              description: '可读可改工作区',
            ),
            PermissionPreset(value: 'full-access', name: '完全权限'),
          ],
          defaultOptions: [
            PermissionPreset(value: 'workspace-write', name: '工作区内修改'),
            PermissionPreset(value: 'full-access', name: '完全权限'),
          ],
          defaultPreset: 'workspace-write',
        ),
      );
      await app.refreshSettings();
      await tester.pumpWidget(host(app));
      await tester.pumpAndSettle();

      expect(find.text('工作区内修改'), findsOneWidget);
      await tester.tap(find.text('新会话默认权限'));
      await tester.pumpAndSettle();
      // 选择器列出可当默认的两档（`defaultOptions`）。
      expect(find.text('完全权限'), findsWidgets);
    });
  });
}
