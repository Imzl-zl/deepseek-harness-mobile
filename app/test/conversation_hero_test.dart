/// 连接后落到的第一屏 = DSH 的「新会话页」（hero）。
///
/// ## 这一组守什么
///
/// 用户 2026-10-17 的原话是"连接后最好是电脑显示啥手机也显示啥"，
/// 随后澄清"我说的是**刚连上的时候的页面**"。DSH 那边这一屏**不是"没有会话"，
/// 是"已有会话但它是 blank"**（`ConversationMainPanel.tsx:41-43`），
/// 所以手机上要成立两件事：
///
/// 1. **连上之后要真的落在那个 blank 会话上** —— 不然它被 `sessionVisible`
///    从列表里藏掉（`tree.ts:245`），用户永远看不到这一屏；
/// 2. 落到之后**那一屏长成 hero**（鱼 + 「探索未至之境」+ 预览版徽标 + 两枚 chip），
///    占位文案换成 `placeholder.hero`。
///
/// 另外三条是"不能越界"：非 blank 不显示 hero、断线不显示 hero、
/// 拿不到目录时 chip 说拿不到而不是摆一份手抄的名单。
library;

import 'dart:async';

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/theme/dsh_icons.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:dsh_mobile/ui/conversation_hero.dart';
import 'package:dsh_mobile/ui/dsh_app_bar.dart';
import 'package:dsh_mobile/ui/dsh_composer.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'fake_sync_client.dart';

class _HeroClient extends FakeSyncClient {
  _HeroClient({
    this.sessions = const [],
    this.projections = const {},
    this.workspaces,
    this.presets,
    this.replay = const [],
  });

  final List<Object?> sessions;
  final Map<String, Object?> projections;

  /// `null` = 这台电脑没有这个方法（回 `null`，与连接器"缺服务就不挂"同形）。
  final Object? workspaces;
  final Object? presets;

  /// 订阅后要推的**持久事件**（真形状用）。
  ///
  /// 电脑侧**每个**会话的头几条都是记账事件（`session` / `permission/preset` /
  /// `sandbox/mode` / `approval/policy`，2026-10-17 从会话日志数出来的），
  /// 投影成只计数、不渲染的 [OtherItem]。默认空 = 旧形状（那个形状下
  /// `items.isEmpty` 恒真，hero 的旧判据看着一直是绿的）。
  final List<SessionEvent> replay;

  final List<String> calls = [];
  final Map<String, Map<String, Object?>> paramsOf = {};

  /// 订阅过的会话（`subscribe` 是**独立方法**，不走 `call` —— 第一版把它当成
  /// `call('session.subscribe')` 断言，于是"订阅了没有"根本没被验到）。
  final List<String> subscribed = [];

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

  /// **必须自己覆写**：它记 `subscribed`（"落上去就要订阅它"那条断言靠它）。
  /// `FakeSyncClient` 的默认实现不记，所以不能靠继承。
  @override
  Future<SessionAnchor> subscribe(String sid, {required int since}) async {
    subscribed.add(sid);
    return SessionAnchor(since: since, hasMore: false);
  }

  @override
  Stream<SessionDelta> sessionUpdates(String sid) => replay.isEmpty
      ? const Stream.empty()
      : Stream.fromIterable([
          SessionDelta(sid: sid, events: replay, transient: const {}),
        ]);

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    calls.add(method);
    paramsOf[method] = params;
    switch (method) {
      // **形状照电脑侧**：`{sessions: […]}`（`connector/src/handlers.ts`）。
      case 'session.list':
        return {'sessions': sessions} as T;
      case 'session.projections':
        return projections as T;
      case 'workspace.list':
        return workspaces as T;
      case 'agentPresets.list':
        return presets as T;
      case 'session.create':
        return {'sid': 'new-1'} as T;
      default:
        return null as T;
    }
  }
}

