/// 会话渲染这条链的回归（事件 → 条目投影 → 可见内容）。
///
/// ## 为什么单独一组
///
/// 2026-10-17 之前对话流只渲染"纯文本消息 + 工具名一行"：
/// 助手的**思考过程**（`{type:'reasoning'}` 块）、工具**结果明细**、
/// 用户消息的**附件**、**插话**标记全部丢掉。形状判据全部来自真实会话日志
/// （`~/.dsh/sessions/**/session.v4.jsonl.zstd` 按帧解压后所见）。
///
/// 另两条结构性修复也在这里钉住：
/// - **一条坏事件不再炸掉整批**（此前 `itemIdOf` 抛一个 StateError，
///   整个 delta 的条目全部丢失 —— "会话打开了但一条都不渲染"）；
/// - **插话判定**逐字移植 DSH Web 的 `SteeringHistory`
///   （`ui-chat/src/client/model/steering-history.ts`）。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/data/projection.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/ui/chat_turns.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'fake_sync_client.dart';

class _RenderClient extends FakeSyncClient {
  _RenderClient({this.onCall});

  final Object? Function(String method, Map<String, Object?> params)? onCall;
  final _jobs = StreamController<JobFrame>.broadcast();
  final Map<String, StreamController<SessionDelta>> _sessions = {};

  void emit(String sid, List<SessionEvent> events) {
    _sessions
        .putIfAbsent(sid, () => StreamController<SessionDelta>.broadcast())
        .add(
          SessionDelta(
            sid: sid,
            events: events,
            transient: const <String, Object?>{},
          ),
        );
  }

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
  Stream<SessionDelta> sessionUpdates(String sid) => _sessions
      .putIfAbsent(sid, () => StreamController<SessionDelta>.broadcast())
      .stream;

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async => onCall?.call(method, params) as T;
}

/// 一条 `user/message`（真日志形状：data 就是消息，带 id）。
SessionEvent _userEvent({
  required int seq,
  required String id,
  required List<Map<String, Object?>> content,
}) => SessionEvent(
  itemId: 'm:$id',
  type: 'user/message',
  seq: seq,
  time: 1792023957795,
  data: <String, Object?>{
    'content': content,
    'source': {'kind': 'user'},
    'role': 'user',
    'id': id,
  },
);

/// 一条 `assistant/message`（真日志形状：消息在 data.message 上）。
SessionEvent _assistantEvent({
  required int seq,
  required String id,
  required List<Map<String, Object?>> content,
}) => SessionEvent(
  itemId: 'm:$id',
  type: 'assistant/message',
  seq: seq,
  time: 1792023988752,
  data: <String, Object?>{
    'turn': 1,
    'step': 1,
    'message': <String, Object?>{
      'role': 'assistant',
      'content': content,
      'source': {'kind': 'model', 'provider': 'stepfun'},
      'id': id,
    },
    'stream': const [],
  },
);

/// 一条 `tool/result`（真日志形状）。
SessionEvent _toolResultEvent({
  required int seq,
  required String callId,
  required String name,
  required List<Map<String, Object?>> content,
  Map<String, Object?>? metadata,
}) => SessionEvent(
  itemId: 't:$callId',
  type: 'tool/result',
  seq: seq,
  time: 1792023989223,
  data: <String, Object?>{
    'turn': 1,
    'step': 1,
    'message': <String, Object?>{
      'role': 'tool',
      'source': {'kind': 'tool', 'callId': callId},
      'toolCallId': callId,
      'name': name,
      'content': content,
      // 条件条目用 `if` 而不用 null-aware marker：后者的 key 取**值的字符串形式**，
      // 展开成 `metadata: metadata` 之类的怪键（app_model.dart 同一处踩过）。
      // ignore: use_null_aware_elements
      if (metadata != null) 'metadata': metadata,
    },
  },
);

/// 把一条事件喂给投影（测试里反复用）。
ChatItem _project(SessionEvent event) =>
    projectEvent(type: event.type, seq: event.seq, data: event.data).item!;

