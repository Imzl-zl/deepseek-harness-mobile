/// 用量页（独立一页，不再是设置页里的一组）。
///
/// ## 为什么独立成页
///
/// 用户 2026-10-19 原话：「用量你最好也是做成一个页面的，你看 D:\sudy\github\rikkahub
/// 你这样信息量不多，单页面的话信息量可以做很多，总量，单个项目使用量是吧」。
///
/// DSH 没有跨会话汇总接口（`tokenUsage` 投影是单会话的，见
/// `model/usage_summary.dart` 的文件头），所以数据由**本插件的
/// `usage.summary`** 聚合（契约 §5.7）；这一页只负责把它显示得像一份账。
///
/// ## 一页放什么（按"从总到分"排）
///
/// 1. **总量**（最大的那个数字）+ 会话数 + "子智能体不计入"的说明；
/// 2. **按项目**（工作区目录）—— 每行：项目名 · 用量 · 几个会话，
///.expanded 时列出该项目下的会话（标题 + 用量）；
/// 3. **没有 `byProject` 时**（老连接器）退回扁平的会话榜。
///
/// ## 有意偏离 DSH
///
/// DSH Web 只有**统计条**（`ui-chat/src/client/chat/StatsPills.tsx`，单会话的
/// 轮次/步数/耗时），没有独立统计页。这一页是我们自己的形态，
/// 但**每个数字仍来自 DSH 的持久真值**（`tokenUsage` 投影经插件聚合），
/// 不是本地记账 —— 本地记账只覆盖插件在线期间，给出的数字像总量其实不是。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_model.dart';
import '../model/session_stats.dart' show formatTokenCount;
import '../model/usage_summary.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';

/// 用量页 + 它的数据缝：**进来先拉总量，再拉一段按天活动**。
///
/// ## 为什么是两次请求
///
/// 总量 / 分项 / 项目 / 会话榜都来自 `session.list` 行自带的 `tokenUsage` 投影提示
/// （一次往返）；按天活动要读每个会话的 `trajectory`（日志），**只能按窗口、
/// 按需读**（`connector/src/handlers.ts` 的 `usage.summary`）。
/// 先出总量、活动后补，页面不会为了热力图空转。
///
/// ## 为什么不把快照塞进来
///
/// 原来的接线是 `unawaited(app.refreshUsageSummary())` 之后立刻
/// `push(UsagePage(summary: app.usageSummary))` —— 这时还是 null，而 `UsagePage`
/// 不监听 `AppModel`，于是真机上永远停在空态（2026-10-21 抓到）。
/// 现在这一层 `ListenableBuilder` 听 `AppModel`，拉到之后自己重画。
class UsagePageHost extends StatefulWidget {
  const UsagePageHost({super.key, required this.app, this.onOpenSession});

  final AppModel app;
  final void Function(String sid)? onOpenSession;

  @override
  State<UsagePageHost> createState() => _UsagePageHostState();
}

class _UsagePageHostState extends State<UsagePageHost> {
  /// 首次进入的活动窗口。30 天：够看"最近在不在干活"，读的会话也不多。
  static const int _initialWindow = 30;

  @override
  void initState() {
    super.initState();
    // 不等它们：页面先以"正在读取"出现，拉到之后由 `ListenableBuilder` 重画。
    unawaited(widget.app.refreshUsageSummary());
    unawaited(widget.app.refreshUsageDays(_initialWindow));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // **页面是独立路由**：`ChatPage` 的重建到不了它，所以它必须自己听
      // `AppModel`（与「切换子智能体」面板同一条纪律）。
      listenable: widget.app,
      builder: (context, _) {
        final window = widget.app.usageDaysWindow ?? _initialWindow;
        return UsagePage(
          summary: widget.app.usageSummary,
          loading: widget.app.usageSummaryLoading,
          failure: widget.app.lastError?.message,
          days: widget.app.usageDays,
          daysWindow: window,
          daysLoading: widget.app.usageDaysLoading,
          daysProgress: widget.app.usageDaysProgress,
          daysFailure: widget.app.usageDaysFailure,
          onSelectWindow: (value) =>
              unawaited(widget.app.refreshUsageDays(value)),
          onRetryDays: () => unawaited(widget.app.refreshUsageDays(window)),
          onOpenSession: widget.onOpenSession,
        );
      },
    );
  }
}

/// 用量页。数据由调用方拉好传进来（**这一页不自己发请求**）——
/// 与设置页同一约定：拉取是 `AppModel` 的事，页面只显示。
class UsagePage extends StatelessWidget {
  const UsagePage({
    super.key,
    this.summary,
    this.onOpenSession,
    this.failure,
    this.loading = false,
    this.days = const [],
    this.daysWindow = 30,
    this.daysLoading = false,
    this.daysProgress,
    this.daysFailure,
    this.onSelectWindow,
    this.onRetryDays,
  });

  /// 汇总；`null` = 还没拉到（或形状不认识）—— 页面显示空态。
  final UsageSummary? summary;

