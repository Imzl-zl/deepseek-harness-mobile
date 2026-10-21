/// 子智能体的**运行态视图**：目录事实（`SubagentRow`）+ 子会话自己的投影提示。
///
/// ## 为什么与 `core/job.dart` 的 `SubagentRow` 分开
///
/// `mode` 是**目录事实**（能不能续聊，落盘后不变），而"此刻跑没跑"是
/// **运行时状态**（子会话自己 `session.list` 行的 `running`）。2026-10-21 之前
/// 两者被合成一个 `SubagentRow.status`，由 `mode` 推 —— 于是可续聊的子会话
/// 跑完后仍显示「正在运行」。这里按 DSH 的两个维度分开：
///
/// | 维度 | 来源 | DSH 依据 |
/// |---|---|---|
/// | 活动态 | 子会话 `running` + `subagentTiming.lastTurnCompleted` | `SubagentHeaderLineage.tsx:250-256,471-475` |
/// | 耗时 | `subagentTiming.settledMs` + `active` | `SubagentHeaderLineage.tsx:77-91` |
/// | token | `tokenUsage` 四个桶之和 | `SubagentHeaderLineage.tsx:66-74,260` |
/// | 详情行 | `title · mode · activity · 时长` | `SubagentHeaderLineage.tsx:257-259` |
///
/// 两个投影提示都来自**子会话自己**的 `session.list` 行
/// （`projections.values`，连接器原样透传），所以不需要新方法面。
///
/// ## 为什么右列只放一个数（触屏，不是桌面）
///
/// Web 的行右侧是**两行小字**（token 一行、时长一行，`grid-template-rows:17px 15px`，
/// `SubagentHeaderLineage.module.css:248-264`），因为桌面行高 44、字号 10 看得清。
/// 手机右抽屉只有 300dp：右列两行会吃掉约 70dp（23%），label 与详情行只剩
/// 200dp 出头，两行 10px 的小字在手机上既小又不齐。
///
/// 所以：**右列只放 token 这一个数**（数字右对齐最好扫），**时长并进详情行**
/// （它是"多久"的短语，与 mode / activity 读在一起更自然）。
///
/// 因果与代价见 `.agents/notes/implemented/2026-10-21-subagent-catalog-tree-and-state.md`。
library;

import 'dart:math' as math;

import '../core/job.dart';
import 'session_stats.dart';

/// `subagentTiming` 投影的 wire view（DSH `subagent/src/projection.ts:35-43,106-113`）。
///
/// - `settledMs`：**已结束轮次**累加的毫秒；
/// - `active`：当前未结束的那一段 `{since, through}`（没有 = 没有未结束的轮次）；
/// - `lastTurnCompleted`：最近一个结束的轮次是否以 `completed` 收尾
///   （新轮次一开始就被清掉 —— `projection.ts:72-78`）。
///
/// 字段名与投影**逐字对应**，不重新命名。
class SubagentTiming {
  const SubagentTiming({
    required this.settledMs,
    this.activeSince,
    this.activeThrough,
    this.lastTurnCompleted = false,
  });

  final int settledMs;

  /// `active.since`（毫秒时间戳）；`null` = 没有未结束的轮次。
  final int? activeSince;

  /// `active.through`（毫秒时间戳）：**同一切面**的上界。
  ///
  /// 子会话停下后**不能**拿更新的东西（手机本地时钟 / 会话元数据）当终点 ——
  /// DSH 的 README 原话："an interrupted open turn is bounded by its same-cut
  /// `active.through`, never by newer session metadata"
  /// （`ui-subagent/README.zh.md:66` 与 `README.md:66` 同一条）。
  final int? activeThrough;

  /// 最近一个结束的轮次是否正常完成（`turn/end` 的 `reason.kind === 'completed'`）。
  final bool lastTurnCompleted;

  /// 活跃耗时（毫秒）。**逐字照 Web 的 `activityDuration`**
  /// （`SubagentHeaderLineage.tsx:77-91`）：
  ///
  /// - 没有 `active` ⇒ 就是 `settledMs`（冻结）；
  /// - 正在跑 ⇒ `settledMs + (now - since)`（每秒长一格）；
  /// - 已经停了 ⇒ `settledMs + (active.through - since)` —— **不再长**，
  ///   哪怕 `now` 一直在走。
  int durationMs({required bool running, required int now}) {
    final since = activeSince;
    if (since == null) return settledMs;
    final end = running ? now : (activeThrough ?? since);
    return settledMs + math.max(0, end - since);
  }
}

