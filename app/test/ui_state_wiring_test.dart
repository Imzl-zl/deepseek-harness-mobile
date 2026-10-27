/// 设备本地状态缝的**接线**（机制本身在 `ui_state_test.dart`）。
///
/// 这里锁四件事：
/// 1. 启动前置读：`AppModel.loadUiState()` 把 `device.*` 落进现有字段；
/// 2. 页签**按会话**、存 id：切到轨迹后重建页面还在轨迹上，换会话回对话；
/// 3. 抽屉折叠**按工作区身份**：改标题不影响它，重建抽屉也不丢；
/// 4. 换电脑只清 `host.*`，`device.*` 留着。
///
/// Note: 语义与取舍见 `.agents/notes/proposed/2026-10-27-ui-state-design.md` §2/§3。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/data/store.dart';
import 'package:dsh_mobile/data/ui_state.dart';
import 'package:dsh_mobile/model/preferences.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:dsh_mobile/ui/session_drawer.dart';
import 'package:dsh_mobile/ui/trajectory_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 内存偏好缝（`PreferenceStore`），带"盘上还剩什么"的直接可读视图。
class _Prefs implements PreferenceStore {
  _Prefs([Map<String, String>? initial])
    : values = <String, String>{...?initial};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<Map<String, String>> readAll(String prefix) async => {
    for (final entry in values.entries)
      if (entry.key == prefix || entry.key.startsWith(prefix))
        entry.key: entry.value,
  };

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String prefix, {bool includePrefixed = true}) async =>
      values.removeWhere(
        (key, _) =>
            key == prefix || (includePrefixed && key.startsWith(prefix)),
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
  }) async => throw const ProtocolException(ErrorCode.relayOffline, '这条用例不连通道');
}

/// 能让连接态走一遍 backoff → serving 的替身（落点只在那一步发生）。
///
/// 形状照 `running_reconnect_test.dart` 的 `_ReconnectClient`：
/// `session.list` 回线上形状的行，其余方法回空对象。
class _LandingClient extends FakeSyncClient {
  _LandingClient({required List<Map<String, Object?>> rows}) : _rows = rows;

  final List<Map<String, Object?>> _rows;
  final StreamController<conn.ConnectionState> _states =
      StreamController<conn.ConnectionState>.broadcast();
  conn.ConnectionState _state = conn.ConnectionState.idle;

  void emitState(conn.ConnectionState next) {
    _state = next;
    _states.add(next);
  }

  @override
  conn.ConnectionState get state => _state;
  @override
  Stream<conn.ConnectionState> get connection => _states.stream;
  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();
  @override
  Stream<SessionStatus> get sessionStatus =>
      const Stream<SessionStatus>.empty();
  @override
  Stream<SessionDelta> sessionUpdates(String sid) =>
      const Stream<SessionDelta>.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> reconnect() async {}
  @override
  Future<void> setAppState(AppState state) async {}
  @override
  Future<void> unsubscribe(String sid) async {}
  @override
  Future<void> close() async => _states.close();

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'session.list') return {'sessions': _rows} as T;
    // 其余（目录 / 工作区 / 设置 / 版本）回空对象：这一组只关心落点。
    return <String, Object?>{} as T;
  }
}

/// `session.list` 的一行（**线上形状**：`connector/src/handlers.ts:740-744` 恒发键）。
Map<String, Object?> _landingRow({
  required String sid,
  required bool blank,
  required int updatedAt,
}) => <String, Object?>{
  'sid': sid,
  'updatedAt': updatedAt,
  'running': false,
  'blank': blank,
  'subagent': false,
};

