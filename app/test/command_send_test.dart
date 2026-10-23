/// 斜杠命令的**执行面**：分流、发送、失败留声（`command.execute`）。
///
/// ## 这一组守什么
///
/// 2026-10-23 之前 `/goal …` 在手机上走 `session.prompt`，于是它变成**一条普通消息**
/// —— 电脑侧不会建目标，命令卡也不会出现。命令卡的渲染早已被 `command_item_test.dart`
/// 钉住（`command/run` + `command/done`），所以这里只验**执行面**：
///
/// 1. 分流只有一处（[sendRouteOf]）：命令 → `command.execute`、普通文本 →
///    `session.prompt`、子会话 → `subagent.prompt`；
/// 2. `command.execute` 的参数是 `{sid, line}`（**不传 agent id**，连接器从 sid 解析），
///    附件恒为空数组；
/// 3. **`matched:false` 不是失败**：DSH 的 `execute` 回 `undefined` 表示"没这条命令"，
///    Web 的输入流水线把这种行退成普通消息（`ui-conversation/src/client/input/machine.ts:170-175`），
///    手机照同一条 —— 但要**说一句**，否则用户以为命令跑过了；
/// 4. 失败如实报且**文本留在输入框**（改一改就能再发）。
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/command.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'fake_sync_client.dart';

/// 假电脑：答本组用例会问到的那几个方法，其余全炸（"这个用例不该调它"）。
class _CommandClient extends FakeSyncClient {
  _CommandClient({this.commandResult, this.commandThrows = false});

  /// `command.execute` 的应答（`{matched, execution?}`）。
  final Object? commandResult;

  /// 让 `command.execute` 抛（模拟连接断了 / 电脑侧 500）。
  final bool commandThrows;

  /// 发出去的写方法：方法名 + params + 幂等键。
  final sent = <(String, Map<String, Object?>, String?)>[];

  @override
  ConnectionState get state => ConnectionState.serving;
  @override
  Stream<ConnectionState> get connection => const Stream.empty();
  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();
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
    if (method == 'command.execute' || method == 'session.prompt') {
      sent.add((method, params, requestId));
      if (method == 'command.execute') {
        if (commandThrows) {
          throw const ProtocolException(ErrorCode.internal, '电脑侧炸了');
        }
        return commandResult as T;
      }
      return <String, Object?>{'accepted': true} as T;
    }
    // 其余按形状给最小合法应答：让 `lastError` 保持空，断言才只反映这一条路径。
    final result = switch (method) {
      'session.list' => {
        'sessions': [
          {
            'sid': 'sid_1',
            'updatedAt': 1,
            'projections': {
              'values': {'title': '会话'},
            },
          },
        ],
      },
      'session.projections' => <String, Object?>{},
      'session.modelCatalog' => {'available': false},
      'permission.catalog' => {'available': false},
      'agentPresets.list' => {'available': false},
      'workspace.list' => {'workspaces': []},
      'job.list' => {'jobs': []},
      'repo.info' => <String, Object?>{},
      'endpoint.describe' => {'endpoints': []},
      _ => throw ProtocolException(ErrorCode.relayOffline, '测试里不连：$method'),
    };
    return result as T;
  }
}