/// 行上的活动态（DSH 的 `entry.activity` + `lastTurnCompleted`）。
enum SubagentActivity {
  /// 子会话此刻有轮次在跑（`activity.running`）。
  running,

  /// 已停，且最近一个轮次正常完成（`activity.completed`）。
  completed,

  /// 已停，但最近一个轮次不是正常完成（`activity.inactive`）。
  inactive,
}

/// 解析 `subagentTiming` 投影（形状见 [SubagentTiming]）。
///
/// **认不出就是 `null`**：没有计时就不摆时长，不拿本地时钟凑一个
/// （那正是 2026-10-21 之前"一次性任务时长永远涨"的成因）。
SubagentTiming? parseSubagentTiming(Object? raw) {
  if (raw is! Map) return null;
  final settled = raw['settledMs'];
  if (settled is! num) return null;
  int? since;
  int? through;
  final active = raw['active'];
  if (active != null) {
    // `active` 存在就等于"有一个未结束的轮次"（`projection.ts:37`），
    // 两个时间戳缺一个就没法算 —— 整条当成认不出，而不是降级成 `settledMs`
    // （那会把一段真实的活跃时间说成没有）。
    if (active is! Map) return null;
    final s = active['since'];
    final t = active['through'];
    if (s is! num || t is! num) return null;
    since = s.toInt();
    through = t.toInt();
  }
  return SubagentTiming(
    settledMs: settled.toInt(),
    activeSince: since,
    activeThrough: through,
    lastTurnCompleted: raw['lastTurnCompleted'] == true,
  );
}

/// 一份目录读取的结论：**内容 + 状态**。
///
/// 三态必须分开，否则"读到空"与"没读到"在界面上是同一句话 ——
/// 而它们下一步动作完全不同（等一秒 vs 点重试）。判据照 Web
/// （`SubagentHeaderLineage.tsx:196-198,212-234`）：
///
/// - `loading` + 空 entries ⇒ 「正在加载子智能体…」；
/// - `error` ⇒ 「无法加载子智能体」+「重试」；
/// - `ready` + 空 entries ⇒ **已知空叶**（`isKnownLeaf`），空态；
/// - `loading` 但**有** entries ⇒ 保留旧内容（刷新不闪空）。
///
/// **不带错误文本**：读取失败的那句话是固定的（Web 的兜底也是
/// `t('load.error')`，`locales.ts:23`），而原始原因已经在
/// `AppModel.lastError` 里 —— 存两份就有"哪份更新"的问题。
class SubagentCatalog {
  const SubagentCatalog({required this.state, this.entries = const []});

  /// 还没读到过 / 正在读。Web 把 `idle` 与 `loading` 合并成同一个
  /// 可见状态（`SubagentHeaderLineage.tsx:465-467`：`idle` 且没有投影值
  /// ⇒ `'loading'`），这里照同一条。
  const SubagentCatalog.loading({this.entries = const []})
    : state = SubagentCatalogState.loading;

  const SubagentCatalog.ready(this.entries)
    : state = SubagentCatalogState.ready;

  const SubagentCatalog.failed()
    : state = SubagentCatalogState.error,
      entries = const [];

  final SubagentCatalogState state;
  final List<SubagentRow> entries;

  /// 这一层**成功读到且为空** —— 只有这时才敢说"它没有下级"。
  /// `loading` / `error` 都不是证据（`SubagentHeaderLineage.tsx:196-198`）。
  bool get isKnownLeaf =>
      state == SubagentCatalogState.ready && entries.isEmpty;

  /// 正在读且还没有内容（界面上那句「正在加载子智能体…」的判据）。
  bool get isLoadingEmpty =>
      state == SubagentCatalogState.loading && entries.isEmpty;
}

/// 目录三态。
enum SubagentCatalogState { loading, ready, error }

/// 目录一行 + 它此刻的运行态。
///
/// 不可变值类型：页面每次 `build` 从 `AppModel` 现算，不留第二份状态。
class SubagentNode {
  const SubagentNode({
    required this.row,
    this.running = false,
    this.timing,
    this.tokens,
    this.title,
  });

  /// 目录事实（id / createdAt / mode / label）。
  final SubagentRow row;

  /// 子会话**此刻**有没有轮次在跑（子会话自己 `session.list` 的 `running`）。
  final bool running;

  /// 子会话自己的计时投影；`null` = 电脑侧没给（老连接器 / 该会话还没轮次）。
  final SubagentTiming? timing;

  /// 子会话自己的 token 用量；`null` = 没给。
  final TokenUsage? tokens;

  /// 子会话自己的标题（`projections.values.title`，与侧栏同一个来源）。
  final String? title;

  String get id => row.id;

  bool get isExternal => row.isExternal;

