/// 子智能体「进入 / 返回 / 切兄弟 / 只读」这条 UI 链的回归（2026-10-21）。
///
/// 数据面已有 `subagent_panel_test`（三态与指标解析）与 `subagent_tree_test`
/// （目录树本身）钉住；这里补的是**跨层那几跳**：
///
/// 1. 点面板里的行 → `openSession(child)` → 顶栏左侧变「← 返回父会话」、
///    标题变当前子级名（点它开「切换子智能体」）；
/// 2. 点头部条的标题 → 底部 sheet 列出父级的兄弟 → 选一个真的切过去；
/// 3. 一次性 / 未知模式的子会话：输入栏换成**横向只读状态框**。
///
/// 少任何一跳都会表现成"点了没反应"、"进了出不来"或"发出去没人接"。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:dsh_mobile/ui/dsh_composer.dart';
import 'package:dsh_mobile/ui/subagent_readonly_band.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

class _SubagentClient extends FakeSyncClient {
  _SubagentClient({
    this.mode = 'continuable',
    this.siblings = const ['调研实现'],
    this.parentTitle = '父会话',
  });

  /// catalog 行的 mode；`one-shot` 时子会话输入栏应换成只读状态框。
  final String mode;

  /// 父会话目录里的子级名字（按顺序，第一个是 child-1）。
  final List<String> siblings;

  /// 父会话的标题（顶栏 `父会话 › 子级名` 的前半段）。
  final String parentTitle;

  final _jobs = StreamController<JobFrame>.broadcast();

  /// 发出去的写方法（`session.prompt` / `subagent.prompt`），带 params。
  final sent = <(String, Map<String, Object?>)>[];

  @override
  ConnectionState get state => ConnectionState.serving;

  @override
  Stream<ConnectionState> get connection => const Stream.empty();

  @override
  Stream<JobFrame> get jobUpdates => _jobs.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> reconnect() => start();

  @override
  Future<void> setAppState(AppState state) async {}

  @override
  Future<void> close() async {
    await _jobs.close();
  }

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
    if (method == 'session.prompt' || method == 'subagent.prompt') {
      sent.add((method, params));
      return <String, Object?>{'accepted': true} as T;
    }
    final result = switch (method) {
      'session.list' => {
        'sessions': [
          {
            'sid': 'sid_A',
            'updatedAt': 1,
            'projections': {
              'values': {'title': parentTitle},
            },
          },
          for (var i = 0; i < siblings.length; i++)
            {
              'sid': 'child-${i + 1}',
              'updatedAt': 2 + i,
              'subagent': true,
              'projections': {
                'values': {'title': siblings[i]},
              },
            },
        ],
      },
      // 目录**按 sid 各是一条直接子级表**（DSH 的 catalog 只含直接子级）：
      // 父会话有 [siblings]，子级 child-1 自己还有一个孙级，child-2 是空叶。
      'session.projections' => switch (params['sid']) {
        'child-1' => {
          'subagentCatalog': [
            {
              'id': 'grand-1',
              'createdAt': 3000,
              'mode': 'one-shot',
              'label': '孙级调研',
            },
          ],
        },
        'child-2' => {'subagentCatalog': <Object?>[]},
        _ => {
          'subagentCatalog': [
            for (var i = 0; i < siblings.length; i++)
              {
                'id': 'child-${i + 1}',
                // 第一个子级是"正在被进入的那一个"，它的 mode 由 [mode] 决定。
                'createdAt': 1000 + i,
                'mode': i == 0 ? mode : 'one-shot',
                'label': siblings[i],
              },
          ],
        },
      },
      _ => null,
    };
    return result as T;
  }
}