/// 一行 blank 会话（`session.list` 的行形状）。
///
/// 可选字段用 **null-aware value**（`'cwd': ?cwd`）而不是 `if (x != null) …`：
/// 这里 key 是字面量，所以没有 `selectModel` 那个"key 取值的字符串形式"的坑
/// （见 `tools.md` 的 Dart 坑条目），而 `dart analyze` 也只认这一种写法。
Map<String, Object?> blankRow(String sid, {String? cwd}) => {
  'sid': sid,
  'blank': true,
  'itemCount': 0,
  'updatedAt': 5,
  // 恒发键（`connector/src/handlers.ts:740-744`）：假行必须是线上形状。
  'running': false,
  'subagent': false,
  'cwd': ?cwd,
};

/// 一份够真的目录应答（四个内置 + 一个自建；内置**不发布 name**）。
Map<String, Object?> presetReply() => {
  'available': true,
  'roster': {
    'presets': [
      {'id': 'standard', 'isDefault': true},
      {'id': 'ptc', 'isDefault': false},
      {'id': 'minimal', 'isDefault': false},
      {'id': 'cordis', 'isDefault': false},
      {
        'id': 'team-review',
        'isDefault': false,
        'name': 'Team Review',
        'description': 'Review-only composition.',
      },
    ],
  },
};

Map<String, Object?> workspaceReply({String? owningWorkspace}) => {
  'workspaces': [
    {
      'workspaceId': 'w1',
      'title': 'dsh-mobile',
      'path': r'D:\sudy\myproject\dsh-mobile',
      'createdAt': '2026-10-01T00:00:00.000Z',
      'sessionIds': owningWorkspace == 'w1' ? ['blank-1'] : <String>[],
    },
    {
      'workspaceId': 'w2',
      'title': 'deepseek-harness',
      'path': r'D:\sudy\github\deepseek-harness',
      'createdAt': '2026-09-01T00:00:00.000Z',
      'sessionIds': owningWorkspace == 'w2' ? ['blank-1'] : <String>[],
    },
  ],
  'archivedSessionIds': <String>[],
  // 连接器无条件写三列（`handlers.ts:1004-1014`）；少一列整份快照就解不出来。
  'pinnedSessionIds': <String>[],
};

Widget host(AppModel app, {bool paired = true}) => MaterialApp(
  theme: DshTheme.dark(),
  home: ChatPage(
    app: app,
    paired: paired,
    onOpenDrawer: () {},
    onNewSession: () {},
    onRePair: () {},
    drawer: const SizedBox.shrink(),
  ),
);

