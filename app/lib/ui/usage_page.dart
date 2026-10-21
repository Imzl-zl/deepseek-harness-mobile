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
        _ProjectHeader(group: group),
        for (final entry in group.entries)
          _SessionRow(
            entry: entry,
            onTap: onOpenSession == null
                ? null
                : () => onOpenSession!(entry.sid),
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
        ],
      ),
    );
  }
}

/// 一个项目的标题行（名字 · 用量 · 几个会话）。
class _ProjectHeader extends StatelessWidget {
  const _ProjectHeader({required this.group});

  final ({UsageProject project, List<UsageEntry> entries}) group;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final project = group.project;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
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
                fontSize: 13.5,
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
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: c.labelSecondary,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '${project.sessions} 个会话',
            style: TextStyle(fontSize: 11, color: c.labelCaption),
          ),
        ],
      ),
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
                style: TextStyle(fontSize: 11.5, color: c.labelTertiary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
