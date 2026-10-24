/// 用量独立页的回归（总量 + 按项目 + 按会话）。
///
/// ## 这一组守什么
///
/// 2026-10-19 用户原话：「用量你最好也是做成一个页面的，你看 D:\sudy\github\rikkahub
/// 你这样信息量不多，单页面的话信息量可以做很多，总量，单个项目使用量是吧」。
/// 所以从"设置页里的一组"搬成独立页（`ui/usage_page.dart`），明细的断言
/// 也从 `settings_page_test.dart` 搬到这里。
///
/// ## 数据契约
///
/// 电脑侧答 `{sessions, grandTotalTokens, byProject:[{path,tokens,sessions}],
/// bySession:[{sid,title,cwd,tokens}]}`（契约 §5.7 的 `usage.summary`）。
/// **DSH 没有跨会话汇总接口**，聚合在连接器做（见 `model/usage_summary.dart`
/// 的文件头）。
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/usage_summary.dart';
import 'package:dsh_mobile/ui/usage_page.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

import 'fake_sync_client.dart';

/// 一份**带项目分组**的汇总（两个项目、三个会话）。
///
/// 注意 `byProject` 两档都 > 0 —— 电脑侧会过滤掉全零的档
/// （契约 §5.7 的聚合规则②），fixture 照真实形状来。
const _summary = UsageSummary(
  sessions: 3,
  grandTotalTokens: 298000000,
  byProject: [
    UsageProject(
      path: 'D:\\sudy\\myproject\\dsh-mobile',
      tokens: 249000000,
      sessions: 2,
    ),
    UsageProject(path: '', tokens: 49000000, sessions: 1),
  ],
  bySession: [
    UsageEntry(
      sid: 'sid-1',
      title: '插件UI与交互体验优化',
      tokens: 200000000,
      cwd: 'D:\\sudy\\myproject\\dsh-mobile',
    ),
    UsageEntry(
      sid: 'sid-2',
      title: '',
      tokens: 49000000,
      cwd: 'D:\\sudy\\myproject\\dsh-mobile',
    ),
    UsageEntry(sid: 'sid-3', title: '另一个项目', tokens: 49000000, cwd: ''),
  ],
);

