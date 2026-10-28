/// 连接瞬间只该出现**一次**加载态，然后直接落到最终那一屏。
///
/// ## 之前发生了什么（真机反馈）
///
/// 刚连上时界面会连续换好几屏：先是会话列表（空），再跳成 hero，再跳进上一次
/// 的会话 —— 每一步都是"数据到位了一半"的画。用户的原话是"连续跳好几个页面"。
///
/// 根因：`_boot()` 一结束就画 `ChatPage`，而**落点要等 `session.list` 回来**；
/// 这中间 `currentSid` 是 `null`，于是先画了"没有会话"的那一屏。
///
/// 判据：`AppModel.landingDone`（首次落点已尝试，**包括"没有可落的会话"**）。
/// 未完成且已配对 ⇒ 画加载态；完成 ⇒ 画最终屏。落点规则本身不变
/// （`docs/subsystems/connect-landing.md` §2）。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart' as conn;
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

class _Client extends FakeSyncClient {
  _Client({this.rows = const [], this.holdList = true});

  List<Object?> rows;

  /// `true` = 清单永远不回来（用例 1 要"还没回来"那一帧）。
  final bool holdList;

  final Completer<void> listGate = Completer<void>();

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
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    if (method == 'session.list') {
      if (holdList) await listGate.future;
      return {'sessions': rows} as T;
    }
    throw const ProtocolException(ErrorCode.relayOffline, '测试不连');
  }
}

Widget _page(AppModel app) => MaterialApp(
  theme: DshTheme.dark(),
  home: ChatPage(
    app: app,
    paired: true,
    onOpenDrawer: () {},
    onNewSession: () {},
    drawer: const SizedBox.shrink(),
  ),
);

void main() {
  testWidgets('清单还没回来：画加载态，不先画"没有会话"', (tester) async {
    final client = _Client();
    final app = AppModel(client: client);
    addTearDown(app.dispose);

    await tester.pumpWidget(_page(app));
    // 进服务态：落点开始（清单还没回来）。
    unawaited(app.landAfterConnect());
    await tester.pump();

    expect(find.text('正在连接电脑…'), findsOneWidget);
    expect(app.landingDone, isFalse, reason: '落点还没走完 —— 界面不该假装"没有会话"');

    // 收尾：让清单回来，别把悬着的 future 留在用例后面。
    client.listGate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  });

  testWidgets('落点完成（有会话）：加载态消失，直接是那一屏', (tester) async {
    final client = _Client(
      holdList: false,
      rows: [
        {
          'sid': 's1',
          'title': '会话一',
          'updatedAt': 2,
          'running': false,
          'blank': false,
          'subagent': false,
        },
      ],
    );
    final app = AppModel(client: client);
    addTearDown(app.dispose);

    await tester.pumpWidget(_page(app));
    await tester.pump();

    // 生产里这一串由"进服务态"那条回调触发；**必须 `runAsync`**：
    // 里面有真实异步链，`testWidgets` 的假时钟不会替它转。
    await tester.runAsync(() => app.landAfterConnect());
    // **不用 `pumpAndSettle`**：加载态那枚转圈是无限动画，settle 永远等不到。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('正在连接电脑…'), findsNothing);
    expect(app.currentSid, 's1');
    expect(app.landingDone, isTrue);
  });

  testWidgets('落点完成（清单为空）：也算完成，不无限转圈', (tester) async {
    final client = _Client(holdList: false, rows: const []);
    final app = AppModel(client: client);
    addTearDown(app.dispose);

    await tester.pumpWidget(_page(app));
    await tester.pump();

    await tester.runAsync(() => app.landAfterConnect());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(app.landingDone, isTrue);
    expect(find.text('正在连接电脑…'), findsNothing);
  });
}
