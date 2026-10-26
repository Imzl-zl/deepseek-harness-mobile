/// 收口改动卡（`workspace/changes` → `file.changes` → `_ChangedFilesCard`）。
///
/// ## 这一组守什么
///
/// 1. **数字与行都是电脑的记录**：标题用宿主的 `total`、行用 `display`、
///    二进制 / 过大是宿主的标记（`workspace-changes/src/types.ts:14-40`）；
///    手机不从工具调用自己推 `+N −M`。
/// 2. **两种"没有"分开**：`summary: null`（电脑侧没这条记录）⇒ 不画卡；
///    读失败 ⇒ 把电脑侧原话摆出来。
/// 3. **打开只走 `AppModel.openFile`**：点一行发出的 `file.read` 路径 = 那一行的 `path`。
/// 4. 没有 `caps.changes`（老连接器）⇒ 一次 `file.changes` 都不发、也不画卡。
library;

import 'dart:convert';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/items.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/data/projection.dart';
import 'package:dsh_mobile/model/changes.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:dsh_mobile/wire/rpc/changes.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

const String _sid = 'sid_1';

/// 宿主的记录形状（连接器 `dsh/changes.ts` 逐字段构造出来的那一层）。
const Map<String, Object?> _summary = {
  'turn': 3,
  'files': [
    {
      'path': 'app/lib/main.dart',
      'display': 'app/lib/main.dart',
      'added': 9,
      'deleted': 2,
    },
    {
      'path': 'assets/logo.png',
      'display': 'assets/logo.png',
      'added': 0,
      'deleted': 0,
      'binary': true,
    },
  ],
  'total': 2,
  'added': 9,
  'deleted': 2,
};

class _ChangesClient extends FakeSyncClient {
  _ChangesClient({
    this.changesAvailable = true,
    this.noRecord = false,
    this.readThrows,
  });

  final bool changesAvailable;

  /// `file.changes` 回 `{summary: null}`（电脑侧没有这条记录）。
  final bool noRecord;

  /// 让 `file.changes` 抛（宿主快照读失败）。
  final Exception? readThrows;

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
              'caps': <String, Object?>{
                if (changesAvailable) 'changes': true,
                'files': true,
              },
            }
            as T;
      case 'file.changes':
        final thrown = readThrows;
        if (thrown != null) throw thrown;
        return <String, Object?>{'summary': noRecord ? null : _summary} as T;
      case 'file.read':
        return <String, Object?>{
              'page': {'text': '// file', 'offset': 1, 'lines': 1, 'eof': true},
            }
            as T;
    }
    return <String, Object?>{} as T;
  }
}

/// 一条 `workspace/changes`（真形状只有轮号：`workspace-changes/src/types.ts:99-108`）。
ChatItem _changesEvent({required int seq, required int turn}) => projectEvent(
  type: 'workspace/changes',
  seq: seq,
  data: <String, Object?>{'turn': turn},
  turn: turn,
).item!;

ChatItem _writeCall({required int seq, required int turn}) => projectEvent(
  type: 'tool/call',
  seq: seq,
  turn: turn,
  data: <String, Object?>{
    'turn': turn,
    'step': 1,
    'callId': 'c1',
    'name': 'write',
    'arguments': jsonEncode(<String, Object?>{
      'file_path': 'app/lib/main.dart',
      'content': 'x',
    }),
  },
).item!;

ChatItem _assistant({required int seq, required int turn}) => projectEvent(
  type: 'assistant/message',
  seq: seq,
  turn: turn,
  data: <String, Object?>{
    'turn': turn,
    'step': 1,
    'message': <String, Object?>{
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': '改好了。'},
      ],
      'source': {'kind': 'model'},
      'id': 'm1',
    },
  },
).item!;

