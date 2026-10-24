/// 插件页：**清单 + 行级启停**（`plugin.list` / `plugin.setEnabled`）。
///
/// ## 这一组守什么
///
/// 1. 行字段来自宿主的 `PluginInfo`：展示名从 `meta.title` 的**语言表**里挑一档、
///    没有就退回模块名；`patchId` 缺席的行**开关是禁用的**（点一个必然失败的开关
///    比没有更糟），原因写在行下方。
/// 2. 空清单与"没有插件服务"是两句不同的话：前者是电脑侧的答案，后者是老连接器。
/// 3. 启停发的是 `{id, enabled}` + 幂等键；回执里的 `enabled` 是**宿主回读后的真值**，
///    所以 `overridden` 时那一行不会被我们"改成功"。
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/plugins.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/plugins_page.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 一台假电脑：`repo.info`（能力位）+ `plugin.list` + `plugin.setEnabled`。
class _PluginClient extends FakeSyncClient {
  _PluginClient({
    this.pluginsAvailable = true,
    this.rows = const [],
    this.toggleResult,
  });

  final bool pluginsAvailable;
  final List<Map<String, Object?>> rows;

  /// `plugin.setEnabled` 的回执；`null` 时回 `{enabled: 请求值, application:'applied'}`。
  final Map<String, Object?>? toggleResult;

  /// 发出去的调用：方法名 + 参数 + 幂等键。
  final sent = <(String, Map<String, Object?>, String?)>[];

  @override
  ConnectionState get state => ConnectionState.serving;
  @override
  Stream<ConnectionState> get connection => const Stream.empty();
  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();
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
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    switch (method) {
      case 'repo.info':
        return <String, Object?>{
              'protocol': 1,
              'caps': <String, Object?>{if (pluginsAvailable) 'plugins': true},
            }
            as T;
      case 'plugin.list':
        sent.add((method, params, requestId));
        return <String, Object?>{'plugins': rows} as T;
      case 'plugin.setEnabled':
        sent.add((method, params, requestId));
        return (toggleResult ??
                <String, Object?>{
                  'name': 'x',
                  'enabled': params['enabled'],
                  'application': 'applied',
                })
            as T;
    }
    return <String, Object?>{} as T;
  }
}

/// 两行真形状的 `PluginInfo`：第一行可改，第二行只能从电脑的管理面改。
const _rows = <Map<String, Object?>>[
  {
    'entryId': 'entry-a',
    'moduleName': '@deepseek-ai/dsh-tool-bash',
    'meta': {
      'title': {'en': 'Bash tool', 'zh': 'Bash 工具'},
      'description': 'Run shell commands',
    },
    'enabled': true,
    'fiberPhase': 'active',
    'patchId': 'patch-a',
  },
  {
    'entryId': 'entry-b',
    'moduleName': '@deepseek-ai/dsh-base',
    'enabled': false,
    'fiberPhase': 'pending',
    'readOnlyReason': 'management-required',
  },
];

Future<AppModel> _app(_PluginClient client) async {
  final app = AppModel(client: client);
  await app.refreshRepoInfo();
  return app;
}

void main() {
  group('模型（行与本地化文本）', () {
    test('展示名从语言表里挑一档；没有 title 就退回模块名', () {
      final first = PluginRow.fromWire(_rows[0])!;
      expect(first.displayName, 'Bash 工具');
      expect(first.moduleName, '@deepseek-ai/dsh-tool-bash');
      expect(first.canToggle, isTrue);

      final second = PluginRow.fromWire(_rows[1])!;
      expect(
        second.displayName,
        '@deepseek-ai/dsh-base',
        reason: '没有 meta 就退回模块名，不编一个',
      );
      expect(second.canToggle, isFalse);
      expect(second.readOnlyHint, '只能在电脑上改');
    });

    test('认不出的行整行不要（没有 entryId 就点不动）', () {
      expect(PluginRow.fromWire(null), isNull);
      expect(PluginRow.fromWire({'moduleName': 'x'}), isNull);
      expect(PluginRow.fromWire({'entryId': ''}), isNull);
    });
  });

  group('页面', () {
    testWidgets('两行都画出来；只读那行的开关是禁用的', (tester) async {
      final app = await _app(_PluginClient(rows: _rows));
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: DshTheme.dark(),
          home: PluginsPageHost(app: app),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Bash 工具'), findsOneWidget);
      expect(find.text('@deepseek-ai/dsh-base'), findsOneWidget);
      expect(find.text('只能在电脑上改'), findsOneWidget);

      final toggleable = tester.widget<Switch>(
        find.byKey(const ValueKey<String>('plugin-switch-entry-a')),
      );
      expect(toggleable.value, isTrue);
      expect(toggleable.onChanged, isNotNull);

      final readOnly = tester.widget<Switch>(
        find.byKey(const ValueKey<String>('plugin-switch-entry-b')),
      );
      expect(readOnly.onChanged, isNull, reason: '没有 patchId 的行不该可点');
    });

    testWidgets('空清单 ⇒ "没有可管理的插件"（与"没有插件服务"是两句话）', (tester) async {
      final app = await _app(_PluginClient(rows: const []));
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: DshTheme.dark(),
          home: PluginsPageHost(app: app),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('这台电脑没有可管理的插件。'), findsOneWidget);
    });

    testWidgets('老连接器（没有 caps.plugins）⇒ 说清原因，且一次请求都不发', (tester) async {
      final client = _PluginClient(pluginsAvailable: false, rows: _rows);
      final app = await _app(client);
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: DshTheme.dark(),
          home: PluginsPageHost(app: app),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('没有插件服务'), findsOneWidget);
      expect(
        client.sent.where((call) => call.$1 == 'plugin.list'),
        isEmpty,
        reason: '没有能力位就不发请求 —— 否则会把 unsupported 画成"读取失败"',
      );
    });

    testWidgets('点开关 ⇒ 发 {id, enabled} + 幂等键，并按回执更新那一行', (tester) async {
      final client = _PluginClient(rows: _rows);
      final app = await _app(client);
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: DshTheme.dark(),
          home: PluginsPageHost(app: app),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('plugin-switch-entry-a')),
      );
      await tester.pumpAndSettle();

      final toggle = client.sent.where(
        (call) => call.$1 == 'plugin.setEnabled',
      );
      expect(toggle.length, 1);
      expect(toggle.single.$2, {'id': 'entry-a', 'enabled': false});
      expect(toggle.single.$3, isNotNull, reason: '写操作必须带幂等键');

      final row = app.plugins.firstWhere((item) => item.entryId == 'entry-a');
      expect(row.enabled, isFalse);
    });

    testWidgets('宿主回 overridden ⇒ 那一行按宿主说的保持原状，并说清原因', (tester) async {
      final client = _PluginClient(
        rows: _rows,
        toggleResult: const {
          'name': '@deepseek-ai/dsh-tool-bash',
          'enabled': true,
          'application': 'overridden',
        },
      );
      final app = await _app(client);
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: DshTheme.dark(),
          home: PluginsPageHost(app: app),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey<String>('plugin-switch-entry-a')),
      );
      await tester.pumpAndSettle();

      final row = app.plugins.firstWhere((item) => item.entryId == 'entry-a');
      expect(row.enabled, isTrue, reason: '回执里的 enabled 是宿主回读后的真值');
      expect(find.textContaining('被更高优先级的配置盖住了'), findsOneWidget);
    });
  });
}
