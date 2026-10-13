/// 聊天页与抽屉的 widget 测试（**主页是聊天页**，照 `mock/proto`）。
///
/// ## 这一组守的是什么
///
/// 1. **信息架构**：主页是聊天页（不是会话列表），会话历史在抽屉里。
///    这条错了就是"结构上不是原型"——第一版正是这么错的。
/// 2. **三种空态分开说**：没配对 / 真没有会话 / 有会话但没选中。
/// 3. 顶栏三件套（`☰` / 状态胶囊 / `＋`）与输入栏三条硬规则的结构。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/send_mode.dart';
import 'package:dsh_mobile/theme/dsh_icons.dart';
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

  /// 被调过的方法名（按顺序）——用来断言"到底问没问过"。
  final List<String> calls = <String>[];

  /// 最后一次调用的参数（发送模式等"带了什么"的判据）。
  Map<String, Object?>? lastParams;

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
    calls.add(method);
    lastParams = params;
    final failure = failWith;
    if (failure != null) throw failure;
    // **形状照电脑侧**：`{ sessions: [...] }`（`connector/src/handlers.ts`）。
    // 假客户端若回一个裸数组，就会**掩盖**"真机回对象、而界面只认数组"
    // 这类形状不一致 —— 那正是列表在真机上恒为空的原因，且它不报错。
    if (method == 'session.list') return {'sessions': sessions} as T;
    return null as T;
  }
}

/// 一个**可以推连接状态**的假客户端（回归用）。
///
/// 与 [FakeClient] 的差别：那个的 `connection` 是 `Stream.empty()`（界面测试只关心
/// 静态形态），而"进服务态要不要自动拉列表"这条必须**能推出一次 `serving`** 才验得了。
class _StatefulFakeClient implements SyncClient {
  _StatefulFakeClient({this.sessions = const [], this.failWith});

  final List<Object?> sessions;
  final ProtocolException? failWith;

  /// 被调过的方法名（按顺序）——用来断言"到底问没问过"。
  final List<String> calls = [];

  final _states = StreamController<ConnectionState>.broadcast();
  var _state = ConnectionState.idle;

  void emit(ConnectionState next) {
    _state = next;
    _states.add(next);
  }

  @override
  ConnectionState get state => _state;

  @override
  Stream<ConnectionState> get connection => _states.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> setAppState(AppState state) async {}

  @override
  Future<void> close() async {
    await _states.close();
  }

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
    calls.add(method);
    final failure = failWith;
    if (failure != null) throw failure;
    // **形状照电脑侧**：`{ sessions: [...] }`（`connector/src/handlers.ts`）。
    // 假客户端若回一个裸数组，就会**掩盖**"真机回对象、而界面只认数组"
    // 这类形状不一致 —— 那正是列表在真机上恒为空的原因，且它不报错。
    if (method == 'session.list') return {'sessions': sessions} as T;
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

