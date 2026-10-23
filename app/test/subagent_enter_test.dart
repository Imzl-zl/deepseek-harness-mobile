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
import 'package:dsh_mobile/ui/dsh_app_bar.dart';
import 'package:dsh_mobile/ui/dsh_composer.dart';
import 'package:dsh_mobile/ui/subagent_readonly_band.dart';
import 'package:dsh_mobile/ui/subagent_tree.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

class _SubagentClient extends FakeSyncClient {
  _SubagentClient({
    this.mode = 'continuable',
    this.grandMode = 'one-shot',
    this.siblings = const ['调研实现'],
    this.parentTitle = '父会话',
    this.noParentId = const {},
    this.failingCatalogs = const {},
  });

  /// catalog 行的 mode；`one-shot` 时子会话输入栏应换成只读状态框。
  final String mode;

  /// 孙级那一行的 mode（它在 **child-1** 的目录里，不在祖父目录里）。
  final String grandMode;

  /// 父会话目录里的子级名字（按顺序，第一个是 child-1）。
  final List<String> siblings;

  /// 父会话的标题。
  final String parentTitle;

  /// 这些 sid 的 `session.list` 行**不带** `parentSessionId`：
  /// 老连接器（没有这个字段）与"这个会话查不到父级"都长这样。
  final Set<String> noParentId;

  /// 这些 sid 的 `session.projections` 读失败（目录三态的 error 档）。
  final Set<String> failingCatalogs;

  final _jobs = StreamController<JobFrame>.broadcast();

  /// 挂住某些 sid 目录读取的闸门（模拟网络慢的那一拍）。
  final _gates = <String, Completer<void>>{};

  /// 让 [sid] 的**目录读取**在 [releaseCatalog] 之前不返回。
  ///
  /// 挂住的不是"还没开始读"：`AppModel._readProjections` 已经把那一层置成
  /// `loading`（**保留旧 entries**），所以界面上那一行照常画得出来、也点得动。
  void holdCatalog(String sid) => _gates[sid] = Completer<void>();