void main() {
  testWidgets('总量 + 按项目 + 按会话，一页三级', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: UsagePage(summary: _summary)),
    );
    await tester.pumpAndSettle();

    // ① 总量卡（同一个格式化函数 ⇒ `298M`）。
    expect(find.text('这台电脑一共'), findsOneWidget);
    expect(find.text('298M'), findsOneWidget);
    expect(find.text('来自 3 个会话（子智能体不计入）'), findsOneWidget);

    // ② 项目名取**路径末段**（`D:\sudy\myproject\dsh-mobile` → `dsh-mobile`）。
    expect(find.text('dsh-mobile'), findsOneWidget);
    // 没有 `cwd` 的那个项目档显示成「未关联项目」。
    expect(find.text(UsageProject.kUnlinkedProjectLabel), findsOneWidget);

    // ③ 会话行：标题空串按 DSH 的链退到「未命名」。
    expect(find.text('插件UI与交互体验优化'), findsOneWidget);
    expect(find.text('未命名'), findsOneWidget);
    // 挂在「未关联项目」下的那个会话。
    expect(find.text('另一个项目'), findsOneWidget);

    // 老连接器（没有 `totals` / `byDay`）：两块都**不出现** ——
    // 不摆四个 0、也不画一张空热力图（对照组，证明上面那条不是恒真）。
    expect(find.text('输入（未命中缓存）'), findsNothing);
    expect(find.text('最近 52 周'), findsNothing);
  });

  testWidgets('项目头可折叠：点一下收起，再点展开（默认展开）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: UsagePage(summary: _summary)),
    );
    await tester.pumpAndSettle();

    // 默认展开：会话行在。
    expect(find.text('插件UI与交互体验优化'), findsOneWidget);

    await tester.tap(find.text('dsh-mobile'));
    await tester.pumpAndSettle();
    expect(find.text('插件UI与交互体验优化'), findsNothing, reason: '收起只藏身子');

    await tester.tap(find.text('dsh-mobile'));
    await tester.pumpAndSettle();
    expect(find.text('插件UI与交互体验优化'), findsOneWidget);
  });

  testWidgets('四个分项 + 热力图：有数据才出现；轮次是轮次，不是 token', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: UsagePage(
          summary: UsageSummary(
            sessions: 2,
            grandTotalTokens: 1234,
            bySession: [],
            totals: UsageTotals(
              uncachedInputTokens: 1000,
              outputTokens: 200,
              cacheReadTokens: 30,
              cacheWriteTokens: 4,
            ),
            byDay: [
              UsageDay(date: '2026-10-01', turns: 2, tokens: 1200),
              UsageDay(date: '2026-10-02', turns: 3, tokens: 8400),
              UsageDay(date: '2026-10-03', turns: 1, tokens: 300),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('输入（未命中缓存）'), findsOneWidget);
    expect(find.text('输出'), findsOneWidget);
    expect(find.text('缓存读 / 写'), findsOneWidget);
    // 轮次 = `byDay` 之和（2+3+1）。
    expect(find.text('轮次'), findsOneWidget);
    expect(find.text('6'), findsOneWidget);
    expect(find.text('最近 52 周'), findsOneWidget);
    // 还没点格子：那行是操作提示（不是空着，也不是假装有数据）。
    expect(find.text('点一格看当天'), findsOneWidget);
    // 图例两侧的刻度词。
    expect(find.text('少'), findsOneWidget);
    expect(find.text('多'), findsOneWidget);
  });

  testWidgets('热力图在 390dp 手机上不溢出（宽度由横向滚动承担）', (tester) async {
    // 这一条防的是"在自己机器上好好的、到窄屏就黄条"：
    // 网格本身约 673dp 装不进 390dp，所以必须靠横向滚动 —— 溢出在测试里是异常。
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final today = DateTime.now();
    final key =
        '${today.year}-${today.month.toString().padLeft(2, '0')}-'
        '${today.day.toString().padLeft(2, '0')}';
    await tester.pumpWidget(
      MaterialApp(
        home: UsagePage(
          summary: UsageSummary(
            sessions: 1,
            grandTotalTokens: 5000,
            bySession: const [],
            totals: const UsageTotals(
              uncachedInputTokens: 4000,
              outputTokens: 900,
              cacheReadTokens: 80,
              cacheWriteTokens: 20,
            ),
            byDay: [UsageDay(date: key, turns: 2, tokens: 5000)],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // 格子确实铺出来了（不是"没溢出因为没渲染"）。
    expect(find.byKey(Key('heat-$key')), findsOneWidget);
  });

  testWidgets('热力图：点一格能读出那天（日期 · 轮次 · token）', (tester) async {
    // 用"今天"造数据：格子是按日历铺的，历史日期也要落在网格里。
    final today = DateTime.now();
    String keyOf(int daysAgo) {
      final date = DateTime(
        today.year,
        today.month,
        today.day,
      ).subtract(Duration(days: daysAgo));
      return '${date.year}-${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}';
    }

    final threeDaysAgo = keyOf(3);
    await tester.pumpWidget(
      MaterialApp(
        home: UsagePage(
          summary: UsageSummary(
            sessions: 1,
            grandTotalTokens: 9999,
            bySession: const [],
            byDay: [UsageDay(date: threeDaysAgo, turns: 4, tokens: 15000)],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(Key('heat-$threeDaysAgo')));
    await tester.pumpAndSettle();

    // 读出行由**生产数据**算出来：4 轮、15000 tok（`formatTokenCount` 格式化）。
    final readout = find.textContaining('4 轮');
    expect(readout, findsOneWidget);
    final text = tester.widget<Text>(readout).data!;
    expect(text, contains('15K tok'), reason: '读数走同一个格式化函数');
  });

  test('fromWire：totals 与 byDay 原样解析；缺席就 null / 空表', () {
    final both = UsageSummary.fromWire({
      'sessions': 1,
      'grandTotalTokens': 100,
      'totals': {
        'uncachedInputTokens': 60,
        'outputTokens': 30,
        'cacheReadTokens': 8,
        'cacheWriteTokens': 2,
      },
      'byDay': [
        {'date': '2026-10-01', 'turns': 2, 'tokens': 900},
        {'date': '2026-10-02', 'turns': 0},
      ],
    });
    expect(both, isNotNull);
    expect(both!.totals!.uncachedInputTokens, 60);
    expect(both.totals!.cacheTokens, 10);
    expect(both.byDay.length, 2);
    expect(both.totalTurns, 2);
    expect(both.byDay.first.tokens, 900);
    // 某一天没有 `tokens` 键 ⇒ 0（那一天没计量），整天不丢。
    expect(both.byDay.last.tokens, 0);

    // 老连接器：两个键都不在 ⇒ 界面整块不出现（不是四个 0、也不是 0 轮）。
    final old = UsageSummary.fromWire({'sessions': 1, 'grandTotalTokens': 100});
    expect(old, isNotNull);
    expect(old!.totals, isNull, reason: '不摆四个 0');
    expect(old.byDay, isEmpty);
    expect(old.totalTurns, isNull);
  });

  test('heatAlphaAt：0 是底色；色阶按**这一年自己的分位**，且严格单调', () {
    // 空样本（这一年没有任何计量）也要给一个能看的档，而不是全白。
    expect(heatAlphaAt(0, const []), 0.0, reason: '那一天存在，只是没干活');
    expect(heatAlphaAt(100, const []), 0.30);

    final scale = heatScaleOf([0, 100, 200, 300, 400, 500, 0]);
    expect(scale, [100, 200, 300, 400, 500], reason: '0 不进样本（那是"没干活"）');

    // 单调：拿真实样本逐个走一遍，防止将来改分位时出现"更忙更浅"。
    var previous = -1.0;
    for (final tokens in [0, 100, 200, 300, 400, 500]) {
      final alpha = heatAlphaAt(tokens, scale);
      expect(alpha, greaterThanOrEqualTo(previous));
      previous = alpha;
    }
    // 样本里最大的一天一定是深色档（"相对你这台机器算多"由数据回答）。
    expect(heatAlphaAt(500, scale), 1.0);
    expect(heatAlphaAt(100, scale), 0.30);
  });

  testWidgets('点会话行：回调带上 sid', (tester) async {
    String? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: UsagePage(
          summary: _summary,
          onOpenSession: (sid) => opened = sid,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('插件UI与交互体验优化'));
    await tester.pumpAndSettle();
    expect(opened, 'sid-1');
  });

  testWidgets('拉不到：空态说原因，不摆 0 tok', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: UsagePage(failure: '电脑侧炸了')),
    );
    await tester.pumpAndSettle();

    expect(find.text('拉不到用量'), findsOneWidget);
    expect(find.text('电脑侧炸了'), findsOneWidget);
    // 不摆一个看起来在统计的 0。
    expect(find.text('这台电脑一共'), findsNothing);
  });

  group('UsageSummary.fromWire', () {
    test('认不出就回 null', () {
      expect(UsageSummary.fromWire(null), isNull);
      expect(UsageSummary.fromWire('nope'), isNull);
      expect(
        UsageSummary.fromWire(<String, Object?>{'sessions': 1}),
        isNull,
        reason: '缺 grandTotalTokens',
      );
    });

    test('按项目分组：空目录单独一档', () {
      final summary = UsageSummary.fromWire(<String, Object?>{
        'sessions': 3,
        'grandTotalTokens': 300,
        'byProject': <Object?>[
          <String, Object?>{'path': 'D:\\a', 'tokens': 200, 'sessions': 2},
          <String, Object?>{'path': '', 'tokens': 100, 'sessions': 1},
        ],
        'bySession': <Object?>[
          <String, Object?>{
            'sid': 's1',
            'title': 'x',
            'cwd': 'D:\\a',
            'tokens': 200,
          },
          <String, Object?>{'sid': 's2', 'title': '', 'cwd': '', 'tokens': 100},
        ],
      })!;
      expect(summary.byProject.length, 2);
      expect(summary.byProject.first.label, 'a');
      expect(summary.byProject.last.label, UsageProject.kUnlinkedProjectLabel);
      // `grouped` 把会话挂到项目下（顺序仍按用量降序）。
      final groups = summary.grouped;
      expect(groups.length, 2);
      expect(groups.first.entries.length, 1);
      expect(groups.first.entries.single.sid, 's1');
      expect(groups.last.entries.single.sid, 's2');
    });

    test('老连接器没有 byProject：grouped 空，界面退回扁平榜', () {
      final summary = UsageSummary.fromWire(<String, Object?>{
        'sessions': 1,
        'grandTotalTokens': 10,
        'bySession': <Object?>[
          <String, Object?>{'sid': 's1', 'title': 'x', 'tokens': 10},
        ],
      })!;
      expect(summary.byProject, isEmpty);
      expect(summary.grouped, isEmpty);
      // 会话行仍解析得出来（`cwd` 缺省为空串）。
      expect(summary.bySession.single.cwd, '');
    });
  });

  // 2026-10-21 真机：用量页永远是「还没有用量数据」，而电脑侧有几十万 token。
  // 根因是接线 —— `main.dart` 先 `unawaited(refreshUsageSummary())` 再立刻
  // `push(UsagePage(summary: app.usageSummary))`，而那一份是**拉之前**的 null；
  // `UsagePage` 又是无状态的、不监听 `AppModel`，于是拉到也没人重画。
  // 这一条钉的是 `UsagePageHost`：它自己拉，并且**听 AppModel**。
  testWidgets('UsagePageHost：拉到的数据会自己画出来（不是永远空态）', (tester) async {
    final client = _UsageClient();
    final app = AppModel(client: client);
    await app.start();

    await tester.pumpWidget(MaterialApp(home: UsagePageHost(app: app)));
    // 第一帧还是空态（拉取是异步的）。
    expect(find.text('还没有用量数据'), findsOneWidget);

    // 拉到之后必须**自己重画**（少了 `ListenableBuilder` 就永远停在这里）。
    await tester.pump();
    await tester.pump();

    expect(find.text('还没有用量数据'), findsNothing);
    expect(find.text('这台电脑一共'), findsOneWidget);
    // 10240 → `10.2K`（`formatTokenCount` 的 `_scaled`：< 100 保留一位小数）。
    // 总量 / 项目行 / 会话行各一处，所以是 `findsWidgets`。
    expect(find.text('10.2K'), findsWidgets, reason: '总量来自电脑侧的聚合结果');
    expect(client.calls, 1, reason: '进页面只拉一次');
    app.dispose();
  });
}

/// 只答 `usage.summary` 的替身（其余方法回 null）。
class _UsageClient extends FakeSyncClient {
  int calls = 0;

  @override
  ConnectionState get state => ConnectionState.serving;
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
    if (method == 'usage.summary') {
      calls += 1;
      return {
            'sessions': 1,
            'grandTotalTokens': 10240,
            'byProject': [
              {
                'path': 'D:\\sudy\\myproject\\dsh-mobile',
                'tokens': 10240,
                'sessions': 1,
              },
            ],
            'bySession': [
              {
                'sid': 'sid-1',
                'title': '父会话',
                'cwd': 'D:\\sudy\\myproject\\dsh-mobile',
                'tokens': 10240,
              },
            ],
          }
          as T;
    }
    return null as T;
  }
}