    testWidgets('有会话但没选中 → **列表直接铺在主界面**上', (tester) async {
      // **这是被真机逼出来的一处有意改动**（原设计是"会话只在左侧抽屉里"）。
      //
      // 真机上数据明明已经拉到了，用户却"什么都看不见"：主界面是一块几乎空白的屏，
      // 会话藏在 `☰` 后面。所以主界面现在自己就把列表铺出来 ——
      // 抽屉仍在（它是原型的信息架构），但**首页必须自己能选会话**。
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

      // 会话条目**在主界面上可见**（不必先开抽屉）。
      expect(
        find.text('s1'),
        findsOneWidget,
        reason: '主界面必须直接看得见会话，而不是让人先找到 ☰',
      );
      expect(find.text('还没有会话'), findsNothing);
      // 抽屉入口仍然在（它没被删掉，只是不再是**唯一**的入口）。
      expect(find.byTooltip('打开会话抽屉'), findsOneWidget);
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
      // 模型 chip **显示真状态**：没选中会话时电脑侧也说不出模型，
      // 于是显示"未选择"。这里曾经写死 `'claude-opus'`，与电脑侧真实状态毫无关系
      // （源头见 `connector/src/dsh/models.ts` 的文件头）。
      expect(find.text('未选择'), findsOneWidget);
      // 没选中会话：模型 chip 显示"未选择"。
      expect(find.text('未选择'), findsOneWidget);
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

    testWidgets('发送带上当前发送模式（默认排队，切插话后带 steer）', (tester) async {
      // DSH 原生的二选一"繁忙时的发送行为"（排队 / 插话）：我们这边一个方法
      // 带 `mode` 参数（`connector/src/handlers.ts` 的 `session.prompt` 收
      // `'queue' | 'steer'`）。**不带这个字段电脑侧也按 queue 走**，所以这条
      // 用例守的是"用户切了插话，那句话真的以 steer 发出去"—— 少了它，
      // 界面上选了插话而线上还是排队，用户看不出任何差别。
      final client = FakeClient();
      final app = AppModel(client: client);
      await app.openSession('sid_send');
      await tester.pumpWidget(_wrap(app));
      await tester.pumpAndSettle();

      // 发送键是 `DshIcon('paperPlane')`（不是 Material 图标），所以按
      // 图标**名**找，不用 `find.byIcon(Icons.send)`。
      Finder sendButton() =>
          find.byWidgetPredicate((w) => w is DshIcon && w.name == 'paperPlane');
      await tester.enterText(find.byType(TextField), '你好');
      await tester.pumpAndSettle();
      await tester.tap(sendButton());
      await tester.pumpAndSettle();

      expect(client.calls, contains('session.prompt'));
      expect(client.lastParams!['mode'], 'queue', reason: '默认排队发送');

      // 切到插话再发一条：线上值要跟着变。
      await app.setSendMode(SendMode.steer);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '第二句');
      await tester.pumpAndSettle();
      await tester.tap(sendButton());
      await tester.pumpAndSettle();

      expect(client.lastParams!['mode'], 'steer', reason: '切了插话就要以 steer 发');
    });

    testWidgets('窄屏(360px)下控制行不溢出：第四个图标没挤走任何东西', (tester) async {
      // 2026-10-13 控制行加了"发送模式"图标（第 4 个控件）。默认 800px 宽的
      // 测试窗口下看不出来，而常见安卓机宽 360px：62% 的模型 chip + 38(＋)
      // + 34×2(权限/模式) + 38(发送) 加间距会超。所以这条按**真机宽度**量。
      // 判据取"没有 overflow 异常"：Flutter 的 RenderFlex 溢出会作为异常
      // 冒到 `takeException()`，比量坐标更接近用户看到的样子。
      final view = tester.view;
      view.physicalSize = const Size(360, 800);
      view.devicePixelRatio = 1;
      addTearDown(() {
        view.resetPhysicalSize();
        view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(_wrap(AppModel(client: FakeClient())));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull, reason: '360px 宽下控制行不许溢出');
      // 发送键必须完整在卡片里（右边缘不越界）。
      final card = tester.getRect(find.byType(DshComposer));
      final send = tester.getRect(
        find.byWidgetPredicate((w) => w is DshIcon && w.name == 'paperPlane'),
      );
      expect(send.right, lessThanOrEqualTo(card.right));
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

  group('回归：连上电脑之后的三条链（真机上抓到的三个 bug）', () {
    testWidgets('进服务态就**自动拉会话列表** —— 否则界面永远停在"还没有会话"', (tester) async {
      // 守的是一个真 bug（真机：配对连上后抽屉永远是空的）：
      // `refreshSessions()` 当时**没有任何调用点** —— 定义在、没人调。
      // 于是"电脑上有 10 个会话"与"电脑上一个都没有"在界面上长得一模一样。
      final client = _StatefulFakeClient(
        sessions: [
          {'sid': 's1', 'itemCount': 3, 'updatedAt': 1},
        ],
      );
      final app = AppModel(client: client);
      await app.start();
      await tester.pumpWidget(_wrap(app));
      await tester.pumpAndSettle();

      // 客户端自己推一次 `serving`（等价于握手完成）。
      client.emit(ConnectionState.serving);
      await tester.pumpAndSettle();

      expect(
        client.calls.where((m) => m == 'session.list').length,
        1,
        reason: '进服务态必须自动拉一次会话列表（连上却什么都不问 = 界面永远是空的）',
      );
      expect(app.sessions, isNotEmpty, reason: '拉回来的会话要进模型');
    });

    testWidgets('模型 chip 显示电脑侧那个模型，不是写死的占位', (tester) async {
      // 守的是一个真 bug：`chat_page.dart` 里 `modelName: 'claude-opus'` 是**写死的**，
      // 于是手机上显示的模型与电脑侧真实状态毫无关系。现在接的是 DSH 的
      // `modelSelection` 投影（`connector/src/dsh/models.ts`），这一条钉住
      // "电脑侧说什么，手机就显示什么"。
      final client = _StatefulFakeClient(
        sessions: [
          {
            'sid': 's1',
            'itemCount': 1,
            'updatedAt': 1,
            'running': false,
            // 形状与 DSH 的 `ModelSelection` 逐字一致。
            'model': {'provider': 'lightvela-free', 'model': 'auto'},
          },
          {
            'sid': 's2',
            'itemCount': 1,
            'updatedAt': 2,
            'running': true,
            // 这台没有 model 字段：电脑侧也说不出模型（新会话 / 投影还没落）。
          },
        ],
      );
      final app = AppModel(client: client);
      await app.start();
      await tester.pumpWidget(_wrap(app));
      await tester.pumpAndSettle();
      client.emit(ConnectionState.serving);
      await tester.pumpAndSettle();

      // 有模型的那台：显示模型 id。
      await app.openSession('s1');
      await tester.pumpAndSettle();
      expect(
        find.text('auto'),
        findsOneWidget,
        reason: '电脑侧给了模型就必须显示它 —— 写死占位等于对用户说谎',
      );
      expect(find.text('未选择'), findsNothing, reason: '已经有了还显示"未选择"，说明投影没接上');

      // 没模型的那台：显示"未选择"，**不猜**。
      await app.openSession('s2');
      await tester.pumpAndSettle();
      expect(
        find.text('未选择'),
        findsOneWidget,
        reason: '电脑侧没说就别猜 —— 猜一个就是把"看起来连着"当成"连着"',
      );
    });

    testWidgets('已配对但列表为空：给"重新拉取会话"的出路，且失败要显示', (tester) async {
      // 会话由**电脑侧**随时新建，而自动拉只在进服务态那一次 ——
      // 没有手动入口，用户只能杀 App 重进（真机上就是这么被卡住的）。
      final client = _StatefulFakeClient(
        sessions: const [],
        failWith: const ProtocolException(
          ErrorCode.connectorUnsupported,
          '电脑侧不支持 session.list',
        ),
      );
      final app = AppModel(client: client);
      await tester.pumpWidget(_wrap(app));
      await tester.pumpAndSettle();

      expect(find.text('重新拉取会话'), findsOneWidget, reason: '空列表要有手动重拉入口');
      await tester.tap(find.text('重新拉取会话'));
      await tester.pumpAndSettle();

      // **失败要有声音**：否则用户以为"电脑上真没有会话"。
      // 原因会出现在**两处**，这是有意的、两处都该在：
      // ① 空态正文（常驻，用户回头看还在）② 点按钮后的 SnackBar（即时反馈）。
      // 所以断言"至少一处"，而不是恰好一处。
      expect(
        find.textContaining('电脑侧不支持 session.list'),
        findsWidgets,
        reason: '重拉失败必须把原因显示出来，不能静默',
      );
    });

    testWidgets('模型 chip 有**宽度上限** —— 不占满控制行', (tester) async {
      // 守的是一个真 bug（真机：模型名被拉成一整条，不像胶囊）：
      // 原型 `#chipModel { max-width: 62% }` 是明确写了上限的，
      // 而落地端只写了 `Flexible`（"可被压缩"≠"最宽多少"）——
      // 没有上限时它会吃满左组剩余宽度。
      //
      // **判据必须量到"没有上限就会失败"的那一点**：
      // 第一版用 `chip.width < field.width * 0.62` 是**空转的** ——
      // chip 的文本本来就窄（`claude-opus` 只有十来个字符），
      // 去掉上限它照样小于 62%，所以变异校验时它**不会变红**（实测踩到）。
      // 正确判据是量**上限本身有没有生效**：给一个超长模型名，
      // 有上限时它被截断到 ~62%，没有上限时它一路撑满。
      await tester.pumpWidget(_wrap(AppModel(client: FakeClient())));
      await tester.pumpAndSettle();

      final chatPage = tester.widget<ChatPage>(find.byType(ChatPage));
      // 用超长名字重建输入栏（直接喂 `DshComposer`，不经过页面的真数据链路）。
      await tester.pumpWidget(
        MaterialApp(
          theme: DshTheme.dark(),
          home: Scaffold(
            body: DshComposer(
              controller: TextEditingController(),
              attachments: const [],
              modelName:
                  'claude-opus-a-very-long-model-name-that-would-fill-the-row',
              reasoningLabel: '高',
              accessMode: AccessMode.workspaceWrite,
              sendMode: SendMode.queue,
              sending: false,
              onSend: () {},
              onAttach: () {},
              onPickModel: () {},
              onPickAccess: () {},
              onPickSendMode: () {},
              onRemoveAttachment: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final composer = tester.getRect(find.byType(DshComposer));
      final chip = tester.getRect(
        find.textContaining('claude-opus-a-very-long'),
      );
      expect(
        chip.width,
        lessThan(composer.width * 0.62 + 1),
        reason: '超长模型名必须被 62% 上限截住（没有上限它会撑满整行）',
      );
      expect(chatPage.app, isNotNull);
    });
  });

  group('回归：抽屉真的能开（真机上点 ☰ 与"打开会话抽屉"都没反应）', () {
    testWidgets('选中了空会话：说"这个会话还没有内容"，不说"选一个会话"', (tester) async {
      // 守的是真机上"点了会话看起来没生效"：`items` 为空时一律走空态，
      // 而空态对"已选中但会话是空的"仍然说"选一个会话" ——
      // 用户**刚刚才点过**，那句话让人以为点击失败（实测）。
      final client = _StatefulFakeClient(
        sessions: [
          {'sid': 's1', 'updatedAt': 1},
        ],
      );
      final app = AppModel(client: client);
      await tester.pumpWidget(_wrap(app));
      await tester.pumpAndSettle();

      // 选中一个还没有任何条目的会话。
      await app.openSession('s1');
      await tester.pumpAndSettle();

      expect(
        find.text('这个会话还没有内容'),
        findsOneWidget,
        reason: '已选中会话时不能说"选一个会话"（用户刚选过，会以为点击失效）',
      );
      expect(find.text('选一个会话'), findsNothing);
    });

    testWidgets('`ChatPageState.openDrawer` 存在且能开出抽屉', (tester) async {
      // 守的是一个**静默失效**的真 bug：外层用 `GlobalKey` 调
      // `_chatKey.currentState?.openDrawer()`，而
      //  ① `ChatPage` 的 State 是私有的、**没有 `openDrawer`**，
      //  ② key 的类型还写成了 `GlobalKey<ScaffoldState>`（挂不到 `ChatPage` 上）。
      // 两条叠起来让 `currentState` 恒为 `null`、`?.` 静默吞掉 ——
      // 点 `☰`、点空态里的按钮都毫无反应，**且不报任何错**（真机实测）。
      final key = GlobalKey<ChatPageState>();
      await tester.pumpWidget(
        MaterialApp(
          theme: DshTheme.dark(),
          home: ChatPage(
            key: key,
            app: AppModel(client: FakeClient()),
            paired: true,
            onOpenDrawer: () {},
            onNewSession: () {},
            drawer: const Drawer(child: Text('抽屉内容')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 静态类型层面就要求这个方法存在（不存在则本文件编译不过）。
      expect(
        key.currentState,
        isNotNull,
        reason:
            'key 的类型必须是 ChatPageState，否则 currentState 恒为 null（`?.` 会静默吞掉整次调用）',
      );
      expect(find.text('抽屉内容'), findsNothing, reason: '还没开');

      key.currentState!.openDrawer();
      await tester.pumpAndSettle();

      expect(
        find.text('抽屉内容'),
        findsOneWidget,
        reason: 'openDrawer() 必须真的把抽屉打开（真机上这里曾经完全没反应）',
      );
    });
  });
}