Future<void> _pumpChat(WidgetTester tester, AppModel app) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: DshTheme.dark(),
      home: ChatPage(
        app: app,
        onOpenDrawer: () {},
        onNewSession: () {},
        drawer: const Drawer(child: SizedBox()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// 起一个连着假电脑、已选中 `sid_1` 的 AppModel。
Future<AppModel> _appWith(_CommandClient client) async {
  final app = AppModel(client: client);
  await app.start();
  await app.refreshSessions();
  await app.openSession('sid_1');
  return app;
}

/// 输入一句并点发送（走真的输入栏，不直接调 `_send`）。
Future<void> _sendText(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField).first, text);
  await tester.pump();
  await tester.tap(find.byTooltip('发送'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('sendRouteOf：一处分流', () {
    test('斜杠行 = 命令；其余 = 普通消息', () {
      expect(
        sendRouteOf(text: '/goal 睡觉', isSubagent: false),
        SendRoute.command,
      );
      // 草稿先 trim 再判（与 Web 的 `machine.ts:144` 同一个口径）。
      expect(
        sendRouteOf(text: '   /plan off', isSubagent: false),
        SendRoute.command,
      );
      expect(sendRouteOf(text: '睡觉', isSubagent: false), SendRoute.prompt);
      expect(sendRouteOf(text: '', isSubagent: false), SendRoute.prompt);
      // **是不是命令由电脑侧判**（白名单 + DSH 的 parseCommand）：手机只认"以 / 开头"。
      // 这条行在 DSH 眼里不是命令（`/etc` 后面跟的是 `/`），于是电脑回 `undefined`，
      // 手机按 Web 的同一条退成普通消息 —— 路径字符串仍然发得出去。
      expect(
        sendRouteOf(text: '/etc/passwd 是啥', isSubagent: false),
        SendRoute.command,
      );
    });

    test('子会话恒走 subagent.prompt（命令面没有它）', () {
      // 子会话唯一的写入口是 `subagent.prompt`（宿主对子会话的 `session.prompt`
      // 回 `is owned by subagent routing`），而 `commands.execute` 要活的 root agent。
      expect(
        sendRouteOf(text: '/goal 睡觉', isSubagent: true),
        SendRoute.subagentPrompt,
      );
      expect(
        sendRouteOf(text: '继续', isSubagent: true),
        SendRoute.subagentPrompt,
      );
    });
  });

  group('AppModel.executeCommand', () {
    test('参数是 {sid, line}，且带幂等键', () async {
      final client = _CommandClient(
        commandResult: {
          'matched': true,
          'execution': {
            'commandId': 'cmd-1-1',
            'result': {'kind': 'success', 'text': 'Goal created'},
          },
        },
      );
      final app = await _appWith(client);

      final outcome = await app.executeCommand('/goal 睡觉');

      expect(client.sent, hasLength(1));
      final (method, params, requestId) = client.sent.single;
      expect(method, 'command.execute');
      expect(params, {'sid': 'sid_1', 'line': '/goal 睡觉'});
      // 幂等键：重发不该落两张命令卡（契约 §5.7 的「幂等键」列）。
      expect(requestId, isNotNull);
      expect(requestId, isNotEmpty);
      expect(outcome?.matched, isTrue);
      expect(outcome?.succeeded, isTrue);
      expect(outcome?.text, 'Goal created');
      app.dispose();
    });

    test('matched:false 不是失败：不写 lastError，也不假装成功', () async {
      final client = _CommandClient(commandResult: {'matched': false});
      final app = await _appWith(client);

      final outcome = await app.executeCommand('/nope');

      expect(outcome, isNotNull);
      expect(outcome!.matched, isFalse);
      expect(outcome.succeeded, isFalse);
      expect(app.lastError, isNull, reason: '"电脑上没这条命令"是信息，不是故障');
      app.dispose();
    });

    test('失败留声：抛了就记进 lastError 并返回 null', () async {
      final client = _CommandClient(commandThrows: true);
      final app = await _appWith(client);

      final outcome = await app.executeCommand('/goal 睡觉');

      expect(outcome, isNull);
      expect(app.lastError?.message, '电脑侧炸了');
      app.dispose();
    });

    test('应答形状认不出：留声，不让调用方读上一条错误', () async {
      // `matched: true` 却没有 `execution` —— 电脑侧实现不对，不能读成成功。
      final client = _CommandClient(commandResult: {'matched': true});
      final app = await _appWith(client);

      final outcome = await app.executeCommand('/goal 睡觉');

      expect(outcome, isNull);
      expect(app.lastError?.message, contains('形状认不出'));
      app.dispose();
    });
  });

  group('聊天页接线：一处分流', () {
    testWidgets('斜杠命令走 command.execute（不是 session.prompt），成功后清空输入框', (
      tester,
    ) async {
      final client = _CommandClient(
        commandResult: {
          'matched': true,
          'execution': {
            'commandId': 'cmd-1-1',
            'result': {'kind': 'success', 'text': 'Goal created'},
          },
        },
      );
      final app = await _appWith(client);
      await _pumpChat(tester, app);

      await _sendText(tester, '/goal 睡觉');

      expect(client.sent, hasLength(1), reason: '只发一次，不发两遍');
      final (method, params, _) = client.sent.single;
      expect(method, 'command.execute', reason: '斜杠行是命令，不是普通消息');
      expect(params['line'], '/goal 睡觉');
      expect(find.text('/goal 睡觉'), findsNothing, reason: '跑过了就清空输入框');
      app.dispose();
    });

    testWidgets('普通文本仍走 session.prompt', (tester) async {
      final client = _CommandClient();
      final app = await _appWith(client);
      await _pumpChat(tester, app);

      await _sendText(tester, '睡觉');

      expect(client.sent, hasLength(1));
      final (method, params, _) = client.sent.single;
      expect(method, 'session.prompt', reason: '没有斜杠就不是命令');
      expect(params['content'], [
        {'type': 'text', 'text': '睡觉'},
      ]);
      app.dispose();
    });

    testWidgets('电脑上没有这条命令：按普通消息发出去，并说一句', (tester) async {
      // Web 的同一条推导：目录未命中 ⇒ 退成普通消息（`machine.ts:170-175`）。
      final client = _CommandClient(commandResult: {'matched': false});
      final app = await _appWith(client);
      await _pumpChat(tester, app);

      await _sendText(tester, '/nope 你好');

      expect(client.sent, hasLength(2), reason: '先问命令面，再按消息发');
      expect(client.sent[0].$1, 'command.execute');
      expect(client.sent[1].$1, 'session.prompt');
      expect(client.sent[1].$2['content'], [
        {'type': 'text', 'text': '/nope 你好'},
      ]);
      // **必须说出来**：不说的话用户以为命令跑过了。
      expect(find.textContaining('电脑上没有这条命令'), findsOneWidget);
      app.dispose();
    });

    testWidgets('命令执行失败：如实报，且文本留在输入框', (tester) async {
      final client = _CommandClient(commandThrows: true);
      final app = await _appWith(client);
      await _pumpChat(tester, app);

      await _sendText(tester, '/goal 睡觉');

      expect(client.sent, hasLength(1), reason: '失败了就不该再当消息发一遍');
      expect(client.sent.single.$1, 'command.execute');
      expect(find.textContaining('命令没有执行'), findsOneWidget);
      expect(find.text('/goal 睡觉'), findsOneWidget, reason: '文本要留着，改一改就能再发');
      app.dispose();
    });
  });
}
