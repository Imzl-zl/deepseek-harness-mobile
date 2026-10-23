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

/// 用量页 + 它的数据缝：**进来就拉一次，拉到就重画**。
///
/// ## 为什么要有这一层（2026-10-21 真机抓到）
///
/// 原来的接线是（`main.dart` 的 `_openUsage`）：
///
/// ```dart
/// unawaited(app.refreshUsageSummary());        // 异步开始拉
/// push(UsagePage(summary: app.usageSummary))   // 立刻读 —— 这时还是 null
/// ```
///
/// 而 [UsagePage] 是**无状态**的、只拿一份快照、**不监听 `AppModel`**，
/// 于是拉回来的数据没有触发任何重画：真机上永远是「还没有用量数据」，
/// 而电脑侧明明有几十万 token（同屏的统计条就摆着 92.7K）。
///
/// 判据见 `app/test/usage_page_test.dart` 的「先空态、拉到后自己重画」——
/// 少了这一层，那条用例在拉完之后仍看到空态。
class UsagePageHost extends StatefulWidget {
  const UsagePageHost({super.key, required this.app, this.onOpenSession});

  final AppModel app;
  final void Function(String sid)? onOpenSession;

  @override
  State<UsagePageHost> createState() => _UsagePageHostState();
}

class _UsagePageHostState extends State<UsagePageHost> {
  @override
  void initState() {
    super.initState();
    // 不等它：页面先以空态出现，拉到之后由下面的 `ListenableBuilder` 重画。
    unawaited(widget.app.refreshUsageSummary());
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // **页面是独立路由**：`ChatPage` 的重建到不了它，所以它必须自己听
      // `AppModel`（与「切换子智能体」面板同一条纪律）。
      listenable: widget.app,
      builder: (context, _) => UsagePage(
        summary: widget.app.usageSummary,
        failure: widget.app.lastError?.message,
        onOpenSession: widget.onOpenSession,
      ),
    );
  }
}

/// 用量页。数据由调用方拉好传进来（**这一页不自己发请求**）——
/// 与设置页同一约定：拉取是 `AppModel` 的事，页面只显示。
class UsagePage extends StatelessWidget {
  const UsagePage({super.key, this.summary, this.onOpenSession, this.failure});

  /// 汇总；`null` = 还没拉到（或形状不认识）—— 页面显示空态。
  final UsageSummary? summary;

  /// 点一个会话行（打开那个会话）。`null` = 不可点。
  final void Function(String sid)? onOpenSession;

  /// 拉取失败的原因（`null` = 没失败）。
  final String? failure;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final data = summary;
    return Scaffold(
      backgroundColor: c.bgBase,
      appBar: AppBar(title: const Text('用量'), backgroundColor: c.layer1),
      body: data == null
          ? _EmptyUsage(failure: failure)
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _TotalCard(summary: data),
                // 四个分项：**电脑侧没报就整块不出现**（老连接器），
                // 不摆四个 0。
                if (data.totals != null) ...[
                  const SizedBox(height: 12),
                  _BreakdownGrid(totals: data.totals!, turns: data.totalTurns),
                ],
                // 热力图：**没有按天数据就整块不出现**（同上）。
                if (data.byDay.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  _HeatmapCard(days: data.byDay),
                ],
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
            onTap: onOpenSession == null
                ? null
                : () => onOpenSession!(entry.sid),
          ),
      ];
    }
    return [
      for (final group in groups) ...[
        _ProjectSection(group: group, onOpenSession: onOpenSession),
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
        ],
      ),
    );
  }
}

/// 四个分项的小卡片（2×2）：输入 / 输出 / 缓存 / 轮次。
///
/// 为什么是"小卡片"而不是一行字：用量页的动作是**看趋势与构成**，
/// 四格并排比四行文字更快扫到（参照 rikkahub 的 `StatsGrid` + `StatCard`，
/// `ui/pages/stats/StatsPage.kt:277-360`）。
class _BreakdownGrid extends StatelessWidget {
  const _BreakdownGrid({required this.totals, required this.turns});

  final UsageTotals totals;

  /// 轮次总数；`null` = 没有按天数据（那一格不出现，而不是显示 0）。
  final int? turns;

