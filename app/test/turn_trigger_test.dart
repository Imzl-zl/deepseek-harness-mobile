/// 唤醒新一轮的**非人消息**要按 DSH 的 `turn-trigger` 显示，不是笼统的「上下文注入」。
///
/// ## 判据出处
///
/// - 分类：`ui-chat/src/client/conversation-nodes/message.ts:96-111`
///   非 `source.kind === 'user'` 的 `user/message` → `context` 节点；
///   其中被 `inbox-next-turn` claim 掉的那条是 `waking` → 渲染成 `turn-trigger`。
/// - 标题：`chat/turn-trigger.ts:29-70` 的 kind → locale key，
///   `locale.ts:53-62` 的 zh 值（`subagent-settled` = 「子任务状态更新」等）。
/// - 形状：`TurnTriggerNodeView.tsx:39-42` 只画标题 + 时间 + 箭头，
///   **没有** `ContextInjectionRow` 那个「· 生产者」尾巴。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/data/projection.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_turns.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 只关心"推一批事件进来"的替身（其余一律 relayOffline）。
class _Client extends FakeSyncClient {
  final StreamController<SessionDelta> updates =
      StreamController<SessionDelta>.broadcast();

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
  Stream<SessionDelta> sessionUpdates(String sid) => updates.stream;
  @override
  Future<void> unsubscribe(String sid) async {}

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async => throw const ProtocolException(ErrorCode.relayOffline, '测试不连');
}

MessageItem _project({required bool waking, String kind = 'subagent-settled'}) {
  final projection = projectEvent(
    type: 'user/message',
    seq: 10,
    time: 1,
    waking: waking,
    data: {
      'id': 'm1',
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'Background subagent finished.'},
      ],
      'source': {'kind': kind, 'form': 'notice'},
    },
  );
  return projection.items.single as MessageItem;
}

