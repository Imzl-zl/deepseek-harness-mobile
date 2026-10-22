/// 轮组在**真页面**上的折叠行为（不是纯函数——那条在 `turn_groups_test.dart`）。
///
/// 守三件事：
///
/// 1. 一轮收口后，过程条目（工具卡）默认**收起**，只留用户那句话、正文与收口行；
/// 2. **点收口行能展开 / 再收起**（箭头朝向跟着变）；
/// 3. 「工作步骤收起时机」＝`下次有新消息时` 时，**最新那一轮默认展开**。
///
/// 为什么要 widget 级：折叠是"条目表被过滤"这件事，纯函数对了不代表页面用的是它
/// （2026-10-22 的教训：接线漏了那句 `applyTurnCollapse` 照样全绿）。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/preferences.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 能推任意事件的替身（`itemId` 按契约 §5.2 的规则手推）。
class _FeedClient extends FakeSyncClient {
  final _sessions = StreamController<SessionDelta>.broadcast();

  void emit(String sid, List<Map<String, Object?>> events) {
    _sessions.add(
      SessionDelta(
        sid: sid,
        events: [
          for (final e in events)
            SessionEvent(
              itemId: e['itemId'] as String,
              type: e['type'] as String,
              seq: e['seq'] as int,
              time: e['time'] as int? ?? 0,
              data: e['data'],
            ),
        ],
        transient: const {},
      ),
    );
  }

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
  Stream<SessionDelta> sessionUpdates(String sid) => _sessions.stream;

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async => <String, Object?>{} as T;
}

/// 一轮：`turn/start` → 用户消息 → 工具调用+结果 → 助手正文 → `turn/end`。
///
/// [emptyAnswer] = 助手那条**只有工具、没有正文**（真日志里工具那一步就是这样）。
List<Map<String, Object?>> _closedTurn(
  int turn, {
  String tool = 'bash',
  bool emptyAnswer = false,
}) => [
  {
    'type': 'turn/start',
    'seq': turn * 10 + 1,
    'itemId': 's:${turn * 10 + 1}',
    'time': 1,
    'data': {'turn': turn},
  },
  {
    'type': 'user/message',
    'seq': turn * 10 + 2,
    'itemId': 'm:u$turn',
    'time': 2,
    'data': {
      'id': 'u$turn',
      'role': 'user',
      'source': {'kind': 'user'},
      'content': '第 $turn 问',
    },
  },
  {
    'type': 'tool/call',
    'seq': turn * 10 + 3,
    'itemId': 't:c$turn',
    'time': 3,
    'data': {
      'turn': turn,
      'step': 1,
      'callId': 'c$turn',
      'name': tool,
      'arguments': '{}',
    },
  },
  {
    'type': 'tool/result',
    'seq': turn * 10 + 4,
    'itemId': 't:c$turn',
    'time': 4,
    'data': {
      'turn': turn,
      'step': 1,
      'message': {
        'role': 'tool',
        'toolCallId': 'c$turn',
        'source': {'kind': 'tool', 'callId': 'c$turn'},
        'content': 'ok',
      },
    },
  },
  {
    'type': 'assistant/message',
    'seq': turn * 10 + 5,
    'itemId': 'm:a$turn',
    'time': 5,
    'data': {
      'turn': turn,
      'step': 1,
      'message': {
        'id': 'a$turn',
        'role': 'assistant',
        // 只有工具、没有正文的那一步：`content` 是空表。
        'content': emptyAnswer
            ? <Object?>[]
            : [
                {'type': 'text', 'text': '第 $turn 答'},
              ],
      },
    },
  },
  {
    'type': 'turn/end',
    'seq': turn * 10 + 6,
    'itemId': 'e:$turn',
    'time': 6,
    'data': {
      'turn': turn,
      'reason': {'kind': 'completed'},
    },
  },
];

Future<AppModel> _pump(WidgetTester tester, _FeedClient client) async {
  final app = AppModel(client: client);
  await app.start();
  await app.openSession('s1');
  await tester.pumpWidget(
    MaterialApp(
      theme: DshTheme.dark(),
      home: ChatPage(
        app: app,
        paired: true,
        onOpenDrawer: () {},
        onNewSession: () {},
        drawer: const Drawer(child: SizedBox(height: 200)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return app;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(milliseconds: 10));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('收口后过程默认收起；点收口行展开、再点收起', (tester) async {
    final client = _FeedClient();
    final app = await _pump(tester, client);
    addTearDown(app.dispose);

    client.emit('s1', _closedTurn(1));
    await _settle(tester);

    // 收口行在，工具卡不在（默认 `completion` ⇒ 收起）。
    expect(find.textContaining('第 1 轮'), findsOneWidget);
    expect(find.text('bash'), findsNothing, reason: '收起时过程条目不该占屏');
    expect(find.text('第 1 答'), findsOneWidget, reason: '正文始终可见');
    expect(find.text('第 1 问'), findsOneWidget, reason: '用户那句话始终可见');

    // 展开：点收口行（箭头朝下 ⇒ 现在朝上）。
    await tester.tap(find.textContaining('第 1 轮'));
    await _settle(tester);
    expect(find.text('bash'), findsOneWidget, reason: '展开后工具卡回来');

    // 再收起。
    await tester.tap(find.textContaining('第 1 轮'));
    await _settle(tester);
    expect(find.text('bash'), findsNothing);
  });

  testWidgets('工具那一步的空助手消息不留空行（收起后不该只剩一个空「助手」）', (tester) async {
    final client = _FeedClient();
    final app = await _pump(tester, client);
    addTearDown(app.dispose);

    client.emit('s1', _closedTurn(1, emptyAnswer: true));
    await _settle(tester);

    expect(find.textContaining('第 1 轮'), findsOneWidget);
    expect(find.text('bash'), findsNothing, reason: '默认收起');
    expect(find.text('助手'), findsNothing, reason: '空正文的那条助手消息不该画成一行只有头像的空行');
  });

  testWidgets('收起时机＝下次有新消息时：最新一轮默认展开', (tester) async {
    final client = _FeedClient();
    final app = await _pump(tester, client);
    addTearDown(app.dispose);
    await app.setCollapseTiming(CollapseTiming.nextInput);
    await tester.pumpAndSettle();

    client.emit('s1', _closedTurn(1));
    await _settle(tester);
    expect(find.text('bash'), findsOneWidget, reason: '最新那一轮保持展开，等下一句才收');

    // 第二轮来了 ⇒ 第一轮变"上一轮"，收起；第二轮展开。
    client.emit('s1', _closedTurn(2, tool: 'read'));
    await _settle(tester);
    expect(find.text('bash'), findsNothing, reason: '上一轮该收了');
    expect(find.text('read'), findsOneWidget);
  });
}
