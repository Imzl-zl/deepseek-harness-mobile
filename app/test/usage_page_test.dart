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
import 'package:flutter/semantics.dart';
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

/// `today` 往前 [days] 天的 `YYYY-MM-DD`（格子按日历铺，历史日期也要落在网格里）。
String _dayAgo(DateTime today, int days) {
  final date = today.subtract(Duration(days: days));
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

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
    // 项目占比（249M / 298M ≈ 84%，49M / 298M ≈ 16%）—— 一眼看出花在哪。
    expect(find.text('84%'), findsOneWidget);
    expect(find.text('16%'), findsOneWidget);

    // ③ 会话行：标题空串按 DSH 的链退到「未命名」。
    expect(find.text('插件UI与交互体验优化'), findsOneWidget);
    expect(find.text('未命名'), findsOneWidget);
    // 挂在「未关联项目」下的那个会话。
    expect(find.text('另一个项目'), findsOneWidget);
    // 会话在所属项目里的占比（200M / 249M ≈ 80%，49M / 249M ≈ 20%）。
    expect(find.text('80%'), findsOneWidget);
    expect(find.text('20%'), findsOneWidget);

    // 老连接器（没有 `totals`）：四格分项**整块不出现** —— 不摆四个 0。
    // 没有按天活动时也不画热力图（对照组，证明上面那条不是恒真）。
    expect(find.text('输入（未命中缓存）'), findsNothing);
    expect(find.text('点一格看当天'), findsNothing);
    expect(find.text('这段时间电脑上没有记录到活动'), findsOneWidget);
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

  testWidgets('四个分项 + 近期活动：有数据才出现', (tester) async {
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    final todayKey = _dayAgo(todayDate, 0);
    final yesterdayKey = _dayAgo(todayDate, 1);
    await tester.pumpWidget(
      MaterialApp(
        home: UsagePage(
          summary: const UsageSummary(
            sessions: 2,
            grandTotalTokens: 1234,
            bySession: [],
            totals: UsageTotals(
              uncachedInputTokens: 1000,
              outputTokens: 200,
              cacheReadTokens: 30,
              cacheWriteTokens: 4,
            ),
          ),
          days: [
            UsageDay(date: yesterdayKey, turns: 2, tokens: 1200),
            UsageDay(date: todayKey, turns: 3, tokens: 8400),
          ],
          daysWindow: 30,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('输入（未命中缓存）'), findsOneWidget);
    expect(find.text('输出'), findsOneWidget);
    expect(find.text('缓存读'), findsOneWidget);
    expect(find.text('缓存写'), findsOneWidget);
    // 累计卡里的缓存命中率（同一个格式化函数：30 / (1000+30+4) ⇒ 3%）。
    expect(find.text('缓存命中 3%'), findsOneWidget);

    // 构成条**真的看得见**：8dp 高、有宽度（`ColoredBox` 在松高度约束下会取 0 高，
    // 2026-11-08 真机截图里那条是"有但看不见"）。
    final bar = find.byKey(const Key('usage-composition'));
    expect(bar, findsOneWidget);
    expect(tester.getSize(bar).height, 8);
    expect(tester.getSize(bar).width, greaterThan(100));

    // 近期活动：今天 / 近 30 天两行读数（数字来自 `days`）。
    expect(find.text('近期活动'), findsOneWidget);
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('近 30 天'), findsOneWidget);
    expect(find.text('8.4K tok'), findsOneWidget);
    expect(find.text('3 轮'), findsOneWidget);

    // 热力图（窗口 30 天 ⇒ 连续日历）。
    expect(find.text('最近 30 天'), findsOneWidget);
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
    final readout = find.byKey(const Key('usage-readout'));
    expect(readout, findsOneWidget);
    final text = tester.widget<Text>(readout).data!;
    expect(text, contains('4 轮'));
    expect(text, contains('15K tok'), reason: '读数走同一个格式化函数');
  });

  group('时间范围（纯前端切片，不改契约）', () {
    test('7 / 30 天只取窗口内的日期，且周数按**连续日历**算（不是只画 N 格）', () {
      // 固定"今天"= 2026-10-24（周六）。7 天窗口从 10-18（周日）起 ⇒
      // 首日那一周的周一是 10-12，今天所在的周一是 10-19 ⇒ **2 周**。
      final today = DateTime(2026, 10, 24);
      final days = [
        for (var back = 0; back <= 120; back += 10)
          UsageDay(
            date: _dayAgo(today, back),
            turns: 1,
            tokens: 100 * (back + 1),
          ),
      ];

      final week = usageWindowOf(days, UsageRange.d7, today);
      expect(week.weeks, 2, reason: '7 天窗口在周六看是 2 列 —— 连续日历，不是一根 7 格长条');
      expect(
        week.days.map((day) => day.date).toList(),
        ['2026-10-24'],
        reason: '只留 10-18 及以后的；10-14 在窗口外',
      );

      final month = usageWindowOf(days, UsageRange.d30, today);
      expect(month.weeks, 5, reason: '30 天 = 10-24 往前 29 天，首日周一到今天周一跨 5 周');
      expect(month.days.length, greaterThan(week.days.length));
      expect(
        month.days.every((day) => day.date.compareTo('2026-09-25') >= 0),
        isTrue,
        reason: '30 天窗口的起点是 9-25',
      );
    });

    test('窗口档位只有 7 / 30 / 90：越界的请求按最近那档显示', () {
      // 三档就是连接器的 `days` 窗口；页面不再有"全部"（一年窗口要把全部
      // 会话的日志读一遍，代价与收益不成比例）。
      expect(UsageRange.ofDays(7), UsageRange.d7);
      expect(UsageRange.ofDays(30), UsageRange.d30);
      expect(UsageRange.ofDays(90), UsageRange.d90);
      expect(UsageRange.ofDays(1), UsageRange.d7);
      expect(UsageRange.ofDays(365), UsageRange.d90);
    });

    testWidgets('切窗口是一次回调（数据要重新拉，不是本地切片）', (tester) async {
      int? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: UsagePage(
            summary: _summary,
            days: const [UsageDay(date: '2026-10-24', turns: 1, tokens: 10)],
            daysWindow: 30,
            onSelectWindow: (value) => picked = value,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey<String>('usage-range-d7')));
      await tester.pumpAndSettle();
      expect(picked, 7, reason: '窗口变了要重新问电脑侧要这段时间的活动');

      // 拿到新窗口之后（宿主传给页面的是 7）读数仍正确。
      await tester.pumpWidget(
        MaterialApp(
          home: UsagePage(
            summary: _summary,
            days: const [UsageDay(date: '2026-10-24', turns: 1, tokens: 10)],
            daysWindow: 7,
            onSelectWindow: (value) => picked = value,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('最近 7 天'), findsOneWidget);
    });
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

  group('近期活动的读数（纯函数）', () {
    final today = DateTime(2026, 11, 8);

    test('今日 / 本段 / 前段各算各的；更早的不计', () {
      // 窗口 30 天：本段 = 10-10..11-08，前段 = 09-10..10-09。
      final days = [
        const UsageDay(date: '2026-11-08', turns: 2, tokens: 100), // 今天
        const UsageDay(date: '2026-11-07', turns: 1, tokens: 50), // 本段
        const UsageDay(date: '2026-10-01', turns: 3, tokens: 400), // 前段
        const UsageDay(date: '2026-09-01', turns: 9, tokens: 900), // 更早
      ];
      final stats = activityStatsOf(days, 30, today);
      expect(stats.todayTokens, 100);
      expect(stats.todayTurns, 2);
      expect(stats.windowTokens, 150);
      expect(stats.windowTurns, 3);
      expect(stats.previousTokens, 400);
    });

    test('对比文案：前一段没有数据就说没有，不编 +100%', () {
      expect(deltaTextOf(150, 400, 30), '较前 30 天 -63%');
      expect(deltaTextOf(500, 400, 30), '较前 30 天 +25%');
      expect(deltaTextOf(100, 0, 30), '前一段没有数据');
      expect(deltaTextOf(0, 0, 30), isNull, reason: '两段都是 0 就没什么可说的');
    });

    test('缓存命中率走与统计条同一个格式化函数', () {
      const totals = UsageTotals(
        uncachedInputTokens: 1000,
        outputTokens: 200,
        cacheReadTokens: 30,
        cacheWriteTokens: 4,
      );
      expect(totals.billedInput, 1034);
      expect(totals.cacheHitText, '3');
      // 没有任何计费输入 ⇒ null（不画 NaN%）。
      expect(
        const UsageTotals(
          uncachedInputTokens: 0,
          outputTokens: 10,
          cacheReadTokens: 0,
          cacheWriteTokens: 0,
        ).cacheHitText,
        isNull,
      );
    });
  });

  test('percentTextOf：四舍五入，极小占比不显示成 0%，没有合计就不编', () {
    expect(percentTextOf(0.62), '62%');
    expect(percentTextOf(0.004), '<1%', reason: '差一点点也是花了，不写成 0%');
    expect(percentTextOf(0), '0%');
    expect(percentTextOf(null), isNull, reason: '合计为 0 时没有占比可算');
  });

  testWidgets('一条用量都没有：说人话，不摆一张 0 卡', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: UsagePage(
          summary: UsageSummary(
            sessions: 2,
            grandTotalTokens: 0,
            bySession: [],
            byProject: [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('还没有用量数据'), findsOneWidget);
    expect(find.text('这台电脑一共'), findsNothing, reason: '不摆 0 卡');
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
    // 第一帧还是"正在读取"（拉取是异步的）—— **不能说"还没有用量数据"**，
    // 那句话会被读成"电脑上真的没有"。
    expect(find.text('正在读取…'), findsOneWidget);

    // 拉到之后必须**自己重画**（少了 `ListenableBuilder` 就永远停在这里）。
    await tester.pump();
    await tester.pump();

    expect(find.text('正在读取…'), findsNothing);
    expect(find.text('这台电脑一共'), findsOneWidget);
    // 10240 → `10.2K`（`formatTokenCount` 的 `_scaled`：< 100 保留一位小数）。
    // 总量 / 项目行 / 会话行各一处，所以是 `findsWidgets`。
    expect(find.text('10.2K'), findsWidgets, reason: '总量来自电脑侧的聚合结果');
    expect(client.calls, 2, reason: '总量一次 + 按天活动一次（活动要带 days）');
    expect(client.lastDays, 60, reason: '活动窗口 30 天 × 2（本段 + 前段对比）');
    expect(find.text('近期活动'), findsOneWidget);
    app.dispose();
  });

  testWidgets('按天活动分批：没扫完就自己继续要，扫完就不再要', (tester) async {
    final client = _UsageClient(progressTotal: 3);
    final app = AppModel(client: client);
    await app.start();

    await tester.pumpWidget(MaterialApp(home: UsagePageHost(app: app)));
    await tester.pump();
    await tester.pump();
    expect(client.daysCalls, 1);
    expect(find.textContaining('正在统计活动：1/3'), findsOneWidget);

    // 补批定时器 350ms：到点要下一批，且**不闪**"正在读取活动…"。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(client.daysCalls, 2);
    expect(find.textContaining('正在统计活动：2/3'), findsOneWidget);
    expect(find.text('正在读取活动…'), findsNothing);

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(client.daysCalls, 3);
    expect(find.textContaining('正在统计活动'), findsNothing, reason: '扫完就别再报进度');
    app.dispose();
  });

  // ---------------------------------------------------------------------------
  // 语义角色（a11y）
  // ---------------------------------------------------------------------------

  testWidgets('热力图一格：有名字（哪天 · 几轮 · 多少 tok）+ 按钮 + 选中态', (tester) async {
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    final todayKey = _dayAgo(todayDate, 0);
    await tester.pumpWidget(
      MaterialApp(
        home: UsagePage(
          summary: const UsageSummary(
            sessions: 1,
            grandTotalTokens: 8400,
            bySession: [],
          ),
          days: [UsageDay(date: todayKey, turns: 3, tokens: 8400)],
          daysWindow: 30,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 这一格**没有文字**（信息全在颜色深浅里）：名字只能自己报。
    final before = tester.getSemantics(find.byKey(Key('heat-$todayKey')));
    expect(
      before,
      isSemantics(isButton: true, hasTapAction: true),
      reason: '点一格会选中当天并在上方给出读数 —— 有真实后果',
    );
    expect(
      before.getSemanticsData().label,
      allOf(contains('3 轮'), contains('8.4K tok')),
      reason: '无名按钮读不出"哪天、多少"',
    );

    await tester.tap(find.byKey(Key('heat-$todayKey')));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.byKey(Key('heat-$todayKey'))),
      isSemantics(isSelected: true),
      reason: '选中只画了一圈描边：读屏用户只能靠这个位知道选的是哪格',
    );
  });

  testWidgets('范围胶囊：按钮 + 选中态；没有切换窗口的去处时不报按钮', (tester) async {
    Future<void> pump({void Function(int days)? onSelectWindow}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: UsagePage(
            summary: const UsageSummary(
              sessions: 1,
              grandTotalTokens: 10,
              bySession: [],
            ),
            days: const [UsageDay(date: '2026-10-24', turns: 1, tokens: 10)],
            daysWindow: 30,
            onSelectWindow: onSelectWindow,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pump(onSelectWindow: (_) {});
    expect(
      find.semantics.byLabel('30 天').evaluate().single,
      isSemantics(isButton: true, isSelected: true, hasTapAction: true),
      reason: '当前档既是按钮也是选中项',
    );
    expect(
      find.semantics.byLabel('7 天').evaluate().single,
      isSemantics(isButton: true, hasTapAction: true),
    );

    // 页面没接这条回调：三枚胶囊就成了点不动的装饰，不该报按钮。
    await pump();
    expect(
      find.semantics.byLabel('7 天').evaluate().single,
      isNot(isSemantics(isButton: true)),
    );
  });

  testWidgets('项目头是按钮：语义动作真的收起了身子', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: UsagePage(summary: _summary)),
    );
    await tester.pumpAndSettle();

    final header = find.semantics.byLabel(RegExp('dsh-mobile'));
    expect(
      header.evaluate().single,
      isSemantics(isButton: true, hasTapAction: true),
      reason: '点整行 = 收起 / 展开这个项目的会话',
    );

    tester.semantics.performAction(header, SemanticsAction.tap);
    await tester.pumpAndSettle();
    expect(find.text('插件UI与交互体验优化'), findsNothing, reason: '语义动作要真的走到折叠');
  });
}

/// 只答 `usage.summary` 的替身（其余方法回 null）。
class _UsageClient extends FakeSyncClient {
  _UsageClient({this.progressTotal});

  /// 给了就按批返回进度（`daysCalls` 逐次 +1，直到等于它）。
  final int? progressTotal;

  int calls = 0;

  /// 带 `days` 的请求有几次（按天活动）。
  int daysCalls = 0;

  /// 最后一次请求带的 `days`（按天活动那次才有）。
  int? lastDays;

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
      final days = params['days'];
      if (days is int) {
        lastDays = days;
        daysCalls += 1;
      }
      final total = progressTotal;
      final scanned = total == null
          ? null
          : (daysCalls >= total ? total : daysCalls);
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
            // **老连接器也在总量里报 `byDay`**（那版没有 `days`）；
            // 新连接器只在带 `days` 的那次里给。
            if (days is int)
              'byDay': [
                {
                  'date':
                      '${DateTime.now().year}-'
                      '${DateTime.now().month.toString().padLeft(2, '0')}-'
                      '${DateTime.now().day.toString().padLeft(2, '0')}',
                  'turns': 2,
                  'tokens': 5000,
                },
              ],
            if (scanned != null)
              'daysProgress': {'scanned': scanned, 'total': total},
          }
          as T;
    }
    return null as T;
  }
}