  /// 点一个会话行（打开那个会话）。`null` = 不可点。
  final void Function(String sid)? onOpenSession;

  /// 总量拉取失败的原因（`null` = 没失败）。
  final String? failure;

  /// 总量那次请求是否在途（空态用它区分"正在读"与"没有数据"）。
  final bool loading;

  /// 按天活动（`usage.summary {days}` 的 `byDay`）。
  final List<UsageDay> days;

  /// 活动的窗口（天）。
  final int daysWindow;

  final bool daysLoading;
  final String? daysFailure;

  /// 按天活动的扫描进度（`scanned / total` 个会话）；`null` = 老连接器没报。
  final ({int scanned, int total})? daysProgress;

  /// 切换活动窗口（7 / 30 / 90 天）—— 会重新拉一次。
  final void Function(int days)? onSelectWindow;

  /// 活动拉取失败后重试。
  final VoidCallback? onRetryDays;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final data = summary;
    return Scaffold(
      backgroundColor: c.bgBase,
      appBar: AppBar(title: const Text('用量'), backgroundColor: c.layer1),
      body: data == null
          ? _EmptyUsage(failure: failure, loading: loading)
          // **真的没有用量**（0 个有数据的会话）：说一句人话，不摆一张 0 卡。
          : data.grandTotalTokens == 0 && data.bySession.isEmpty
          ? const _EmptyUsage()
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _TotalCard(summary: data),
                // 四个分项：**电脑侧没报就整块不出现**（老连接器），
                // 不摆四个 0。
                if (data.totals != null) ...[
                  const SizedBox(height: 12),
                  _BreakdownGrid(totals: data.totals!),
                ],
                const SizedBox(height: 20),
                _ActivityCard(
                  // **老连接器把 `byDay` 放在总量应答里**（那版没有 `days`），
                  // 新连接器只在带 `days` 的那次里给 —— 两边都认，界面不用分叉。
                  days: days.isEmpty ? data.byDay : days,
                  window: daysWindow,
                  loading: daysLoading,
                  progress: daysProgress,
                  failure: daysFailure,
                  onSelectWindow: onSelectWindow,
                  onRetry: onRetryDays,
                ),
                const SizedBox(height: 24),
                ..._projectSections(context, data),
              ],
            ),
    );
  }

  /// 按项目分组的段；没有 `byProject` 时退回扁平会话榜。
  List<Widget> _projectSections(BuildContext context, UsageSummary data) {
    final groups = data.grouped;
    if (groups.isEmpty) {
      return [
        const _SectionTitle('按会话'),
        for (final entry in data.bySession)
          _SessionRow(
            entry: entry,
            totalTokens: data.grandTotalTokens,
            onTap: onOpenSession == null
                ? null
                : () => onOpenSession!(entry.sid),
          ),
      ];
    }
    return [
      for (final group in groups) ...[
        _ProjectSection(
          group: group,
          totalTokens: data.grandTotalTokens,
          onOpenSession: onOpenSession,
        ),
        const SizedBox(height: 12),
      ],
    ];
  }
}

/// 总量卡（这一页最大的一行字）。
class _TotalCard extends StatelessWidget {
  const _TotalCard({required this.summary});

  final UsageSummary summary;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
      decoration: BoxDecoration(
        color: c.layer1,
        borderRadius: BorderRadius.circular(DshRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('这台电脑一共', style: TextStyle(fontSize: 12, color: c.labelCaption)),
          const SizedBox(height: 6),
          // **同一个格式化函数**（`formatTokenCount`）—— 总量与单会话统计条
          // 上的那个数字必须长得一样，否则用户会以为两个口径。
          //
          // 数字与单位分成两个 `Text` 而不是 `RichText`：一个数字就是一个
          // 可被 `find.text` 命中的 widget（测试要断言它），
          // 而 `RichText` 里的 TextSpan 找不到。
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                summary.totalLabel,
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w700,
                  color: c.labelPrimary,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                'tok',
                style: TextStyle(fontSize: 14, color: c.labelCaption),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '来自 ${summary.sessions} 个会话（子智能体不计入）',
            style: TextStyle(fontSize: 12, color: c.labelTertiary),
          ),
          if (summary.totals != null) ...[
            const SizedBox(height: 14),
            // **构成条**：四个桶按比例占宽 —— 一眼看出"钱花在输入、输出还是
            // 缓存重读上"。没有分项（老连接器）就不画。
            _CompositionBar(totals: summary.totals!),
            const SizedBox(height: 8),
            if (summary.totals!.cacheHitText != null)
              Text(
                '缓存命中 ${summary.totals!.cacheHitText}%',
                style: TextStyle(fontSize: 11, color: c.labelSecondary),
              ),
          ],
        ],
      ),
    );
  }
}

/// 四个桶的构成条（按 token 比例分宽；全零时只留一条底色轨道）。
class _CompositionBar extends StatelessWidget {
  const _CompositionBar({required this.totals});

