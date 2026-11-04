/// 目标条这条链的回归（`goal` 投影 → 目标条 → `/goal …` 四个动作 → 重读投影）。
///
/// ## 为什么单独一组
///
/// 「目标」不是聊天消息，是输入框上方的一条 dock。手机上它有三条容易各走各的判据：
/// 1. **数据**：`session.projections` 的 `goal` 键，形状照
///    `packages/goal/goal/src/index.ts:61-77` 的 `goalProjectionSchema`；
/// 2. **可见性**：`phase == complete` 与 `null` 都**不画条**
///    （`ui-goal/src/client/GoalBar.tsx:86`）；
/// 3. **动作**：走斜杠命令（`/goal pause|resume|clear|edit`，
///    `command-goal/src/index.ts:16`），不是新方法。
///
/// 这一组把三条钉在**同一个文件**里，因为它们的错法长得一样：条子画出来但点不动、
/// 或者点下去发错一条命令行 —— 两种都"不报错"。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/goal.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:dsh_mobile/ui/goal_bar.dart';
import 'package:dsh_mobile/ui/queue_dock.dart';
import 'package:dsh_mobile/wire/reading.dart';
import 'package:dsh_mobile/wire/rpc/projections.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

class _GoalClient extends FakeSyncClient {
  _GoalClient({this.onCall});

  final Object? Function(String method, Map<String, Object?> params)? onCall;
  final calls =
      <({String method, Map<String, Object?> params, String? requestId})>[];
  final _sessions = <String, StreamController<SessionDelta>>{};

  /// `loadOlderHistory` 会拿到的那一页（默认空 = 没有更早的历史）。
  List<SessionEvent> pageEvents = const [];

  void emit(String sid, SessionEvent event) => _sessions
      .putIfAbsent(sid, () => StreamController<SessionDelta>.broadcast())
      .add(SessionDelta(sid: sid, events: [event], transient: const {}));

  int callsOf(String method) =>
      calls.where((call) => call.method == method).length;

  @override
  bool hasOlderHistory(String sid) => pageEvents.isNotEmpty;

  @override
  Future<SessionPage> page({
    required String sid,
    required int beforeSeq,
    int maxMessages = SyncClient.kHistoryPageMaxMessages,
    int minMessages = SyncClient.kHistoryPageMinMessages,
    int minTurns = SyncClient.kHistoryPageMinTurns,
  }) async => SessionPage(events: pageEvents, hasMore: false);

  @override
  ConnectionState get state => ConnectionState.serving;
  @override
  Stream<ConnectionState> get connection => const Stream.empty();
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
  Stream<SessionDelta> sessionUpdates(String sid) => _sessions
      .putIfAbsent(sid, () => StreamController<SessionDelta>.broadcast())
      .stream;

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    calls.add((method: method, params: params, requestId: requestId));
    return onCall?.call(method, params) as T;
  }
}

/// `goal` 投影的真形状（`goal/src/index.ts:62-77`：外面一层 + 里面那份快照）。
Map<String, Object?> goalProjection({
  String id = 'goal-1',
  int revision = 1,
  String objective = '把目标条接上手机',
  String phase = 'active',
  Map<String, Object?>? blockedReason,
  int maxGoalRounds = 256,
  int roundsStarted = 3,
}) {
  final snapshot = <String, Object?>{
    'id': id,
    'revision': revision,
    'objective': objective,
    'phase': phase,
    'maxGoalRounds': maxGoalRounds,
  };
  // 可选字段（`goal/src/index.ts:69`）：只在有值时出现 —— 线上就是这样。
  if (blockedReason != null) snapshot['blockedReason'] = blockedReason;
  return {
    'goal': snapshot,
    'roundsStarted': roundsStarted,
    'createdAt': 1700000000000,
    'updatedAt': 1700000005000,
  };
}

/// `session.projections` 的应答：`goal` 键装的就是那份投影 view（可能为 `null`）。
///
/// **要多包一层**：投影的 wire view 自己是 `{goal: {…}, roundsStarted, …}`，
/// 所以应答是 `{'goal': <view>}` —— 少了这层包裹，`parseGoalView` 读不到 `goal`。
Map<String, Object?> projectionsReply(Map<String, Object?>? goal) => {
  'goal': goal,
};