  /// 活动态。判据照 Web（`SubagentHeaderLineage.tsx:250-256`）：
  /// 正在跑 ⇒ running；停了且最近一轮正常完成 ⇒ completed；否则 inactive。
  SubagentActivity get activity {
    if (running) return SubagentActivity.running;
    if (!row.isExternal && timing?.lastTurnCompleted == true) {
      return SubagentActivity.completed;
    }
    return SubagentActivity.inactive;
  }

  /// 活动态的词。**外部任务不显示** —— Web 的 `activity` 对 external 是
  /// `undefined`（`SubagentHeaderLineage.tsx:252`），第二行只留 `title · 外部任务`。
  String? get activityText {
    if (row.isExternal) return null;
    return switch (activity) {
      SubagentActivity.running => '正在运行',
      SubagentActivity.completed => '已完成',
      SubagentActivity.inactive => '当前未运行',
    };
  }

  /// 行的**详情行**：`title · mode · activity · 时长`。
  ///
  /// 内容与 Web 的第二行同源（`title · mode · activity`，`SubagentHeaderLineage.tsx:257-259`），
  /// 但**时长从右列搬到了这里** —— 见文件头「为什么右列只放一个数」。
  ///
  /// 空的段**整段不出现**（不留下 `· ·`）；全空时是空串。
  String detailLine(int now) => [
    if (title != null && title!.isNotEmpty) title!,
    row.modeText,
    // 列表元素用 null-aware element（`?x`）是安全的；
    // **map 里不要这么写**（键会取值的字符串形式，见 `tools.md`）。
    ?activityText,
    ?durationText(now),
  ].join(' · ');

  /// 四个互不重叠桶之和（Web `:66-74` 的 `tokenTotal`）。
  ///
  /// **全零当作没有**：投影对象存在但四桶全零 = "还没用"，摆一个 `0 tok`
  /// 是把"没有"说成"有、恰好是零"（本仓第八条教训的反面案例就是
  /// 输入框底下那个 `0 tok`，见 `memory.md` §八条教训 4）。
  int? get tokenTotal {
    final usage = tokens;
    if (usage == null) return null;
    final total = usage.grandTotal;
    return total == 0 ? null : total;
  }

  /// 行右上那行：`12.2K tok`（Web `tokens.total` = `{value} tok`）。
  String? get tokenText {
    final total = tokenTotal;
    if (total == null) return null;
    return '${formatTokenCount(total)} tok';
  }

  /// 活跃耗时（毫秒）；`null` = 电脑侧没给计时，**不拿本地时间凑**。
  int? durationMs(int now) => timing?.durationMs(running: running, now: now);

  /// 行右下那行：`1分05秒`。格式照 Web 的 `formatDuration`
  /// （`SubagentHeaderLineage.tsx:116-152` + `locales.ts:8-17`）。
  String? durationText(int now) {
    final ms = durationMs(now);
    return ms == null ? null : formatSubagentDuration(ms);
  }
}

/// 子智能体行的时长文字。
///
/// 与 `model/session_stats.dart` 的 `formatCompactDuration` **不是同一个**：
/// 那个是统计条 pill 的紧凑写法（`45.2秒` / `2分42秒`），这个是 DSH 子智能体
/// 目录的写法（整秒起步，按天/月/年降精度）——
/// `SubagentHeaderLineage.tsx:102-152` 的 `formatDuration`。
///
/// 模板逐字照 `ui-subagent/src/client/locales.ts:8-17`。
String formatSubagentDuration(int ms) {
  final totalSeconds = math.max(0, ms) ~/ 1000;
  final totalMinutes = totalSeconds ~/ 60;
  final totalHours = totalMinutes ~/ 60;
  final days = totalHours ~/ 24;
  final seconds = totalSeconds % 60;
  final minutes = totalMinutes % 60;
  final hours = totalHours % 24;
  final ss = seconds.toString().padLeft(2, '0');
  final mm = minutes.toString().padLeft(2, '0');
  if (days >= 365) {
    final years = days ~/ 365;
    final months = (days % 365) ~/ 30;
    return months == 0 ? '约$years年' : '约$years年$months个月';
  }
  if (days >= 30) {
    final months = days ~/ 30;
    final rest = days % 30;
    return rest == 0 ? '约$months个月' : '约$months个月$rest天';
  }
  if (days > 0) {
    return hours == 0 ? '$days天' : '$days天$hours小时';
  }
  if (totalHours > 0) return '$totalHours小时$mm分$ss秒';
  if (totalMinutes > 0) return '$totalMinutes分$ss秒';
  return '$totalSeconds秒';
}