  @override
  Widget build(BuildContext context) {
    final cells = <Widget>[
      _MiniCard(
        label: '输入（未命中缓存）',
        value: formatTokenCount(totals.uncachedInputTokens),
      ),
      _MiniCard(label: '输出', value: formatTokenCount(totals.outputTokens)),
      _MiniCard(label: '缓存读 / 写', value: formatTokenCount(totals.cacheTokens)),
      if (turns != null) _MiniCard(label: '轮次', value: '$turns'),
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
  const _MiniCard({required this.label, required this.value});

  final String label;
  final String value;

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
          Text(label, style: TextStyle(fontSize: 11, color: c.labelCaption)),
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

/// 活动热力图：**最近 26 周**，一格一天，颜色深浅 = 那天开了几轮。
///
/// ## 为什么 26 周而不是 52 周
///
/// rikkahub 画 52 周（`ui/pages/stats/StatsPage.kt:144-260`），但它的格子是
/// 4dp + 计算过的间距；390dp 的屏上 52 周 × 7 行的格子会挤到 5px 上下，
/// 点也点不到、深浅也分不出。**26 周**（半年）是这台机器上仍能读出"哪几天在干活"
/// 的上限，其余信息由上面的四格卡片承担。
///
/// ## 数据口径（写在卡片上，不靠猜）
///
/// 只数轮次、不摊 token（契约 §5.7 聚合规则⑤）；覆盖范围是各会话
/// `trajectory` 保留的最近 200 轮。所以底下一句如实写"按轮次"。
class _HeatmapCard extends StatelessWidget {
  const _HeatmapCard({required this.days});

  final List<UsageDay> days;

  static const int _weeks = 26;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final byDate = {for (final day in days) day.date: day.turns};
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    // 本周周一（`DateTime.weekday` 的 1 = 周一）。
    final thisMonday = todayDate.subtract(
      Duration(days: todayDate.weekday - 1),
    );
    final firstMonday = thisMonday.subtract(
      const Duration(days: 7 * (_weeks - 1)),
    );
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
              Expanded(
                child: Text(
                  '最近 $_weeks 周',
                  style: TextStyle(fontSize: 12, color: c.labelSecondary),
                ),
              ),
              Text(
                '按轮次',
                style: TextStyle(fontSize: 11, color: c.labelCaption),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 3.0;
              final cell =
                  ((constraints.maxWidth - gap * (_weeks - 1)) / _weeks).clamp(
                    4.0,
                    14.0,
                  );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var week = 0; week < _weeks; week++) ...[
                    if (week > 0) const SizedBox(width: gap),
                    Column(
                      children: [
                        for (var weekday = 0; weekday < 7; weekday++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: gap),
                            child: _HeatCell(
                              turns: _turnsOf(
                                byDate,
                                firstMonday.add(
                                  Duration(days: week * 7 + weekday),
                                ),
                              ),
                              size: cell,
                              future: firstMonday
                                  .add(Duration(days: week * 7 + weekday))
                                  .isAfter(todayDate),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  int _turnsOf(Map<String, int> byDate, DateTime date) =>
      byDate[_dateKey(date)] ?? 0;
}

class _HeatCell extends StatelessWidget {
  const _HeatCell({
    required this.turns,
    required this.size,
    required this.future,
  });

  final int turns;
  final double size;

  /// 未来的日子（本周内）画成透明 —— 它不是"0 轮"。
  final bool future;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final alpha = heatAlphaOf(turns);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: future
            ? Colors.transparent
            : alpha == 0.0
            ? c.layer2
            : c.accentBlue.withValues(alpha: alpha),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

String _dateKey(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// 热力图一格的不透明度：**纯函数**（界面只调它，测试只测它）。
///
/// 0 轮 = 底色（不是透明 —— 那一天存在，只是没干活）；越忙越深。
double heatAlphaOf(int turns) => switch (turns) {
  <= 0 => 0.0,
  <= 1 => 0.30,
  <= 3 => 0.50,
  <= 6 => 0.75,
  _ => 1.0,
};

/// 一个项目的标题行（名字 · 用量 · 几个会话）。
class _ProjectHeader extends StatelessWidget {
  const _ProjectHeader({
    required this.group,
    required this.open,
    required this.onTap,
  });

  final ({UsageProject project, List<UsageEntry> entries}) group;

  /// 这一个项目展开着没有（决定箭头朝向）。
  final bool open;

  /// 点整行 = 收起/展开（**只有项目头可点**，会话行仍然是"进入会话"）。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final project = group.project;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(DshRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
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
      ),
    );
  }
}

/// 一个项目段：**头可点、身子可折**（用户 2026-10-24 原话「用量页不可折叠」）。
///
/// 默认**展开**：折叠是省屏的手段，不该把信息默认藏起来。
class _ProjectSection extends StatefulWidget {
  const _ProjectSection({required this.group, this.onOpenSession});

  final ({UsageProject project, List<UsageEntry> entries}) group;
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
            open: _open,
            onTap: () => setState(() => _open = !_open),
          ),
        ),
        if (_open)
          for (final entry in widget.group.entries)
            if (ids.contains(entry.sid))
              _SessionRow(
                entry: entry,
                onTap: widget.onOpenSession == null
                    ? null
                    : () => widget.onOpenSession!(entry.sid),
              ),
      ],
    );
  }
}

/// 一个会话的行（标题 + 用量）。
class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.entry, this.onTap});

  final UsageEntry entry;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    // 标题空串按 DSH 的链退到「未命名」（`SessionSummary.displayTitle`
    // 同一条规则），不在这里兜一个目录名。
    final title = entry.title.isEmpty ? '未命名' : entry.title;
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
      trailing: Text(
        formatTokenCount(entry.tokens),
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          color: c.labelTertiary,
        ),
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

/// 空态：拉不到 / 还没有数据。
class _EmptyUsage extends StatelessWidget {
  const _EmptyUsage({this.failure});

  final String? failure;

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
            Text(
              reason == null ? '还没有用量数据' : '拉不到用量',
              style: TextStyle(fontSize: 14, color: c.labelSecondary),
            ),
            if (reason != null) ...[
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