  final UsageTotals totals;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final parts = <({int value, Color color})>[
      (value: totals.uncachedInputTokens, color: c.accentBlue),
      (value: totals.cacheReadTokens, color: c.ctxTools),
      (value: totals.cacheWriteTokens, color: c.labelCaption),
      (value: totals.outputTokens, color: c.stateWarn),
    ];
    final sum = parts.fold<int>(0, (acc, part) => acc + part.value);
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: SizedBox(
        key: const Key('usage-composition'),
        height: 8,
        child: sum == 0
            ? ColoredBox(color: c.layer2)
            : Row(
                // **stretch 是必须的**：`ColoredBox` 没有子节点，在 Row 的
                // 松高度约束下会取 0 高 —— 条子于是"存在但看不见"
                // （2026-11-08 真机截图抓到的）。
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final part in parts)
                    if (part.value > 0)
                      Expanded(
                        flex: part.value,
                        child: ColoredBox(color: part.color),
                      ),
                ],
              ),
      ),
    );
  }
}

/// 占比文字（`62%` / `<1%`）；`null` 原样给 `null`（合计为 0 时不编一个 0%）。
///
/// 公开给用例直接断言：格式化口径只有这一处（四个小卡片、项目行、会话行共用）。
String? percentTextOf(double? fraction) {
  if (fraction == null) return null;
  final percent = fraction * 100;
  if (percent > 0 && percent < 0.5) return '<1%';
  return '${percent.round()}%';
}

/// 一条按比例填充的细条（项目 / 会话的占比）。
class _ShareBar extends StatelessWidget {
  const _ShareBar({required this.fraction, required this.color});

