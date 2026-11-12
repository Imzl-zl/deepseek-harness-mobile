/// 文件面板两段清单的**语义角色**：朗读器要能说出"这是个按钮"。
///
/// ## 为什么这两行要单独有一条用例
///
/// `ChangesPane` 与 `ChangedFileList` 是上一批从 `chat_page.dart` 搬出来的
/// （笔记 `implemented/2026-11-12-chat-page-files-pane-move.md`：**只搬、不改行为**），
/// 于是它们保留了搬移前的样子 —— 手写 `InkWell`，只有点击动作、没有角色。
/// 而它们点下去都**真的会发生什么**：
///
/// | 行 | 点一下的后果 |
/// |---|---|
/// | 改动清单行（`ChangesPane`） | 打开这一行的 diff / 文件内容（`AppModel.openFile`） |
/// | 差异行（`ChangedFileList`） | **复制这一行的路径**（`Clipboard.setData` + toast） |
///
/// 有真实后果 ⇒ 该报按钮角色（判据同 `implemented/2026-11-11-fake-affordances.md`
/// 的反面：点了会发生的才配报）。
///
/// 这一组钉三件事：
///
/// 1. 两行对朗读器都是**按钮**；
/// 2. 行内文字**没被吞掉**（路径与 `+N` 仍读得到）—— 只加角色，不加
///    `MergeSemantics` / `excludeSemantics`（本仓已否过一次，会让行内其它入口摸不到）；
/// 3. 按下语义动作**真的到达那一步**（打开的是这一行的 path / 复制的就是这一行）。
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/files_pane.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';
import 'projection_fixture.dart';

const String _sid = 'sid_1';

/// 宿主的改动记录（连接器 `dsh/changes.ts` 逐字段构造出来的那一层）。
const Map<String, Object?> _summary = {
  'turn': 3,
  'files': [
    {
      'path': 'app/lib/main.dart',
      'display': 'app/lib/main.dart',
      'added': 9,
      'deleted': 2,
    },
  ],
  'total': 1,
  'added': 9,
  'deleted': 2,
};

class _ChangesClient extends FakeSyncClient {
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
              'caps': <String, Object?>{'changes': true, 'files': true},
            }
            as T;
      case 'file.changes':
        return <String, Object?>{'summary': _summary} as T;
      case 'file.diff':
        return <String, Object?>{
              'diff': {
                'kind': 'text',
                'path': 'app/lib/main.dart',
                'display': 'app/lib/main.dart',
                'before': true,
                'after': true,
                'coarse': false,
                'hunks': const <Object?>[],
              },
            }
            as T;
      case 'file.read':
        return <String, Object?>{
              'page': {'text': '// file', 'offset': 1, 'lines': 1, 'eof': true},
            }
            as T;
    }
    return <String, Object?>{} as T;
  }
}

Future<AppModel> _model(_ChangesClient client) async {
  final app = AppModel(client: client);
  app.seedForTest(
    sid: _sid,
    title: 't',
    updatedAt: 1,
    items: [
      projectEvent(
        type: 'workspace/changes',
        seq: 6,
        data: <String, Object?>{'turn': 1},
        turn: 1,
      ).item!,
    ],
  );
  await app.refreshRepoInfo();
  await app.openSession(_sid);
  return app;
}

Widget _host(Widget child) => MaterialApp(
  theme: DshTheme.dark(),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('改动清单行：按钮角色 + 路径仍读得到 + 按下真的打开这一行', (tester) async {
    final client = _ChangesClient();
    final app = await _model(client);
    addTearDown(app.dispose);

    await tester.pumpWidget(_host(ChangesPane(app: app, seq: 6, tab: 0)));
    await tester.pumpAndSettle();

    final row = tester.getSemantics(
      find.byKey(const ValueKey<String>('changed-file-0')),
    );
    expect(
      row,
      isSemantics(isButton: true, hasTapAction: true),
      reason: '行是手写 InkWell：不加 Semantics 就只有点击动作、没有按钮角色',
    );
    expect(
      row.getSemanticsData().label,
      allOf(contains('app/lib/main.dart'), contains('+9')),
      reason: '只加角色，不能把行内文字吞掉',
    );

    // 角色不是靠"吞掉动作"换来的：语义动作真的走到 `openFile`。
    tester.semantics.performAction(
      find.semantics.byLabel(RegExp(r'app/lib/main\.dart')),
      SemanticsAction.tap,
    );
    await tester.pumpAndSettle();
    // diff 模式的坐标是 `seq` + 行下标（不是路径）：下标 0 = 第一行。
    expect(
      client.sent
          .where((c) => c.$1 == 'file.diff')
          .map((c) => (c.$2['seq'], c.$2['index'])),
      [(6, 0)],
    );
  });

  testWidgets('差异行（点一下复制路径）：按钮角色 + 路径仍读得到 + 复制的是这一行', (tester) async {
    final clipboard = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') clipboard.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(
      _host(
        const ChangedFileList(
          rows: [(path: 'app/lib/main.dart', stat: (added: 9, removed: 2))],
          showStat: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final row = tester.getSemantics(
      find.byKey(const ValueKey<String>('changed-path-app/lib/main.dart')),
    );
    expect(
      row,
      isSemantics(isButton: true, hasTapAction: true),
      reason: '它不只是文字：点一下会复制这一行的路径',
    );
    expect(
      row.getSemanticsData().label,
      contains('app/lib/main.dart'),
      reason: '没有路径的按钮念不出"复制哪个文件"',
    );

    tester.semantics.performAction(
      find.semantics.byLabel(RegExp(r'app/lib/main\.dart')),
      SemanticsAction.tap,
    );
    await tester.pumpAndSettle();

    expect(clipboard, hasLength(1));
    expect(
      (clipboard.single.arguments as Map<Object?, Object?>)['text'],
      'app/lib/main.dart',
    );
  });
}