void main() {
  group('消息投影：正文之外的三样', () {
    test('助手消息的 reasoning 块抽成思考过程', () {
      final item =
          _project(
                _assistantEvent(
                  seq: 16,
                  id: 'asst-1',
                  content: [
                    {'type': 'reasoning', 'text': '先看工作区。'},
                    {'type': 'text', 'text': '好的，我来看看。'},
                  ],
                ),
              )
              as MessageItem;
      expect(item.text, '好的，我来看看。');
      expect(item.reasoning, '先看工作区。');
    });
    test('用户消息的图片块只计数不渲染', () {
      final item =
          projectEvent(
                type: 'user/message',
                seq: 8,
                data: <String, Object?>{
                  'id': 'u-1',
                  'content': [
                    {
                      'type': 'image',
                      'attachment': {'attachmentId': 'sha256:abc'},
                    },
                    {'type': 'text', 'text': '看这两张图'},
                  ],
                },
              ).item!
              as MessageItem;
      expect(item.text, '看这两张图');
      expect(item.attachmentCount, 1);
    });

    test('tool/result：输出进明细，metadata.diffs 折成 +N/−M', () {
      final item =
          _project(
                _toolResultEvent(
                  seq: 18,
                  callId: 'c-1',
                  name: 'edit',
                  content: [
                    {'type': 'text', 'text': 'Applied 1 edit.'},
                  ],
                  metadata: {
                    'diffs': [
                      {
                        'path': 'a.dart',
                        'oldText': 'old1\nold2',
                        'newText': 'new1\nnew2\nnew3',
                      },
                    ],
                  },
                ),
              )
              as ToolCallItem;
      expect(item.status, ToolCallStatus.completed);
      expect(item.detail, 'Applied 1 edit.');
      expect(item.diffStat?.added, 3);
      expect(item.diffStat?.removed, 2);
    });
  });

  group('插话判定（DSH SteeringHistory 的移植）', () {
    test('从 next-step claim 掉的用户消息才是插话；排队消息不是', () async {
      final client = _RenderClient(
        onCall: (m, p) => m == 'session.list'
            ? {
                'sessions': [
                  {'sid': 's1', 'updatedAt': 1},
                ],
              }
            : null,
      );
      final app = AppModel(client: client);
      await app.refreshSessions();
      await app.openSession('s1');

      // ① 插话消息先被插进 next-step。
      client.emit('s1', [
        const SessionEvent(
          itemId: 'agent/inbox/spliced:3',
          type: 'agent/inbox/spliced',
          seq: 3,
          time: 1,
          data: <String, Object?>{
            'target': 'next-step',
            'start': 0,
            'inserted': [
              {'id': 'steer-1'},
            ],
          },
        ),
      ]);
      await Future<void>.delayed(Duration.zero);

      // ② 它被 claim 掉（splice 从 next-step 移除）。
      client.emit('s1', [
        const SessionEvent(
          itemId: 'agent/inbox/spliced:5',
          type: 'agent/inbox/spliced',
          seq: 5,
          time: 2,
          data: <String, Object?>{
            'target': 'next-step',
            'start': 0,
            'removedCount': 1,
            'inserted': <Map<String, Object?>>[],
          },
        ),
      ]);
      await Future<void>.delayed(Duration.zero);

      // ③ 作为 user/message 到达 → 插话。
      client.emit('s1', [
        _userEvent(
          seq: 6,
          id: 'steer-1',
          content: [
            {'type': 'text', 'text': '改成先跑测试'},
          ],
        ),
      ]);
      // ④ 一条普通排队消息（进 next-turn，没被 claim）。
      client.emit('s1', [
        const SessionEvent(
          itemId: 'agent/inbox/spliced:8',
          type: 'agent/inbox/spliced',
          seq: 8,
          time: 3,
          data: <String, Object?>{
            'target': 'next-turn',
            'start': 0,
            'inserted': [
              {'id': 'queued-1'},
            ],
          },
        ),
        _userEvent(
          seq: 9,
          id: 'queued-1',
          content: [
            {'type': 'text', 'text': '排队的'},
          ],
        ),
      ]);
      await Future<void>.delayed(Duration.zero);

      final byId = {for (final item in app.items) item.itemId: item};
      final steer = byId['m:steer-1']! as MessageItem;
      expect(steer.steering, isTrue, reason: '从 next-step claim 掉的用户消息是插话');
      final queued = byId['m:queued-1']! as MessageItem;
      expect(queued.steering, isFalse, reason: '排队消息不是插话');
      app.dispose();
    });
  });

  group('逐条错误隔离（一条坏事件不再炸掉整批）', () {
    test('坏事件记下来，好事件照常渲染', () async {
      final client = _RenderClient(
        onCall: (m, p) => m == 'session.list'
            ? {
                'sessions': [
                  {'sid': 's1', 'updatedAt': 1},
                ],
              }
            : null,
      );
      final app = AppModel(client: client);
      await app.refreshSessions();
      await app.openSession('s1');

      client.emit('s1', [
        // 坏事件：user/message 缺 id（itemIdOf 抛 StateError）。
        const SessionEvent(
          itemId: 'user/message:7',
          type: 'user/message',
          seq: 7,
          time: 1,
          data: <String, Object?>{
            'content': [
              {'type': 'text', 'text': '没有 id 的消息'},
            ],
          },
        ),
        // 好事件：紧随其后。
        _userEvent(
          seq: 8,
          id: 'good-1',
          content: [
            {'type': 'text', 'text': '这条必须渲染'},
          ],
        ),
      ]);
      await Future<void>.delayed(Duration.zero);

      expect(
        app.items.whereType<MessageItem>().length,
        1,
        reason: '坏事件不能把好事件一起带走',
      );
      expect((app.items.single as MessageItem).text, '这条必须渲染');
      expect(app.projectionFailureOf('s1'), contains('user/message'));
      app.dispose();
    });
  });

  group('界面：思考过程块', () {
    // 2026-10-20：收起时**显示首行摘要**（DSH 的 `settledReasoningPreview`，
    // 默认档 `detailed` 就是开着的：`presentation-policy.ts:36,44`；
    // 摘要取首行见 `ReasoningRow.tsx:56-69`），正文仍要展开才见。
    testWidgets('默认收起：只见首行摘要，点开见全文', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AssistantTurn(text: '正文', reasoning: '第一行思考\n第二行思考'),
            ),
          ),
        ),
      );
      expect(find.text('思考过程'), findsOneWidget);
      expect(find.textContaining('第一行思考'), findsOneWidget, reason: '首行摘要要显示');
      expect(
        find.textContaining('第二行思考'),
        findsNothing,
        reason: '折叠时正文不该渲染（只有首行摘要）',
      );
      await tester.tap(find.text('思考过程'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('第二行思考', findRichText: true),
        findsOneWidget,
        reason: '展开后正文按 Markdown 渲染，整段都在',
      );
    });

    // 正文形态：DSH 的思考正文是 `MarkdownText variant="compact"`
    // （`ReasoningContent.tsx:16`）—— 所以 `**加粗**` 要渲染成粗体，
    // 而不是把星号原样露出来。
    testWidgets('思考正文跑 Markdown（compact 档）', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AssistantTurn(text: '正文', reasoning: '看 **重点** 这里'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('思考过程'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('**重点**'),
        findsNothing,
        reason: 'Markdown 记号不该原样露出',
      );
      expect(find.textContaining('重点', findRichText: true), findsOneWidget);
    });
  });

  group('界面：插话气泡', () {
    testWidgets('带"插话"标', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: UserTurn('改成先跑测试', steering: true),
            ),
          ),
        ),
      );
      expect(find.text('插话'), findsOneWidget);
    });
  });
}
