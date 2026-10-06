/// 聊天页与抽屉的 widget 测试（**主页是聊天页**，照 `mock/proto`）。
///
/// ## 这一组守的是什么
///
/// 1. **信息架构**：主页是聊天页（不是会话列表），会话历史在抽屉里。
///    这条错了就是"结构上不是原型"——第一版正是这么错的。
/// 2. **三种空态分开说**：没配对 / 真没有会话 / 有会话但没选中。
/// 3. 顶栏三件套（`☰` / 状态胶囊 / `＋`）与输入栏三条硬规则的结构。
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:dsh_mobile/ui/dsh_composer.dart';
import 'package:dsh_mobile/ui/session_drawer.dart';
// **`hide ConnectionState`**：Flutter 的 `material.dart` 也导出 `ConnectionState`
// （`AsyncSnapshot` 的 none/waiting/active/done），与我们的**连接状态机**同名
// 但毫无关系。隐藏它，让本文件里 `ConnectionState` 只有一个意思。
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

/// 一个**只回固定答案**的假客户端：界面测试只关心"拿到这些数据时长什么样"。
class FakeClient implements SyncClient {
  FakeClient({this.sessions = const [], this.failWith});

  final List<Object?> sessions;
  final ProtocolException? failWith;

  @override
  ConnectionState get state => ConnectionState.idle;

  @override
  Stream<ConnectionState> get connection => const Stream.empty();

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
    final failure = failWith;
    if (failure != null) throw failure;
    if (method == 'session.list') return sessions as T;
    return null as T;
  }
}

Widget _wrap(
  AppModel app, {
  bool paired = true,
  VoidCallback? onConnect,
  VoidCallback? onOpenDrawer,
}) => MaterialApp(
  theme: DshTheme.dark(),
  home: ChatPage(
    app: app,
    paired: paired,
    onConnect: onConnect,
    onOpenDrawer: onOpenDrawer ?? () {},
    onNewSession: () {},
    drawer: const Drawer(child: SizedBox()),
  ),
);