  /// 0..1（越界会被夹住）。
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return ClipRRect(
      borderRadius: BorderRadius.circular(99),
      child: SizedBox(
        height: 4,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: c.layer2),
            Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: fraction.clamp(0.0, 1.0),
                heightFactor: 1,
                child: ColoredBox(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 四个分项的小卡片（2×2）：未缓存输入 / 输出 / 缓存读·写。
///
/// 为什么是"小卡片"而不是一行字：用量页的动作是**看趋势与构成**，
/// 四格并排比四行文字更快扫到（参照 rikkahub 的 `StatsGrid` + `StatCard`，
/// `ui/pages/stats/StatsPage.kt:277-360`）。
///
/// **轮次不在这里**：全库轮次没有可靠来源（`trajectory` 只保留每会话最近 200 轮），
/// 摆一个"看起来是总量"的轮次就是编 —— 轮次归「近期活动」那一段，带窗口。
class _BreakdownGrid extends StatelessWidget {
  const _BreakdownGrid({required this.totals});

  final UsageTotals totals;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final cells = <Widget>[
      _MiniCard(
        label: '输入（未命中缓存）',
        value: formatTokenCount(totals.uncachedInputTokens),
        color: c.accentBlue,
        hint: percentTextOf(totals.shareOf(totals.uncachedInputTokens)),
      ),
      _MiniCard(
        label: '输出',
        value: formatTokenCount(totals.outputTokens),
        color: c.stateWarn,
        hint: percentTextOf(totals.shareOf(totals.outputTokens)),
      ),
      _MiniCard(
        label: '缓存读',
        value: formatTokenCount(totals.cacheReadTokens),
        color: c.ctxTools,
        hint: percentTextOf(totals.shareOf(totals.cacheReadTokens)),
      ),
      _MiniCard(
        label: '缓存写',
        value: formatTokenCount(totals.cacheWriteTokens),
        color: c.labelCaption,
        hint: percentTextOf(totals.shareOf(totals.cacheWriteTokens)),
      ),
    ];
    return Column(
      children: [
        for (var i = 0; i < cells.length; i += 2) ...[
          if (i > 0) const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: cells[i]),
              const SizedBox(width: 8),
              Expanded(
                child: i + 1 < cells.length ? cells[i + 1] : const SizedBox(),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _MiniCard extends StatelessWidget {
  const _MiniCard({
    required this.label,
    required this.value,
    required this.color,
    this.hint,
  });

  final String label;
  final String value;

  /// 与构成条同一色：四格与那条带子的颜色必须对得上（否则读比例时得猜）。
  final Color color;

  /// 这一项占合计的百分比（`62%`）；`null` = 合计为 0，不显示。
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: c.layer1,
        borderRadius: BorderRadius.circular(DshRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: c.labelCaption),
                ),
              ),
              if (hint != null)
                Text(
                  hint!,
                  style: TextStyle(
                    fontSize: 10,
                    color: c.labelCaption,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: c.labelPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 一段活动窗口的读数（今日 / 本段 / 前段）。
typedef ActivityStats = ({
  int todayTokens,
  int todayTurns,
  int windowTokens,
  int windowTurns,
  int previousTokens,
});

/// 从**已经拉回来的一段 `byDay`** 里切出今日 / 本窗口 / 前一窗口。
///
/// [days] 覆盖 `2 × window` 天（`AppModel.refreshUsageDays` 就是这么要的），
/// 所以"前一段"不需要再发一次请求。纯函数：界面只调它，测试直接断言。
ActivityStats activityStatsOf(List<UsageDay> days, int window, DateTime today) {
  final todayDate = DateTime(today.year, today.month, today.day);
  final todayKey = _dateKey(todayDate);
  final windowStart = _dateKey(todayDate.subtract(Duration(days: window - 1)));
  final previousStart = _dateKey(
    todayDate.subtract(Duration(days: window * 2 - 1)),
  );
  var todayTokens = 0;
  var todayTurns = 0;
  var windowTokens = 0;
  var windowTurns = 0;
  var previousTokens = 0;
  for (final day in days) {
    if (day.date == todayKey) {
      todayTokens += day.tokens;
      todayTurns += day.turns;
    }
    if (day.date.compareTo(windowStart) >= 0) {
      windowTokens += day.tokens;
      windowTurns += day.turns;
    } else if (day.date.compareTo(previousStart) >= 0) {
      previousTokens += day.tokens;
    }
  }
  return (
    todayTokens: todayTokens,
    todayTurns: todayTurns,
    windowTokens: windowTokens,
    windowTurns: windowTurns,
    previousTokens: previousTokens,
  );
}

/// "较前 N 天"那段话。前一段没有数据就说没有，**不编一个 +100%**。
String? deltaTextOf(int current, int previous, int window) {
  if (previous <= 0) return current <= 0 ? null : '前一段没有数据';
  final percent = ((current - previous) * 100 / previous).round();
  return '较前 $window 天 ${percent >= 0 ? '+' : ''}$percent%';
}

/// 近期活动：窗口胶囊 + 今日 / 本段 / 前段对比 + 热力图。
///
/// ## 为什么窗口在这里、而且会重新请求
///
/// 按天活动要读每个会话的 `trajectory`（日志），所以"看最近 90 天"不能靠
/// 本地切片（那要把一年全读回来）。三档窗口各自是一次有界请求
/// （`usage.summary {days}`），数据量只随窗口里的会话数长。
class _ActivityCard extends StatelessWidget {
  const _ActivityCard({
    required this.days,
    required this.window,
    required this.loading,
    this.progress,
    this.failure,
    this.onSelectWindow,
    this.onRetry,
  });

  final List<UsageDay> days;
  final int window;
  final bool loading;

  /// 扫描进度；`scanned < total` 时数字还会长，界面要说出来。
  final ({int scanned, int total})? progress;
  final String? failure;
  final void Function(int days)? onSelectWindow;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final stats = activityStatsOf(days, window, DateTime.now());
    // 已经有一段数据时，切窗口**继续显示旧读数**（旁边放小转圈），
    // 而不是把整块藏掉再闪回来。
    final showHeatmap = failure == null && days.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          decoration: BoxDecoration(
            color: c.layer1,
            borderRadius: BorderRadius.circular(DshRadius.lg),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '近期活动',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: c.labelPrimary,
                    ),
                  ),
                  const Spacer(),
                  if (loading && days.isNotEmpty) ...[
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                  ],
                  for (final option in UsageRange.values)
                    _RangeChip(
                      key: ValueKey<String>('usage-range-${option.name}'),
                      label: option.label,
                      selected: option.days == window,
                      onTap: () => onSelectWindow?.call(option.days),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              if (loading && days.isEmpty)
                Row(
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '正在读取活动…',
                      style: TextStyle(fontSize: 12, color: c.labelTertiary),
                    ),
                  ],
                )
              else if (failure != null)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '拉不到活动：$failure',
                        style: TextStyle(fontSize: 12, color: c.labelTertiary),
                      ),
                    ),
                    TextButton(
                      key: const Key('usage-days-retry'),
                      onPressed: onRetry,
                      child: const Text('重试'),
                    ),
                  ],
                )
              else if (days.isEmpty &&
                  (progress == null || progress!.scanned >= progress!.total))
                Text(
                  '这段时间电脑上没有记录到活动',
                  style: TextStyle(fontSize: 12, color: c.labelTertiary),
                )
              else ...[
                _ActivityLine(
                  label: '今天',
                  tokens: stats.todayTokens,
                  turns: stats.todayTurns,
                ),
                const SizedBox(height: 6),
                _ActivityLine(
                  label: '近 $window 天',
                  tokens: stats.windowTokens,
                  turns: stats.windowTurns,
                  note: deltaTextOf(
                    stats.windowTokens,
                    stats.previousTokens,
                    window,
                  ),
                ),
                if (stats.windowTurns > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    '日均 ${formatTokenCount((stats.windowTokens / window).round())} tok'
                    ' · 平均每轮 ${formatTokenCount((stats.windowTokens / stats.windowTurns).round())} tok',
                    style: TextStyle(fontSize: 10.5, color: c.labelCaption),
                  ),
                ],
                // **数字还在长**：电脑侧一次只扫几个会话，明说统计到哪了，
                // 别让人把"半份账"当成完整结果。
                if (progress != null &&
                    progress!.scanned < progress!.total) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(strokeWidth: 1.6),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '正在统计活动：${progress!.scanned}/${progress!.total} 个会话…',
                        style: TextStyle(fontSize: 10.5, color: c.labelCaption),
                      ),
                    ],
                  ),
                ],
              ],
            ],
          ),
        ),
        if (showHeatmap) ...[
          const SizedBox(height: 10),
          _HeatmapCard(days: days, range: UsageRange.ofDays(window)),
        ],
      ],
    );
  }
}