ChatItem _turnEnd({required int seq, required int turn}) => projectEvent(
  type: 'turn/end',
  seq: seq,
  turn: turn,
  data: <String, Object?>{
    'turn': turn,
    'reason': <String, Object?>{'kind': 'completed'},
  },
).item!;

Future<AppModel> _seeded(_ChangesClient client) async {
  final app = AppModel(client: client);
  app.seedForTest(
    sid: _sid,
    title: 't',
    updatedAt: 1,
    items: [
      _writeCall(seq: 2, turn: 1),
      _assistant(seq: 3, turn: 1),
      _turnEnd(seq: 4, turn: 1),
      _changesEvent(seq: 6, turn: 1),
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
  group('值解析（model + wire）', () {
    test('summary 解析：行字段、binary / oversized、truncated 照报', () {
      final summary = ChangesSummary.fromWire(_summary);
      expect(summary, isNotNull);
      expect(summary!.turn, 3);
      expect(summary.total, 2);
      expect(summary.files.map((f) => f.path), [
        'app/lib/main.dart',
        'assets/logo.png',
      ]);
      expect(summary.files.last.binary, isTrue);
      expect(summary.files.first.binary, isFalse);
      expect(summary.truncated, isFalse);

      // `total` 比 `files` 多 = 宿主的 maxFiles 截过。
      final capped = ChangesSummary.fromWire({..._summary, 'total': 9});
      expect(capped!.truncated, isTrue);
      expect(capped.total, 9);
    });

    test('summary 解析：缺字段整个不要（不编 0）', () {
      expect(ChangesSummary.fromWire({'turn': 1}), isNull);
      expect(
        ChangesSummary.fromWire({
          'turn': 1,
          'files': [],
          'total': 0,
          'added': 0,
          // deleted 缺
        }),
        isNull,
      );
    });

    test('{summary:null} 是有效应答；缺 summary 键才是形状错', () {
      expect(valueOrNull(readChangesSummary({'summary': null})), isNull);
      expect(
        readChangesSummary({'summary': null}),
        isA<WireOk<ChangesSummary?>>(),
      );
      expect(readChangesSummary({}), isA<WireBad<ChangesSummary?>>());
      expect(readChangesSummary('x'), isA<WireBad<ChangesSummary?>>());
      expect(
        readChangesSummary({
          'summary': {'turn': 1},
        }),
        isA<WireBad<ChangesSummary?>>(),
        reason: 'summary 在但字段不齐 ⇒ 形状错，不能静默当成"没记录"',
      );
    });

    test('itemId：workspace/changes 按轮号（同一轮最新一条覆盖），缺 turn 抛', () {
      expect(
        itemIdOf(
          const EventLike(type: 'workspace/changes', seq: 6, data: {'turn': 3}),
        ),
        'w:3',
      );
      expect(
        () => itemIdOf(
          const EventLike(type: 'workspace/changes', seq: 6, data: {}),
        ),
        throwsStateError,
      );
    });

    test('投影：workspace/changes → ChangesItem（带轮号与 seq）', () {
      final item = _changesEvent(seq: 6, turn: 3) as ChangesItem;
      expect(item.itemId, 'w:3');
      expect(item.seq, 6);
      expect(item.turn, 3);
    });
  });

  group('模型（AppModel）', () {
    Future<AppModel> app(_ChangesClient client) async {
      final app = await _seeded(client);
      addTearDown(app.dispose);
      return app;
    }

    test('读到记录：三态 loaded + summary；请求带 seq', () async {
      final client = _ChangesClient();
      final model = await app(client);

      await model.loadChangesSummary(6);

      expect(
        client.sent.where((c) => c.$1 == 'file.changes').map((c) => c.$2),
        [
          {'sid': _sid, 'seq': 6},
        ],
      );
      final state = model.changesStateOf(6);
      expect(state.loaded, isTrue);
      expect(state.summary!.total, 2);
      expect(model.changesLoading(6), isFalse);
      expect(model.changesFailureOf(6), isNull);
    });

    test('电脑侧没有记录：loaded 但 summary 为 null（不是失败）', () async {
      final client = _ChangesClient(noRecord: true);
      final model = await app(client);

      await model.loadChangesSummary(6);

      final state = model.changesStateOf(6);
      expect(state.loaded, isTrue);
      expect(state.summary, isNull);
      expect(model.changesFailureOf(6), isNull);
    });

    test('没有 caps.changes：一次请求都不发', () async {
      final client = _ChangesClient(changesAvailable: false);
      final model = await app(client);

      await model.loadChangesSummary(6);

      expect(client.sent.where((c) => c.$1 == 'file.changes'), isEmpty);
      expect(model.changesStateOf(6).loaded, isFalse);
    });

    test('读失败：原因照报电脑侧原话', () async {
      final client = _ChangesClient(
        readThrows: Exception('snapshot read failed: EACCES'),
      );
      final model = await app(client);

      await model.loadChangesSummary(6);

      expect(model.changesStateOf(6).loaded, isFalse);
      expect(model.changesFailureOf(6), contains('snapshot read failed'));
    });
  });

  group('卡片', () {
    testWidgets('标题用完整文件数、行用 display、二进制是宿主的标记', (tester) async {
      final client = _ChangesClient();
      final model = await _seeded(client);
      addTearDown(model.dispose);
      await _pump(tester, model);

      expect(find.text('已编辑 2 个文件'), findsOneWidget);
      expect(find.text('app/lib/main.dart'), findsOneWidget);
      expect(find.text('assets/logo.png'), findsOneWidget);
      expect(find.text('+9'), findsWidgets);
      expect(find.text('-2'), findsWidgets);
      expect(find.text('二进制'), findsOneWidget);
      // 请求确实发了（seq 是坐标，不是路径）。
      expect(
        client.sent
            .where((c) => c.$1 == 'file.changes')
            .map((c) => c.$2['seq']),
        [6],
      );
    });

    testWidgets('点一行：file.read 收到那一行的 path（唯一打开动作）', (tester) async {
      final client = _ChangesClient();
      final model = await _seeded(client);
      addTearDown(model.dispose);
      await _pump(tester, model);

      await tester.tap(find.text('assets/logo.png'));
      await tester.pumpAndSettle();

      expect(
        client.sent.where((c) => c.$1 == 'file.read').map((c) => c.$2['path']),
        ['assets/logo.png'],
      );
      // 打开动作落到右抽屉（与正文提及同一个落点）。
      expect(
        find.byKey(const ValueKey<String>('file-open-back')),
        findsOneWidget,
      );
    });

    testWidgets('电脑侧没有这条记录：不画卡，也不报错', (tester) async {
      final client = _ChangesClient(noRecord: true);
      final model = await _seeded(client);
      addTearDown(model.dispose);
      await _pump(tester, model);

      expect(find.textContaining('已编辑'), findsNothing);
      expect(find.textContaining('读取失败'), findsNothing);
    });

    testWidgets('没有 caps.changes：不画卡、一次 file.changes 都不发', (tester) async {
      final client = _ChangesClient(changesAvailable: false);
      final model = await _seeded(client);
      addTearDown(model.dispose);
      await _pump(tester, model);

      expect(find.textContaining('已编辑'), findsNothing);
      expect(client.sent.where((c) => c.$1 == 'file.changes'), isEmpty);
    });

    testWidgets('读失败：卡片位置摆出电脑侧原话 + 重试', (tester) async {
      final client = _ChangesClient(
        readThrows: const ProtocolException(
          ErrorCode.internal,
          'snapshot read failed: EACCES',
        ),
      );
      final model = await _seeded(client);
      addTearDown(model.dispose);
      await _pump(tester, model);

      expect(find.textContaining('改动记录读取失败'), findsOneWidget);
      expect(find.textContaining('snapshot read failed'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
    });
  });
}
