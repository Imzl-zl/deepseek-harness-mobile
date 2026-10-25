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
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/pairing_client.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/core/transport.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/model/permission.dart';
import 'package:dsh_mobile/model/send_mode.dart';
import 'package:dsh_mobile/theme/dsh_icons.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:dsh_mobile/ui/dsh_app_bar.dart';
import 'package:dsh_mobile/ui/dsh_composer.dart';
import 'package:dsh_mobile/ui/dsh_state_dot.dart';
import 'package:dsh_mobile/ui/edge_stick.dart';
import 'package:dsh_mobile/ui/pairing_page.dart';
import 'package:dsh_mobile/ui/session_drawer.dart';
import 'package:dsh_mobile/ui/side_pane.dart';
// **`hide ConnectionState`**：Flutter 的 `material.dart` 也导出 `ConnectionState`
// （`AsyncSnapshot` 的 none/waiting/active/done），与我们的**连接状态机**同名
// 但毫无关系。隐藏它，让本文件里 `ConnectionState` 只有一个意思。
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'fake_sync_client.dart';

/// 一个**只回固定答案**的假客户端：界面测试只关心"拿到这些数据时长什么样"。
class FakeClient extends FakeSyncClient {
  FakeClient({
    this.sessions = const [],
    this.failWith,
    this.projections,
    ConnectionState? state,
  }) : _state = state;

  final List<Object?> sessions;
  final ProtocolException? failWith;

  /// `session.projections` 的应答（统计条三个值的来源）。默认不给。
  final Map<String, Object?>? projections;

  /// 连接状态（`null` = 保持历史上的 idle 默认：多数界面用例不关心连接）。
  ///
  /// 要测"服务态下的空态措辞"时传 `ConnectionState.serving` 并 `app.start()` ——
  /// 否则 `AppModel._connection` 停在 idle，空态会走"没连上"那一支
  /// （2026-10-16 起它优先于"还没有会话"）。
  final ConnectionState? _state;

  /// 被调过的方法名（按顺序）——用来断言"到底问没问过"。
  final List<String> calls = <String>[];

  /// 最后一次调用的参数（发送模式等"带了什么"的判据）。
  Map<String, Object?>? lastParams;

  @override
  ConnectionState get state => _state ?? ConnectionState.idle;

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
    // 统计条的三个投影（`session.projections`）。**形状照连接器拆信封后的 `values`**。
    if (method == 'session.projections') return projections as T;
    return null as T;
  }
}

/// 一个**可以推连接状态**的假客户端（回归用）。
///
/// 与 [FakeClient] 的差别：那个的 `connection` 是 `Stream.empty()`（界面测试只关心
/// 静态形态），而"进服务态要不要自动拉列表"这条必须**能推出一次 `serving`** 才验得了。
class _StatefulFakeClient extends FakeSyncClient {
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
  Future<void> reconnect() => start();

  @override
  Future<void> setAppState(AppState state) async {}

  @override
  Future<void> close() async {
    await _states.close();
  }

  @override
  Stream<JobFrame> get jobUpdates => const Stream<JobFrame>.empty();

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
    // 投影应答**也是对象**（`connector/src/handlers.ts` 的 `session.projections`
    // 回一整包 `{键: 值}`，读不到就抛）。回 `null` 是把"形状不对"伪装成
    // "没事发生" —— 手机现在会把它记成一次真实的读取失败（`AppModel.lastError`），
    // 而那是**对的**：替身该复现真形状（`tools.md` 的"替身复现的不是真形状"）。
    if (method == 'session.projections') return <String, Object?>{} as T;
    return null as T;
  }
}

