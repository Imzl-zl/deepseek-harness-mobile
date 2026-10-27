/// 批 E：连接瞬间"还有子智能体在跑"要**在会话页就看得见**。
///
/// 判据出处：桌面在客户端算数量（`ui-workspace/src/client/tree.ts:381-386`
/// 的 `runningChildCount`：父行 `values.subagentCatalog` × 子行 `running`），
/// 行里再画第二枚状态点（`rows/Rows.tsx:352-362`）。
/// 手机不改语义，只改形态：**一枚点 + 一行文字**（360dp 放不下两枚点）。
///
/// Note: 设计与行规格见 `.agents/notes/proposed/2026-10-27-ui-state-design.md` §5。
library;

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/chat_item.dart' show SessionSummary;
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:dsh_mobile/wire/reading.dart' show WireOk;
import 'package:dsh_mobile/wire/rpc/session.dart' show readSessionRow;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

Map<String, Object?> _child(String sid, {required bool running}) => {
  'sid': sid,
  'updatedAt': 1,
  'running': running,
  'blank': false,
  'subagent': true,
  'parentSessionId': 'parent',
};

Map<String, Object?> _parent(List<String> childIds) => {
  'sid': 'parent',
  'updatedAt': 2,
  'running': false,
  'blank': false,
  'subagent': false,
  'projections': {
    'kind': 'sequenced',
    'asOfSeq': 0,
    'values': {
      'subagentCatalog': [
        for (final id in childIds)
          {'id': id, 'createdAt': 1, 'mode': 'one-shot'},
      ],
    },
  },
};

class _Client extends FakeSyncClient {
  _Client(this.rows);

  final List<Object?> rows;

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
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();
  @override
  Future<void> unsubscribe(String sid) async {}
  @override
  Future<SessionAnchor> subscribe(String sid, {required int since}) async =>
      const SessionAnchor(since: 0, hasMore: false);

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'session.list') return {'sessions': rows} as T;
    throw const ProtocolException(ErrorCode.relayOffline, '测试不连');
  }
}

void main() {
  test('行解码：父行带 values.subagentCatalog → SessionSummary.subagents', () {
    final row = readSessionRow(_parent(['c1', 'c2']));
    expect(row, isA<WireOk<SessionSummary>>());
    expect((row as WireOk<SessionSummary>).value.subagents.map((s) => s.id), [
      'c1',
      'c2',
    ]);
  });

  test('runningChildrenOf：只数在跑的子级（照 tree.ts:381-386）', () async {
    final app = AppModel(
      client: _Client([
        _parent(['c1', 'c2', 'c3']),
        _child('c1', running: true),
        _child('c2', running: false),
        _child('c3', running: true),
      ]),
    );
    addTearDown(app.dispose);
    await app.refreshSessions();

    expect(app.runningChildrenOf('parent'), 2);
  });

  test('没有子目录 / 子级都不在跑 → 0', () async {
    final app = AppModel(
      client: _Client([
        {
          'sid': 'plain',
          'updatedAt': 1,
          'running': true,
          'blank': false,
          'subagent': false,
        },
      ]),
    );
    addTearDown(app.dispose);
    await app.refreshSessions();

    expect(app.runningChildrenOf('plain'), 0);
  });

  testWidgets('会话页：一行「N 个子智能体在运行」，点它打开子智能体面板', (tester) async {
    final app = AppModel(
      client: _Client([
        _parent(['c1', 'c2']),
        _child('c1', running: true),
        _child('c2', running: false),
      ]),
    );
    addTearDown(app.dispose);
    await app.refreshSessions();
    await app.openSession('parent');

    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: ChatPage(
          app: app,
          paired: true,
          onOpenDrawer: () {},
          onNewSession: () {},
          drawer: const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 个子智能体在运行'), findsOneWidget);

    await tester.tap(find.text('1 个子智能体在运行'));
    await tester.pumpAndSettle();
    expect(find.text('子智能体'), findsWidgets, reason: '点这一行落到子智能体面板');
  });

  testWidgets('360dp + 字号 1.3 + 键盘态：这一行不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.reset);

    final app = AppModel(
      client: _Client([
        _parent(['c1']),
        _child('c1', running: true),
      ]),
    );
    addTearDown(app.dispose);
    await app.refreshSessions();
    await app.openSession('parent');

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(360, 780),
          textScaler: TextScaler.linear(1.3),
          viewInsets: EdgeInsets.only(bottom: 300),
        ),
        child: MaterialApp(
          theme: DshTheme.dark(),
          home: ChatPage(
            app: app,
            paired: true,
            onOpenDrawer: () {},
            onNewSession: () {},
            drawer: const SizedBox.shrink(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1 个子智能体在运行'), findsOneWidget);
    expect(
      tester.takeException(),
      isNull,
      reason: '多出来的一行必须进 `_BottomBudget`，不能用"挤一挤"解决',
    );
  });
}
