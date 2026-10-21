/// 计数 chip 在**顶栏那一行**里的接线回归（原 `live_chips_row_test.dart` 的接替者）。
///
/// ## 为什么换了一份
///
/// 原来这份测的是"顶栏下方那一行 chip 的排版"（换不换行、占几行）。2026-10-17
/// 用户定案把子智能体 / 后台任务**放回顶栏**（DSH 本来就是这么放的），那一行撤销 ——
/// 被测对象不存在了，所以整份换成测**新的那个面**：chip 真的挂在顶栏里、
/// 与标题同一行、且标题与分段控件之间**不再夹着一行**。
///
/// 这比只测 `ChatAppBar` 更硬：它走真实 `ChatPage`，于是"计数有没有从
/// `AppModel` 接到顶栏"也在判据里（第一版就是漏了传，截图里那一行空着）。
///
/// ## 为什么 chip 是"图标 + 计数"而不是 DSH 的全文本
///
/// 411.4dp 的真机上顶栏留给「标题 + chip」的只有 **285.4dp**，而实测全文本
/// chip 单枚就要 **137.8dp**（`3 个子智能体`）/ **174.5dp**（`2 个后台任务运行中`）——
/// 两枚 320dp，标题将被压到没位置。所以留形态、把全文本退进 aria/tooltip。
library;

import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/job.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_page.dart';
import 'package:dsh_mobile/ui/dsh_app_bar.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'fake_sync_client.dart';

/// 只回界面需要的形状：会话行、子智能体投影、任务清单。
class _ChipsClient extends FakeSyncClient {
  _ChipsClient({
    required this.subagents,
    required this.liveJobs,
    this.finishedJobs = 4,
  });

  final int subagents;
  final int liveJobs;

  /// 已结束的任务条数（用来验证"报的是在跑数，不是总数"）。
  final int finishedJobs;

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
  Future<void> unsubscribe(String sid) async {}

  @override
  Stream<SessionDelta> sessionUpdates(String sid) => const Stream.empty();

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    switch (method) {
      case 'session.list':
        return {
              'sessions': [
                {'sid': 's1', 'itemCount': 3, 'updatedAt': 1},
                // 子智能体"正在跑"来自**子会话自己**的 `running`
                // （`SubagentHeaderLineage.tsx:471-475`），不是 catalog 的 `mode`。
                for (var i = 0; i < subagents; i += 1)
                  {
                    'sid': 'sub-$i',
                    'updatedAt': 2,
                    'subagent': true,
                    'running': true,
                  },
              ],
            }
            as T;
      case 'session.projections':
        return {
              'subagentCatalog': [
                for (var i = 0; i < subagents; i += 1)
                  {'id': 'sub-$i', 'createdAt': 1, 'mode': 'continuable'},
              ],
            }
            as T;
      case 'job.list':
        return {
              'jobs': [
                for (var i = 0; i < totalJobs; i += 1)
                  {
                    'id': 'j$i',
                    'kind': 'bash',
                    'label': 'flutter build apk --release $i',
                    'status': i < liveJobs ? 'running' : 'completed',
                    'startedAt': 1,
                  },
              ],
            }
            as T;
      default:
        return null as T;
    }
  }

  /// 任务总量：在跑的 + 已结束的。
  int get totalJobs => liveJobs + finishedJobs;
}

/// 起真实的 `ChatPage`，返回顶栏里两枚 chip 的矩形与标题的纵向中心。
Future<
  ({
    Rect? sub,
    Rect? job,
    String? subLabel,
    String? jobLabel,
    int? subCount,
    int? jobCount,
    double titleMid,
    double segmentedTop,
    double topBarBottom,
  })
