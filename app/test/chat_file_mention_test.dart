/// 正文提及 → **右抽屉预览** 的接线（聊天页这一层）。
///
/// ## 这一组守什么
///
/// 1. 助手正文里被解析器认出来的行内代码**可点**；
/// 2. 点它走 `AppModel.openFile`（`file.read` 带的是原样路径），
///    然后右抽屉自己拉开、落在文件面板上；
/// 3. 面板里是**那份文件的内容**，标题是文件名、副标题是完整路径；
/// 4. `返回改动` 收起这份文件，面板回到改动清单。
///
/// 解析器本身（唯一命中 / 歧义惰性）在 `file_mentions_test.dart`；
/// 读的三种结论在 `file_open_test.dart`。这里只钉"接起来了没有"。
library;

import 'dart:convert';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/data/projection.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

const String _sid = 'sid_1';

/// 一台假电脑：能力位 + `file.read`（把请求记下来）。
class _MentionClient extends FakeSyncClient {
  final sent = <(String, Map<String, Object?>)>[];

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
    sent.add((method, params));
    switch (method) {
      case 'repo.info':
        return <String, Object?>{
              'protocol': 1,
              'caps': <String, Object?>{'files': true},
            }
            as T;
      case 'file.read':
        return <String, Object?>{
              'page': {
                'text': '// 第 1 行\n// 第 2 行',
                'offset': 1,
                'lines': 2,
                'eof': true,
              },
            }
            as T;
    }
    return <String, Object?>{} as T;
  }
}

ChatItem _writeCall({
  required int seq,
  required int turn,
  required String path,
}) => projectEvent(
  type: 'tool/call',
  seq: seq,
  turn: turn,
  data: <String, Object?>{
    'turn': turn,
    'step': 1,
    'callId': 'c1',
    'name': 'write',
    'arguments': jsonEncode(<String, Object?>{
      'file_path': path,
      'content': 'x',
    }),
  },
).item!;

/// 一条 `tool/result`（成功）：真机上写调用**总有结果**，而结果会覆盖同 itemId 的
/// 调用条目 —— 路径从调用继承（见 `data/projection.dart` 的 tool/result 分支）。
ChatItem _writeResult({
  required int seq,
  required int turn,
  required ChatItem previous,
}) => projectEvent(
  type: 'tool/result',
  seq: seq,
  turn: turn,
  previous: previous,
  data: <String, Object?>{
    'turn': turn,
    'step': 1,
    'callId': 'c1',
    'message': <String, Object?>{
      'role': 'tool',
      'toolCallId': 'c1',
      'id': 'r-c1',
      'isError': false,
      'content': [
        {'type': 'text', 'text': 'ok'},
      ],
    },
  },
).item!;

/// 一条 `turn/end`：桌面只对**已收口**的轮解析提及，手机同一条
/// （`ui-chat/src/client/chat/AssistantNodeView.tsx:19-27`）。
ChatItem _turnEnd({required int seq, required int turn}) => projectEvent(
  type: 'turn/end',
  seq: seq,
  turn: turn,
  data: <String, Object?>{
    'turn': turn,
    'reason': <String, Object?>{'kind': 'completed'},
  },
).item!;

ChatItem _assistant({
  required int seq,
  required int turn,
  required String text,
}) => projectEvent(
  type: 'assistant/message',
  seq: seq,
  turn: turn,
  data: <String, Object?>{
    'turn': turn,
    'step': 1,
    'message': <String, Object?>{
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': text},
      ],
      'source': {'kind': 'model'},
      'id': 'm1',
    },
  },
).item!;

Future<AppModel> _seeded(_MentionClient client) async {
  final call = _writeCall(seq: 2, turn: 1, path: 'src/a.ts');
  final app = AppModel(client: client);
  app.seedForTest(
    sid: _sid,
    title: 't',
    updatedAt: 1,
    items: [
      call,
      _writeResult(seq: 3, turn: 1, previous: call),
      _assistant(seq: 4, turn: 1, text: '改了 `src/a.ts` 里的两行。'),
      _turnEnd(seq: 5, turn: 1),
    ],
  );
  await app.refreshRepoInfo();
  await app.openSession(_sid);
  return app;
}

Future<void> _pump(WidgetTester tester, AppModel app) async {
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
}

void main() {
  testWidgets('点正文里的提及：读取原样路径，右抽屉拉开并显示内容', (tester) async {
    final client = _MentionClient();
    final app = await _seeded(client);
    addTearDown(app.dispose);

    await _pump(tester, app);

    // 先确认模型层：这一轮的收口消息确实拿到了词表。
    expect(
      app.fileMentionsOf(app.items.whereType<MessageItem>().first),
      {'src/a.ts': 'src/a.ts'},
      reason: '模型层的词表（失败在这里 = 收口判定没命中）',
    );
    final mention = find.byTooltip('打开 src/a.ts');
    expect(mention, findsOneWidget, reason: '这一轮写过 src/a.ts ⇒ 正文里可点');

    await tester.tap(mention);
    await tester.pumpAndSettle();

    expect(
      client.sent.where((c) => c.$1 == 'file.read').map((c) => c.$2['path']),
      ['src/a.ts'],
      reason: '路径原样交给 file.read（scope 在宿主）',
    );
    // 抽屉标题：文件名 + 完整路径。
    expect(find.text('a.ts'), findsOneWidget);
    expect(find.text('src/a.ts'), findsWidgets);
    // 内容来自 file.read 的应答。
    expect(find.textContaining('第 1 行'), findsOneWidget);
    expect(find.textContaining('已到末尾'), findsOneWidget);
  });

  testWidgets('返回改动：收起这份文件，面板回到改动清单', (tester) async {
    final client = _MentionClient();
    final app = await _seeded(client);
    addTearDown(app.dispose);
    await _pump(tester, app);

    await tester.tap(find.byTooltip('打开 src/a.ts'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('file-open-back')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey<String>('file-open-back')));
    await tester.pumpAndSettle();

    expect(find.textContaining('第 1 行'), findsNothing);
    // 改动清单回来了：清单页才有「差异」那条分段（预览页没有）。
    // （不断言「文件」两个字：抽屉的 tab 也叫「文件」，那不是清单的标志。）
    expect(find.text('差异'), findsOneWidget);
  });

  testWidgets('没认出来的 token 不可点（普通代码）', (tester) async {
    final client = _MentionClient();
    final app = AppModel(client: client);
    addTearDown(app.dispose);
    app.seedForTest(
      sid: _sid,
      title: 't',
      updatedAt: 1,
      items: [
        _writeCall(seq: 2, turn: 1, path: 'src/a.ts'),
        _assistant(seq: 3, turn: 1, text: '顺带看了 `docs/other.md`。'),
      ],
    );
    await app.refreshRepoInfo();
    await app.openSession(_sid);
    await _pump(tester, app);

    expect(find.byTooltip('打开 docs/other.md'), findsNothing);
    expect(client.sent.where((c) => c.$1 == 'file.read'), isEmpty);
  });
}