/// 一行活动读数：`今天  12.4K tok · 3 轮`，右侧可带一句对比。
class _ActivityLine extends StatelessWidget {
  const _ActivityLine({
    required this.label,
    required this.tokens,
    required this.turns,
    this.note,
  });

  final String label;
  final int tokens;
  final int turns;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: TextStyle(fontSize: 11, color: c.labelCaption),
          ),
        ),
        Text(
          '${formatTokenCount(tokens)} tok',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: c.labelPrimary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '$turns 轮',
          style: TextStyle(fontSize: 11, color: c.labelTertiary),
        ),
        const Spacer(),
        if (note != null)
          Text(note!, style: TextStyle(fontSize: 10.5, color: c.labelCaption)),
      ],
    );
  }
}

/// 活动热力图：一格一天，**颜色 = 那天用掉的 token**。
///
/// ## 它凭什么不再"只是一张图"
///
/// 三件能读出数字的东西：
///
/// 1. **可点**：点一格，标题右边那行读出 `10月3日 · 3 轮 · 12.4K tok`；
/// 2. **有刻度**：左边星期（一/三/五）、顶上按周对齐的月份；
/// 3. **有图例**：少 → 多 五档，与格子用同一个色阶（[heatAlphaAt]）。
///
/// ## 尺寸为什么是 10dp 且可横向滚
///
/// 4dp 的装饰格**点不中**（那是"看个样子"的根源）。10dp 格 + 3dp 缝 ⇒
/// 52 周约 **673dp**，一屏放不下，所以网格横向可滚、星期列固定不动。
///
/// ## 数据口径（写在卡片上，不靠猜）
///
/// 颜色按 token；一格同时能读出轮次。两数都是真值：每轮用量来自那条
/// `assistant/message` 的 `data.usage`（连接器在 `trajectory` 里累进本轮）。
/// 覆盖范围是各会话 `trajectory` 保留的最近 200 轮。
class _HeatmapCard extends StatefulWidget {
  const _HeatmapCard({required this.days, required this.range});

  final List<UsageDay> days;

  /// 窗口（与上面那排胶囊同一档）—— 只决定画几列，不再自己切数据。
  final UsageRange range;

  @override
  State<_HeatmapCard> createState() => _HeatmapCardState();
}

class _HeatmapCardState extends State<_HeatmapCard> {
  static const double _cell = 10;

  /// 格与缝；一格 + 一缝 = [_slot]。
  static const double _gap = 3;
  static const double _slot = _cell + _gap;

  /// 选中的那天（`YYYY-MM-DD`）；`null` = 还没点（显示"点一格"）。
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    final window = usageWindowOf(widget.days, widget.range, today);
    final byDate = {for (final day in window.days) day.date: day};
    // 本周周一（`DateTime.weekday` 的 1 = 周一）。
    final thisMonday = todayDate.subtract(
      Duration(days: todayDate.weekday - 1),
    );
    final firstMonday = thisMonday.subtract(
      Duration(days: 7 * (window.weeks - 1)),
    );
    final scale = heatScaleOf(byDate.values.map((day) => day.tokens));
    // 窗口一换，落在窗口外的选中日期就没有读数可显示了 —— 清掉，不摆旧值。
    final selected = _selected == null ? null : byDate[_selected];

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: c.layer1,
        borderRadius: BorderRadius.circular(DshRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '最近 ${widget.range.days} 天',
                style: TextStyle(fontSize: 12, color: c.labelSecondary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  selected == null ? '点一格看当天' : _readoutOf(selected),
                  key: const Key('usage-readout'),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: selected == null ? c.labelCaption : c.labelPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 星期列**固定不滚**（滚走了就不知道哪一行是哪天）。
              const _WeekdayColumn(cell: _cell, gap: _gap),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  // 默认停在最右（最近的几周才是常看的）。
                  reverse: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _MonthRow(
                        firstMonday: firstMonday,
                        todayDate: todayDate,
                        weeks: window.weeks,
                      ),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var week = 0; week < window.weeks; week++) ...[
                            if (week > 0) const SizedBox(width: _gap),
                            Column(
                              children: [
                                for (var weekday = 0; weekday < 7; weekday++)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      bottom: _gap,
                                    ),
                                    child: Builder(
                                      builder: (context) {
                                        final date = firstMonday.add(
                                          Duration(days: week * 7 + weekday),
                                        );
                                        final key = _dateKey(date);
                                        final day = byDate[key];
                                        return _HeatCell(
                                          key: Key('heat-$key'),
                                          alpha: heatAlphaAt(
                                            day?.tokens ?? 0,
                                            scale,
                                          ),
                                          size: _cell,
                                          future: date.isAfter(todayDate),
                                          selected: key == _selected,
                                          onTap: date.isAfter(todayDate)
                                              ? null
                                              : () => setState(
                                                  () => _selected = key,
                                                ),
                                        );
                                      },
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _Legend(scale: scale),
        ],
      ),
    );
  }

