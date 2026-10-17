/// 排队消息这条链的回归（`inbox` 投影 → 排队条 → `session.updateQueue`）。
///
/// ## 为什么单独一组
///
/// 2026-10-17 之前手机上**没有排队这个概念**：会话正在跑时发出去的消息
/// 排进下一个轮次，而用户看不见它排在哪、也没法撤。DSH Web 的排队 dock
/// （`ui-conversation/src/client/queue/QueueDock.tsx`）三个行内按钮
/// （编辑 / 删除 / 插话）走 `session/updateQueue`，手机照接。
///
/// 形状判据全部来自 DSH：
/// - `inbox` 投影的 wire view 是 `{'next-turn': […], 'next-step': […]}`
///   （`api/session-controller/tests/session-projections.host.spec.ts:262-265`
///    用的就是这个形状断言）；
/// - 排队项是 DSH 的 `UserMessage`：`{id, content, source, role}`
///   （形状照真实会话日志：`~/.dsh/sessions/**/session.v4.jsonl.zstd`）；
/// - 预览规则照 `QueueDock.tsx:20-27`（滤掉图片/文件块、200 字封顶）。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/queue_item.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/queue_dock.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

class _QueueClient implements SyncClient {
  _QueueClient({this.onCall});

  final Object? Function(String method, Map<String, Object?> params)? onCall;
  final List<Map<String, Object?>> calls = [];
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
  Future<void> setAppState(AppState state) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> subscribe(String sid, {required int since}) async {}
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
    calls.add({'method': method, 'params': params, 'requestId': requestId});
    return onCall?.call(method, params) as T;
  }
}

/// `inbox` 投影的真形状（两条 next-turn + 一条 next-step + 一条带图片的）。
Map<String, Object?> _inboxProjection() => {
  'next-turn': [
    {
      'id': 'msg-queued-1',
      'role': 'user',
      'source': {'kind': 'user'},
      'content': [
        {'type': 'text', 'text': '第一条排队消息'},
      ],
    },
    {
      'id': 'msg-queued-2',
      'role': 'user',
      'source': {'kind': 'user'},
      'content': [
        {
          'type': 'image',
          'attachment': {
            'attachmentId': 'sha256:abc',
            'mediaType': 'image/png',
          },
        },
        {'type': 'text', 'text': '带图的第二条'},
      ],
    },
  ],
  'next-step': [
    {
      'id': 'msg-steering-1',
      'role': 'user',
      'source': {'kind': 'user'},
      'content': [
        {'type': 'text', 'text': '已经插进当前轮次的'},
      ],
    },
  ],
};

/// `session.projections` 的应答：`inbox` 是其中一个键（连接器拆掉信封后的形状）。
Map<String, Object?> _projectionsWithInbox() => {'inbox': _inboxProjection()};

