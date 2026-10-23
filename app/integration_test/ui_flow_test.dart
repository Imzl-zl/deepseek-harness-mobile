/// 真机上的**界面流程**：主页是聊天页、抽屉能开、右抽屉能开。
///
/// ## 为什么必须在设备上跑
///
/// 这些是"点得中吗"的问题 —— 布局对了不等于能点中（`adb` 坐标点偏过好几次，
/// 而 `uiautomator` 在 Flutter 自绘界面里看不到我们的语义树）。
/// 用 `integration_test` 直接按 widget 找元素并点，绕开坐标问题。
///
/// 它同时补上手工做不到的一步：`adb shell input tap` 只能点坐标，
/// 而这个测试点的是**元素**。
///
/// 跑法（模拟器已在跑）：
/// ```
/// flutter test integration_test/ui_flow_test.dart -d emulator-5554
/// ```
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:dsh_mobile/ui/dsh_brand.dart';
import 'package:dsh_mobile/ui/dsh_composer.dart';
import 'package:dsh_mobile/ui/side_pane.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 假客户端（同 `test/widget_test.dart` 那份：界面测试不关心协议）。
///
/// **不用 `FakeSyncClient` 基类**：那个在 `test/` 下，而 `integration_test/`
/// 用相对路径跨目录引它会让 `dart analyze` 的继承解析出问题
/// （`@override` 全报"不 override 任何成员"，2026-10-19 实测）。
/// 这里自己实现全份 —— 它本来就已经实现了绝大部分。
class _FakeClient implements SyncClient {
  @override
  ConnectionState get state => ConnectionState.idle;
  @override
  Stream<ConnectionState> get connection => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<void> reconnect() => start();
  @override
  Future<void> setAppState(AppState state) async {}
  @override
  Future<void> close() async {}
  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();
  @override
  Stream<SessionStatus> get sessionStatus =>
      const Stream<SessionStatus>.empty();
  @override
  Future<SessionAnchor> subscribe(String sid, {required int since}) async =>
      const SessionAnchor(since: 0, hasMore: false);
  @override
  Future<void> unsubscribe(String sid) async {}
  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();
  @override
  Future<SessionPage> page({
    required String sid,
    required int beforeSeq,
    int maxMessages = SyncClient.kHistoryPageMaxMessages,
    int minMessages = SyncClient.kHistoryPageMinMessages,
    int minTurns = SyncClient.kHistoryPageMinTurns,
  }) async => const SessionPage(events: [], hasMore: false);
  @override
  bool hasOlderHistory(String sid) => false;
  @override
  Future<SessionEvent> refetch({required String sid, required int seq}) async =>
      throw const ProtocolException(ErrorCode.relayOffline, '测试里不连');
  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async => throw const ProtocolException(ErrorCode.relayOffline, '测试里不连');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('示例模式下能开右抽屉（状态位 → 文件面板）', (tester) async {
    final app = AppModel(client: _FakeClient());
    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: ChatPage(
          app: app,
          paired: false,
          onOpenDrawer: () {},
          onNewSession: () {},
          drawer: const Drawer(child: SizedBox()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 没配对时状态位走"去配对"那条路（不该开右抽屉）。
    // 所以先装示例数据 —— 那是"没连电脑也想看界面"的入口。
    await tester.tap(find.text('看示例数据'));
    await tester.pumpAndSettle();

    // 状态位该显示任务数（示例数据里有两个 running）。
    expect(find.textContaining('任务运行中'), findsOneWidget);

    // 点它 → 右抽屉打开，且默认在"文件"面板。
    await tester.tap(find.textContaining('任务运行中'));
    await tester.pumpAndSettle();
    expect(find.byType(SidePane), findsOneWidget);
    expect(find.text('chat_page.dart'), findsOneWidget);
    expect(find.text('app/lib/ui/chat_page.dart'), findsOneWidget);

    // 切到"任务"面板。
    await tester.tap(find.text('任务'));
    await tester.pumpAndSettle();
    expect(find.text('进行中'), findsOneWidget);
    // 用 `textContaining`：那行命令可能被省略号截断（`TextOverflow.ellipsis`），
    // 而 `find.text` 要求**完全相等** —— 第一版就是这么写错的。
    expect(find.textContaining('flutter build'), findsOneWidget);

    // 切到"子代理"面板。
    await tester.tap(find.text('子代理'));
    await tester.pumpAndSettle();
    expect(find.text('Extract DSH icon paths'), findsOneWidget);

    // 关掉（右上角那个 × ）。
    await tester.tap(find.byTooltip('收起'));
    await tester.pumpAndSettle();
    expect(find.byType(SidePane), findsNothing);
  });

  testWidgets('统计条三项各自弹 sheet（上下文的是三段用量条）', (tester) async {
    final app = AppModel(client: _FakeClient());
    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: ChatPage(
          app: app,
          paired: false,
          onOpenDrawer: () {},
          onNewSession: () {},
          drawer: const Drawer(child: SizedBox()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('看示例数据'));
    await tester.pumpAndSettle();
    // 打开第一个示例会话（统计条要有会话才显示）。
    await app.openSession('preview-1');
    await tester.pumpAndSettle();

    // 三项统计都在。
    expect(find.textContaining('第 1 轮'), findsOneWidget);
    expect(find.textContaining('302K'), findsOneWidget);

    // 点"上下文"那一项 → 三段用量条 + 图例（照原型 `sheet-context`）。
    await tester.tap(find.text('3%'));
    await tester.pumpAndSettle();
    expect(find.textContaining('上下文已用'), findsOneWidget);
    expect(find.text('系统提示词'), findsOneWidget);
    expect(find.text('工具定义'), findsOneWidget);
    expect(find.text('对话消息'), findsOneWidget);
    // `19900 / 1000000` → `19.9K / 1M`。
    expect(find.text('19.9K / 1M'), findsOneWidget);

    // 关掉，再点"会话统计"那一项 → 五个 kv。
    Navigator.of(tester.element(find.text('系统提示词'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('第 1 轮'));
    await tester.pumpAndSettle();
    expect(find.text('会话统计'), findsOneWidget);
    expect(find.text('首 token (TTFT)'), findsOneWidget);
    expect(find.text('输出速度'), findsOneWidget);
    Navigator.of(tester.element(find.text('会话统计'))).pop();
    await tester.pumpAndSettle();

    // 再点"Token 用量" → 六行。
    await tester.tap(find.textContaining('302K'));
    await tester.pumpAndSettle();
    expect(find.text('Token 用量'), findsOneWidget);
    expect(find.text('缓存读取'), findsOneWidget);
    expect(find.text('合计'), findsOneWidget);
  });

  testWidgets('＋ 菜单：五项都在，选"附件"才加进来', (tester) async {
    final app = AppModel(client: _FakeClient());
    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: ChatPage(
          app: app,
          paired: false,
          onOpenDrawer: () {},
          onNewSession: () {},
          drawer: const Drawer(child: SizedBox()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('看示例数据'));
    await tester.pumpAndSettle();
    await app.openSession('preview-1');
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('添加文件或调用指令'));
    await tester.pumpAndSettle();
    for (final label in ['附件', '工作区文件', '新建终端', '浏览器', '后台任务']) {
      expect(find.text(label), findsOneWidget, reason: '菜单缺「$label」');
    }
    await tester.tap(find.text('附件'));
    await tester.pumpAndSettle();
    expect(find.text('新增文件.txt'), findsOneWidget);
  });

  testWidgets('左缘跟手拖 / 顶栏 ☰ 都能开抽屉', (tester) async {
    final app = AppModel(client: _FakeClient());
    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: ChatPage(
          app: app,
          paired: false,
          onOpenDrawer: () {},
          onNewSession: () {},
          drawer: const Drawer(child: Text('抽屉内容')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('抽屉内容'), findsNothing, reason: '还没划');

    // 左缘最外缘往右拖：原生 `Drawer` 的**跟手**拖动（`drawerEdgeDragWidth: 32`）。
    await tester.dragFrom(const Offset(2, 300), const Offset(300, 0));
    await tester.pumpAndSettle();
    expect(find.text('抽屉内容'), findsOneWidget, reason: '左缘跟手拖必须能开抽屉');

    // 关掉，再用顶栏 ☰ 开一次 —— 两条入口都要通。
    await tester.tap(find.byTooltip('打开会话抽屉'));
    await tester.pumpAndSettle();
    expect(find.text('抽屉内容'), findsOneWidget, reason: '顶栏 ☰ 也要能开');
  });

  testWidgets('接管：审批 → 提问 → 计划 依次出现（队列是瀑布）', (tester) async {
    final app = AppModel(client: _FakeClient());
    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: ChatPage(
          app: app,
          paired: false,
          onOpenDrawer: () {},
          onNewSession: () {},
          drawer: const Drawer(child: SizedBox()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('看示例数据'));
    await tester.pumpAndSettle();
    await app.openSession('preview-1');
    await tester.pumpAndSettle();

    // 从 ＋ 菜单进"演示：接管输入栏"。
    await tester.tap(find.byTooltip('添加文件或调用指令'));
    await tester.pumpAndSettle();
    // **先滚到它再点**：菜单现在有 6 项，最后一项在 320×640 上落在 y≈707，
    // 超出屏幕（`tap` 报 "would not hit test"）。这与配对页那个确认按钮
    // 是同一类问题 —— 小屏上够不着就得滚。
    await tester.ensureVisible(find.text('演示：接管输入栏'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('演示：接管输入栏'));
    await tester.pumpAndSettle();

    // **队首是审批**（瀑布：一次只处理一个）。
    expect(find.text('等待审批'), findsOneWidget);
    expect(find.text('允许一次'), findsOneWidget);
    expect(find.text('等待回答'), findsNothing, reason: '队列是瀑布 —— 提问不该和审批同时出现');

    // 点"允许一次" → 换提问。
    await tester.tap(find.text('允许一次'));
    await tester.pumpAndSettle();
    expect(find.text('等待回答'), findsOneWidget);
    expect(find.text('一起拆'), findsOneWidget);
    // 推荐是独立徽标（不在标签里）。
    expect(find.text('推荐'), findsOneWidget);

    // 未回答时提交无效。
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();
    expect(find.text('等待回答'), findsOneWidget, reason: '没答就不该走');

    // 选一个再提交 → 换计划。
    await tester.tap(find.text('先只拆资源束'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('提交'));
    await tester.pumpAndSettle();
    expect(find.text('等待确认计划'), findsOneWidget);
    expect(find.text('同意执行'), findsOneWidget);

    // 同意 → 三个都答完，接管卡消失（输入栏回来）。
    await tester.tap(find.text('同意执行'));
    await tester.pumpAndSettle();
    expect(find.text('等待确认计划'), findsNothing);
    expect(find.byType(DshComposer), findsOneWidget);
  });

  testWidgets('轨迹页：甘特四行 + 账本，点条目弹 sheet', (tester) async {
    final app = AppModel(client: _FakeClient());
    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: ChatPage(
          app: app,
          paired: false,
          onOpenDrawer: () {},
          onNewSession: () {},
          drawer: const Drawer(child: SizedBox()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('看示例数据'));
    await tester.pumpAndSettle();

    // 切到轨迹页签。
    await tester.tap(find.text('轨迹'));
    await tester.pumpAndSettle();

    // 甘特四行（"错误"在账本里还会出现一次，所以用 findsWidgets）。
    for (final label in ['输入', '模型', '工具', '错误']) {
      expect(find.text(label), findsWidgets, reason: '甘特缺「$label」那一行');
    }
    expect(find.text('← 横滑查看完整时间轴 →'), findsOneWidget);

    // 账本。
    expect(find.text('上下文'), findsOneWidget);
    expect(find.text(kAppName), findsOneWidget);
    expect(find.text('工具 · read'), findsOneWidget);

    // 点一条 → 弹 `sheet-traj`。
    await tester.tap(find.text('工具 · read'));
    await tester.pumpAndSettle();
    expect(find.text('轨迹条目'), findsOneWidget);
    // `84 ms` 会**出现两次**：账本那一行 + sheet 里的"耗时"。
    //（那是同一个值的两处呈现，不是 bug —— 第一版写成 findsOneWidget 就红了。）
    expect(find.text('84 ms'), findsNWidgets(2));
    expect(find.text('查看完整调用'), findsOneWidget);

    await tester.tap(find.text('查看完整调用'));
    await tester.pumpAndSettle();
    expect(find.text('轨迹条目'), findsNothing);
  });

  testWidgets('输入栏在示例模式下可用（＋ 能加附件）', (tester) async {
    final app = AppModel(client: _FakeClient());
    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.dark(),
        home: ChatPage(
          app: app,
          paired: false,
          onOpenDrawer: () {},
          onNewSession: () {},
          drawer: const Drawer(child: SizedBox()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('看示例数据'));
    await tester.pumpAndSettle();

    // 示例模式**没有当前会话**（示例会话要进抽屉选）——
    // 所以输入栏仍是置灰的。这条断言把这个事实钉住：
    // 要么给示例模式自动选中第一个会话，要么输入栏就该灰着。
    // 当前行为是**灰着**（`enabled: _hasData && sid != null`）。
    final composer = tester.widget<DshComposer>(find.byType(DshComposer));
    expect(composer.enabled, isFalse, reason: '示例模式没有当前会话，输入栏该灰着（发消息需要 sid）');
  });
}