>
_measure(
  WidgetTester tester, {
  required double width,
  required int subagents,
  required int liveJobs,
  int finishedJobs = 4,
}) async {
  final view = tester.view;
  view.physicalSize = Size(width, 844);
  view.devicePixelRatio = 1;
  addTearDown(() {
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  final client = _ChipsClient(
    subagents: subagents,
    liveJobs: liveJobs,
    finishedJobs: finishedJobs,
  );
  final app = AppModel(client: client);
  await app.refreshSessions();
  await app.openSession('s1');
  await app.refreshJobs('s1');

  await tester.pumpWidget(
    MaterialApp(
      theme: DshTheme.dark(),
      home: ChatPage(
        app: app,
        onOpenDrawer: () {},
        onNewSession: () {},
        onOpenSession: (_) {},
        drawer: const Drawer(child: SizedBox()),
      ),
    ),
  );
  // **不能用 `pumpAndSettle`**：在跑的任务/chip 会画一枚永不结束的转圈点，
  // settle 会一直等下去（是超时，不是断言失败）。推进两帧就够量布局了。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));

  // **按图标取 chip，不按 tooltip 文案取**：子智能体那枚的 aria 在"有在跑的"时
  // 会变成 `N 个子智能体，正在运行`，按文案找会随数据漂。
  DshCountChip? chipOf(String icon) {
    for (final chip in tester.widgetList<DshCountChip>(
      find.byType(DshCountChip),
    )) {
      if (chip.icon == icon) return chip;
    }
    return null;
  }

  Rect? rectOf(String icon) {
    final chip = chipOf(icon);
    return chip == null ? null : tester.getRect(find.byWidget(chip));
  }

  // 标题是顶栏里**唯一**那个 13px / `maxLines: 1` 的 `Text`（chip 的计数是 12px、
  // 不设 maxLines），所以按样式找它比按名字找稳 —— 会话名由 `AppModel` 决定。
  final title = find.byWidgetPredicate(
    (w) => w is Text && w.style?.fontSize == 13 && w.maxLines == 1,
  );
  final sub = chipOf('users');
  final job = chipOf('checklist');

  return (
    sub: rectOf('users'),
    job: rectOf('checklist'),
    subLabel: sub?.label,
    jobLabel: job?.label,
    subCount: sub?.count,
    jobCount: job?.count,
    titleMid: tester.getRect(title).center.dy,
    segmentedTop: tester.getRect(find.byType(DshSegmented)).top,
    topBarBottom: tester.getRect(find.byType(ChatAppBar)).bottom,
  );
}

void main() {
  testWidgets('411dp（真机宽度）：两枚 chip 在顶栏里，与标题同行', (tester) async {
    final m = await _measure(
      tester,
      width: 1080 / (420 / 160),
      subagents: 3,
      liveJobs: 2,
    );
    expect(m.sub, isNotNull, reason: '子智能体 chip 必须在顶栏里');
    expect(m.job, isNotNull, reason: '后台任务 chip 必须在顶栏里');
    expect(
      m.sub!.center.dy,
      m.titleMid,
      reason: '与标题**同一行**（DSH 的 header actions band 就是这个形态）',
    );
    expect(m.job!.center.dy, m.titleMid);
    expect(tester.takeException(), isNull, reason: '411dp 下不许溢出');
  });

  testWidgets('计数口径照 DSH：子智能体报总数，后台任务报在跑数', (tester) async {
    final m = await _measure(tester, width: 411.43, subagents: 3, liveJobs: 2);
    expect(m.subCount, 3, reason: '子智能体那枚显示的是**总数**');
    expect(m.jobCount, 2, reason: '后台任务那枚显示的是**在跑数**（总共有 6 条）');
    // 全文本那句（DSH 的原文）在 aria/tooltip 里，不占顶栏宽度。
    // 子智能体的 aria 在**有在跑的**时报在跑数（替身给的目录行没有 `finishedAt`，
    // 按"还没结束"算 —— 与 DSH 的 `SubagentHeaderLineage.tsx:679-680` 同一条规则）；
    // 后台任务那边报的本来就是在跑数。
    expect(m.subLabel, '3 个子智能体，正在运行');
    expect(m.jobLabel, '2 个后台任务运行中');
  });

  testWidgets('标题与分段控件之间不再夹着一行 chip', (tester) async {
    final m = await _measure(tester, width: 360, subagents: 3, liveJobs: 2);
    // 顶栏 56 高 + 分段控件自己的 6px 上边距 —— 中间没有第二行的位置。
    expect(
      m.segmentedTop - m.topBarBottom,
      lessThanOrEqualTo(8),
      reason: '分段控件紧贴顶栏；夹着一行 chip 时这个间距会是 34dp 级',
    );
    expect(tester.takeException(), isNull, reason: '360px 下不许溢出');
  });

  testWidgets('两位数计数 + 长会话名：chip 不溢出、不换行', (tester) async {
    final m = await _measure(tester, width: 360, subagents: 12, liveJobs: 12);
    expect(m.sub, isNotNull);
    expect(m.job, isNotNull);
    expect(m.sub!.center.dy, m.titleMid, reason: '两位数也不许掉到第二行');
    expect(tester.takeException(), isNull);
  });

  testWidgets('真机宽度 + 两位数计数：不溢出', (tester) async {
    final m = await _measure(
      tester,
      width: 1080 / (420 / 160),
      subagents: 12,
      liveJobs: 12,
    );
    expect(m.sub?.center.dy, m.titleMid);
    expect(tester.takeException(), isNull);
  });

  testWidgets('两类计数都为 0：整枚不占位，且顶栏仍是原来那三个控件', (tester) async {
    final m = await _measure(
      tester,
      width: 360,
      subagents: 0,
      liveJobs: 0,
      finishedJobs: 0,
    );
    expect(m.sub, isNull, reason: '0 个时不显示，而不是显示"0 个子智能体"');
    expect(m.job, isNull);
    expect(find.byType(DshCountChip), findsNothing);
    expect(find.byTooltip('打开会话抽屉'), findsOneWidget);
    expect(find.byTooltip('新建会话'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