  /// 选中那天的读出行：`10月3日 · 3 轮 · 12.4K tok`。
  String _readoutOf(UsageDay day) {
    final parts = _datePartsOf(day.date);
    final label = parts == null ? day.date : '${parts.$2}月${parts.$3}日';
    final tokens = day.tokens > 0 ? formatTokenCount(day.tokens) : '无计量';
    return '$label · ${day.turns} 轮 · $tokens tok';
  }
}

/// `YYYY-MM-DD` → `(year, month, day)`；认不出给 `null`。
(int, int, int)? _datePartsOf(String date) {
  final parts = date.split('-');
  if (parts.length != 3) return null;
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final day = int.tryParse(parts[2]);
  if (year == null || month == null || day == null) return null;
  return (year, month, day);
}

/// 左边的星期列（只标一/三/五，与 GitHub 同一档密度）。
class _WeekdayColumn extends StatelessWidget {
  const _WeekdayColumn({required this.cell, required this.gap});

  final double cell;
  final double gap;

  static const List<String> _labels = ['一', '', '三', '', '五', '', ''];

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final label in _labels)
            SizedBox(
              height: cell + gap,
              child: Center(
                child: Text(
                  label,
                  style: TextStyle(fontSize: 9, color: c.labelCaption),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 顶上按月对齐的月份标签（只在"这一周的周一进入新月份"处标，太近的不叠）。
class _MonthRow extends StatelessWidget {
  const _MonthRow({
    required this.firstMonday,
    required this.todayDate,
    required this.weeks,
  });

  final DateTime firstMonday;
  final DateTime todayDate;

  /// 这一屏画几周（窗口决定：7/30/90 天与"全部"各是连续的一段日历）。
  final int weeks;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    const slot = _HeatmapCardState._slot;
    final labels = <({int week, String text})>[];
    var lastMonth = firstMonday.month;
    var lastLabeledWeek = -99;
    for (var week = 0; week < weeks; week++) {
      final monday = firstMonday.add(Duration(days: week * 7));
      if (monday.month == lastMonth) continue;
      lastMonth = monday.month;
      // 相邻标签至少隔 3 格，否则 `10月`/`11月` 会叠在一起。
      if (week - lastLabeledWeek < 3) continue;
      lastLabeledWeek = week;
      labels.add((week: week, text: '${monday.month}月'));
    }
    // 宽度必须**显式给**：这块在横向滚动里，父级宽度是无限的，
    // 而 `Stack` 不接受无限宽（`RenderStack._computeSize` 会断言）。
    return SizedBox(
      width: weeks * slot,
      height: 13,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final label in labels)
            Positioned(
              left: label.week * slot,
              child: Text(
                label.text,
                style: TextStyle(fontSize: 9, color: c.labelCaption),
              ),
            ),
        ],
      ),
    );
  }
}

/// 图例：少 → 多 五档，用的是与格子同一个 [heatAlphaAt]。
class _Legend extends StatelessWidget {
  const _Legend({required this.scale});

  /// 这一年的非零 token 升序（色阶的分位依据）。
  final List<int> scale;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    // 图例用这一年的中位数量级做样本：读的人关心"深浅对应多少"，
    // 而不是把 5 个格子各自标上数字（那会挤满一行）。
    final sample = scale.isEmpty ? 0 : scale[scale.length ~/ 2];
    return Row(
      children: [
        Text('少', style: TextStyle(fontSize: 10, color: c.labelCaption)),
        const SizedBox(width: 4),
        for (var step = 0; step <= 4; step++) ...[
          if (step > 0) const SizedBox(width: 3),
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: step == 0
                  ? c.layer2
                  : c.accentBlue.withValues(alpha: step / 4 * 0.7 + 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
        const SizedBox(width: 4),
        Text('多', style: TextStyle(fontSize: 10, color: c.labelCaption)),
        const Spacer(),
        Text(
          sample > 0 ? '中位 ${formatTokenCount(sample)} tok/天' : '按 token 深浅',
          style: TextStyle(fontSize: 10, color: c.labelCaption),
        ),
      ],
    );
  }
}

class _HeatCell extends StatelessWidget {
  const _HeatCell({
    super.key,
    required this.alpha,
    required this.size,
    required this.future,
    required this.selected,
    this.onTap,
  });

