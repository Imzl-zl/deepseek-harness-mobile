/// 跨会话用量汇总（`usage.summary`，只读）。
///
/// ## 它是什么
///
/// DSH 的 `tokenUsage` 投影是**单会话**的（`llm/token-meter/src/usage-projection.ts:56-63`
/// 的 state 是 `{totals, last:{turn, step, buckets}}`），没有跨会话汇总接口，
/// 所以**聚合在连接器做**（`connector/src/handlers.ts` 的 `usage.summary`）。
/// 本文件只负责把电脑侧答的载荷解析成界面能用的形状。
///
/// ## 为什么不为 null 的字段兜底
///
/// 载荷形状由契约 §5.7 定，而契约里写明了三条聚合规则（子智能体不计入 /
/// 全零不进榜 / 只求和数值字段）。解析时**认不出就是 null**（整个汇总），
/// 界面显示"拉不到"，不摆一个 `0 tok` —— 那会把"没数据"说成"用了 0"
/// （`memory.md` 教训 4："空"有两种表达，判空只查一种就会漏）。
library;

// `formatTokenCount` 在 `model/session_stats.dart`（单会话统计条用的同一个
// 函数）—— 汇总与单会话的"同一个数字"必须格式化成同一个样子，
// 所以这里 import 它而不是再写一份。
import 'session_stats.dart' show formatTokenCount;

/// 四个 token 分项（`usage.summary.totals`）。
///
/// **键名是 DSH 的原名**（`llm/token-meter/src/usage-projection.ts:16-21` 的
/// `zeroBuckets`）：连接器不翻译，界面自己给中文标签 —— 词属于界面。
class UsageTotals {
  const UsageTotals({
    required this.uncachedInputTokens,
    required this.outputTokens,
    required this.cacheReadTokens,
    required this.cacheWriteTokens,
  });

  final int uncachedInputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;

  /// 缓存两项之和（"省下来的"那一格）。
  int get cacheTokens => cacheReadTokens + cacheWriteTokens;
}

/// 一天的活动（热力图一格）：**轮次数**，不是 token。
///
/// 为什么只数轮次：投影里没有"每一轮用了多少 token"，按天摊 token 就是编
/// （契约 §5.7 的聚合规则⑤）。
class UsageDay {
  const UsageDay({required this.date, required this.turns});

  /// `YYYY-MM-DD`（**电脑侧本地时区**）。
  final String date;

  /// 那天开了几轮。
  final int turns;
}

/// 一个项目（工作区目录）在汇总里的一行。
class UsageProject {
  const UsageProject({
    required this.path,
    required this.tokens,
    required this.sessions,
  });

  /// 工作区目录（`session.list` 的 `cwd`）。**可能为空串** —— 那台电脑
  /// 没给 `cwd` 的会话归到这一档，界面显示成「未关联项目」。
  final String path;

  /// 这个项目下全部会话的 token 总量（> 0）。
  final int tokens;

  /// 参与汇总的会话数（含全零的那些）。
  final int sessions;

  /// 界面上的项目名：**路径末段**（`D:\sudy\myproject\dsh-mobile` → `dsh-mobile`）。
  ///
  /// 为什么不直接用整条路径：一屏放不下，而用户认的是项目名。
  /// **不用 DSH 的 `workspace.title`**：`SessionSummary` 里没有 `workspaceId`
  /// （`connector/src/dsh/workspaces.ts:9` 明说只有 `cwd`），要拿标题得多一次
  /// 往返加一次 id 映射；而按 `cwd` 分组**一次调用就够**。
  String get label {
    if (path.isEmpty) return kUnlinkedProjectLabel;
    final normalized = path.replaceAll('\\', '/');
    final segments = normalized.split('/').where((s) => s.isNotEmpty);
    return segments.isEmpty ? path : segments.last;
  }

  /// 没有 `cwd` 的项目档显示名。
  static const String kUnlinkedProjectLabel = '未关联项目';
}

/// 一个会话在汇总榜上的一行。
class UsageEntry {
  const UsageEntry({
    required this.sid,
    required this.title,
    required this.tokens,
    this.cwd = '',
  });

  /// 会话别名（电脑侧分配的不透明 id，契约 §5.1）。
  final String sid;

  /// 标题。**可能为空串** —— 电脑侧取不到 `projections.values.title` 时给空，
  /// 界面按 DSH 的链退到「未命名」，不在这里兜一个目录名。
  final String title;

  /// 这个会话的 token 总量（> 0：全零的会话电脑侧已过滤掉）。
  final int tokens;

  /// 这个会话所属的工作区目录（`cwd`）。空串 = 电脑侧没给。
  final String cwd;
}

/// 跨会话用量汇总。
class UsageSummary {
  const UsageSummary({
    required this.sessions,
    required this.grandTotalTokens,
    required this.bySession,
    this.byProject = const [],
    this.totals,
    this.byDay = const [],
  });

  /// 参与汇总的会话数（含全零的那些 —— "用了 0" 与 "没这项" 都不是"不存在"）。
  final int sessions;