void main() {
  group('parseQueueItems：inbox 投影的真形状', () {
    test('只列 next-turn；预览折占位；附件计数；可编辑判据', () {
      final items = parseQueueItems(_inboxProjection());
      expect(items.map((i) => i.itemId), ['msg-queued-1', 'msg-queued-2']);
      expect(items[0].previewText, '第一条排队消息');
      expect(items[0].attachmentCount, 0);
      expect(items[0].editable, isTrue, reason: '纯文本才可编辑');
      // 图片块折成 `[image]` 占位（Web 的 previewOf 同一条）。
      expect(items[1].previewText, '[image] 带图的第二条');
      expect(items[1].attachmentCount, 1);
      expect(items[1].editable, isFalse, reason: '带图片的编辑不了（DSH 只收纯文本）');
    });

    test('预览 200 字封顶（按字符不按字节，中文优先）', () {
      final items = parseQueueItems({
        'next-turn': [
          {
            'id': 'm1',
            'content': [
              {'type': 'text', 'text': '中' * 250},
            ],
          },
        ],
      });
      expect(items.single.previewText.length, 201, reason: '200 字 + 省略号');
      expect(items.single.previewText.endsWith('…'), isTrue);
    });

    test('认不出：空表（不猜）', () {
      expect(parseQueueItems(null), isEmpty);
      expect(parseQueueItems('x'), isEmpty);
      expect(parseQueueItems({'next-turn': 'x'}), isEmpty);
      expect(
        parseQueueItems({
          'next-step': [
            {'id': 'x', 'content': []},
          ],
        }),
        isEmpty,
        reason: 'next-step 不列（已生效，不在队列里）',
      );
    });
  });

  group('AppModel.updateQueue：载荷形状与重读', () {
    test('三种 action 的形状 + 幂等键 + 成功后重读投影', () async {
      final client = _QueueClient(
        onCall: (m, p) => switch (m) {
          'session.projections' => _projectionsWithInbox(),
          'session.updateQueue' => const {'accepted': true},
          _ => null,
        },
      );
      final app = AppModel(client: client);
      await app.start();
      await app.openSession('sid_A');
      expect(app.queueOf('sid_A').length, 2);

      // 删除。
      expect(
        await app.updateQueue('sid_A', 'msg-queued-1', QueueActionKind.remove),
        isTrue,
      );
      var call = client.calls.lastWhere(
        (c) => c['method'] == 'session.updateQueue',
      );
      expect(call['params'], {
        'sid': 'sid_A',
        'itemId': 'msg-queued-1',
        'action': {'kind': 'remove'},
      });
      expect(call['requestId'], isNotNull, reason: '写操作必须带幂等键');

      // 插话。
      expect(
        await app.updateQueue('sid_A', 'msg-queued-2', QueueActionKind.steer),
        isTrue,
      );
      call = client.calls.lastWhere(
        (c) => c['method'] == 'session.updateQueue',
      );
      expect((call['params']! as Map)['action'], {'kind': 'steer'});

      // 编辑：只发纯文本 content。
      expect(
        await app.updateQueue(
          'sid_A',
          'msg-queued-2',
          QueueActionKind.edit,
          text: '改过的内容',
        ),
        isTrue,
      );
      call = client.calls.lastWhere(
        (c) => c['method'] == 'session.updateQueue',
      );
      expect((call['params']! as Map)['action'], {
        'kind': 'edit',
        'content': [
          {'type': 'text', 'text': '改过的内容'},
        ],
      });

      // 每次都重读投影（队列变化不推投影，见方法头）。
      expect(
        client.calls.where((c) => c['method'] == 'session.projections').length,
        greaterThanOrEqualTo(4),
      );
      app.dispose();
    });

    test('失败：留声并返回 false，仍然重读（错误码的语义就是"刷新"）', () async {
      final client = _QueueClient(
        onCall: (m, p) => switch (m) {
          'session.projections' => _projectionsWithInbox(),
          'session.updateQueue' => throw const ProtocolException(
            ErrorCode.sessionSteerUnavailable,
            'current turn no longer accepts steering',
          ),
          _ => null,
        },
      );
      final app = AppModel(client: client);
      await app.start();
      await app.openSession('sid_A');

      expect(
        await app.updateQueue('sid_A', 'msg-queued-1', QueueActionKind.steer),
        isFalse,
      );
      expect(app.lastError?.code, ErrorCode.sessionSteerUnavailable);
      app.dispose();
    });

    test('队列按 sid 取：别的会话的投影包不串台', () async {
      final client = _QueueClient(
        onCall: (m, p) =>
            m == 'session.projections' ? _projectionsWithInbox() : null,
      );
      final app = AppModel(client: client);
      await app.start();
      await app.openSession('sid_A');
      // `sid_B` 从没打开过：投影包是 sid_A 的，不能把它的队列给 sid_B。
      expect(app.queueOf('sid_B'), isEmpty);
      app.dispose();
    });
  });

  // 排队条的界面行为：计数头 / 折叠 / 插话门。
  group('QueueDock 界面', () {
    Widget wrap(AppModel app, {required bool running}) => MaterialApp(
      theme: DshTheme.dark(),
      home: Scaffold(
        body: QueueDock(app: app, sid: 'sid_A', running: running),
      ),
    );

    testWidgets('空队列：整条不占位', (tester) async {
      final app = AppModel(client: _QueueClient(onCall: (m, p) => null));
      await tester.pumpWidget(wrap(app, running: false));
      await tester.pumpAndSettle();
      expect(find.byType(QueueDock), findsOneWidget);
      expect(find.textContaining('排队消息'), findsNothing);
      app.dispose();
    });

    testWidgets('两条：折叠成计数头，点开才见行', (tester) async {
      final app = AppModel(
        client: _QueueClient(
          onCall: (m, p) =>
              m == 'session.projections' ? _projectionsWithInbox() : null,
        ),
      );
      await app.start();
      await app.openSession('sid_A');
      await tester.pumpWidget(wrap(app, running: false));
      await tester.pumpAndSettle();

      expect(find.text('2 条排队消息'), findsOneWidget);
      expect(find.text('第一条排队消息'), findsNothing, reason: '默认折叠');
      await tester.tap(find.text('2 条排队消息'));
      await tester.pumpAndSettle();
      expect(find.text('第一条排队消息'), findsOneWidget);
      app.dispose();
    });

    testWidgets('插话门：没在跑时禁用并说清原因', (tester) async {
      final app = AppModel(
        client: _QueueClient(
          onCall: (m, p) =>
              m == 'session.projections' ? _projectionsWithInbox() : null,
        ),
      );
      await app.start();
      await app.openSession('sid_A');
      await tester.pumpWidget(wrap(app, running: false));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2 条排队消息'));
      await tester.pumpAndSettle();

      // 没在跑：插话钮禁用，tooltip 是 DSH 的原话"仅运行中可插话发送"。
      // 两行各一枚，取第一枚（门对每一行都一样）。
      final steer = find.byTooltip('仅运行中可插话发送').first;
      expect(steer, findsOneWidget);
      final inkWell = find.descendant(
        of: steer,
        matching: find.byType(InkWell),
      );
      expect(tester.widget<InkWell>(inkWell).onTap, isNull, reason: '禁用 = 点不动');
      app.dispose();
    });

    testWidgets('插话门：在跑时可点', (tester) async {
      final app = AppModel(
        client: _QueueClient(
          onCall: (m, p) =>
              m == 'session.projections' ? _projectionsWithInbox() : null,
        ),
      );
      await app.start();
      await app.openSession('sid_A');
      await tester.pumpWidget(wrap(app, running: true));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2 条排队消息'));
      await tester.pumpAndSettle();

      final steer = find.byTooltip('插话发送').first;
      expect(steer, findsOneWidget);
      final inkWell = find.descendant(
        of: steer,
        matching: find.byType(InkWell),
      );
      expect(tester.widget<InkWell>(inkWell).onTap, isNotNull);
      app.dispose();
    });
  });
}