/// 让 `_onConnectionChanged` 里那串 `unawaited(...)` 跑完。
Future<void> _landingSettle() async {
  for (var i = 0; i < 8; i += 1) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('启动前置读（device.* → AppModel 字段）', () {
    test('读回工作步骤密度 / 性能用量 / 收起时机 / 字号档', () async {
      final prefs = _Prefs({
        UiKey.transcriptView: 'detailed',
        UiKey.performanceView: 'compact',
        UiKey.collapseTiming: 'next-input',
        UiKey.uiScaleIndex: '3',
      });
      final app = AppModel(client: _IdleClient(), prefs: prefs);
      addTearDown(app.dispose);

      await app.loadUiState();

      expect(app.transcriptView, TranscriptView.detailed);
      expect(app.performanceUsage, PerformanceUsage.compact);
      expect(app.collapseTiming, CollapseTiming.nextInput);
      expect(app.uiScaleIndex, 3);
    });

    test('盘上是坏的 → 保持默认（不猜）', () async {
      final prefs = _Prefs({
        UiKey.transcriptView: '???',
        UiKey.uiScaleIndex: '9',
      });
      final app = AppModel(client: _IdleClient(), prefs: prefs);
      addTearDown(app.dispose);

      await app.loadUiState();

      expect(app.transcriptView, TranscriptView.standard);
      expect(app.uiScaleIndex, 3, reason: '越界要夹到边界，不是丢回默认');
    });
  });

  group('页签：按会话、存 id', () {
    testWidgets('切到轨迹 → 重建页面仍在轨迹；换会话回对话', (tester) async {
      final prefs = _Prefs();
      final app = AppModel(client: _IdleClient(), prefs: prefs);
      addTearDown(app.dispose);
      await app.loadUiState();
      app.seedForTest(sid: 's1', title: 'A', updatedAt: 2, items: const []);
      app.seedForTest(sid: 's2', title: 'B', updatedAt: 1, items: const []);
      await app.openSession('s1');

      Widget host() => MaterialApp(
        theme: DshTheme.dark(),
        home: ChatPage(
          app: app,
          paired: true,
          onOpenDrawer: () {},
          onNewSession: () {},
          drawer: const SizedBox.shrink(),
        ),
      );

      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(find.byType(TrajectoryTab), findsNothing, reason: '默认是对话');

      await tester.tap(find.text('轨迹'));
      await tester.pumpAndSettle();
      expect(find.byType(TrajectoryTab), findsOneWidget);
      expect(prefs.values[UiKey.sessionView('s1')], 'trajectory');

      // "重建页面" = 重启后回到同一屏：同一份盘 + 新 widget。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      expect(find.byType(TrajectoryTab), findsOneWidget, reason: '重启后还在轨迹');

      // 换会话：它没存过页签 ⇒ 回对话。
      await app.openSession('s2');
      await tester.pumpAndSettle();
      expect(find.byType(TrajectoryTab), findsNothing);
      expect(prefs.values.containsKey(UiKey.sessionView('s2')), isFalse);
    });
  });

  group('抽屉折叠：按工作区身份（不是显示标题）', () {
    testWidgets('收起后重建抽屉仍收起；改标题不影响', (tester) async {
      final state = <String, bool>{};
      bool? expandedOf(String key) => state[key];

      Widget drawerWith(String label) => MaterialApp(
        theme: DshTheme.dark(),
        home: Scaffold(
          body: SessionDrawer(
            sections: [
              DrawerSection(
                label: label,
                workspaceId: 'w1',
                sessions: const [
                  DrawerSession(
                    sid: 's1',
                    title: 's1',
                    preview: '',
                    timeLabel: '',
                  ),
                ],
              ),
            ],
            connection: const DrawerConnection(
              name: 'pc',
              detail: '',
              platform: '',
            ),
            footItems: const [],
            onNewSession: () {},
            onOpenSession: (_) {},
            onClose: () {},
            expandedOf: expandedOf,
            onExpandedChanged: (key, expanded) => state[key] = expanded,
          ),
        ),
      );

      await tester.pumpWidget(drawerWith('dsh-mobile'));
      await tester.pumpAndSettle();
      expect(find.text('s1'), findsOneWidget, reason: '默认展开');

      await tester.tap(find.text('dsh-mobile'));
      await tester.pumpAndSettle();
      expect(find.text('s1'), findsNothing, reason: '点组头收起');
      expect(state, {'w1': false}, reason: '键必须是工作区身份');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(drawerWith('改过的工作区名'));
      await tester.pumpAndSettle();
      expect(
        find.text('s1'),
        findsNothing,
        reason: '改标题不该让折叠记忆失效（键是 workspaceId，不是标题）',
      );
    });
  });

  group('落点：记住的会话优先于 blank 复用', () {
    // 真机 2026-10-27 复现：冷启动不回到上次的会话，而是落到一个 blank 会话上
    // （于是页签/草稿都"没恢复"）。根因是**两条落点路径**：
    // `refreshSessions()` 末尾先 `_openBlankSessionIfUnselected()` 选中 blank，
    // 之后 `_landOnSession()` 因 `_currentSid != null` 直接早退 ——
    // 记住的会话永远没机会。规则见 `docs/subsystems/connect-landing.md` §2 四档。
    test('冷启动：记住的会话还在 → 落到它，不是那个 blank', () async {
      final prefs = _Prefs({UiKey.lastSession: 's-remembered'});
      final client = _LandingClient(
        rows: <Map<String, Object?>>[
          // blank 排在最前且最新 —— "复用 blank" 这一步总能赢，
          // 真机上就是这样把记忆覆盖掉的。
          _landingRow(sid: 's-blank', blank: true, updatedAt: 9999),
          _landingRow(sid: 's-remembered', blank: false, updatedAt: 1),
        ],
      );
      final app = AppModel(client: client, prefs: prefs);
      addTearDown(app.dispose);
      await app.loadUiState();

      await app.start();
      client.emitState(conn.ConnectionState.backoff);
      client.emitState(conn.ConnectionState.serving);
      await _landingSettle();

      expect(app.currentSid, 's-remembered', reason: '第 1 档：上次看的那个还在');
      expect(
        prefs.values[UiKey.lastSession],
        's-remembered',
        reason: '落点不许把记忆覆盖成那个 blank',
      );
    });

    test('没有记忆时：仍落最新（第 2/3 档），不靠 blank 复用', () async {
      final prefs = _Prefs();
      final client = _LandingClient(
        rows: <Map<String, Object?>>[
          _landingRow(sid: 's-old', blank: false, updatedAt: 1),
          _landingRow(sid: 's-new', blank: false, updatedAt: 50),
        ],
      );
      final app = AppModel(client: client, prefs: prefs);
      addTearDown(app.dispose);
      await app.loadUiState();

      await app.start();
      client.emitState(conn.ConnectionState.backoff);
      client.emitState(conn.ConnectionState.serving);
      await _landingSettle();

      expect(app.currentSid, 's-new');
    });
  });

  group('换电脑：只清 host.*', () {
    test('device.* 留着，host.* 清光', () async {
      final prefs = _Prefs();
      final app = AppModel(client: _IdleClient(), prefs: prefs);
      addTearDown(app.dispose);
      await app.loadUiState();
      await app.uiState!.setThemeMode('dark');
      await app.uiState!.setUiScaleIndex(2);
      await app.uiState!.setLastSession('sid-1');
      await app.uiState!.setView('sid-1', 'trajectory');

      await app.clearHostUiState();

      expect(app.uiState!.themeMode, 'dark');
      expect(app.uiState!.uiScaleIndex, 2);
      expect(app.uiState!.lastSession, isNull);
      expect(app.viewOf('sid-1'), isNull);
      expect(prefs.values.keys.where((k) => k.startsWith('host.')), isEmpty);
    });
  });
}
