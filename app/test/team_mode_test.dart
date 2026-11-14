/// 模型菜单里的「启用智能体团队协作」开关（`ui/team_mode_row.dart`）
/// 与它的写路径（`AppModel.setTeamEnabled` → `team.setEnabled`）。
///
/// ## 这组钉的是 DSH 的四条行为
///
/// 逐条照 `ui-agent-team/src/client/TeamModeToggle.tsx`：
///
/// 1. **不做乐观更新**：开关只认投影（`checked={mode.enabled}`），所以"点了之后
///    投影还没回来"时它不该自己翻；
/// 2. **停用要先确认，且只在用过模型时确认**（`:47` 的
///    `!enabled && modelSelection.lastUsed !== null`）；
/// 3. 确认框点取消 ⇒ **一次写都不发**；
/// 4. 写失败 ⇒ 行上留一句 `mode.failed`，不静默。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/team_mode_row.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 只回答 `team.setEnabled` 与 `session.projections` 的替身。
class _TeamClient extends FakeSyncClient {
  _TeamClient({this.failSet = false});

  final bool failSet;
  final List<String> called = [];
  final List<Map<String, Object?>> setCalls = [];
  final _jobs = StreamController<JobFrame>.broadcast();
  Object? projectionsReply;

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
    switch (method) {
      case 'team.setEnabled':
        setCalls.add({...params, 'requestId': requestId});
        if (failSet) throw Exception('电脑侧拒绝：TEAM_LEAD_REQUIRED');
        return <String, Object?>{} as T;
      case 'session.projections':
        return (projectionsReply ?? <String, Object?>{}) as T;
      case 'repo.info':
        return <String, Object?>{
              'caps': {'jobs': false, 'team': true},
            }
            as T;
      default:
        return <String, Object?>{} as T;
    }
  }
}

Widget _wrap(Widget child) => MaterialApp(
  theme: DshTheme.dark(),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  group('TeamModeRow', () {
    testWidgets('开关只认投影：点一下不会自己翻过去', (tester) async {
      var called = false;
      await tester.pumpWidget(
        _wrap(
          TeamModeRow(
            enabled: false,
            modelEverUsed: false,
            onSetEnabled: (enabled) async {
              called = true;
              return null;
            },
          ),
        ),
      );
      expect(find.text(TeamCopy.label), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(called, isTrue, reason: '写发出去了');
      final sw = tester.widget<Switch>(find.byType(Switch));
      expect(sw.value, isFalse, reason: '投影没变，开关就不该翻（不做乐观更新）');
    });

    testWidgets('停用且用过模型 ⇒ 先弹确认；取消则一次都不写', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        _wrap(
          TeamModeRow(
            enabled: true,
            modelEverUsed: true,
            onSetEnabled: (enabled) async {
              calls += 1;
              return null;
            },
          ),
        ),
      );
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text(TeamCopy.disableTitle), findsOneWidget);
      expect(find.text(TeamCopy.disableDescription), findsOneWidget);
      expect(find.text(TeamCopy.disableWarning), findsOneWidget);
      await tester.tap(find.text(TeamCopy.disableCancel));
      await tester.pumpAndSettle();
      expect(calls, 0, reason: '取消 = 不写');
    });

    testWidgets('停用但没用过模型 ⇒ 直接写，不弹确认（DSH 的 lastUsed 判据）', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        _wrap(
          TeamModeRow(
            enabled: true,
            modelEverUsed: false,
            onSetEnabled: (enabled) async {
              calls += 1;
              return null;
            },
          ),
        ),
      );
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text(TeamCopy.disableTitle), findsNothing);
      expect(calls, 1);
    });

    testWidgets('确认后写失败 ⇒ 行上留一句 mode.failed', (tester) async {
      await tester.pumpWidget(
        _wrap(
          TeamModeRow(
            enabled: false,
            modelEverUsed: false,
            onSetEnabled: (enabled) async => 'TEAM_LEAD_REQUIRED',
          ),
        ),
      );
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text(TeamCopy.failed('TEAM_LEAD_REQUIRED')), findsOneWidget);
    });

    testWidgets('外部锁定（没有当前模型）⇒ 开关不可点', (tester) async {
      await tester.pumpWidget(
        _wrap(
          TeamModeRow(
            enabled: false,
            modelEverUsed: false,
            disabled: true,
            onSetEnabled: (enabled) async => null,
          ),
        ),
      );
      final sw = tester.widget<Switch>(find.byType(Switch));
      expect(sw.onChanged, isNull);
    });
  });

  group('AppModel.setTeamEnabled', () {
    test('发 team.setEnabled（带幂等键）并重读投影，不乐观改状态', () async {
      final client = _TeamClient()
        ..projectionsReply = {
          'agentTeam': {'enabled': true, 'tasks': <Object?>[]},
        };
      final app = AppModel(client: client);
      addTearDown(app.dispose);
      await app.start();
      await app.refreshRepoInfo();
      await app.openSession('sid_A');

      final ok = await app.setTeamEnabled(true);
      expect(ok, isTrue);
      expect(client.setCalls.single['enabled'], isTrue);
      expect(client.setCalls.single['sid'], 'sid_A');
      expect(client.setCalls.single['requestId'], isNotNull, reason: '要带幂等键');
      // 真值来自重读后的投影
      expect(app.teamBoard?.enabled, isTrue);
    });

    test('电脑侧拒绝 ⇒ false 且 lastError 有原因', () async {
      final client = _TeamClient(failSet: true);
      final app = AppModel(client: client);
      addTearDown(app.dispose);
      await app.start();
      await app.refreshRepoInfo();
      await app.openSession('sid_A');
      final ok = await app.setTeamEnabled(true);
      expect(ok, isFalse);
      expect(app.lastError, isNotNull);
    });
  });
}