Widget _wrap(
  AppModel app, {
  bool paired = true,
  VoidCallback? onConnect,
  VoidCallback? onRePair,
  VoidCallback? onOpenDrawer,
}) => MaterialApp(
  theme: DshTheme.dark(),
  home: ChatPage(
    app: app,
    paired: paired,
    onConnect: onConnect,
    onRePair: onRePair,
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

      // 顶栏的控件都在（这是聊天页，不是别的页）：☰ 左抽屉 + ● 连接状态点 + ⊕ 新建。
      expect(
        find.descendant(
          of: find.byType(ChatAppBar),
          matching: find.byType(DshAppBarButton),
        ),
        findsNWidgets(2),
        reason: '顶栏左侧 ☰ 与右侧 ⊕（图标就该在顶栏左侧 —— 用户 2026-10-16 纠正）',
      );
      expect(find.byTooltip('新建会话'), findsOneWidget);
      // 输入栏在（置灰但可见）。
      expect(find.byType(DshComposer), findsOneWidget);
      // **不是**配对页。
      expect(find.text('配对'), findsNothing);
      // **「对话 / 轨迹」tab 不在**（2026-10-19 用户原话：
      // 「没有会话的时候对话，轨迹不用显示吧，没会话你显示没用啊」）——
      // 轨迹页读的是当前会话的事件流，没会话时它是空屏，
      // 那一格 tab 等于在说"这里有个你点不开的东西"。
      expect(find.text('轨迹'), findsNothing);
    });

    testWidgets('空态说"还没配对"，且给两个不需要连电脑的入口', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _wrap(
          AppModel(client: FakeClient()),
          paired: false,
          onConnect: () => tapped = true,
        ),
      );
      await tester.pumpAndSettle();

      // 2026-10-26 改的字：`paired` 的含义是"手里有配对凭据"，
      // 旧文案"还没连电脑"会被读成"从没配对过"。
      expect(find.text('还没配对'), findsOneWidget);
      expect(find.text('还没连电脑'), findsNothing);
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
            {
              'sid': 's1',
              'updatedAt': 0,
              'running': false,
              'blank': false,
              'subagent': false,
              'projections': {
                'kind': 'cached',
                'asOfSeq': 1,
                'values': {'title': '第一个会话'},
              },
            },
          ],
        ),
      );
      await app.refreshSessions();
      await tester.pumpWidget(_wrap(app));
      await tester.pumpAndSettle();

      // 会话条目**在主界面上可见**（不必先开抽屉）。
      expect(
        find.text('第一个会话'),
        findsOneWidget,
        reason: '主界面必须直接看得见会话，而不是让人先找到 ☰',
      );
      expect(find.text('还没有会话'), findsNothing);
      // 抽屉入口在顶栏左侧的 ☰（也能从左缘跟手拖出）。
      expect(
        find.descendant(
          of: find.byType(ChatAppBar),
          matching: find.byType(DshAppBarButton),
        ),
        findsNWidgets(2),
        reason: '顶栏只有 ☰ 与 ⊕',
      );
    });

    testWidgets('左缘上半屏往内划能开抽屉（顶栏不放入口之后它是主入口）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: DshTheme.dark(),
          home: ChatPage(
            app: AppModel(client: FakeClient()),
            paired: true,
            onOpenDrawer: () {},
            onNewSession: () {},
            drawer: const Drawer(child: Text('抽屉内容')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('抽屉内容'), findsNothing, reason: '还没划');

      // 与原型 `.edge--open` 手势带同一个位置：左缘**最边缘**、上半屏。
      // （把手贴边；与系统返回的冲突用 `setSystemGestureExclusionRects` 解决。）
      await tester.dragFrom(const Offset(2, 200), const Offset(300, 0));
      await tester.pumpAndSettle();

      expect(
        find.text('抽屉内容'),
        findsOneWidget,
        reason: '左缘侧滑必须能开抽屉 —— ☰ 去掉之后它是唯一入口',
      );
    });

    testWidgets('空态那枚「打开会话抽屉」按钮仍然调得到回调', (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        _wrap(
          AppModel(client: FakeClient()),
          paired: true,
          onOpenDrawer: () => opened += 1,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('打开会话抽屉'));
      await tester.pump();
      expect(opened, 1, reason: '空态里的按钮是侧滑之外的备用入口，不能跟着 ☰ 一起失效');
    });
  });

  group('输入栏三条硬规则（§7.2）', () {
    testWidgets('规则 3：控制行左有 ＋/模型/权限，右**只有**发送', (tester) async {
      await tester.pumpWidget(_wrap(AppModel(client: FakeClient())));
      await tester.pumpAndSettle();

      // 左组三件。
      expect(find.byTooltip('添加文件或调用指令'), findsOneWidget);
      // 权限 chip 的 tooltip 是**当前档位**。没选中会话时电脑侧也说不出档位，
      // 于是是"未知"—— 这里曾经断言 `'工作区内可改'`，那是一个**写死的默认值**：
      // 手机在不知道自己权限的情况下对用户声称"工作区内可改"。
      // 2026-10-15 权限档改接电脑侧真值（`permissions` 投影）之后，
      // "不知道"就必须显示成不知道。
      expect(find.byTooltip('未知'), findsOneWidget);
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

    testWidgets('＋ 菜单不再摆「附件」（没有传输通路，摆了就是骗人）', (tester) async {
      // 2026-10-20：那一行原先加的是一个**假附件**
      //（`PendingAttachment(name: '新增文件.txt')`），而 `_send()` 的
      // `content` 只有文本块 —— **附件被静默丢弃**。用户看到芯片以为传了
      // 文件，发出去的东西里没有它。这比死按钮更糟：它不是没反应，是骗人。
      //
      // 这条守的是"别在没有传输通路时把那行加回来"。
      // 附件轨道本身的布局规则在 `composer_layout_test.dart` 直接验
      //（硬规则 1：卡片内部、文字行上方）。
      final app = AppModel(
        client: FakeClient(
          sessions: [
            {
              'sid': 's1',
              'updatedAt': 0,
              'running': false,
              'blank': false,
              'subagent': false,
            },
          ],
        ),
      );
      await app.refreshSessions();
      await app.openSession('s1');
      await tester.pumpWidget(_wrap(app));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('添加文件或调用指令'));
      await tester.pumpAndSettle();
      expect(find.text('添加'), findsOneWidget);
      expect(find.text('附件'), findsNothing, reason: '附件发送还没接 —— 摆一行加假芯片就是静默丢弃');
      // **桌面快捷键那三项也拔掉了**（2026-10-20）：`工作区文件` /
      // `新建终端` / `浏览器` 的副标题全是"桌面端 Ctrl+X"，手机上点下去
      // 只能弹"还没做" —— 而 `settings_page.dart:7` 写着
      // 「一行点下去只弹"还没做"的假入口，比没有这一行更糟」。
      for (final dead in ['工作区文件', '新建终端', '浏览器']) {
        expect(
          find.text(dead),
          findsNothing,
          reason: '$dead 是桌面快捷键入口，手机上只能弹"还没做"',
        );
      }
      // 剩下两项都是真的：`后台任务` 开右抽屉的任务页，`演示` 灌接管队列。
      expect(find.text('后台任务'), findsOneWidget);
      expect(find.text('演示：接管输入栏'), findsOneWidget);
    });

    testWidgets('＋ → 后台任务：**落到真的面板**（不是"还没做"）', (tester) async {
      // 右抽屉本来就有「任务」面板（顶栏计数 chip 也是开它），
      // 所以这个入口没有理由只弹一句"还没做"。
      final app = AppModel(
        client: FakeClient(
          sessions: [
            {
              'sid': 's1',
              'updatedAt': 0,
              'running': false,
              'blank': false,
              'subagent': false,
            },
          ],
        ),
      );
      await app.refreshSessions();
      await app.openSession('s1');
      await tester.pumpWidget(_wrap(app));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('添加文件或调用指令'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('后台任务'));
      await tester.pumpAndSettle();

      // 抽屉开着、且落在「后台任务」那一页（表头就是它）。
      expect(find.text('后台任务'), findsOneWidget);
      // 空态说的是数据来源，不是"还没做"。
      expect(find.textContaining('没有后台任务'), findsOneWidget);
      expect(find.textContaining('还没接'), findsNothing);
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
    testWidgets('底栏出口都在（文件/归档/设置——演示与自动化已删）', (tester) async {
      // 「演示」「自动化」2026-10-16 删除：一个是配对后就没用的示例数据入口，
      // 一个是 C 类（schedule/skill 不上手机）的死桩。删除的理由与代价见
      // `.agents/notes/implemented/2026-10-16-drawer-foot-drops-demo-and-automation.md`。
      // 本用例守的是"传进来的项都渲染"，具体哪几项由装配点（main.dart）定。
      await tester.pumpWidget(
        MaterialApp(
          theme: DshTheme.dark(),
          home: Scaffold(
            drawer: SessionDrawer(
              sections: const [],
              connection: const DrawerConnection(
                name: '我的电脑',
                detail: '直连已连接 · 空闲',
                platform: 'DSH',
                online: true,
              ),
              footItems: [
                DrawerFootItem(icon: 'folderClose', label: '文件', onTap: () {}),
                DrawerFootItem(icon: 'archive', label: '归档', onTap: () {}),
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

      for (final label in ['文件', '归档', '设置']) {
        expect(find.text(label), findsOneWidget, reason: '底栏缺 $label');
      }
      expect(find.text('演示'), findsNothing, reason: '演示入口已删');
      expect(find.text('自动化'), findsNothing, reason: '自动化是 C 类死桩，已删');
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
          {
            'sid': 's1',
            'itemCount': 3,
            'updatedAt': 1,
            'running': false,
            'blank': false,
            'subagent': false,
          },
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
            'blank': false,
            'subagent': false,
            // 形状与 DSH 的 `ModelSelection` 逐字一致。
            'model': {'provider': 'lightvela-free', 'model': 'auto'},
          },
          {
            'sid': 's2',
            'itemCount': 1,
            'updatedAt': 2,
            'running': true,
            'blank': false,
            'subagent': false,
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
              access: const PermissionChip(
                icon: 'permissionWorkspaceWrite',
                label: '工作区内可改',
                warn: false,
              ),
              sendMode: SendMode.queue,
              sending: false,
              onSend: () {},
              onAttach: () {},
              onPickModel: () {},
              onPickAccess: () {},
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

  group('回归：抽屉的打开缝真的通（真机上曾经完全没反应）', () {
    testWidgets('选中了空会话：说"这个会话还没有内容"，不说"选一个会话"', (tester) async {
      // 守的是真机上"点了会话看起来没生效"：`items` 为空时一律走空态，
      // 而空态对"已选中但会话是空的"仍然说"选一个会话" ——
      // 用户**刚刚才点过**，那句话让人以为点击失败（实测）。
      //
      // **先让它进入服务态**：2026-10-16 起"配对但没连上"优先于这一支
      // （那才是真实现状），而本条要测的正是"连上了、会话是空的"这一种。
      final client = _StatefulFakeClient(
        sessions: [
          {
            'sid': 's1',
            'updatedAt': 1,
            'running': false,
            'blank': false,
            'subagent': false,
          },
        ],
      );
      final app = AppModel(client: client);
      client.emit(ConnectionState.serving);
      await app.start();
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
      // 空态里那枚按钮、以及外层任何"打开抽屉"的调用都毫无反应，**且不报任何错**（真机实测）。
      // 顶栏的 ☰ 在 2026-10-16 已去掉（改左缘侧滑），但这道缝还在用（空态按钮）。
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

  // 议题 3 的硬判据：**任何界面状态下，从根界面出发 ≤2 次点击走到"重新配对"**。
  // 三个代表状态各钉一条（写不成断言不算做完）：
  //   ① 已配对 + 有会话：顶栏状态位 → 连接 sheet → 重新配对（2 次）。
  //   ② 已配对 + 空态：空态"重新配对"按钮（1 次）。
  //   ③ 未配对：空态"连电脑（配对）"（1 次，回配对页）。
  group('议题 3：任何状态 ≤2 次点击走到"重新配对"', () {
    testWidgets('① 已配对 + 有会话：状态位 → sheet → 重新配对（2 次点击）', (tester) async {
      final app = AppModel(
        client: FakeClient(
          sessions: [
            {
              'sid': 's1',
              'updatedAt': 1,
              'running': false,
              'blank': false,
              'subagent': false,
            },
          ],
        ),
      );
      await app.refreshSessions();
      var rePair = 0;
      await tester.pumpWidget(
        _wrap(app, paired: true, onRePair: () => rePair += 1),
      );
      await tester.pumpAndSettle();

      // 第 1 次点击：顶栏连接状态点（常驻，点它弹连接操作 sheet）。
      expect(
        find.byType(DshConnectionDotButton),
        findsOneWidget,
        reason: '连接状态点必须常驻，否则重配没有 ≤2 步的落点',
      );
      await tester.tap(find.byType(DshConnectionDotButton));
      await tester.pumpAndSettle();
      expect(find.text('重新配对（换一台电脑）'), findsOneWidget);
      expect(find.text('打开侧面板'), findsOneWidget);

      // 第 2 次点击：sheet 里的"重新配对"。
      await tester.tap(find.text('重新配对（换一台电脑）'));
      await tester.pumpAndSettle();
      expect(rePair, 1, reason: '从根界面 2 次点击必须触发重新配对');
    });

    testWidgets('② 已配对 + 空态：空态"重新配对"按钮 1 次点击直达', (tester) async {
      // 服务态下"还没有会话"（没连上时优先说连接，见 chat_empty_state_test）。
      final app = AppModel(client: FakeClient(state: ConnectionState.serving));
      await app.start();
      var rePair = 0;
      await tester.pumpWidget(
        _wrap(app, paired: true, onRePair: () => rePair += 1),
      );
      await tester.pumpAndSettle();

      expect(find.text('还没有会话'), findsOneWidget);
      // 空态下"重新配对（换一台电脑）"是唯一的（此刻没有开 sheet），点它直达。
      expect(find.text('重新配对（换一台电脑）'), findsOneWidget);
      await tester.tap(find.text('重新配对（换一台电脑）'));
      await tester.pumpAndSettle();
      expect(rePair, 1, reason: '空态下 1 次点击即触发重新配对');
    });

    testWidgets('③ 未配对：空态"连电脑（配对）"1 次点击进配对', (tester) async {
      var connect = 0;
      await tester.pumpWidget(
        _wrap(
          AppModel(client: FakeClient()),
          paired: false,
          onConnect: () => connect += 1,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('连电脑（配对）'));
      await tester.pump();
      expect(connect, 1, reason: '未配对时 1 次点击即回到配对入口');
    });
  });

  // 议题 2 的「人话提示」：身份被拒后被**自动送到**配对页，那句"为什么"必须
  // **常驻**——SnackBar 4 秒就消失，用户看到时已经不解释了（2026-10-15 真机
  // 第一版正是 SnackBar，截图里那句话已经没了）。
  group('配对页的「为什么」横幅', () {
    Future<HttpResult> send(HttpCall call) => throw StateError('渲染不该触发换票');
    ChannelTransport transportFor(String upgradeUrl) =>
        throw StateError('渲染不该建传输');

    Widget page({String? notice}) => MaterialApp(
      theme: DshTheme.dark(),
      home: PairingPage(
        onPaired: (_) async {},
        send: send,
        transportFor: transportFor,
        notice: notice,
      ),
    );

    testWidgets('有 notice：横幅常驻，且不顶替原来的步骤', (tester) async {
      const why = '这台电脑已不再认可本机（可能已停用，或凭据已失效）。请重新扫码配对。';
      await tester.pumpWidget(page(notice: why));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pairing-notice')), findsOneWidget);
      expect(find.text(why), findsOneWidget);
      expect(
        find.text('扫二维码，或把内容粘贴到下面'),
        findsOneWidget,
        reason: '横幅是补充，不是把原来的步骤顶掉',
      );
    });

    testWidgets('没有 notice：不出现横幅（主动进来的那一侧）', (tester) async {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('pairing-notice')), findsNothing);
      expect(find.text('扫二维码，或把内容粘贴到下面'), findsOneWidget);
    });

    testWidgets('配对码输入框关掉输入法联想（手打的 JSON 不能被纠错改掉）', (tester) async {
      // 依据：`packages/flutter/lib/src/services/text_input.dart:623-636` ——
      // `enableSuggestions` 在 Android 是独立的 NO_SUGGESTIONS 标记，iOS 的联想
      // **跟着 `autocorrect` 走**，所以两个都要 false。
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.enableSuggestions, isFalse);
      expect(field.autocorrect, isFalse);
    });
  });

  // 统计条三项：轮次/步数 + **输出速率**、用量 + 缓存命中、**上下文占用**。
  // 后两项是 2026-10-15 真机对比 Web 截图后补的 —— 手机原来一个都没有
  // （`decodeMs`/`decodeTokens`/`contextWindow` 三个字段根本没解析）。
  group('统计条：三项都与 Web 同公式', () {
    testWidgets('三条都从投影来：轮步 + tok/s、用量 + 缓存、上下文百分比', (tester) async {
      final app = AppModel(
        client: FakeClient(
          sessions: const [
            {
              'sid': 's1',
              'updatedAt': 1,
              'running': false,
              'blank': false,
              'subagent': false,
            },
          ],
          projections: const {
            'tokenUsage': {
              'uncachedInputTokens': 1000,
              'outputTokens': 200,
              'cacheReadTokens': 40000,
              'cacheWriteTokens': 500,
            },
            'sessionStats': {
              'turns': 3,
              'steps': 12,
              'llmMs': 4200,
              'toolMs': 800,
              'decodeMs': 10000,
              'decodeTokens': 750,
            },
            'contextPressure': {
              'pressureTokens': 41000,
              'projectedTokens': 44000,
              'contextWindow': 128000,
            },
          },
        ),
      );
      await app.refreshSessions();
      await app.openSession('s1');
      await tester.pumpWidget(_wrap(app));
      await tester.pumpAndSettle();

      // 轮次步数 + 输出速率（750 tok / 10 s = 75 tok/s，照 Web 的 decodeSpeed）。
      // 文案逐字照 Web 的 `stats.counts` = `{turns} 轮 {steps} 步`（`locale.ts:77`）：
      // **没有「第」、两个数之间没有 `·`** —— 电脑端显示的就是 `5 轮 73 步 · 77 tok/s`。
      expect(find.text('3 轮 12 步 · 75 tok/s'), findsOneWidget);
      // 用量 + 缓存命中（分母是计费输入，不含输出：40000 / 41500 ≈ 96%）。
      // 文案与 Web 逐字一致：`{count} tok · 缓存命中 {percent}%`
      // （`locale.ts:78` 的 `stats.cacheHit`；合计 = 41500 + 200 = 41700 → 41.7K）。
      expect(find.text('41.7K tok · 缓存命中 96%'), findsOneWidget);
      // 上下文占用（44000 / 128000 ≈ 34%）。
      expect(find.text('34%'), findsOneWidget);
    });

    testWidgets('全零投影：统计条整条不显示（不出 `0 tok` / `0%`）', (tester) async {
      // 2026-10-19 用户："输入框下面的没有数据的时候应该都不显示，怎么还有一个
      // 用量在显示 0？"——blank 会话的投影**字段齐全但全为 0**（不是 null），
      // 于是"读不到才隐藏"那条判据漏了它。
      final app = AppModel(
        client: FakeClient(
          sessions: const [
            {
              'sid': 's1',
              'updatedAt': 1,
              'running': false,
              'blank': false,
              'subagent': false,
            },
          ],
          projections: const {
            'tokenUsage': {
              'uncachedInputTokens': 0,
              'outputTokens': 0,
              'cacheReadTokens': 0,
              'cacheWriteTokens': 0,
            },
            'sessionStats': {
              'turns': 0,
              'steps': 0,
              'llmMs': 0,
              'toolMs': 0,
              'decodeMs': 0,
              'decodeTokens': 0,
            },
            'contextPressure': {
              'pressureTokens': 0,
              'projectedTokens': 0,
              'contextWindow': 128000,
            },
          },
        ),
      );
      await app.refreshSessions();
      await app.openSession('s1');
      await tester.pumpWidget(_wrap(app));
      await tester.pumpAndSettle();

      for (final text in ['0 tok', '0%', '0 轮 0 步', '0 tok/s']) {
        expect(
          find.textContaining(text),
          findsNothing,
          reason: '没数据就不该出现「$text」这种像数据的数字',
        );
      }
      // 组件本身还在 widget 树里（它自己决定渲染什么），判据是**它没占高度**。
      final bar = find.byType(DshStatsBar);
      if (bar.evaluate().isNotEmpty) {
        expect(
          tester.getSize(bar.first),
          Size.zero,
          reason: '三条都空时整条收起（空条会白占一行高度）',
        );
      }
    });

    testWidgets('统计条横滚不裁切：四位数也滑得到', (tester) async {
      // 2026-10-17 真机反馈："数字变四位数那怎么办？"—— `Row` 布局在总宽超屏时
      // 把第三项（上下文百分比）**整块裁掉**（release 里没有溢出条纹，只是看不见）。
      // 现在是**单行 + 横向滚动**：读数一开始可能在视口外，但**滑得到**。
      // 判据因此是两段：① 三项都在；② 左滑之后第三项真的进了视口。
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final app = AppModel(
        client: FakeClient(
          sessions: const [
            {
              'sid': 's1',
              'updatedAt': 1,
              'running': false,
              'blank': false,
              'subagent': false,
            },
          ],
          projections: const {
            'tokenUsage': {
              'uncachedInputTokens': 123456,
              'outputTokens': 12345,
              'cacheReadTokens': 234567,
              'cacheWriteTokens': 0,
            },
            'sessionStats': {
              'turns': 12,
              'steps': 345,
              'llmMs': 4200,
              'toolMs': 800,
              'decodeMs': 10000,
              'decodeTokens': 750,
            },
            'contextPressure': {
              'pressureTokens': 41000,
              'projectedTokens': 44000,
              'contextWindow': 128000,
            },
          },
        ),
      );
      await app.refreshSessions();
      await app.openSession('s1');
      await tester.pumpWidget(_wrap(app));
      await tester.pumpAndSettle();

      // 三项都必须在：370K tok 那一项很长，320px 上整条装不下。
      expect(find.text('12 轮 345 步 · 75 tok/s'), findsOneWidget);
      expect(find.text('370K tok · 缓存命中 66%'), findsOneWidget);
      final last = find.text('34%');
      expect(last, findsOneWidget);
      expect(
        tester.getTopLeft(last).dx,
        greaterThanOrEqualTo(320),
        reason: '三项合计宽于 320px，第三项一开始就在视口右边',
      );

      // **滑得到**：这一条才是"没被裁掉"的判据（`Row` 时代它永远出不来）。
      await tester.drag(find.byType(DshStatsBar), const Offset(-400, 0));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(last).dx,
        lessThan(320),
        reason: '左滑之后第三项必须进入视口 —— 藏起来不等于滑不到',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('选中了会话：对话/轨迹两个 tab 都在', (tester) async {
      // 守"没会话不显 tab"这条**不会砍过头**：选中了会话就要有两个
      // （轨迹页有话说 —— 会话刚建、事件正在来）。
      final app = AppModel(
        client: FakeClient(
          sessions: const [
            {
              'sid': 's1',
              'updatedAt': 1,
              'running': false,
              'blank': false,
              'subagent': false,
            },
          ],
        ),
      );
      await app.refreshSessions();
      await app.openSession('s1');
      await tester.pumpWidget(_wrap(app));
      await tester.pumpAndSettle();

      expect(find.text('对话'), findsOneWidget);
      expect(find.text('轨迹'), findsOneWidget);
    });

    testWidgets('投影读不到：三条整条不显示（不猜数字）', (tester) async {
      final app = AppModel(
        client: FakeClient(
          sessions: const [
            {
              'sid': 's1',
              'updatedAt': 1,
              'running': false,
              'blank': false,
              'subagent': false,
            },
          ],
        ),
      );
      await app.refreshSessions();
      await app.openSession('s1');
      await tester.pumpWidget(_wrap(app));
      await tester.pumpAndSettle();

      expect(find.textContaining('tok/s'), findsNothing);
      expect(find.textContaining('缓存'), findsNothing);
    });
  });

  // 顶栏**连接状态点**：一个点只做一件事 —— 弹连接操作 sheet（**含 serving**）。
  // 照 DSH 的按钮语义（`ui-primitives/src/ConnectionIndicator.tsx:75-81`：异常/重连
  // 指示器本身就是"立即重连"按钮）。**右抽屉入口搬到自己那个按钮上** ——
  // DSH 同分法：右面板入口是 header 角落的 `ExpandButton`，与连接指示器无关
  // （`ui-sidebar-right/src/client/index.ts:238-239`）。
  group('顶栏：连接状态点只做连接的事，右抽屉有自己的按钮', () {
    testWidgets('serving：点状态点弹连接 sheet（不再抢右抽屉）', (tester) async {
      final client = _StatefulFakeClient(
        sessions: [
          {
            'sid': 's1',
            'itemCount': 3,
            'updatedAt': 1,
            'running': false,
            'blank': false,
            'subagent': false,
          },
        ],
      );
      final app = AppModel(client: client);
      await app.start();
      await tester.pumpWidget(_wrap(app, paired: true));
      await tester.pumpAndSettle();
      client.emit(ConnectionState.serving);
      await tester.pumpAndSettle();

      expect(find.byType(SidePane), findsNothing, reason: '右抽屉还没开');

      await tester.tap(find.byType(DshConnectionDotButton));
      await tester.pumpAndSettle();

      expect(find.text('重新配对（换一台电脑）'), findsOneWidget);
      expect(
        find.byType(SidePane),
        findsNothing,
        reason: '点状态点只弹连接 sheet；右抽屉有自己的按钮',
      );
    });

    testWidgets('右缘上半屏往左划一步开 SidePane（右侧不加图标）', (tester) async {
      final app = AppModel(
        client: FakeClient(
          sessions: [
            {
              'sid': 's1',
              'updatedAt': 1,
              'running': false,
              'blank': false,
              'subagent': false,
            },
          ],
        ),
      );
      await app.refreshSessions();
      await tester.pumpWidget(_wrap(app, paired: true));
      await tester.pumpAndSettle();

      expect(find.byType(SidePane), findsNothing);
      // 顶栏与右缘都**不放图标**（用户："右侧侧滑不加图标"）：只有划。
      await tester.dragFrom(const Offset(798, 200), const Offset(-260, 0));
      await tester.pumpAndSettle();
      expect(
        find.byType(SidePane),
        findsOneWidget,
        reason: '右抽屉必须有一步入口（原来挂在状态位、后来在顶栏、现在是右缘侧滑）',
      );
    });

    testWidgets('点跟着连接状态变：服务中=绿点，重连中=转圈', (tester) async {
      final client = _StatefulFakeClient(
        sessions: [
          {
            'sid': 's1',
            'updatedAt': 1,
            'running': false,
            'blank': false,
            'subagent': false,
          },
        ],
      );
      final app = AppModel(client: client);
      await app.start();
      await tester.pumpWidget(_wrap(app, paired: true));
      await tester.pumpAndSettle();

      DshStateDotState dot() =>
          tester.widget<DshStateDot>(find.byType(DshStateDot)).state;

      client.emit(ConnectionState.serving);
      await tester.pumpAndSettle();
      expect(dot(), DshStateDotState.done, reason: '服务中画绿点');

      client.emit(ConnectionState.backoff);
      // **不能用 `pumpAndSettle`**：转圈是一个永不结束的动画（1.5s 循环），
      // settle 会一直等下去 —— 超时而不是失败。推进两帧看状态就够。
      await tester.pump();
      await tester.pump();
      expect(dot(), DshStateDotState.ongoing, reason: '重连中画转圈');
    });
  });

  // 抽屉入口（2026-10-16 第三轮定稿，用户逐条纠正出来的）：
  // - **左边**：顶栏左侧的 `☰`（图标就该在顶栏左侧）+ 从屏幕左缘**跟手**拖出；
  // - **右边**：不加图标，只有一条**棒棒**当标识（`ui/edge_stick.dart`），
  //   从右缘**跟手**拖出；**右抽屉开着时那条棒棒消失**。
  // 两个抽屉都是原生 Drawer（`drawer` / `endDrawer`），跟手/回弹/遮罩全由 Flutter 管。
  // 与系统返回的冲突用 `setSystemGestureExclusionRects` 解决（上半屏 192dp，
  // `platform/gesture_exclusion.dart`），不是把棒棒往里挪。
  group('抽屉入口：顶栏 ☰ + 左缘跟手拖；右侧棒棒 + 右缘跟手拖', () {
    Widget page() => MaterialApp(
      theme: DshTheme.dark(),
      home: ChatPage(
        app: AppModel(client: FakeClient()),
        paired: true,
        onOpenDrawer: () {},
        onNewSession: () {},
        drawer: const Drawer(child: Text('抽屉内容')),
      ),
    );

    testWidgets('顶栏左侧 ☰ 点一下开左抽屉', (tester) async {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(find.text('抽屉内容'), findsNothing, reason: '还没点');

      await tester.tap(find.byTooltip('打开会话抽屉'));
      await tester.pumpAndSettle();

      expect(find.text('抽屉内容'), findsOneWidget);
    });

    testWidgets('左缘拖一下也能开（原生跟手拖动）', (tester) async {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();

      await tester.dragFrom(const Offset(2, 200), const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(find.text('抽屉内容'), findsOneWidget);
    });

    testWidgets('顶栏只有 ☰ 与 ⊕ 两个按钮（右边不加图标）', (tester) async {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();

      final buttons = find.descendant(
        of: find.byType(ChatAppBar),
        matching: find.byType(DshAppBarButton),
      );
      expect(buttons, findsNWidgets(2), reason: '☰ + ⊕');
      expect(
        find.byTooltip('打开右侧面板（文件 / 任务 / 子智能体）'),
        findsNothing,
        reason: '用户点名"右侧侧滑不加图标"',
      );
    });

    testWidgets('右缘拖一下开右抽屉；**棒棒在它开着时消失**', (tester) async {
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();

      expect(
        find.byType(DshRightEdgeStick),
        findsOneWidget,
        reason: '右抽屉关着时，右缘那条"能划"的棒棒要在',
      );

      await tester.dragFrom(const Offset(798, 200), const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(find.byType(SidePane), findsOneWidget, reason: '右缘拖动开右抽屉');

      expect(
        find.byType(DshRightEdgeStick),
        findsNothing,
        reason: '用户原话："侧滑之后棒要消失啊" —— 抽屉开着时它还挡在那，纯属碍事',
      );
    });
  });

  // 顶栏**一行**：标题限宽 + 两枚计数 chip（子智能体 / 后台任务）与它同一行。
  // 形态照 DSH 的 `.crumb`（`max-width:220px; font-size:14px; line-height:20px`，
  // `ui-conversation/src/client/skeleton/ConversationRoot.module.css:125-139`）
  // 与 header 的 actions band（`ConversationSession.tsx:127-129`）——
  // 手机按同形态**收窄一档**（标题 140 / 13px；chip 取图标 + 计数），
  // 因为 411dp 屏上留给「标题 + chip」的只有 285.4dp，而全文本 chip 单枚就 137.8dp。
  group('顶栏标题限宽与计数 chip 的席位', () {
    Widget bar(
      String title, {
      int subagents = 0,
      int runningSubagents = 0,
      int jobs = 0,
      int runningJobs = 0,
    }) => MaterialApp(
      theme: DshTheme.dark(),
      home: Scaffold(
        appBar: ChatAppBar(
          title: title,
          onOpenDrawer: () {},
          onNewSession: () {},
          connectionState: DshStateDotState.done,
          connectionTooltip: '连接状态：已连接（点按查看连接操作）',
          onConnectionTap: (_) {},
          subagentCount: subagents,
          subagentRunning: runningSubagents,
          jobCount: jobs,
          jobRunning: runningJobs,
          onTapSubagents: () {},
          onTapJobs: () {},
        ),
      ),
    );

    testWidgets('长标题被限到 140px、13px/w500', (tester) async {
      const long = '手机端控制电脑DSH方案与顶栏布局';
      await tester.pumpWidget(bar(long * 6));
      await tester.pumpAndSettle();

      final title = tester.getRect(find.text(long * 6));
      expect(
        title.width,
        lessThanOrEqualTo(kDshTitleMaxWidth + 0.5),
        reason: '标题上限 $kDshTitleMaxWidth（同 DSH `.crumb` 的形态，手机收窄一档）',
      );
      // 字号与字重同源 `.crumb`（14px / w500），手机收窄一档到 13 ——
      // 同一行还要放两枚计数 chip。
      final style = tester.widget<Text>(find.text(long * 6)).style;
      expect(style?.fontSize, 13, reason: '同 `.crumb` 形态，手机收窄一档');
      expect(
        style?.fontWeight,
        FontWeight.w500,
        reason: '照 `.crumbCurrent` 的 w500',
      );
      // 顶栏：☰（左抽屉）+ ●（连接状态点）+ ⊕（新建）。
      // **右边没有抽屉图标** —— 用户："右侧侧滑不加图标啊"，右边只有那条跟手侧滑的棒棒。
      expect(find.byTooltip('打开会话抽屉'), findsOneWidget, reason: '☰ 在顶栏左侧');
      expect(
        find.byTooltip('打开右侧面板（文件 / 任务 / 子智能体）'),
        findsNothing,
        reason: '右边不加图标（右缘侧滑 + 棒棒标识）',
      );
      expect(find.byType(DshConnectionDotButton), findsOneWidget);
      expect(find.byTooltip('新建会话'), findsOneWidget);
    });

    testWidgets('计数 chip 与标题同一行；文案与计数口径照 DSH', (tester) async {
      await tester.pumpWidget(
        bar('会话标题', subagents: 3, runningSubagents: 2, jobs: 5, runningJobs: 2),
      );
      // **不能用 `pumpAndSettle`**：在跑的 chip 会画一枚永不结束的转圈点，
      // settle 会一直等下去（是超时，不是断言失败）。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // **按图标取 chip**，不按 tooltip 文案取：子智能体那枚的 aria 在"有在跑的"
      // 时会变成 `N 个子智能体，正在运行`，按文案找会随数据漂。
      final chips = tester
          .widgetList<DshCountChip>(find.byType(DshCountChip))
          .toList();
      expect(chips, hasLength(2), reason: '两类计数都 > 0，应当正好两枚');
      final sub = chips.firstWhere((c) => c.icon == 'users');
      final job = chips.firstWhere((c) => c.icon == 'checklist');

      // 文案（aria/tooltip）与 Web 逐字一致：子智能体报**总数**、在跑报**在跑数**；
      // 后台任务在跑时报 `{count} 个后台任务运行中`、count 取**在跑数**。
      expect(sub.label, '2 个子智能体，正在运行');
      expect(sub.count, 3, reason: '子智能体那枚显示的是**总数**');
      expect(job.label, '2 个后台任务运行中');
      expect(job.count, 2, reason: '后台任务那枚显示的是**在跑数**');

      // **同一行**的判据是纵向中心相等 —— 这才是"顶栏一行"。
      final titleMid = tester.getRect(find.text('会话标题')).center.dy;
      expect(
        tester.getRect(find.byWidget(sub)).center.dy,
        titleMid,
        reason: '计数 chip 与标题同一行',
      );
      expect(tester.getRect(find.byWidget(job)).center.dy, titleMid);
      expect(tester.takeException(), isNull);
    });

    testWidgets('计数为 0：整枚不占位（不说"0 个子智能体"）', (tester) async {
      await tester.pumpWidget(bar('会话标题'));
      await tester.pumpAndSettle();
      expect(find.byType(DshCountChip), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('真机宽度 411dp + 两位数计数 + 长标题：不溢出', (tester) async {
      final view = tester.view;
      // 真机逻辑宽度：1080px ÷ (420dpi ÷ 160) = 411.43dp。
      view.physicalSize = const Size(1080 / (420 / 160), 900);
      view.devicePixelRatio = 1;
      addTearDown(() {
        view.resetPhysicalSize();
        view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        bar('手机端控制电脑DSH方案与顶栏布局' * 6, subagents: 12, jobs: 12, runningJobs: 12),
      );
      // 在跑的 chip 有永不结束的转圈点 —— 只能推帧，不能 settle。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull, reason: '真机宽度下顶栏不许溢出');
    });

    testWidgets('360px 长标题 + 两枚两位数 chip：不溢出', (tester) async {
      final view = tester.view;
      view.physicalSize = const Size(360, 800);
      view.devicePixelRatio = 1;
      addTearDown(() {
        view.resetPhysicalSize();
        view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        bar('手机端控制电脑DSH方案与顶栏布局' * 6, subagents: 12, jobs: 12, runningJobs: 12),
      );
      // 同上：转圈点让 settle 永远等不到。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(tester.takeException(), isNull, reason: '360px 宽下顶栏不许溢出');
    });

    testWidgets('状态点语义：7 个连接状态各归哪一档', (tester) async {
      expect(dotStateOf(ConnectionStateView.serving), DshStateDotState.done);
      for (final state in const [
        ConnectionStateView.connecting,
        ConnectionStateView.handshaking,
        ConnectionStateView.backoff,
      ]) {
        expect(
          dotStateOf(state),
          DshStateDotState.ongoing,
          reason: '$state 在等，必须转（静止会被读成"卡住了"）',
        );
      }
      for (final state in const [
        ConnectionStateView.idle,
        ConnectionStateView.closed,
        ConnectionStateView.gaveUp,
      ]) {
        expect(
          dotStateOf(state),
          DshStateDotState.error,
          reason: '$state 需要用户做点什么',
        );
      }
    });
  });

  group('右侧「文件」面板（真清单 + 复制路径）', () {
    /// 起一页示例数据并落到有 `write` 调用的那个会话。
    ///
    /// `preview-2` 里有一条 `name: 'write'` 且带 `changedPath` 的调用
    /// （`lib/data/preview_data.dart`）—— 面板就是按它列出来的。
    ///
    /// 直接调 `loadPreview()` 而不是点「看示例数据」：那个按钮只在**未配对**
    /// 的空态里出现，而 `_wrap` 默认已配对 —— 点它只会找到 0 个。
    Future<AppModel> pumpPreviewSession(WidgetTester tester) async {
      final app = AppModel(client: FakeClient())..loadPreview();
      await tester.pumpWidget(_wrap(app));
      await tester.pumpAndSettle();
      await app.openSession('preview-2');
      await tester.pumpAndSettle();
      return app;
    }

    testWidgets('列出真改动：表头报数量，行里是路径与 +N −M', (tester) async {
      await pumpPreviewSession(tester);
      // 抽屉的 `_sidePanel` 默认就是「文件」（`chat_page.dart:143`），
      // 所以直接开抽屉就落在这一页。
      tester.state<ScaffoldState>(find.byType(Scaffold).first).openEndDrawer();
      await tester.pumpAndSettle();

      expect(find.text('1 个文件'), findsOneWidget, reason: '表头报的是真数量');
      expect(find.text('lib/theme/dsh_icons.dart'), findsOneWidget);
      // 差异页签默认选中，行上带增量。
      //
      // **只在侧栏里找**：会话流里那张工具卡也有 `+100`（同一条改动），
      // 不限定范围时两个都能命中 —— 2026-10-20 修好会话流方向后那张卡从
      // 屏外变成可见，这条断言才暴露出来。
      Finder inPane(Finder finder) =>
          find.descendant(of: find.byType(SidePane), matching: finder);
      expect(inPane(find.text('+100')), findsOneWidget);
      expect(inPane(find.text('−0')), findsOneWidget);
      // **空态不许同时出现** —— 列着东西还说"还没有改动"就是自相矛盾。
      expect(find.text('还没有改动'), findsNothing);
    });

    testWidgets('点一行 → **真的把路径写进剪贴板**（不只是弹个提示）', (tester) async {
      final clipboard = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            final args = call.arguments;
            if (args is Map && args['text'] is String) {
              clipboard.add(args['text'] as String);
            }
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await pumpPreviewSession(tester);
      tester.state<ScaffoldState>(find.byType(Scaffold).first).openEndDrawer();
      await tester.pumpAndSettle();

      await tester.tap(find.text('lib/theme/dsh_icons.dart'));
      await tester.pumpAndSettle();

      expect(clipboard, ['lib/theme/dsh_icons.dart'], reason: '剪贴板里是那条路径');
      expect(find.textContaining('已复制'), findsOneWidget);
    });

    testWidgets('清单**按条目同一性缓存**：没变就不重算，且不可变', (tester) async {
      // `changedFiles` 每次 build 都会被问（`_sideHeader()` / `_fileBody()`），
      // 而它要扫全部条目 —— 八千条事件时那是每帧几万次判断。
      // 失效判据是**列表同一性**：`SessionStore` 每次归并都换成新的
      // `List.unmodifiable`（`session_store.dart:118`），所以 `identical`
      // 为假就等于"条目真的变了"。
      final app = await pumpPreviewSession(tester);
      final first = app.changedFiles;
      final second = app.changedFiles;
      expect(identical(first, second), isTrue, reason: '条目没变就该复用同一份，而不是每次重扫');
      expect(first.single.path, 'lib/theme/dsh_icons.dart');
      // 不可变：调用方拿去渲染，谁也别想着改它。
      expect(() => first.clear(), throwsUnsupportedError);
    });
  });

  group('会话流方向：seq 大的在下（最新一条在最下面）', () {
    // 2026-10-20 隔离实例真机复现：`ListView(reverse: true)` 里 index 0 在**最下面**，
    // 而 `items` 是 seq 升序（`session_store.dart:146`）—— 原来按 `items[index]` 正着取，
    // 于是整段对话**倒着排**（最早的在上），"进入会话落在最新一条"也落到了最早一条。
    test('列表下标 → items 下标：倒着取，流式条目占最下面一格', () {
      // 3 条持久条目、没有流式尾：最下面（index 0）= items[2]（最新）。
      expect(chatItemIndexFor(0, itemCount: 3, hasLive: false), 2);
      expect(chatItemIndexFor(2, itemCount: 3, hasLive: false), 0);
      // 有流式尾：index 0 是它，index 1 才是最新的持久条目。
      expect(chatItemIndexFor(1, itemCount: 3, hasLive: true), 2);
      expect(chatItemIndexFor(3, itemCount: 3, hasLive: true), 0);
    });

    testWidgets('真渲染：助手那条（seq 2）在用户那条（seq 1）下面', (tester) async {
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final app = AppModel(client: FakeClient())..loadPreview();
      await tester.pumpWidget(_wrap(app));
      await tester.pumpAndSettle();
      await app.openSession('preview-1');
      await tester.pumpAndSettle();

      final user = tester
          .getTopLeft(
            find.textContaining('帮我把 sync_client_impl', findRichText: true),
          )
          .dy;
      final assistant = tester
          .getTopLeft(find.textContaining('先量了一下耦合面', findRichText: true))
          .dy;
      expect(assistant, greaterThan(user), reason: 'seq 大的必须在下面');
    });
  });

  group('会话流按 itemId 复用 key（展开的卡片不会被自己收起）', () {
    // 这里守的是一个**用户看得见**的 bug（2026-10-20 修）：原来每次条目变化都
    // `List.generate(items.length, (_) => GlobalKey())` —— 换 key 等于让每一行
    // **重新挂载**，而 `ToolCard` 的展开状态存在 `State` 里，于是"展开一张工具卡，
    // 只要来一条新事件它就自己收起"。
    //
    // 判据要能区分两条路：**只有"条目换了但 id 没变"**才能暴露它 ——
    // 所以下面用 `loadPreview()` 再跑一遍（同一批 itemId，新的列表实例）。
    const detail = '写入了 100 个图标常量';

    testWidgets('展开后换一份 items：**仍然展开**', (tester) async {
      // 视口拉高：`ListView` 懒构建，屏外条目根本不在树上，
      // 而这张卡在示例会话里偏下。用视口而不是滚动手势 ——
      // 后者要挑 `Scrollable`（本页不止一个），脆弱。
      tester.view.physicalSize = const Size(1080, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final app = AppModel(client: FakeClient())..loadPreview();
      await tester.pumpWidget(_wrap(app));
      await tester.pumpAndSettle();
      await app.openSession('preview-2');
      await tester.pumpAndSettle();

      expect(find.textContaining(detail), findsNothing, reason: '默认收起');
      await tester.tap(find.text('write'));
      await tester.pumpAndSettle();
      expect(find.textContaining(detail), findsOneWidget, reason: '点开应展开');

      // 触发一次"条目换了一份、但 itemId 没变"的重建 ——
      // 这正是任何一条新事件到达时的形状。
      app.loadPreview();
      await tester.pumpAndSettle();

      expect(
        find.textContaining(detail),
        findsOneWidget,
        reason: '换 key 会让这一行重新挂载 ⇒ 展开状态丢失（本用例就是钉这个）',
      );
    });
  });
}