  /// 放行被 [holdCatalog] 挂住的那一次读取。
  void releaseCatalog(String sid) {
    final gate = _gates.remove(sid);
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  /// 发出去的写方法（`session.prompt` / `subagent.prompt`），带 params。
  final sent = <(String, Map<String, Object?>)>[];

  /// 读过的目录（`session.projections` 的 sid 顺序；重试用得上）。
  final catalogReads = <String>[];

  /// 每次 `subscribe` 的 sid（`openSession` 必发一次）——
  /// 用来钉"点当前行不再重进自己"：重进会多一条同名记录。
  final subscribes = <String>[];

  /// 孙级会话的标题与它在父级目录里的 label **故意不同**：
  /// 这样"标题取目录里的 label"与"回落到会话自己的标题"能分开断言。
  static const grandTitle = '孙会话标题';
  static const grandLabel = '孙级记录';

  @override
  Future<SessionAnchor> subscribe(String sid, {required int since}) async {
    subscribes.add(sid);
    return super.subscribe(sid, since: since);
  }

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
              // **父级（别名形式）**：电脑侧 `session.list` 的行就带这个键；
              // 根会话（sid_A）没有它 —— 与连接器那条判据一致。
              if (!noParentId.contains('child-${i + 1}'))
                'parentSessionId': 'sid_A',
              'projections': {
                'values': {
                  'title': siblings[i],
                  // 子会话的模型**只在投影提示里**（顶层没有 `model` ——
                  // 连接器读不到子会话的活 agent）。
                  'modelSelection': {
                    'lastUsed': {'provider': 'p', 'model': 'm-child-$i'},
                    'next': {'provider': 'p', 'model': 'm-child-$i'},
                  },
                },
              },
            },
          {
            'sid': 'grand-1',
            'updatedAt': 9,
            'subagent': true,
            if (!noParentId.contains('grand-1')) 'parentSessionId': 'child-1',
            'projections': {
              'values': {'title': grandTitle},
            },
          },
        ],
      },
      // 目录**按 sid 各是一条直接子级表**（DSH 的 catalog 只含直接子级）：
      // 父会话有 [siblings]，子级 child-1 自己还有一个孙级，child-2 是空叶。
      'session.projections' => await _projections(params['sid'] as String?),
      _ => null,
    };
    return result as T;
  }

  Future<Object?> _projections(String? sid) async {
    catalogReads.add(sid ?? '');
    // 闸门先看：`_readProjections` 已经把目录置成 `loading`（旧 entries 还在），
    // 所以挂住应答时界面照常画行 —— 那正是"展开后那一拍里点孙级"的窗口。
    final gate = _gates[sid];
    if (gate != null) await gate.future;
    // 读失败：形状不对（不是对象）—— 目录进 error 态，界面要有重试入口。
    if (sid != null && failingCatalogs.contains(sid)) return 'boom';
    return switch (sid) {
      'child-1' => {
        'subagentCatalog': [
          {
            'id': 'grand-1',
            'createdAt': 3000,
            'mode': grandMode,
            'label': grandLabel,
          },
        ],
      },
      'grand-1' => {'subagentCatalog': <Object?>[]},
      'sid_A' => {
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
      // child-2 / 其他：已知空叶。
      _ => {'subagentCatalog': <Object?>[]},
    };
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
  // 抽屉可能**已经停在**子智能体页（这一屏之前进来过）：那时面板标题与 tab
  // 都叫「子智能体」，再点一次会撞上两个同名文本。两处都在 = 已经在这一页。
  final tabs = find.text('子智能体');
  if (tabs.evaluate().length < 2) {
    await tester.tap(tabs);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
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
    // **只有当前子级名**：父级名不进标题（DSH 的 switcher 同样只显示这一层）。
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
      findsNothing,
      reason: '标题只显示当前子级名（父级由切换面板的 root 表达，不是塞进标题）',
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
      find.text(_SubagentClient.grandLabel),
      findsOneWidget,
      reason: '展开后面板必须真的重画（ListenableBuilder 听 AppModel）',
    );
    app.dispose();
  });

  testWidgets('顶栏标题只有当前子级名：父级名不进标题（照 DSH 的 switcher）', (tester) async {
    // 用**手机宽度**（390dp）+ 一个长父标题：这条钉的是"父级名根本不进来"，
    // 不是"放不下才省掉" —— 上一版是 `父会话 › 子级名`，DSH 的 switcher
    // 只显示 `switcherDisplayTitle`（`SubagentHeaderLineage.tsx:490-495`）。
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
      reason: '父级名一次都不出现（不是"放不下才省"，是不进标题）',
    );
    app.dispose();
  });

  testWidgets('名字查不到时显示会话自己的标题，不再出现「子智能体」字面量', (tester) async {
    // 2026-10-23 的真机症状：孙级的父级仍停在祖父上 ⇒ 父级目录里找不到这一行
    // ⇒ 标题回落到字面量「子智能体」，用户读成"里面还是它自己"。
    // 现在查不到就退到**会话自己的标题**（`currentTitle`）。
    final client = _SubagentClient();
    final app = AppModel(client: client);
    await app.start();
    await app.refreshSessions();
    // 直接落在孙级上、**不经面板**：没有导航记忆，父级目录也还没读，
    // 于是"父级目录里那一行"一定查不到。
    await app.openSession('grand-1');

    await _pumpChat(tester, app);

    // 数据里有父级（`parentSessionId: child-1`）⇒ 仍然是子会话头部。
    expect(find.byTooltip('返回父会话'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byTooltip('切换子智能体'),
        matching: find.text(_SubagentClient.grandTitle),
      ),
      findsOneWidget,
      reason: '父级目录里没有这一行时，标题是会话自己的标题',
    );
    expect(
      find.descendant(
        of: find.byTooltip('切换子智能体'),
        matching: find.text('子智能体'),
      ),
      findsNothing,
      reason: '字面量兜底已删（它会把"查不到"伪装成"名字叫子智能体"）',
    );
    app.dispose();
  });

  testWidgets('子智能体页面的输入栏要显示模型（行里的投影提示 modelSelection）', (tester) async {
    // 2026-10-23 用户看到的问题：进子会话，输入栏的模型显示「未选择」。
    // 根因是连接器顶层 `model` 从**活 agent** 读，子会话不在那张表里；
    // 而行的投影提示 `modelSelection` 对子会话也有（`lastUsed` 由 request/header 推）。
    final app = AppModel(client: _SubagentClient());
    await app.start();
    await app.refreshSessions();
    await app.openSession('sid_A');

    final key = await _pumpChat(tester, app);
    // 对照：父会话的行没有 modelSelection ⇒ 仍是「未选择」，不猜
    expect(
      find.descendant(of: find.byType(DshComposer), matching: find.text('未选择')),
      findsOneWidget,
    );

    await _enterFirstChild(tester, key, '调研实现');
    expect(app.currentSid, 'child-1');
    expect(
      find.descendant(
        of: find.byType(DshComposer),
        matching: find.text('m-child-0'),
      ),
      findsOneWidget,
      reason: '子会话的模型来自投影提示（顶层 model 没有这个会话）',
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

  testWidgets('数据档：直接落在孙级，← 回到数据里的父级（这里根本没有记忆）', (tester) async {
    // 2026-10-23 的 bug：父级来自导航记忆 ⇒ 直接落在孙级上（重启恢复 /
    // 从别的入口进来）时**连返回都没有**；有记忆时又会跳过真正的父级。
    // 判据：这里没有走面板、没有记忆，`←` 必须回 `child-1`（`parentSessionId`）。
    final app = AppModel(client: _SubagentClient());
    await app.start();
    await app.refreshSessions();
    await app.openSession('grand-1');

    await _pumpChat(tester, app);

    expect(find.byTooltip('返回父会话'), findsOneWidget, reason: '数据里有父级 ⇒ 头部就是子会话');
    await tester.tap(find.byTooltip('返回父会话'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(app.currentSid, 'child-1', reason: '孙级的父级是 child-1，不是祖父');
    app.dispose();
  });

  testWidgets('父→子→孙：每层头部是各自的父级，← 逐层返回', (tester) async {
    final client = _SubagentClient(siblings: const ['调研实现', '抽图标']);
    final app = AppModel(client: client);
    await app.start();
    await app.refreshSessions();
    await app.openSession('sid_A');

    final key = await _pumpChat(tester, app);

    // 父 → 子
    await _enterFirstChild(tester, key, '调研实现');
    expect(app.currentSid, 'child-1');

    // 子 → 孙：切换面板（root = sid_A）里展开 child-1，再点孙级
    await tester.tap(find.byTooltip('切换子智能体'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('展开 调研实现 的下级子智能体'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(_SubagentClient.grandLabel).last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(app.currentSid, 'grand-1');

    // **只读档取自孙级自己的父级目录**（child-1 里那一行是 `one-shot`）：
    // 用"当前会话的父级"（sid_A）去查会查不到 ⇒ 显示成「模式未知」。
    // 真机 2026-10-23 抓到过这一支（进孙级后输入栏变成只读）。
    expect(
      find.text('一次性子智能体记录'),
      findsOneWidget,
      reason: 'mode 来自 node 自己那条目录（child-1），不是当前会话的父级（sid_A）',
    );
    expect(find.text('此子智能体暂时只读'), findsNothing);

    // 孙级头部：标题是它在 **child-1** 目录里的 label（不是祖父目录里的东西）
    expect(
      find.descendant(
        of: find.byTooltip('切换子智能体'),
        matching: find.text(_SubagentClient.grandLabel),
      ),
      findsOneWidget,
    );

    // 孙级的切换面板 root = **child-1**：列的是它自己的兄弟（空的），
    // 不再列祖父的子级 —— `抽图标` 出现就说明 root 还是错的。
    await tester.tap(find.byTooltip('切换子智能体'));
    await tester.pumpAndSettle();
    expect(
      find.text('抽图标'),
      findsNothing,
      reason: 'root 必须是真正的父级 child-1，不是祖父 sid_A',
    );

    // 当前行不可点：点它只关面板，不再"进自己"。
    // **判据是 `subscribe` 不多发**（"又进一次自己"在屏幕上看不出差别，
    // 但 `openSession` 一定会重新订阅一次）。
    final subscribesBefore = client.subscribes.length;
    await tester.tap(
      find.descendant(
        of: find.byType(SubagentTree),
        matching: find.text(_SubagentClient.grandLabel),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(app.currentSid, 'grand-1', reason: '点当前行不再 openSession(自己)');
    expect(
      client.subscribes.length,
      subscribesBefore,
      reason: '点当前行不许再订阅一次（那正是"又进了自己一次"）',
    );

    // ← 孙 → 子
    await tester.tap(find.byTooltip('返回父会话'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(app.currentSid, 'child-1', reason: '孙级回的是真正的父级');

    // ← 子 → 父
    await tester.tap(find.byTooltip('返回父会话'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(app.currentSid, 'sid_A', reason: '子级回到父级');

    // 回到父级后不再有返回（根会话没有面包屑，DSH `:801`）
    expect(find.byTooltip('返回父会话'), findsNothing);
    app.dispose();
  });

  testWidgets('展开后那一拍里点孙级：mode 来自它自己那一行，不是回目录里查', (tester) async {
    // 审查 I2：`_switchSibling` 曾经拿"已读目录"回查 mode，而展开**无条件**重读
    // 那一层（`AppModel._readProjections` 先置 `loading`，但保留旧 entries ⇒ 界面
    // 照常画行、也点得动）。于是那一拍里点孙级会查不到 mode ⇒ 可续聊的孙级显示
    // 「此子智能体暂时只读」，而且不自愈（mode 只在进入那一刻取一次）。
    // 判据：把 `session.projections` 的应答挂住，在挂住期间点孙级。
    final client = _SubagentClient(grandMode: 'continuable');
    final app = AppModel(client: client);
    await app.start();
    await app.refreshSessions();
    await app.openSession('sid_A');

    final key = await _pumpChat(tester, app);
    await _enterFirstChild(tester, key, '调研实现');

    // ① 先正常展开一次：孙级那一行进到界面上（那一层目录 ready）。
    await tester.tap(find.byTooltip('切换子智能体'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('展开 调研实现 的下级子智能体'));
    await tester.pumpAndSettle();
    expect(find.text(_SubagentClient.grandLabel), findsOneWidget);

    // ② 收起再展开 = 再读一次那一层，这次把应答挂住：
    //    目录进 `loading`，但旧 entries 还在 ⇒ 孙级行仍然可点。
    client.holdCatalog('child-1');
    await tester.tap(find.byTooltip('收起 调研实现 的下级子智能体'));
    await tester.pump();
    await tester.tap(find.byTooltip('展开 调研实现 的下级子智能体'));
    await tester.pump();
    expect(
      find.text(_SubagentClient.grandLabel),
      findsOneWidget,
      reason: 'loading 保留旧 entries（刷新不闪空）⇒ 这一行照常画出来',
    );

    // ③ 就在这一拍里点孙级。
    await tester.tap(find.text(_SubagentClient.grandLabel));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(app.currentSid, 'grand-1');
    expect(
      find.byType(SubagentReadOnlyBand),
      findsNothing,
      reason: '可续聊的孙级不许被说成只读 —— mode 就在画出它的那一行上',
    );
    expect(find.byType(DshComposer), findsOneWidget);

    client.releaseCatalog('child-1');
    await tester.pump();
    app.dispose();
  });

  testWidgets('目录扫描档 / 记忆档：老连接器没有 parentSessionId 时仍能回父级', (tester) async {
    // 第 2 档（目录扫描）与第 3 档（记忆）**都不能删**：
    // 新手机连老连接器时 `parentSessionId` 为空，删了就退回 2026-10-21
    // 那个"进子会话出不来"的坑。
    final failing = <String>{};
    final client = _SubagentClient(
      noParentId: {'child-1'},
      failingCatalogs: failing,
    );
    final app = AppModel(client: client);
    await app.start();
    await app.refreshSessions();
    await app.openSession('sid_A');

    final key = await _pumpChat(tester, app);

    // ① 目录扫描档：连接器没发父级，但父级目录里就有这一行
    await _enterFirstChild(tester, key, '调研实现');
    expect(app.currentSid, 'child-1');
    expect(find.byTooltip('返回父会话'), findsOneWidget, reason: '父级从目录扫到');
    await tester.tap(find.byTooltip('返回父会话'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(app.currentSid, 'sid_A');

    // ② 记忆档：连目录也没了（读失败 ⇒ 三态 error、entries 清空）
    await _enterFirstChild(tester, key, '调研实现');
    expect(app.currentSid, 'child-1');
    failing.add('sid_A');
    await app.refreshSubagentCatalog('sid_A');
    await tester.pump();
    expect(
      find.byTooltip('返回父会话'),
      findsOneWidget,
      reason: '目录读失败也不能把返回弄丢 —— 这时只有导航记忆还知道父级',
    );
    await tester.tap(find.byTooltip('返回父会话'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(app.currentSid, 'sid_A', reason: '记忆兜底给出的是走进来之前的会话');
    app.dispose();
  });

  testWidgets('目录读失败：顶栏给入口，面板里点重试会真的再读一次', (tester) async {
    // DSH 的 `visible`（`SubagentHeaderLineage.tsx:617-631`）把"加载失败"也算作
    // 要渲染 —— 否则连进面板的入口都没有，那个重试按钮永远够不着。
    final client = _SubagentClient(failingCatalogs: {'sid_A'});
    final app = AppModel(client: client);
    await app.start();
    await app.refreshSessions();
    await app.openSession('sid_A');

    await _pumpChat(tester, app);

    // 0 个子智能体 + 失败 ⇒ chip 仍在（图标换成重试）
    expect(
      find.byType(DshCountChip),
      findsOneWidget,
      reason: '失败时这枚 chip 是唯一入口',
    );

    final before = client.catalogReads.length;
    await tester.tap(find.byType(DshCountChip));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('无法加载子智能体'), findsOneWidget, reason: '面板如实报错');

    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      client.catalogReads.length,
      greaterThan(before),
      reason: '点重试必须真的再发一次 session.projections（不是只重画）',
    );
    app.dispose();
  });
}
