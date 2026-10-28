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
  });

  test('只是注入（没唤醒新一轮）：仍是「上下文注入 · kind」', () {
    final item = _project(waking: false);
    expect(item.systemLabel, '上下文注入');
    expect(item.systemHint, 'subagent-settled');
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
}