/// 起一屏聊天页并进入父会话。
Future<GlobalKey<ChatPageState>> _pumpChat(
  WidgetTester tester,
  AppModel app,
) async {
  final key = GlobalKey<ChatPageState>();
  await tester.pumpWidget(
    MaterialApp(
      theme: DshTheme.dark(),
      home: ChatPage(
        key: key,
        app: app,
        onOpenDrawer: () {},
        onNewSession: () {},
        drawer: const Drawer(child: SizedBox()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return key;
}

/// 打开右抽屉 → 子智能体面板 → 点第一行（进入 child-1）。
Future<void> _enterFirstChild(
  WidgetTester tester,
  GlobalKey<ChatPageState> key,
  String label,
) async {
  key.currentState!.openSide();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.text('子智能体'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.text(label).first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('点目录行进入子会话：顶栏换成「← 返回父会话」+ 可切换的子级名', (tester) async {
    final app = AppModel(client: _SubagentClient());
    await app.start();
    // 标题里的父会话名来自 `session.list` 的投影提示，所以先拉一次列表。
    await app.refreshSessions();
    await app.openSession('sid_A');

    final key = await _pumpChat(tester, app);
    expect(find.byTooltip('打开会话抽屉'), findsOneWidget, reason: '普通会话的左侧是 ☰');

    await _enterFirstChild(tester, key, '调研实现');

    expect(app.currentSid, 'child-1');
    // 左侧 `←` 回父会话（手机惯例：进入下一层时导航栏左侧就是返回）。
    expect(find.byTooltip('返回父会话'), findsOneWidget);
    expect(find.byTooltip('打开会话抽屉'), findsNothing);
    // 标题 = 父级目录那一行的 label（Web `switcherDisplayTitle`，:490-495），
    // 点它开「切换子智能体」；父会话名放得下就并成 `父会话 › 子级名`。
    expect(find.byTooltip('切换子智能体'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byTooltip('切换子智能体'),
        matching: find.text('调研实现'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byTooltip('切换子智能体'), matching: find.text('父会话')),
      findsOneWidget,
      reason: '两个名字放得下时，标题里带父级（量不下就只留子级）',
    );
    expect(
      find.byType(DshComposer),
      findsOneWidget,
      reason: '可续聊的子会话保留正常输入栏（DSH 的 selectReadOnlySubagent 对它返回 null）',
    );

    await tester.tap(find.byTooltip('返回父会话'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(app.currentSid, 'sid_A', reason: '返回必须回到进来之前的那个会话');
    expect(find.byTooltip('返回父会话'), findsNothing);
    expect(find.byTooltip('打开会话抽屉'), findsOneWidget);
    app.dispose();
  });

  testWidgets('一次性子会话：输入栏换成 54px 横向只读状态框，不能继续发', (tester) async {
    final app = AppModel(client: _SubagentClient(mode: 'one-shot'));
    await app.start();
    await app.openSession('sid_A');

    final key = await _pumpChat(tester, app);
    await _enterFirstChild(tester, key, '调研实现');

    expect(app.currentSid, 'child-1');
    expect(find.byType(SubagentReadOnlyBand), findsOneWidget);
    // 文案逐字照 DSH 的 zh 词典（`locales.ts:45-47`）。
    expect(find.text('一次性子智能体记录'), findsOneWidget);
    expect(find.text('一次性任务不支持后续消息，可在这里查看完整执行记录。'), findsOneWidget);
    expect(
      find.byType(DshComposer),
      findsNothing,
      reason: '一次性子会话不接受后续消息；留着输入栏就是承诺一个发不出去的动作',
    );

    // **框还是那个框**（54 高、l4 发丝边、layer-1 底），文字两行 ——
    // 并排会在 390dp 上交错换行。外观由 `ui/subagent_readonly_band.dart` 定，
    // 这里只钉"它在、文案对、输入栏没了"。
    expect(find.byType(SubagentReadOnlyBand), findsOneWidget);

    app.dispose();
  });

  testWidgets('可继续子会话里发消息走 subagent.prompt（宿主只认这条路）', (tester) async {
    // 2026-10-21 真机：子会话的输入框是正常的，但 `session.prompt` 被宿主拒成
    // `internal: session "…" is owned by subagent routing` —— 手机上那句
    // 「发送失败」就是这么来的。可继续档必须换方法，参数形状不变。
    final client = _SubagentClient();
    final app = AppModel(client: client);
    await app.start();
    await app.openSession('sid_A');

    final key = await _pumpChat(tester, app);
    await _enterFirstChild(tester, key, '调研实现');
    expect(app.currentSid, 'child-1');

    await tester.enterText(find.byType(TextField).first, '继续');
    await tester.pump();
    await tester.tap(find.byTooltip('发送'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(client.sent, hasLength(1), reason: '只发一次，不发两遍');
    final (method, params) = client.sent.single;
    expect(method, 'subagent.prompt', reason: '子会话的写入口只有这一个');
    expect(params['sid'], 'child-1');
    expect(params['content'], [
      {'type': 'text', 'text': '继续'},
    ]);
    app.dispose();
  });

  testWidgets('模式未知的子会话也走只读状态框', (tester) async {
    final app = AppModel(client: _SubagentClient(mode: 'unknown'));
    await app.start();
    await app.openSession('sid_A');

    final key = await _pumpChat(tester, app);
    await _enterFirstChild(tester, key, '调研实现');

    expect(find.byType(SubagentReadOnlyBand), findsOneWidget);
    expect(find.text('此子智能体暂时只读'), findsOneWidget);
    expect(find.text('读取子会话后才能确定是否可继续。'), findsOneWidget);
    app.dispose();
  });

  testWidgets('头部条：点标题开「切换子智能体」面板，选兄弟切过去', (tester) async {
    final app = AppModel(
      client: _SubagentClient(siblings: const ['调研实现', '抽图标']),
    );
    await app.start();
    await app.openSession('sid_A');

    final key = await _pumpChat(tester, app);
    await _enterFirstChild(tester, key, '调研实现');
    expect(app.currentSid, 'child-1');

    final crumb = tester.getRect(find.byTooltip('切换子智能体'));
    await tester.tap(find.byTooltip('切换子智能体'));
    await tester.pumpAndSettle();

    // **跟手判据**：面板必须长在标题**下面**，而不是从屏幕底部升起来。
    // 用户 2026-10-21 原话「点击在上面，下面弹出你不觉得不跟手吗？差太远了吧」。
    // 量的是面板标题那枚 `Text` 的矩形（它就是卡片的顶边那一行）。
    final panel = tester.getRect(find.text('切换子智能体').first);
    expect(
      panel.top - crumb.bottom,
      lessThan(80),
      reason: '面板顶边要贴着触发点（底部 sheet 会差出一整屏）',
    );
    expect(
      (panel.left - crumb.left).abs(),
      lessThan(80),
      reason: '水平方向也要落在触发点那一侧，不能跑到屏幕另一端',
    );

    expect(find.text('切换子智能体'), findsWidgets, reason: '面板的标题');
    // 兄弟在 sheet 里（`抽图标` 只在 sheet 里出现：头部条显示的是当前子级）。
    expect(find.text('抽图标'), findsOneWidget);

    await tester.tap(find.text('抽图标'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(app.currentSid, 'child-2', reason: '切换兄弟 = 换主对话区（Web 的 openChild）');
    expect(
      find.byType(SubagentReadOnlyBand),
      findsOneWidget,
      reason: '第二个子级是 one-shot ⇒ 切过去后输入栏也换成只读',
    );
    expect(find.byTooltip('返回父会话'), findsOneWidget, reason: '切兄弟不该丢掉"回父会话"');
    app.dispose();
  });

  testWidgets('切换面板里也能展开子级（面板是独立路由，要自己跟着重建）', (tester) async {
    // 少了这一跳的症状：点 disclosure 发得出 `session.projections`，
    // 但面板里什么都不变（页面层的重建到不了面板这条路由）。
    final app = AppModel(
      client: _SubagentClient(siblings: const ['调研实现', '抽图标']),
    );
    await app.start();
    await app.openSession('sid_A');

    final key = await _pumpChat(tester, app);
    await _enterFirstChild(tester, key, '调研实现');

    await tester.tap(find.byTooltip('切换子智能体'));
    await tester.pumpAndSettle();
    expect(find.text('抽图标'), findsOneWidget);

    // 展开「调研实现」这一级：它会现读 child-1 自己的 catalog（一条孙级）。
    await tester.tap(find.byTooltip('展开 调研实现 的下级子智能体'));
    await tester.pumpAndSettle();
    expect(
      find.text('孙级调研'),
      findsOneWidget,
      reason: '展开后面板必须真的重画（ListenableBuilder 听 AppModel）',
    );
    app.dispose();
  });

  testWidgets('标题预算放不下时不带父级：只留子级名', (tester) async {
    // 这条钉的是"空间怎么省"的判断：两个名字硬塞会各截一半，
    // 而"我在哪个子智能体里"比"父级叫什么"要紧 —— 量不下就只留子级。
    //
    // 用**手机宽度**（390dp）+ 一个长父标题：默认 800dp 的测试画布上什么都放得下，
    // 那测不到"放不下"这一支。
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final app = AppModel(
      client: _SubagentClient(parentTitle: '一个非常非常长的父会话标题用来把顶栏标题预算撑爆'),
    );
    await app.start();
    await app.refreshSessions();
    await app.openSession('sid_A');

    final key = await _pumpChat(tester, app);
    await _enterFirstChild(tester, key, '调研实现');

    final crumb = find.byTooltip('切换子智能体');
    expect(crumb, findsOneWidget);
    expect(
      find.descendant(of: crumb, matching: find.text('调研实现')),
      findsOneWidget,
      reason: '子级名永远显示',
    );
    expect(
      find.textContaining('非常非常长'),
      findsNothing,
      reason: '父级名放不下就整段不出现（不是截一半）',
    );
    app.dispose();
  });

  testWidgets('系统返回键：在子会话里回父会话，不在子会话时不拦', (tester) async {
    // 这条是**移动端专有**的：Web 有浏览器 history，手机只有系统返回。
    // 判据用 `PopScope.canPop`（`packages/flutter/lib/src/widgets/pop_scope.dart:83-96`）。
    final app = AppModel(client: _SubagentClient());
    await app.start();
    await app.openSession('sid_A');

    final key = await _pumpChat(tester, app);
    expect(
      tester.widget<PopScope<void>>(find.byType(PopScope<void>)).canPop,
      isTrue,
      reason: '不在子会话时返回键照常走（不抢）',
    );

    await _enterFirstChild(tester, key, '调研实现');
    expect(app.currentSid, 'child-1');
    expect(
      tester.widget<PopScope<void>>(find.byType(PopScope<void>)).canPop,
      isFalse,
      reason: '子会话里拦下 pop，改由回调回父会话',
    );

    // 系统返回（Android 的返回手势 / 返回键走的就是这一条）。
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(app.currentSid, 'sid_A', reason: '子会话里按返回 = 回父会话，不是退出整个聊天页');
    expect(find.byTooltip('返回父会话'), findsNothing);
    app.dispose();
  });
}