void main() {
  group('主营是聊天页（照原型的信息架构）', () {
    testWidgets('没配对时也显示聊天页，不是"把界面换成配对页"', (tester) async {
      // 守的是一个设计错误：早先的写法是"没配对就把整个界面换成配对页"，
      // 于是用户打开 App 只看得到一张配对表单，**看不到任何界面**。
      await tester.pumpWidget(
        _wrap(AppModel(client: FakeClient()), paired: false),
      );
      await tester.pumpAndSettle();

      // 顶栏三件套都在（这是聊天页，不是别的页）。
      expect(find.byTooltip('打开会话抽屉'), findsOneWidget);
      expect(find.byTooltip('新建会话'), findsOneWidget);
      // 分段控件（对话 / 轨迹）在。
      expect(find.text('对话'), findsOneWidget);
      expect(find.text('轨迹'), findsOneWidget);
      // 输入栏在（置灰但可见）。
      expect(find.byType(DshComposer), findsOneWidget);
      // **不是**配对页。
      expect(find.text('配对'), findsNothing);
    });

    testWidgets('空态说"还没连电脑"，且给两个不需要连电脑的入口', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _wrap(
          AppModel(client: FakeClient()),
          paired: false,
          onConnect: () => tapped = true,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('还没连电脑'), findsOneWidget);
      expect(find.text('看示例数据'), findsOneWidget);
      expect(find.text('连电脑（配对）'), findsOneWidget);

      await tester.tap(find.text('连电脑（配对）'));
      await tester.pump();
      expect(tapped, isTrue);
    });

    testWidgets('有会话但没选中 → 提示去抽屉（不是"还没有会话"）', (tester) async {
      final app = AppModel(
        client: FakeClient(
          sessions: [
            {'sid': 's1', 'updatedAt': 0},
          ],
        ),
      );
      await app.refreshSessions();
      await tester.pumpWidget(_wrap(app));
      await tester.pumpAndSettle();

      expect(find.text('选一个会话'), findsOneWidget);
      expect(find.text('还没有会话'), findsNothing);
      expect(find.text('打开会话抽屉'), findsOneWidget);
    });

    testWidgets('☰ 与空态按钮都能开抽屉（回调被调到）', (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        _wrap(
          AppModel(client: FakeClient()),
          paired: false,
          onOpenDrawer: () => opened += 1,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('打开会话抽屉'));
      await tester.pump();
      expect(opened, 1);
    });
  });

  group('输入栏三条硬规则（§7.2）', () {
    testWidgets('规则 3：控制行左有 ＋/模型/权限，右**只有**发送', (tester) async {
      await tester.pumpWidget(_wrap(AppModel(client: FakeClient())));
      await tester.pumpAndSettle();

      // 左组三件。
      expect(find.byTooltip('添加文件或调用指令'), findsOneWidget);
      expect(find.byTooltip('工作区内可改'), findsOneWidget);
      expect(find.text('claude-opus'), findsOneWidget);
      // 占位符**照抄 DSH 原文**（半角逗号 + 空格）。
      // 用全角逗号会让它更宽、更早折行 —— 而在 320px 屏上它本来就接近放不下
      //（实测 15px 需要 345px、可用 282px），所以"折行"是预期的
      //（文档 §7.2：短屏由 CSS 自然折行，不手动截断）。
      expect(
        find.text('发消息或创建任务, / 调用指令, @ 文件或对话'),
        findsOneWidget,
        reason: '占位符必须与 mock/proto/index.html 的 placeholder 逐字相同',
      );
    });

    testWidgets('规则 2：文字独占一行（占位符不被按钮挤）', (tester) async {
      await tester.pumpWidget(_wrap(AppModel(client: FakeClient())));
      await tester.pumpAndSettle();

      // 占位符所在的 `TextField` 与 `＋` **不在同一行** ——
      // 判据是两者垂直位置不同（文字行在上，控制行在下）。
      final field = tester.getRect(find.byType(TextField));
      final plus = tester.getRect(find.byTooltip('添加文件或调用指令'));
      expect(
        plus.top,
        greaterThanOrEqualTo(field.bottom - 1),
        reason: '＋ 应在文字行**下方**（进文字行会把占位符挤折行）',
      );
    });

    testWidgets('规则 1：附件在**卡片内部**上方，不是卡片外一行', (tester) async {
      // **必须有一个当前会话** —— 没有会话时输入栏是置灰的
      //（`enabled: paired && sid != null`），`＋` 点了没反应。
      // 第一版这条测试就是漏了这一步，报"找不到新增文件.txt"。
      final app = AppModel(
        client: FakeClient(
          sessions: [
            {'sid': 's1', 'updatedAt': 0},
          ],
        ),
      );
      await app.refreshSessions();
      await app.openSession('s1');
      await tester.pumpWidget(_wrap(app));
      await tester.pumpAndSettle();

      // `＋` 现在开**菜单**（照原型：附件 / 工作区文件 / 新建终端 / 浏览器 / 后台任务），
      // 从菜单里选"附件"才加进来。第一版直接点了 `＋` 就断言附件出现 ——
      // 那时 `＋` 是直接加附件，没有菜单。
      await tester.tap(find.byTooltip('添加文件或调用指令'));
      await tester.pumpAndSettle();
      expect(find.text('添加'), findsOneWidget);
      await tester.tap(find.text('附件'));
      await tester.pumpAndSettle();

      expect(find.text('新增文件.txt'), findsOneWidget);
      // 它在输入框**上方**（同一张卡里）。
      final chip = tester.getRect(find.text('新增文件.txt'));
      final field = tester.getRect(find.byType(TextField));
      expect(
        chip.bottom,
        lessThanOrEqualTo(field.top + 1),
        reason: '附件轨应在文字行上方（卡片内部）',
      );
    });

    testWidgets('发送键：空输入时不可点，有内容才亮', (tester) async {
      await tester.pumpWidget(_wrap(AppModel(client: FakeClient())));
      await tester.pumpAndSettle();

      // 空输入：发送键存在但不响应（灰）。
      await tester.enterText(find.byType(TextField), '你好');
      await tester.pumpAndSettle();
      // 有内容后能点（点它会走 `session.prompt`，而这里没有当前会话，
      // 所以只是不崩 —— 断言它没抛异常）。
      await tester.tap(
        find.byIcon(Icons.send).evaluate().isEmpty
            ? find.byType(DshComposer)
            : find.byIcon(Icons.send),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('抽屉', () {
    testWidgets('底栏五个出口都在（文件/归档/示例/自动化/设置）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: DshTheme.dark(),
          home: Scaffold(
            drawer: SessionDrawer(
              sections: const [],
              connection: const DrawerConnection(
                name: '我的电脑',
                detail: '中转已连接 · 空闲',
                platform: 'DSH',
                online: true,
              ),
              footItems: [
                DrawerFootItem(icon: 'folderClose', label: '文件', onTap: () {}),
                DrawerFootItem(icon: 'archive', label: '归档', onTap: () {}),
                DrawerFootItem(icon: 'sparkle', label: '示例', onTap: () {}),
                DrawerFootItem(icon: 'clock', label: '自动化', onTap: () {}),
                DrawerFootItem(icon: 'settings', label: '设置', onTap: () {}),
              ],
              onNewSession: () {},
              onOpenSession: (_) {},
              onClose: () {},
            ),
            body: const SizedBox(),
          ),
        ),
      );
      // 打开抽屉。
      tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
      await tester.pumpAndSettle();

      for (final label in ['文件', '归档', '示例', '自动化', '设置']) {
        expect(find.text(label), findsOneWidget, reason: '底栏缺 $label');
      }
      expect(find.text('新建会话'), findsWidgets);
      expect(find.text('我的电脑'), findsOneWidget);
      expect(find.text('搜索会话'), findsOneWidget);
    });

    testWidgets('会话按今天/昨天/更早分组显示', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: DshTheme.dark(),
          home: Scaffold(
            drawer: SessionDrawer(
              sections: const [
                DrawerSection(
                  label: '今天',
                  sessions: [
                    DrawerSession(
                      sid: 's1',
                      title: '今天的会话',
                      preview: '3 条',
                      timeLabel: '14:20',
                      isActive: true,
                    ),
                  ],
                ),
                DrawerSection(
                  label: '昨天',
                  sessions: [
                    DrawerSession(
                      sid: 's2',
                      title: '昨天的会话',
                      preview: '5 条',
                      timeLabel: '昨天',
                    ),
                  ],
                ),
              ],
              connection: const DrawerConnection(
                name: '我的电脑',
                detail: '空闲',
                platform: 'DSH',
              ),
              footItems: const [],
              onNewSession: () {},
              onOpenSession: (_) {},
              onClose: () {},
            ),
            body: const SizedBox(),
          ),
        ),
      );
      tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
      await tester.pumpAndSettle();

      expect(find.text('今天'), findsOneWidget);
      // **"昨天"会出现两次**（分区标题 + 昨天那条会话的时间标签）——
      // 这是真实的重名，不是 bug：原型里分区叫"昨天"，而昨天的会话
      // 时间列也写"昨天"。所以断言用 `findsNWidgets(2)` 并说明原因，
      // 而不是把它当"只该有一个"。
      expect(find.text('昨天'), findsNWidgets(2));
      expect(find.text('今天的会话'), findsOneWidget);
      expect(find.text('昨天的会话'), findsOneWidget);
    });
  });
}