  /// 全部会话的 token 总量。
  final int grandTotalTokens;

  /// 四个分项。`null` = 电脑侧没报（老连接器）—— 界面**不摆四个 0**。
  final UsageTotals? totals;

  /// 按天的轮次（升序；空表 = 电脑侧没报 / 没有历史）。
  final List<UsageDay> byDay;

  /// 参与汇总的轮次总数（= `byDay` 之和；没有 `byDay` 时是 `null`）。
  int? get totalTurns {
    if (byDay.isEmpty) return null;
    return byDay.fold<int>(0, (sum, day) => sum + day.turns);
  }

  /// 全部有数据的会话（**降序、不截断** —— 用量是独立页面，一页放得下）。
  final List<UsageEntry> bySession;

  /// 按项目聚合的行（降序；空目录单独一档）。
  final List<UsageProject> byProject;

  /// 从电脑侧的载荷解析；**形状不认识就回 null**（调用方显示空态）。
  ///
  /// 期望形状（契约 §5.7 的 `usage.summary`）：
  /// `{sessions, grandTotalTokens, byProject:[{path,tokens,sessions}],
  ///   bySession:[{sid,title,cwd,tokens}]}`。
  static UsageSummary? fromWire(Object? data) {
    if (data is! Map) return null;
    final sessions = data['sessions'];
    final grandTotal = data['grandTotalTokens'];
    if (sessions is! int || grandTotal is! int) return null;
    final raw = data['bySession'];
    final entries = <UsageEntry>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final sid = item['sid'];
        final tokens = item['tokens'];
        // `sid` 与 `tokens` 是这一行的身份与数值，缺一个这一行就没有意义 ——
        // 跳过它，而不是摆一行点不开、数字是 0 的东西。
        if (sid is! String || sid.isEmpty) continue;
        if (tokens is! int) continue;
        final title = item['title'];
        final cwd = item['cwd'];
        entries.add(
          UsageEntry(
            sid: sid,
            title: title is String ? title : '',
            tokens: tokens,
            cwd: cwd is String ? cwd : '',
          ),
        );
      }
    }
    final rawProjects = data['byProject'];
    final projects = <UsageProject>[];
    if (rawProjects is List) {
      for (final item in rawProjects) {
        if (item is! Map) continue;
        final path = item['path'];
        final tokens = item['tokens'];
        final count = item['sessions'];
        // `tokens` 与 `sessions` 是数值；`path` 允许空串（未关联项目那一档）。
        if (path is! String) continue;
        if (tokens is! int || count is! int) continue;
        projects.add(UsageProject(path: path, tokens: tokens, sessions: count));
      }
    }
    // 四个分项：**整个键缺席就是 null**（老连接器），而不是四项 0 ——
    // 摆四个 0 会把"没报"说成"没用"（`memory.md` 教训 4）。
    final rawTotals = data['totals'];
    UsageTotals? totals;
    if (rawTotals is Map) {
      int pick(Object? key) {
        final value = rawTotals[key];
        return value is int && value >= 0 ? value : 0;
      }

      totals = UsageTotals(
        uncachedInputTokens: pick('uncachedInputTokens'),
        outputTokens: pick('outputTokens'),
        cacheReadTokens: pick('cacheReadTokens'),
        cacheWriteTokens: pick('cacheWriteTokens'),
      );
    }
    // 按天的轮次：认不出的一天就跳过（不补一个 0 轮的日子）。
    final rawDays = data['byDay'];
    final days = <UsageDay>[];
    if (rawDays is List) {
      for (final item in rawDays) {
        if (item is! Map) continue;
        final date = item['date'];
        final turns = item['turns'];
        if (date is! String || date.isEmpty) continue;
        if (turns is! int || turns < 0) continue;
        days.add(UsageDay(date: date, turns: turns));
      }
    }
    return UsageSummary(
      sessions: sessions,
      grandTotalTokens: grandTotal,
      bySession: entries,
      byProject: projects,
      totals: totals,
      byDay: days,
    );
  }

  /// 人类可读的总量（`302K` / `1.2M`）。
  ///
  /// **与单会话统计条同一个格式化函数**（`formatTokenCount`）——
  /// 两处各写一份会让"同一个数字在两地显示成两种样子"。
  String get totalLabel => formatTokenCount(grandTotalTokens);

  /// 按项目归组的会话行（**顺序不变**：仍按用量降序）。
  ///
  /// 独立页面用它做"项目 → 会话"两级列表。没有 `byProject` 时
  /// （老连接器）返回空表，界面退回"只有会话榜"的扁平形态。
  List<({UsageProject project, List<UsageEntry> entries})> get grouped {
    if (byProject.isEmpty) return const [];
    final byPath = <String, List<UsageEntry>>{};
    for (final entry in bySession) {
      byPath.putIfAbsent(entry.cwd, () => <UsageEntry>[]).add(entry);
    }
    return [
      for (final project in byProject)
        (
          project: project,
          entries: byPath[project.path] ?? const <UsageEntry>[],
        ),
    ];
  }
}
