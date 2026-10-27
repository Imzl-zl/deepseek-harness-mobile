/// 草稿的接线（机制在 `ui_state_test.dart`）。
///
/// 这里锁三件事：
/// 1. **重启/重建页面后草稿还在**（用户原话："关一次抽屉/重启不能丢"）；
/// 2. **恢复不弹键盘** —— 设 `controller.text` 不请求焦点，
///    否则会违反 `docs/subsystems/input-focus.md`（SDK：`editable_text.dart:4752-4753`）；
/// 3. **草稿按会话**：切到别的会话是空白，切回来还是原来那段。
///
/// Note: 设计见 `.agents/notes/proposed/2026-10-27-ui-state-design.md` §3。
library;

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/data/store.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

class _Prefs implements PreferenceStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<Map<String, String>> readAll(String prefix) async => {
    for (final e in values.entries)
      if (e.key == prefix || e.key.startsWith(prefix)) e.key: e.value,
  };

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String prefix, {bool includePrefixed = true}) async =>
      values.removeWhere(
        (k, _) => k == prefix || (includePrefixed && k.startsWith(prefix)),
      );
}

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
  }) async => throw const ProtocolException(ErrorCode.relayOffline, '测试不连');
}

void main() {
  Future<(AppModel, _Prefs)> boot(WidgetTester tester) async {
    final prefs = _Prefs();
    final app = AppModel(client: _IdleClient(), prefs: prefs);
    addTearDown(app.dispose);
    await app.loadUiState();
    app.seedForTest(sid: 's1', title: 'A', updatedAt: 2, items: const []);
    app.seedForTest(sid: 's2', title: 'B', updatedAt: 1, items: const []);
    await app.openSession('s1');
    return (app, prefs);
  }

  Widget host(AppModel app) => MaterialApp(
    theme: DshTheme.dark(),
    home: ChatPage(
      app: app,
      paired: true,
      onOpenDrawer: () {},
      onNewSession: () {},
      drawer: const SizedBox.shrink(),
    ),
  );

  testWidgets('打字 → 防抖落盘 → 重建页面草稿还在，且不弹键盘', (tester) async {
    final (app, prefs) = await boot(tester);

    await tester.pumpWidget(host(app));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '写到一半');
    await tester.pumpAndSettle();
    // 防抖窗口过后才落盘。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(prefs.values['host.session_draft.s1'], contains('写到一半'));

    // "重启"：换一棵树，同一个 AppModel 与同一份盘。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(host(app));
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField).last);
    expect(field.controller?.text, '写到一半');
    expect(
      tester.testTextInput.isVisible,
      isFalse,
      reason: '恢复草稿不许把输入法叫回来（input-focus.md 的硬规则）',
    );
  });

  testWidgets('草稿按会话：切走是空白，切回来还是原来那段', (tester) async {
    final (app, _) = await boot(tester);

    await tester.pumpWidget(host(app));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'A 的草稿');
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));

    await app.openSession('s2');
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).last).controller?.text,
      isEmpty,
      reason: 'B 没草稿，不该继承 A 的字',
    );

    await app.openSession('s1');
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).last).controller?.text,
      'A 的草稿',
    );
  });
}