void main() {
  test('被 next-turn claim 掉的非人消息：标题是「子任务状态更新」，没有生产者尾巴', () {
    final item = _project(waking: true);
    expect(item.systemLabel, '子任务状态更新');
    expect(item.systemHint, isNull);
    // 唤醒通知有自己的标记与图标（DSH `TurnTriggerNodeView.tsx:15-26,44-47`）。
    expect(item.trigger, isTrue);
    expect(item.systemIcon, 'agentPreset');
  });

  test('只是注入（没唤醒新一轮）：仍是「上下文注入 · kind」', () {
    final item = _project(waking: false);
    expect(item.systemLabel, '上下文注入');
    expect(item.systemHint, 'subagent-settled');
    expect(item.trigger, isFalse);
    expect(item.systemIcon, isNull);
  });

  test('kind → 图标逐条照 DSH 的 TRIGGER_ICONS', () {
    expect(turnTriggerIcon('goal'), 'goal');
    expect(turnTriggerIcon('agent-message'), 'paperPlane');
    expect(turnTriggerIcon('team-message'), 'agentPreset');
    expect(turnTriggerIcon('subagent-settled'), 'agentPreset');
    expect(turnTriggerIcon('webhook'), 'globe');
    expect(turnTriggerIcon('schedule'), 'clock');
    expect(turnTriggerIcon('tool-jobs'), 'queue');
    expect(turnTriggerIcon('cordis-host-runner'), 'cordisPlugin');
    expect(turnTriggerIcon('unknown'), 'contextInjection');
  });

  testWidgets('唤醒通知展开后多一句「这条通知触发了本轮回复。」', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: const Scaffold(
          body: SystemTurn(
            'Background subagent finished.',
            label: '子任务状态更新',
            trigger: true,
            icon: 'agentPreset',
          ),
        ),
      ),
    );
    expect(find.text('这条通知触发了本轮回复。'), findsNothing);

    await tester.tap(find.text('子任务状态更新'));
    await tester.pump();

    expect(find.text('这条通知触发了本轮回复。'), findsOneWidget);
    expect(find.text('Background subagent finished.'), findsOneWidget);
  });

  testWidgets('普通注入展开后**没有**那句说明', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: const Scaffold(
          body: SystemTurn(
            'runtime context',
            label: '上下文注入',
            hint: 'subagent-settled',
          ),
        ),
      ),
    );
    await tester.tap(find.text('上下文注入'));
    await tester.pump();
    expect(find.text('这条通知触发了本轮回复。'), findsNothing);
  });

  test('kind → 标题逐条照 DSH 的 zh 文案', () {
    expect(turnTriggerTitle('goal'), '继续执行目标');
    expect(turnTriggerTitle('agent-message'), '收到任务消息');
    expect(turnTriggerTitle('team-message'), '收到团队消息');
    expect(turnTriggerTitle('subagent-settled'), '子任务状态更新');
    expect(turnTriggerTitle('webhook'), '收到外部事件');
    expect(turnTriggerTitle('schedule'), '自动化任务');
    expect(turnTriggerTitle('tool-jobs'), '后台任务状态更新');
    expect(turnTriggerTitle('cordis-host-runner'), '插件状态更新');
    expect(turnTriggerTitle('something-new'), '收到执行请求');
    expect(turnTriggerTitle(null), '收到执行请求');
  });

  test('插话判定不受影响（source.kind == user 仍是用户气泡）', () {
    final projection = projectEvent(
      type: 'user/message',
      seq: 11,
      time: 1,
      steering: true,
      data: {
        'id': 'm2',
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '插一句'},
        ],
        'source': {'kind': 'user'},
      },
    );
    final item = projection.items.single as MessageItem;
    expect(item.role, MessageRole.user);
    expect(item.steering, isTrue);
    expect(item.systemLabel, isNull);
  });

  test('SessionDelta 的类型字段可构造（这条用例只钉形状，不测网络）', () {
    const event = SessionEvent(
      itemId: 'm1',
      type: 'user/message',
      seq: 1,
      time: 0,
      data: {'id': 'm1'},
    );
    const delta = SessionDelta(
      sid: 's1',
      events: [event],
      transient: <String, Object?>{},
    );
    expect(delta.events.single.itemId, 'm1');
  });

  test('端到端：splice 把 id 从 next-turn claim 掉 → 那条非人消息标成唤醒', () async {
    final client = _Client();
    final app = AppModel(client: client);
    addTearDown(app.dispose);
    await app.openSession('s1');
    await Future<void>.delayed(Duration.zero);

    // DSH 的次序：先 `agent/inbox/spliced`（next-turn 把这条 claim 走），
    // 随后这条 `user/message` 才到（`continuation-messages.ts` 注入）。
    client.updates.add(
      const SessionDelta(
        sid: 's1',
        transient: <String, Object?>{},
        events: [
          // ① 先排进 next-turn 队列。
          SessionEvent(
            itemId: 'inbox-1',
            type: 'agent/inbox/spliced',
            seq: 1,
            time: 1,
            data: {
              'target': 'next-turn',
              'start': 0,
              'removedCount': 0,
              'inserted': [
                {'id': 'm1'},
              ],
              'outcome': 'spliced',
            },
          ),
          // ② 被 claim 掉（removed 部分就是"唤醒这一轮的那条"）。
          SessionEvent(
            itemId: 'inbox-2',
            type: 'agent/inbox/spliced',
            seq: 2,
            time: 2,
            data: {
              'target': 'next-turn',
              'start': 0,
              'removedCount': 1,
              'inserted': <Object?>[],
              'outcome': 'claimed',
            },
          ),
          SessionEvent(
            itemId: 'm1',
            type: 'user/message',
            seq: 3,
            time: 3,
            data: {
              'id': 'm1',
              'role': 'user',
              'content': [
                {'type': 'text', 'text': 'Background subagent finished.'},
              ],
              'source': {'kind': 'subagent-settled', 'form': 'notice'},
            },
          ),
        ],
      ),
    );
    await Future<void>.delayed(Duration.zero);

    final item = app.items.whereType<MessageItem>().single;
    expect(item.systemLabel, '子任务状态更新');
    expect(item.systemHint, isNull);
  });

  // ---------------------------------------------------------------------------
  // `idleSteer`：真机上子智能体收尾走的是 **next-step**，不是 next-turn
  // （2026-10-28 真机日志 `session-bc31f325` 的 seq=114/115/116/117/118 与
  // 120/123/124/125）。判据照 DSH `lib/client.js:9857-9866`：消息落在**本轮第 1 步**、
  // `next-step` 的 claim 晚于 `turn/start`、`next-turn` 的 claim 早于它、
  // 那批 claim 里没有人发的消息 —— 这时它唤醒了一轮。
  // ---------------------------------------------------------------------------

  /// 一批"空闲时被 next-step claim 走"的事件（seq 1..5，与真机同序）。
  SessionDelta idleSteerBatch({
    required String kind,
    required int step,
    List<Map<String, Object?>> queued = const [
      {
        'id': 'm1',
        'source': {'kind': 'agent-message'},
      },
    ],
  }) => SessionDelta(
    sid: 's1',
    transient: const <String, Object?>{},
    events: [
      SessionEvent(
        itemId: 'inbox-1',
        type: 'agent/inbox/spliced',
        seq: 1,
        time: 1,
        data: {
          'target': 'next-step',
          'start': 0,
          'removedCount': 0,
          'inserted': queued,
        },
      ),
      const SessionEvent(
        itemId: 'turn-1',
        type: 'turn/start',
        seq: 2,
        time: 2,
        data: {'turn': 1},
      ),
      const SessionEvent(
        itemId: 'inbox-2',
        type: 'agent/inbox/spliced',
        seq: 3,
        time: 3,
        data: {
          'target': 'next-step',
          'start': 0,
          'removedCount': 1,
          'inserted': <Object?>[],
        },
      ),
      SessionEvent(
        itemId: 'step-1',
        type: 'step/start',
        seq: 4,
        time: 4,
        data: {'turn': 1, 'step': step},
      ),
      SessionEvent(
        itemId: 'm1',
        type: 'user/message',
        seq: 5,
        time: 5,
        data: {
          'id': 'm1',
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'Agent 6cebf3b3 sent a message: 统计完成'},
          ],
          'source': {'kind': kind, 'form': 'relay'},
        },
      ),
    ],
  );

  Future<MessageItem> projectBatch(
    SessionDelta batch, {
    required void Function(AppModel app) dispose,
  }) async {
    final client = _Client();
    final app = AppModel(client: client);
    dispose(app);
    await app.openSession('s1');
    await Future<void>.delayed(Duration.zero);
    client.updates.add(batch);
    await Future<void>.delayed(Duration.zero);
    return app.items.whereType<MessageItem>().single;
  }

  test(
    'idleSteer：next-step 在 turn/start 后被 claim、消息落在第 1 步 → 「收到任务消息」',
    () async {
      final item = await projectBatch(
        idleSteerBatch(kind: 'agent-message', step: 1),
        dispose: (app) => addTearDown(app.dispose),
      );
      expect(item.systemLabel, '收到任务消息');
      expect(item.systemHint, isNull);
      expect(item.trigger, isTrue);
      expect(item.systemIcon, 'paperPlane');
    },
  );

  test('idleSteer 不成立：同一条消息落在第 2 步 → 仍是「上下文注入 · agent-message」', () async {
    final item = await projectBatch(
      idleSteerBatch(kind: 'agent-message', step: 2),
      dispose: (app) => addTearDown(app.dispose),
    );
    expect(item.systemLabel, '上下文注入');
    expect(item.systemHint, 'agent-message');
    expect(item.trigger, isFalse);
  });

  test('idleSteer 不成立：那批 claim 里有**人**发的消息 → 不算唤醒', () async {
    final item = await projectBatch(
      idleSteerBatch(
        kind: 'agent-message',
        step: 1,
        queued: const [
          {
            'id': 'h1',
            'source': {'kind': 'user'},
          },
          {
            'id': 'm1',
            'source': {'kind': 'agent-message'},
          },
        ],
      ),
      dispose: (app) => addTearDown(app.dispose),
    );
    expect(item.systemLabel, '上下文注入');
    expect(item.systemHint, 'agent-message');
    expect(item.trigger, isFalse);
  });

  test('idleSteer：子智能体收尾（subagent-settled）走同一条 → 「子任务状态更新」', () async {
    final item = await projectBatch(
      idleSteerBatch(kind: 'subagent-settled', step: 1),
      dispose: (app) => addTearDown(app.dispose),
    );
    expect(item.systemLabel, '子任务状态更新');
    expect(item.systemHint, isNull);
    expect(item.trigger, isTrue);
    expect(item.systemIcon, 'agentPreset');
  });
}