  final double alpha;
  final double size;

  /// 未来的日子（本周内）画成透明 —— 它不是"0 轮"。
  final bool future;

  /// 选中的那一格：加一圈描边（否则点完看不出点的是哪格）。
  final bool selected;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final box = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: future
            ? Colors.transparent
            : alpha == 0.0
            ? c.layer2
            : c.accentBlue.withValues(alpha: alpha),
        borderRadius: BorderRadius.circular(2),
        border: selected ? Border.all(color: c.labelPrimary, width: 1.2) : null,
      ),
    );
    if (onTap == null) return box;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: box,
    );
  }
}

String _dateKey(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// 热力图的时间范围。
///
/// **这三档就是连接器的 `days` 窗口**（7 / 30 / 90）：按天活动要读每个会话的
/// `trajectory`（日志），所以切窗口是**重新拉一次**，不是本地切片。
/// 没有"全部"：一年窗口要把全部会话的日志读一遍，代价与收益不成比例
/// （见 `.agents/notes/implemented/2026-11-08-usage-summary-from-list-rows.md`）。
enum UsageRange {
  d7('7 天', 7),
  d30('30 天', 30),
  d90('90 天', 90);

  const UsageRange(this.label, this.days);

  /// 胶囊上的字。
  final String label;

  /// 窗口天数。
  final int days;

  /// 窗口天数 → 档位（窗口只可能是这三档；认不出按最近的那档算）。
  static UsageRange ofDays(int days) => days <= 7
      ? UsageRange.d7
      : days >= 90
      ? UsageRange.d90
      : UsageRange.d30;
}

/// 把 `byDay` 切成一个窗口，并算出这一屏要画**几周**。
///
/// **窗口仍是连续日历**：格子按 周 × 星期 画，窗口首日落到它那一周的周一、
/// 一直到今天所在的周 —— 所以"7 天"在周三看是 2 列、周一就正好 1 列，
/// 而不是"只画 7 格"的一根长条。
///
/// 日期比较直接用 `YYYY-MM-DD` 的字符串序（同格式下字典序 = 时间序），
/// 认不出的日期不猜，按它自己的字面值参与比较。
({List<UsageDay> days, int weeks}) usageWindowOf(
  List<UsageDay> days,
  UsageRange range,
  DateTime today,
) {
  final todayDate = DateTime(today.year, today.month, today.day);
  final start = todayDate.subtract(Duration(days: range.days - 1));
  final startKey = _dateKey(start);
  final kept = [
    for (final day in days)
      if (day.date.compareTo(startKey) >= 0) day,
  ];
  final firstMonday = start.subtract(Duration(days: start.weekday - 1));
  final thisMonday = todayDate.subtract(Duration(days: todayDate.weekday - 1));
  final weeks = thisMonday.difference(firstMonday).inDays ~/ 7 + 1;
  return (days: kept, weeks: weeks);
}

/// 范围胶囊（7 / 30 / 90 / 全部）。选中态只换底色与字重，不改高度 ——
/// 这四个词长度不同，靠 `minWidth` 与等高的内边距对齐。
class _RangeChip extends StatelessWidget {
  const _RangeChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: selected ? c.layer2 : Colors.transparent,
        borderRadius: BorderRadius.circular(DshRadius.sm),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 26, minWidth: 44),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: selected ? c.labelPrimary : c.labelCaption,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 这一年的色阶：**非零 token 升序**（空 = 这一年没有任何计量）。
///
/// 分档用**数据自己的四分位**，不发明绝对阈值（"多少 token 算多"因人而异；
/// 而"你这台机器里相对算多"是数据能回答的）。
List<int> heatScaleOf(Iterable<int> tokenValues) {
  final nonzero = [
    for (final value in tokenValues)
      if (value > 0) value,
  ]..sort();
  return nonzero;
}

/// 一格的不透明度：纯函数（界面只调它，测试只测它）。
///
/// `0` 或负数 = 底色（不是透明 —— 那一天存在，只是没干活）；
/// 否则按它在 [scale] 里的**分位**落 0.30 / 0.45 / 0.60 / 0.75 / 1.0。
double heatAlphaAt(int tokens, List<int> scale) {
  if (tokens <= 0) return 0.0;
  if (scale.isEmpty) return 0.30;
  // 这一格在非零样本里的位置（0..1）⇒ 五档。
  var atOrBelow = 0;
  for (final value in scale) {
    if (value <= tokens) atOrBelow++;
  }
  final fraction = atOrBelow / scale.length;
  return switch (fraction) {
    <= 0.2 => 0.30,
    <= 0.4 => 0.45,
    <= 0.6 => 0.60,
    <= 0.8 => 0.75,
    _ => 1.0,
  };
}

/// 一个项目的标题行（名字 · 用量 · 几个会话 · 占全库的比例）。
class _ProjectHeader extends StatelessWidget {
  const _ProjectHeader({
    required this.group,
    required this.totalTokens,
    required this.open,
    required this.onTap,
  });

  final ({UsageProject project, List<UsageEntry> entries}) group;

  /// 全库总量（占比的分母）。
  final int totalTokens;

  /// 这一个项目展开着没有（决定箭头朝向）。
  final bool open;

  /// 点整行 = 收起/展开（**只有项目头可点**，会话行仍然是"进入会话"）。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final project = group.project;
    final share = totalTokens <= 0 ? 0.0 : project.tokens / totalTokens;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(DshRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          children: [
            Row(
              children: [
                DshIcon('workspaceTree', size: 14, color: c.labelSecondary),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    project.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: c.labelPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatTokenCount(project.tokens),
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: c.labelSecondary,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${project.sessions} 个会话',
                  style: TextStyle(fontSize: 11, color: c.labelCaption),
                ),
                const SizedBox(width: 2),
                // 箭头朝向照落地端既有口径：收起朝右、展开朝下。
                DshIcon(
                  open ? 'chevronDown' : 'chevronRight',
                  size: 14,
                  color: c.labelTertiary,
                ),
              ],
            ),
            const SizedBox(height: 5),
            // **占比条**：一眼看出"这台电脑的用量主要花在哪个项目"。
            Row(
              children: [
                const SizedBox(width: 21),
                Expanded(
                  child: _ShareBar(fraction: share, color: c.accentBlue),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 34,
                  child: Text(
                    percentTextOf(share) ?? '',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 10,
                      color: c.labelCaption,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 一个项目段：**头可点、身子可折**（用户 2026-10-24 原话「用量页不可折叠」）。
///
/// 默认**展开**：折叠是省屏的手段，不该把信息默认藏起来。
class _ProjectSection extends StatefulWidget {
  const _ProjectSection({
    required this.group,
    required this.totalTokens,
    this.onOpenSession,
  });

  final ({UsageProject project, List<UsageEntry> entries}) group;
  final int totalTokens;
  final void Function(String sid)? onOpenSession;

  @override
  State<_ProjectSection> createState() => _ProjectSectionState();
}

class _ProjectSectionState extends State<_ProjectSection> {
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    final ids = {for (final entry in widget.group.entries) entry.sid};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 键里带项目路径：热力图/卡片变化导致的整页重建不该把折叠态带丢。
        KeyedSubtree(
          key: ValueKey<String>('usage-project-${widget.group.project.path}'),
          child: _ProjectHeader(
            group: widget.group,
            totalTokens: widget.totalTokens,
            open: _open,
            onTap: () => setState(() => _open = !_open),
          ),
        ),
        if (_open)
          for (final entry in widget.group.entries)
            if (ids.contains(entry.sid))
              _SessionRow(
                entry: entry,
                totalTokens: widget.group.project.tokens,
                onTap: widget.onOpenSession == null
                    ? null
                    : () => widget.onOpenSession!(entry.sid),
              ),
      ],
    );
  }
}

/// 一个会话的行（标题 + 用量 + 在本项目里的占比）。
class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.entry,
    required this.totalTokens,
    this.onTap,
  });

  final UsageEntry entry;

  /// 占比的分母：扁平榜里是全库，项目段里是那个项目。
  final int totalTokens;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    // 标题空串按 DSH 的链退到「未命名」（`SessionSummary.displayTitle`
    // 同一条规则），不在这里兜一个目录名。
    final title = entry.title.isEmpty ? '未命名' : entry.title;
    final share = totalTokens <= 0 ? null : entry.tokens / totalTokens;
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 21, right: 4),
      dense: true,
      onTap: onTap,
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 13, color: c.labelSecondary),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (share != null)
            Text(
              percentTextOf(share)!,
              style: TextStyle(
                fontSize: 10,
                color: c.labelCaption,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          const SizedBox(width: 8),
          Text(
            formatTokenCount(entry.tokens),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: c.labelTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

/// 段标题（与设置页的 `_SectionTitle` 同一份样式）。
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: c.labelCaption,
        ),
      ),
    );
  }
}

/// 空态：正在读 / 拉不到 / 还没有数据。
class _EmptyUsage extends StatelessWidget {
  const _EmptyUsage({this.failure, this.loading = false});

  final String? failure;

  /// 请求是否在途。**在途时不能说"还没有用量数据"** —— 那句话会被读成
  /// "电脑上真的没有"，而真相只是还没回来（2026-11-08 用户反馈的形态）。
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final reason = failure;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DshIcon('gauge', size: 40, color: c.labelTertiary),
            const SizedBox(height: 14),
            if (loading)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            if (loading) const SizedBox(height: 12),
            Text(
              loading
                  ? '正在读取…'
                  : reason == null
                  ? '还没有用量数据'
                  : '拉不到用量',
              style: TextStyle(fontSize: 14, color: c.labelSecondary),
            ),
            if (!loading && reason != null) ...[
              const SizedBox(height: 6),
              Text(
                reason,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: c.labelTertiary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