void main() {
  /// 建一个"连上了"的模型并推一次 `serving`。
  ///
  /// **不在这里 await 任何 Timer**：`testWidgets` 的 body 跑在**假异步区**里，
  /// `await Future.delayed(Duration.zero)` 需要有人 `pump` 才会完成 ——
  /// 在 pump 之前 await 它就是**死锁**（第一版这么写，整个用例文件挂死到超时）。
  /// 微任务（`async` 方法之间的 await）在假异步区里照常推进，所以这里什么都不用做：
  /// 纯 `test()` 里补一句真实延迟，`testWidgets` 里靠 `pumpWidget` + `pumpAndSettle`。
  (_HeroClient, AppModel) connected({
    List<Object?>? sessions,
    Object? workspaces,
    Object? presets,
    Map<String, Object?> projections = const {},
  }) {
    final client = _HeroClient(
      sessions: sessions ?? [blankRow('blank-1')],
      workspaces: workspaces,
      presets: presets,
      projections: projections,
    );
    final app = AppModel(client: client);
    unawaited(app.start());
    client.emit(ConnectionState.serving);
    return (client, app);
  }

  group('连上之后落在 blank 会话上', () {
    test('有一行 blank：自动选中它（否则用户永远看不到这一屏）', () async {
      final (client, app) = connected();
      addTearDown(app.dispose);
      // 纯 `test()` 里是真实事件循环，让 `refreshSessions` 那一串 await 跑完。
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        app.currentSid,
        'blank-1',
        reason:
            'blank 会话被 sessionVisible 从列表里藏掉（tree.ts:245），'
            '不自动选中就等于这一屏在手机上不存在',
      );
      expect(client.subscribed, contains('blank-1'), reason: '落上去就要订阅它');
    });

    test('一个 blank 都没有：不动，照旧让用户从列表里选', () async {
      final (_, app) = connected(
        sessions: [
          {'sid': 'ran-1', 'blank': false, 'itemCount': 3, 'updatedAt': 9},
        ],
      );
      addTearDown(app.dispose);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(app.currentSid, isNull, reason: '没有 blank 就什么都不做，不硬挑一个会话');
    });

    test('子智能体的会话不当 landing 靶子', () async {
      final (_, app) = connected(
        sessions: [
          {'sid': 'sub-1', 'blank': true, 'subagent': true, 'updatedAt': 9},
        ],
      );
      addTearDown(app.dispose);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(app.currentSid, isNull);
    });
  });

  group('那一屏长成 hero', () {
    testWidgets('鱼 + 「探索未至之境」+ 「预览版」+ 两枚 chip 都在', (tester) async {
      final (_, app) = connected(
        workspaces: workspaceReply(owningWorkspace: 'w1'),
        presets: presetReply(),
        projections: {'agentPreset': 'ptc'},
      );
      addTearDown(app.dispose);
      await tester.pumpWidget(host(app));
      await tester.pumpAndSettle();

      expect(find.byType(ConversationHero), findsOneWidget);
      expect(find.text('探索未至之境'), findsOneWidget);
      expect(find.text('预览版'), findsOneWidget);
      expect(
        find.byType(DshIcon),
        findsWidgets,
        reason: '鱼是 DSH 图标集里的 fishLogo',
      );
      expect(
        DshIcons.has('fishLogo'),
        isTrue,
        reason: '鱼必须来自图标集（extract-dsh-icons.mjs 的一条来源），不是手抄的 SVG',
      );
      // 工作区 chip = 归属那个工作区的标题；模式 chip = 投影里那个预设的中文名。
      expect(find.text('dsh-mobile'), findsOneWidget);
      expect(find.text('PTC 模式'), findsOneWidget);
    });

    testWidgets('hero 在对话区里**居中**，不贴底（真机反馈"首页显示在最下面"）', (tester) async {
      // 2026-10-19 真机截图：hero 挤在屏幕最底下、上面一大片空白。
      // DSH 的判据是 `ConversationRoot.module.css:503-518`：
      // "Hero phase: the composer stack … is flex-centered in the column;
      //  composer phase docks it at the bottom" + `padding-bottom: 32px`。
      // 所以这一条同时钉住两件事：**不贴底**（`end` 会红）与
      // **不置顶**（`start` 会红）—— 居中偏上才是 DSH 的 hero 阶段。
      final (_, app) = connected(
        workspaces: workspaceReply(owningWorkspace: 'w1'),
        presets: presetReply(),
        projections: {'agentPreset': 'ptc'},
      );
      addTearDown(app.dispose);
      await tester.pumpWidget(host(app));
      await tester.pumpAndSettle();

      final hero = tester.getRect(find.text('探索未至之境'));
      // 对话区 = 分段控件下缘 → 输入栏上缘（hero 只在这一段里）。
      final areaTop = tester.getRect(find.byType(DshSegmented)).bottom;
      final areaBottom = tester.getRect(find.byType(DshComposer)).top;
      final area = Rect.fromLTRB(0, areaTop, 800, areaBottom);
      // 量的必须是**子控件**（标题那一行）：`Column` 默认 `mainAxisSize.max`
      // 会撑满整个弹性区，容器的 rect 在任何对齐下都一样 —— 那是空转的断言。
      final heroCenter = hero.center.dy;
      final fraction = (heroCenter - area.top) / area.height;

      expect(
        fraction,
        lessThan(0.6),
        reason: 'hero 贴底了（fraction=$fraction）—— DSH hero 阶段是居中的',
      );
      expect(
        fraction,
        greaterThan(0.3),
        reason: 'hero 置顶了（fraction=$fraction）—— DSH hero 阶段是居中略偏上',
      );
    });

    testWidgets('占位文案换成 placeholder.hero 那句', (tester) async {
      final (_, app) = connected(presets: presetReply());
      addTearDown(app.dispose);
      await tester.pumpWidget(host(app));
      await tester.pumpAndSettle();

      expect(
        find.text(kComposerHintHero),
        findsOneWidget,
        reason: 'DSH 在这一屏用 placeholder.hero（locales.ts:23），不是普通那句',
      );
      expect(find.text(kComposerHintDefault), findsNothing);
    });

    testWidgets('记账事件（投影成不可见的 OtherItem）不挡住 hero —— 真机形状', (tester) async {
      // 2026-10-17 真机验收抓到的：连上后占位文案是 hero 那句，对话区却一片空白。
      // 根因是电脑侧每个会话的头几条都是记账事件，投影成只计数、不渲染的
      // OtherItem，于是 `items.isEmpty` 恒为假、hero 分支永不进入。
      // **这个用例必须推真形状**：空 store 的旧用例对此一无所知。
      final client = _HeroClient(
        sessions: [blankRow('blank-1')],
        presets: presetReply(),
        replay: const [
          SessionEvent(
            itemId: 'session:1',
            type: 'session',
            seq: 1,
            time: 1,
            data: {},
          ),
          SessionEvent(
            itemId: 'permission/preset:2',
            type: 'permission/preset',
            seq: 2,
            time: 2,
            data: {},
          ),
          SessionEvent(
            itemId: 'sandbox/mode:3',
            type: 'sandbox/mode',
            seq: 3,
            time: 3,
            data: {},
          ),
          SessionEvent(
            itemId: 'approval/policy:4',
            type: 'approval/policy',
            seq: 4,
            time: 4,
            data: {},
          ),
        ],
      );
      final app = AppModel(client: client);
      unawaited(app.start());
      client.emit(ConnectionState.serving);
      addTearDown(app.dispose);
      await tester.pumpWidget(host(app));
      await tester.pumpAndSettle();

      expect(
        find.byType(ConversationHero),
        findsOneWidget,
        reason: '记账事件在条目表里但一条都画不出来，blank 会话仍该是 hero',
      );
      expect(find.text(kComposerHintHero), findsOneWidget);
    });

    testWidgets('blank 会话里出现可见条目（刚发出的消息）：渲染消息流，不进 hero', (tester) async {
      // 与上一条互补：判据是"没有**可见**内容"，不是"blank"。
      // 用户消息已回来、轮次还没起（电脑侧 blank 尚未翻面）时，
      // 那一行必须看得见 —— 被 hero 盖住等于"消息发出去了却看不到"。
      final client = _HeroClient(
        sessions: [blankRow('blank-1')],
        presets: presetReply(),
        replay: const [
          SessionEvent(
            itemId: 'session:1',
            type: 'session',
            seq: 1,
            time: 1,
            data: {},
          ),
          SessionEvent(
            itemId: 'm:msg-1',
            type: 'user/message',
            seq: 2,
            time: 2,
            // 真形状：载荷就是消息本体 `{id, content:[…]}`，正文在 text 块里。
            data: {
              'id': 'msg-1',
              'role': 'user',
              'content': [
                {'type': 'text', 'text': '在吗'},
              ],
            },
          ),
        ],
      );
      final app = AppModel(client: client);
      unawaited(app.start());
      client.emit(ConnectionState.serving);
      addTearDown(app.dispose);
      await tester.pumpWidget(host(app));
      await tester.pumpAndSettle();

      expect(find.byType(ConversationHero), findsNothing);
      expect(find.text('在吗'), findsOneWidget);
    });

    testWidgets('非 blank 会话：不显示 hero，也不换占位文案', (tester) async {
      final client = _HeroClient(
        sessions: [
          {'sid': 'ran-1', 'blank': false, 'itemCount': 2, 'updatedAt': 9},
        ],
        presets: presetReply(),
      );
      final app = AppModel(client: client);
      unawaited(app.start());
      client.emit(ConnectionState.serving);
      addTearDown(app.dispose);
      await tester.pumpWidget(host(app));
      await tester.pumpAndSettle();
      await app.openSession('ran-1');
      await tester.pumpAndSettle();

      expect(find.byType(ConversationHero), findsNothing);
      expect(find.text(kComposerHintDefault), findsOneWidget);
    });

    testWidgets('连不上时：hero 让位给"已断开"（两枚 chip 点了都要建会话）', (tester) async {
      final (client, app) = connected(presets: presetReply());
      addTearDown(app.dispose);
      await tester.pumpWidget(host(app));
      await tester.pumpAndSettle();
      // 连上之后又断了：blank 还在模型里，但 hero 不该继续摆着。
      client.emit(ConnectionState.closed);
      await tester.pumpAndSettle();

      expect(find.byType(ConversationHero), findsNothing);
      expect(find.text('已断开'), findsOneWidget);
    });

    testWidgets('拿不到预设目录：模式 chip 是占位态，不编一个默认名', (tester) async {
      final (_, app) = connected(presets: {'available': false});
      addTearDown(app.dispose);
      await tester.pumpWidget(host(app));
      await tester.pumpAndSettle();

      expect(find.byType(ConversationHero), findsOneWidget);
      expect(find.text('标准模式'), findsNothing, reason: '拿不到目录时不能显示手抄的内置名');
      // 工作区也没有清单：chip 退回 cwd（这里没有 cwd）→ 占位那句。
      expect(find.text('选择工作区'), findsWidgets);
    });

    testWidgets('清单到了但没有归属：工作区 chip 是占位，不拿已删目录名顶上', (tester) async {
      final (_, app) = connected(
        sessions: [blankRow('blank-1', cwd: r'D:\old\deleted-workspace')],
        workspaces: workspaceReply(),
        presets: presetReply(),
      );
      addTearDown(app.dispose);
      await tester.pumpWidget(host(app));
      await tester.pumpAndSettle();

      expect(find.text('deleted-workspace'), findsNothing);
      expect(find.text('选择工作区'), findsWidgets);
    });
  });

  group('两枚 chip 的写路径', () {
    testWidgets('选模式 → session.create 带 agentPreset（不碰 agentPresets.select）', (
      tester,
    ) async {
      final (client, app) = connected(
        workspaces: workspaceReply(owningWorkspace: 'w1'),
        presets: presetReply(),
        projections: {'agentPreset': 'standard'},
      );
      addTearDown(app.dispose);
      await tester.pumpWidget(host(app));
      await tester.pumpAndSettle();

      await tester.tap(find.text('标准模式'));
      await tester.pumpAndSettle();
      // sheet 里选「创造模式」。
      await tester.tap(find.text('创造模式'));
      await tester.pumpAndSettle();

      // **两枚 chip 的写路径都带 workspaceId**（2026-10-22）：不带它建的会话
      // 不进任何工作区的账本（`session-controller/src/commands.ts:116-148`），
      // 于是它在抽屉里永远落在「未分组」。解析链见
      // `AppModel.defaultNewSessionWorkspaceId`（当前会话的工作区优先）。
      expect(client.paramsOf['session.create'], {
        'workspaceId': 'w1',
        'agentPreset': 'cordis',
      });
      expect(
        client.calls,
        isNot(contains('agentPresets.select')),
        reason: '写路径只走 session.create({agentPreset})，方法面只 +1（读）',
      );
    });

    testWidgets('选工作区 → session.create 带 workspaceId', (tester) async {
      final (client, app) = connected(
        workspaces: workspaceReply(owningWorkspace: 'w1'),
        presets: presetReply(),
      );
      addTearDown(app.dispose);
      await tester.pumpWidget(host(app));
      await tester.pumpAndSettle();

      await tester.tap(find.text('dsh-mobile'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('deepseek-harness'));
      await tester.pumpAndSettle();

      expect(client.paramsOf['session.create'], {'workspaceId': 'w2'});
    });

    testWidgets('选中当前那一项：什么都不建（点一下不该多出一个 blank 会话）', (tester) async {
      final (client, app) = connected(
        workspaces: workspaceReply(owningWorkspace: 'w1'),
        presets: presetReply(),
        projections: {'agentPreset': 'standard'},
      );
      addTearDown(app.dispose);
      await tester.pumpWidget(host(app));
      await tester.pumpAndSettle();

      await tester.tap(find.text('标准模式'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('标准模式').last);
      await tester.pumpAndSettle();

      expect(client.calls, isNot(contains('session.create')));
    });

    testWidgets('拿不到工作区清单：点 chip 如实说，不摆空选择器', (tester) async {
      final (_, app) = connected(presets: presetReply());
      addTearDown(app.dispose);
      await tester.pumpWidget(host(app));
      await tester.pumpAndSettle();

      await tester.tap(find.text('选择工作区'));
      await tester.pumpAndSettle();

      expect(find.textContaining('workspace.list'), findsOneWidget);
    });
  });

  group('窄屏不溢出', () {
    /// 长名字的窄屏：两枚 chip 都得能被压缩（chip 的尾巴是 chevron，
    /// 它一旦被顶出去，用户就看不出这个 chip 能点开）。
    testWidgets('360px + 超长工作区名 + 超长预设名：不溢出，chevron 还在', (tester) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final (_, app) = connected(
        workspaces: {
          'workspaces': [
            {
              'workspaceId': 'w1',
              'title': '一个非常非常长的工作区名字用来把这一行挤爆掉看看会怎么样',
              'path': r'D:\very\long\path',
              'sessionIds': ['blank-1'],
            },
          ],
          'archivedSessionIds': <String>[],
          'pinnedSessionIds': <String>[],
        },
        presets: {
          'available': true,
          'roster': {
            'presets': [
              {
                'id': 'super-long',
                'isDefault': true,
                'name': '一个同样非常非常长的用户自建预设名字',
              },
            ],
          },
        },
      );
      addTearDown(app.dispose);
      await tester.pumpWidget(host(app));
      await tester.pumpAndSettle();

      // `RenderFlex overflowed` 会以异常形式冒出来 —— 不接住就等于测试通过。
      expect(tester.takeException(), isNull, reason: '窄屏 + 长名字不该让 Row 溢出');
      expect(find.byType(ConversationHero), findsOneWidget);
      // 两枚 chevron 都还在：chip 的尾巴就是"这个能点开"，被顶出去等于这个控件不可发现。
      // **必须限定在 hero 里数** —— 输入栏的模型 chip 也用 `chevronDown`，
      // 全页数会得到 3 而看起来像"多了一个"（第一版就是这么写的）。
      // 也**不用 `find.byIcon(Icons.…)`** —— 那种断言在没图标时照样通过。
      final chevrons = tester
          .widgetList<DshIcon>(
            find.descendant(
              of: find.byType(ConversationHero),
              matching: find.byType(DshIcon),
            ),
          )
          .where((icon) => icon.name == 'chevronDown')
          .length;
      expect(chevrons, 2, reason: '两枚 chip 的 chevron 都得在（长名字该省略，不该挤走它）');
      expect(
        tester.getRect(find.byType(ConversationHero)).width <= 360,
        isTrue,
        reason:
            'hero 不该超出屏宽（实测 ${tester.getRect(find.byType(ConversationHero)).width}）',
      );
    });
  });
}