/// 一条命令的成功回执（`commands.execute` 的结算，`{matched, execution}`）。
Map<String, Object?> commandOk(String text) => {
  'matched': true,
  'execution': {
    'result': {'kind': 'success', 'text': text},
  },
};

Widget wrap(AppModel app) => MaterialApp(
  theme: DshTheme.dark(),
  home: Scaffold(
    body: Column(children: [GoalBar(app: app)]),
  ),
);

/// 打开一个会话并等第一包投影落地。
Future<AppModel> _opened(_GoalClient client, {String sid = 'sid_A'}) async {
  final app = AppModel(client: client);
  await app.start();
  await app.openSession(sid);
  return app;
}

void main() {
  group('parseGoalView：三态', () {
    test('null（线上没有目标）⇒ null', () {
      expect(parseGoalView(null), isNull);
    });

    test('完整快照 ⇒ 每个字段照线上读', () {
      final goal = parseGoalView(
        goalProjection(
          id: 'goal-7',
          revision: 3,
          objective: '把 dsh-mobile 的目标条接上',
          phase: 'blocked',
          blockedReason: {'code': 'rounds-exhausted', 'message': '轮次用完了'},
          maxGoalRounds: 12,
          roundsStarted: 12,
        ),
      )!;
      expect(goal.id, 'goal-7');
      expect(goal.revision, 3);
      expect(goal.objective, '把 dsh-mobile 的目标条接上');
      expect(goal.phase, GoalPhase.blocked);
      expect(goal.blockedReason?.code, 'rounds-exhausted');
      expect(goal.blockedReason?.message, '轮次用完了');
      expect(goal.maxGoalRounds, 12);
      expect(goal.roundsStarted, 12);
      expect(goal.createdAt, 1700000000000);
      expect(goal.updatedAt, 1700000005000);
    });

    test('形状不对 ⇒ null（不猜一个半懂的目标）', () {
      // 外层不是对象 / 没有 goal / goal 不是对象
      expect(parseGoalView('x'), isNull);
      expect(parseGoalView(<String, Object?>{}), isNull);
      expect(parseGoalView({'goal': 'x'}), isNull);
      // 必填字段缺失
      for (final missing in [
        'id',
        'revision',
        'objective',
        'phase',
        'maxGoalRounds',
      ]) {
        final payload = goalProjection();
        (payload['goal']! as Map<String, Object?>).remove(missing);
        expect(parseGoalView(payload), isNull, reason: '缺 $missing 就不该解析出目标');
      }
      // 顶层三个派生字段也必填
      for (final missing in ['roundsStarted', 'createdAt', 'updatedAt']) {
        final payload = goalProjection()..remove(missing);
        expect(parseGoalView(payload), isNull, reason: '缺 $missing 就不该解析出目标');
      }
      // 阶段不在四值里
      expect(parseGoalView(goalProjection(phase: 'running')), isNull);
      // 空目标 / 空 id / 非法 revision
      expect(parseGoalView(goalProjection(objective: '')), isNull);
      expect(parseGoalView(goalProjection(id: '')), isNull);
      expect(parseGoalView(goalProjection(revision: 0)), isNull);
    });

    test('blockedReason 不是 {code, message} ⇒ 当没给原因，目标本身照旧', () {
      // 它是 wire schema 里的可选字段（`goal/src/index.ts:69`），
      // 缺了不该让整条目标消失 —— 条子仍然画「受阻的目标」，只是没有 title。
      final goal = parseGoalView(
        goalProjection(phase: 'blocked', blockedReason: {'code': 'only-code'}),
      );
      expect(goal, isNotNull);
      expect(goal!.blockedReason, isNull);
    });

    test('complete 解析得出，但 visible 为 false（不画条是界面判据）', () {
      final goal = parseGoalView(goalProjection(phase: 'complete'))!;
      expect(goal.phase, GoalPhase.complete);
      expect(goal.visible, isFalse);
      expect(parseGoalView(goalProjection(phase: 'paused'))!.visible, isTrue);
    });
  });

  group('AppModel.goal：只解析当前会话那一包', () {
    test('投影带 goal ⇒ 读得到；不带 ⇒ null', () async {
      final withGoal = await _opened(
        _GoalClient(
          onCall: (m, p) => m == 'session.projections'
              ? projectionsReply(goalProjection())
              : null,
        ),
      );
      expect(withGoal.goal?.objective, '把目标条接上手机');
      withGoal.dispose();

      final without = await _opened(
        _GoalClient(
          onCall: (m, p) =>
              m == 'session.projections' ? {'title': '没有目标的会话'} : null,
        ),
      );
      expect(without.goal, isNull, reason: '键缺席 = 没有目标（老连接器同一条）');
      without.dispose();
    });

    test('goal 是 null（清掉了）⇒ null', () async {
      final app = await _opened(
        _GoalClient(
          onCall: (m, p) => m == 'session.projections' ? {'goal': null} : null,
        ),
      );
      expect(app.goal, isNull);
      app.dispose();
    });
  });

  group('四个动作发出去的命令行', () {
    testWidgets('暂停 ⇒ /goal pause', (tester) async {
      final client = _GoalClient(
        onCall: (m, p) => switch (m) {
          'session.projections' => projectionsReply(goalProjection()),
          'command.execute' => commandOk('Goal paused'),
          _ => null,
        },
      );
      final app = await _opened(client);
      await tester.pumpWidget(wrap(app));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(kGoalPauseLabel));
      await tester.pumpAndSettle();
      final call = client.calls.lastWhere((c) => c.method == 'command.execute');
      expect(call.params['line'], '/goal pause');
      expect(call.params['sid'], 'sid_A');
      expect(call.requestId, isNotNull, reason: '写操作必须带幂等键');
      app.dispose();
    });

    testWidgets('恢复 ⇒ /goal resume', (tester) async {
      final client = _GoalClient(
        onCall: (m, p) => switch (m) {
          'session.projections' => projectionsReply(
            goalProjection(phase: 'paused'),
          ),
          'command.execute' => commandOk('Goal resumed'),
          _ => null,
        },
      );
      final app = await _opened(client);
      await tester.pumpWidget(wrap(app));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(kGoalResumeLabel));
      await tester.pumpAndSettle();
      final call = client.calls.lastWhere((c) => c.method == 'command.execute');
      expect(call.params['line'], '/goal resume');
      app.dispose();
    });

    testWidgets('清除 ⇒ /goal clear', (tester) async {
      final client = _GoalClient(
        onCall: (m, p) => switch (m) {
          'session.projections' => projectionsReply(goalProjection()),
          'command.execute' => commandOk('Goal cleared.'),
          _ => null,
        },
      );
      final app = await _opened(client);
      await tester.pumpWidget(wrap(app));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(kGoalClearLabel));
      await tester.pumpAndSettle();
      final call = client.calls.lastWhere((c) => c.method == 'command.execute');
      expect(call.params['line'], '/goal clear');
      app.dispose();
    });

    testWidgets('编辑：行内输入框 → 保存发 `/goal edit <objective>`，条子退回常态', (
      tester,
    ) async {
      final client = _GoalClient(
        onCall: (m, p) => switch (m) {
          'session.projections' => projectionsReply(goalProjection()),
          'command.execute' => commandOk('Goal updated'),
          _ => null,
        },
      );
      final app = await _opened(client);
      await tester.pumpWidget(wrap(app));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(kGoalEditLabel));
      await tester.pumpAndSettle();
      // **行内输入框，不弹 sheet**：当前正文已经装进去了。
      final field = find.byType(TextField);
      expect(field, findsOneWidget);
      expect(tester.widget<TextField>(field).controller?.text, '把目标条接上手机');

      await tester.enterText(field, '改成新的目标');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(kGoalSaveLabel));
      await tester.pumpAndSettle();

      final call = client.calls.lastWhere((c) => c.method == 'command.execute');
      expect(call.params['line'], '/goal edit 改成新的目标');
      expect(find.byType(TextField), findsNothing, reason: '保存成功就退出编辑');
      expect(find.byTooltip(kGoalEditLabel), findsOneWidget);
      app.dispose();
    });

    testWidgets('编辑：空草稿不发命令（保存钮置灰）', (tester) async {
      final client = _GoalClient(
        onCall: (m, p) => switch (m) {
          'session.projections' => projectionsReply(goalProjection()),
          'command.execute' => commandOk('Goal updated'),
          _ => null,
        },
      );
      final app = await _opened(client);
      await tester.pumpWidget(wrap(app));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(kGoalEditLabel));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '   ');
      await tester.pumpAndSettle();

      final save = find.descendant(
        of: find.byTooltip(kGoalSaveLabel),
        matching: find.byType(InkWell),
      );
      expect(tester.widget<InkWell>(save).onTap, isNull, reason: '空草稿点不动');
      await tester.tap(find.byTooltip(kGoalSaveLabel));
      await tester.pumpAndSettle();
      expect(client.callsOf('command.execute'), 0);
      app.dispose();
    });

    testWidgets('清除成功后立刻不画（不等投影重读那一趟）', (tester) async {
      final client = _GoalClient(
        onCall: (m, p) => switch (m) {
          // 投影**不变**（模拟重读还没回来）：条子仍要立刻消失。
          'session.projections' => projectionsReply(goalProjection()),
          'command.execute' => commandOk('Goal cleared.'),
          _ => null,
        },
      );
      final app = await _opened(client);
      await tester.pumpWidget(wrap(app));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('goal-bar')), findsOneWidget);

      await tester.tap(find.byTooltip(kGoalClearLabel));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('goal-bar')),
        findsNothing,
        reason: '清掉之后条子不该还挂着（用户会以为没清掉而再点一次）',
      );
      app.dispose();
    });

    testWidgets('编辑：行内输入框抢到焦点（输入栏已握着焦点时 autofocus 会静默失效）', (tester) async {
      // 真机 2026-11-04 抓到的那一条：点「编辑目标」后打的字全进了消息输入框。
      // 根因不在这一层 —— `TextField.autofocus` 只在"所在 FocusScope 还没有
      // 焦点子节点"时生效（`focus_manager.dart:158-171` 的 `applyIfValid`），
      // 而输入栏永远先握着焦点。所以这里**钉住"焦点真的换了"**。
      final client = _GoalClient(
        onCall: (m, p) => switch (m) {
          'session.projections' => projectionsReply(goalProjection()),
          _ => null,
        },
      );
      final app = await _opened(client);
      final composerFocus = FocusNode();
      addTearDown(composerFocus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: DshTheme.dark(),
          home: Scaffold(
            body: Column(
              children: [
                GoalBar(app: app),
                // 一个"输入栏"替身：它先握着焦点，正是真机上的样子。
                TextField(focusNode: composerFocus),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      composerFocus.requestFocus();
      await tester.pumpAndSettle();
      expect(composerFocus.hasFocus, isTrue, reason: '先让输入栏握着焦点');

      await tester.tap(find.byTooltip(kGoalEditLabel));
      await tester.pumpAndSettle();

      final draft = tester.widget<TextField>(
        find.byKey(const Key('goal-draft')),
      );
      expect(draft.focusNode?.hasFocus, isTrue, reason: '编辑框必须拿到焦点');
      expect(composerFocus.hasFocus, isFalse, reason: '输入栏必须让位');
      app.dispose();
    });

    testWidgets('编辑：取消不发命令，正文不写回', (tester) async {
      final client = _GoalClient(
        onCall: (m, p) => switch (m) {
          'session.projections' => projectionsReply(goalProjection()),
          'command.execute' => commandOk('Goal updated'),
          _ => null,
        },
      );
      final app = await _opened(client);
      await tester.pumpWidget(wrap(app));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(kGoalEditLabel));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '不保存的草稿');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(kGoalCancelLabel));
      await tester.pumpAndSettle();

      expect(client.callsOf('command.execute'), 0, reason: '取消不碰电脑侧');
      expect(find.byType(TextField), findsNothing);
      expect(find.text('把目标条接上手机'), findsOneWidget, reason: '取消不写回');
      app.dispose();
    });

    testWidgets('编辑：目标里的换行被折成空格（命令行不许带换行）', (tester) async {
      // 连接器在拼命令行之前就拒收带换行的 `line`
      // （`connector/src/handlers.ts:1242-1246`）。目标正文**可能带换行**：
      // DSH 的 `/goal` 从 Web 的多行输入框收到什么就是什么，投影原样带下来 ——
      // 不折的话保存必然失败，而用户看到的是协议措辞。
      final client = _GoalClient(
        onCall: (m, p) => switch (m) {
          'session.projections' => projectionsReply(
            goalProjection(objective: '第一行\n第二行'),
          ),
          'command.execute' => commandOk('Goal updated'),
          _ => null,
        },
      );
      final app = await _opened(client);
      await tester.pumpWidget(wrap(app));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(kGoalEditLabel));
      await tester.pumpAndSettle();
      // 输入框是单行：这一格要拼进一条命令，摆一个能敲换行的框等于让用户
      // 打出永远存不上的目标。
      expect(tester.widget<TextField>(find.byType(TextField)).maxLines, 1);
      await tester.tap(find.byTooltip(kGoalSaveLabel));
      await tester.pumpAndSettle();

      final call = client.calls.lastWhere((c) => c.method == 'command.execute');
      final line = call.params['line']! as String;
      expect(line.contains('\n'), isFalse, reason: '命令行里不许有换行');
      expect(line, '/goal edit 第一行 第二行');
      app.dispose();
    });

    testWidgets('失败：电脑上没有 /goal 命令 ⇒ 说清，不静默', (tester) async {
      final client = _GoalClient(
        onCall: (m, p) => switch (m) {
          'session.projections' => projectionsReply(goalProjection()),
          // DSH 的 `commands.execute` 对认不出的命令回 `undefined`。
          'command.execute' => const {'matched': false},
          _ => null,
        },
      );
      final app = await _opened(client);
      await tester.pumpWidget(wrap(app));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(kGoalPauseLabel));
      await tester.pumpAndSettle();
      expect(find.textContaining('没有 /goal 命令'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      app.dispose();
    });

    testWidgets('失败：电脑侧没有给结论 ⇒ 说清，不静默', (tester) async {
      final client = _GoalClient(
        onCall: (m, p) => switch (m) {
          'session.projections' => projectionsReply(goalProjection()),
          // 应答形状认不出（`executeCommand` 回 null，原因在 lastError）。
          'command.execute' => null,
          _ => null,
        },
      );
      final app = await _opened(client);
      await tester.pumpWidget(wrap(app));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(kGoalPauseLabel));
      await tester.pumpAndSettle();
      expect(find.textContaining('目标操作失败：'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      app.dispose();
    });

    testWidgets('失败按 CommandOutcome 的三段式说（原文照显）', (tester) async {
      final client = _GoalClient(
        onCall: (m, p) => switch (m) {
          'session.projections' => projectionsReply(goalProjection()),
          // 电脑侧拒绝了这次暂停（例如轮次已用完）。
          'command.execute' => {
            'matched': true,
            'execution': {
              'result': {
                'kind': 'error',
                'text': 'The goal command is not valid',
              },
            },
          },
          _ => null,
        },
      );
      final app = await _opened(client);
      await tester.pumpWidget(wrap(app));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip(kGoalPauseLabel));
      await tester.pumpAndSettle();
      // 电脑侧的原话照显（不抄一份自己的中文）。
      expect(find.text('The goal command is not valid'), findsOneWidget);
      // 让浮层自己收掉（否则 5 秒的定时器会留在假时钟里）。
      await tester.pump(const Duration(seconds: 6));
      app.dispose();
    });
  });

  group('阶段 / 动作可见性', () {
    testWidgets('active：暂停在、恢复不在；标签「进行中的目标」；36dp 高', (tester) async {
      final app = await _opened(
        _GoalClient(
          onCall: (m, p) => m == 'session.projections'
              ? projectionsReply(goalProjection())
              : null,
        ),
      );
      await tester.pumpWidget(wrap(app));
      await tester.pumpAndSettle();

      expect(find.text('进行中的目标'), findsOneWidget);
      expect(find.text('把目标条接上手机'), findsOneWidget);
      expect(find.byTooltip(kGoalPauseLabel), findsOneWidget);
      expect(find.byTooltip(kGoalResumeLabel), findsNothing);
      expect(find.byTooltip(kGoalEditLabel), findsOneWidget);
      expect(find.byTooltip(kGoalClearLabel), findsOneWidget);
      // **量出来的必须是 36**，不是"等于那个常量"：常量是我们要钉的值，
      // 拿它跟自己比等于没测（改成 40 也照样绿）。DSH `.bar { height: 36px }`
      // 在 `ui-goal/src/client/GoalBar.module.css:29`。
      expect(kGoalBarHeight, 36, reason: '常量本身也不许漂');
      expect(
        tester.getSize(find.byKey(const Key('goal-bar'))).height,
        36,
        reason: 'DSH 的 .bar 是 36（标准字号下 minHeight 就是实际高度）',
      );
      app.dispose();
    });

    testWidgets('paused：恢复在、暂停不在；标签「已暂停的目标」', (tester) async {
      final app = await _opened(
        _GoalClient(
          onCall: (m, p) => m == 'session.projections'
              ? projectionsReply(goalProjection(phase: 'paused'))
              : null,
        ),
      );
      await tester.pumpWidget(wrap(app));
      await tester.pumpAndSettle();

      expect(find.text('已暂停的目标'), findsOneWidget);
      expect(find.byTooltip(kGoalPauseLabel), findsNothing);
      expect(find.byTooltip(kGoalResumeLabel), findsOneWidget);
      app.dispose();
    });

    testWidgets('blocked：标签「受阻的目标」+ 整条 title = blockedReason.message', (
      tester,
    ) async {
      final app = await _opened(
        _GoalClient(
          onCall: (m, p) => m == 'session.projections'
              ? projectionsReply(
                  goalProjection(
                    phase: 'blocked',
                    blockedReason: {
                      'code': 'rounds-exhausted',
                      'message': '这一轮的目标轮次已经用完',
                    },
                  ),
                )
              : null,
        ),
      );
      await tester.pumpWidget(wrap(app));
      await tester.pumpAndSettle();

      expect(find.text('受阻的目标'), findsOneWidget);
      // 桌面是 HTML 的 `title`，触屏同一件事是长按（Tooltip）。
      expect(find.byTooltip('这一轮的目标轮次已经用完'), findsOneWidget);
      expect(find.byTooltip(kGoalResumeLabel), findsOneWidget);
      app.dispose();
    });

    testWidgets('complete / null：整条不画', (tester) async {
      final complete = await _opened(
        _GoalClient(
          onCall: (m, p) => m == 'session.projections'
              ? projectionsReply(goalProjection(phase: 'complete'))
              : null,
        ),
      );
      await tester.pumpWidget(wrap(complete));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('goal-bar')), findsNothing);
      expect(find.text('进行中的目标'), findsNothing);
      complete.dispose();

      final none = await _opened(
        _GoalClient(
          onCall: (m, p) => m == 'session.projections' ? {'goal': null} : null,
        ),
      );
      await tester.pumpWidget(wrap(none));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('goal-bar')), findsNothing);
      none.dispose();
    });
  });

  group('刷新：goal/change 到达就重读投影', () {
    test('收到 goal/change ⇒ 再读一次 session.projections，条子跟上', () async {
      var phase = 'active';
      final client = _GoalClient(
        onCall: (m, p) => m == 'session.projections'
            ? projectionsReply(goalProjection(phase: phase))
            : null,
      );
      final app = await _opened(client);
      final before = client.callsOf('session.projections');
      final itemsBefore = app.items.length;

      // 电脑侧暂停了目标（`/goal pause` 落一条 `goal/change`）。
      phase = 'paused';
      client.emit(
        'sid_A',
        const SessionEvent(
          itemId: 'goal/change:9',
          type: 'goal/change',
          seq: 9,
          time: 1700000009000,
          data: {'operation': 'pause'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        client.callsOf('session.projections'),
        before + 1,
        reason: '投影只在打开会话时读过一次，不重读就永远停在旧目标上',
      );
      expect(app.goal?.phase, GoalPhase.paused);
      expect(app.items.length, itemsBefore, reason: 'goal/change 不是会话内容，不落条目');
      app.dispose();
    });

    test('别的会话的 goal/change 不触发当前会话的重读', () async {
      final client = _GoalClient(
        onCall: (m, p) => m == 'session.projections'
            ? projectionsReply(goalProjection())
            : null,
      );
      final app = await _opened(client); // sid_A
      // **必须先真的打开 sid_B**：`sessionUpdates` 是按会话建的广播流，
      // 没人监听时 `emit` 会被丢掉 —— 那样这条用例恒真（第一版就是这样，
      // 评审 2026-11-04 抓到）。打开 B 再切回 A，B 的订阅仍在。
      await app.openSession('sid_B');
      await app.openSession('sid_A');
      final before = client.callsOf('session.projections');
      client.emit(
        'sid_B',
        const SessionEvent(
          itemId: 'goal/change:4',
          type: 'goal/change',
          seq: 4,
          time: 0,
          data: {'operation': 'pause'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(client.callsOf('session.projections'), before);
      app.dispose();
    });
  });

  group('形状漂移：留声，不吞', () {
    test('goal 键在但解析不出 ⇒ 整包照收 + 计一次数', () {
      WireDiagnostics.reset();
      final value = valueOrReport(
        readSessionProjections({
          'goal': {'goal': 'x'},
          'title': '标题还在',
        }),
        'session.projections',
      );
      expect(value, isNotNull, reason: '整包照收，只有那一格是 null');
      expect(value!.goal, isNull);
      expect(value.title, '标题还在');
      expect(WireDiagnostics.badCount, 1, reason: '形状漂了要留声，别与"没有目标"混成一档');
      WireDiagnostics.reset();
    });

    test('goal 是 null（没有目标）⇒ 不计数', () {
      WireDiagnostics.reset();
      final value = valueOrReport(
        readSessionProjections({'goal': null}),
        'session.projections',
      );
      expect(value!.goal, isNull);
      expect(WireDiagnostics.badCount, 0, reason: '线上合法的"没有目标"不是漂移');
      WireDiagnostics.reset();
    });
  });

  group('翻页：goal/change 也不落条目', () {
    test('往回翻到含 goal/change 的一页 ⇒ 条目数不变', () async {
      final client = _GoalClient(
        onCall: (m, p) => m == 'session.projections'
            ? projectionsReply(goalProjection())
            : null,
      );
      final app = await _opened(client);
      // 先有一条内容，`loadOlderHistory` 才有切点。
      client.emit(
        'sid_A',
        const SessionEvent(
          itemId: 'm:1',
          type: 'user/message',
          seq: 1,
          time: 0,
          data: {
            'id': '1',
            'role': 'user',
            'source': {'kind': 'user'},
            'content': [
              {'type': 'text', 'text': 'hi'},
            ],
          },
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(app.items.length, 1);

      client.pageEvents = const [
        SessionEvent(
          itemId: 'goal/change:2',
          type: 'goal/change',
          seq: 2,
          time: 0,
          data: {'operation': 'pause'},
        ),
      ];
      expect(await app.loadOlderHistory('sid_A'), isTrue, reason: '页里有事件');
      expect(app.items.length, 1, reason: '状态事件不落条目（与收帧同一条规则）');
      app.dispose();
    });
  });

  group('挂在 chat_page 上：目标条在排队条之上', () {
    testWidgets('两条 dock 同时在场时的上下顺序', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      final client = _GoalClient(
        onCall: (m, p) => switch (m) {
          'session.list' => {'sessions': <Object?>[]},
          'session.projections' => {
            ...projectionsReply(goalProjection()),
            // 排队条要有东西才画（空队列整条不占位）。
            'inbox': {
              'next-turn': [
                {
                  'id': 'msg-queued-1',
                  'role': 'user',
                  'source': {'kind': 'user'},
                  'content': [
                    {'type': 'text', 'text': '排着的那句'},
                  ],
                },
              ],
              'next-step': <Object?>[],
            },
          },
          _ => null,
        },
      );
      final app = await _opened(client);
      await tester.pumpWidget(
        MaterialApp(
          theme: DshTheme.dark(),
          home: ChatPage(
            app: app,
            paired: true,
            onOpenDrawer: () {},
            onNewSession: () {},
            drawer: const Drawer(child: SizedBox()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(GoalBar), findsOneWidget);
      expect(find.byType(QueueDock), findsOneWidget);
      final goal = tester.getRect(find.byType(GoalBar));
      final queue = tester.getRect(find.byType(QueueDock));
      expect(
        goal.bottom,
        lessThanOrEqualTo(queue.top),
        reason: '目标条在排队条之上（DSH 的 dock 顺序：目标 order 10）',
      );
      app.dispose();
    });
  });
}
