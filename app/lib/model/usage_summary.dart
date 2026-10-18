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

/// 一个会话在汇总榜上的一行。
class UsageEntry {
  const UsageEntry({
    required this.sid,
    required this.title,
    required this.tokens,
  });

  /// 会话别名（电脑侧分配的不透明 id，契约 §5.1）。
  final String sid;

  /// 标题。**可能为空串** —— 电脑侧取不到 `projections.values.title` 时给空，
  /// 界面按 DSH 的链退到「未命名」，不在这里兜一个目录名。
  final String title;

  /// 这个会话的 token 总量（> 0：全零的会话电脑侧已过滤掉）。
  final int tokens;
}

/// 跨会话用量汇总。
class UsageSummary {
  const UsageSummary({
    required this.sessions,
    required this.grandTotalTokens,
    required this.bySession,
  });

  /// 参与汇总的会话数（含全零的那些 —— "用了 0" 与 "没这项" 都不是"不存在"）。
  final int sessions;

  /// 全部会话的 token 总量。
  final int grandTotalTokens;

  /// 用量前 5 的会话（降序；全零的不在内）。
  final List<UsageEntry> bySession;

  /// 从电脑侧的载荷解析；**形状不认识就回 null**（调用方显示空态）。
  ///
  /// 期望形状（契约 §5.7 的 `usage.summary`）：
  /// `{sessions: int, grandTotalTokens: int, bySession: [{sid, title, tokens}]}`。
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
        entries.add(
          UsageEntry(
            sid: sid,
            title: title is String ? title : '',
            tokens: tokens,
          ),
        );
      }
    }
    return UsageSummary(
      sessions: sessions,
      grandTotalTokens: grandTotal,
      bySession: entries,
    );
  }

  /// 人类可读的总量（`302K` / `1.2M`）。
  ///
  /// **与单会话统计条同一个格式化函数**（`formatTokenCount`）——
  /// 两处各写一份会让"同一个数字在两地显示成两种样子"。
  String get totalLabel => formatTokenCount(grandTotalTokens);
}
