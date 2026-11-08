/// **跨会话用量面**（`usage.summary`，只读）的唯一入口。
///
/// 形状出处 `connector/src/handlers.ts` 的 `usage.summary`：应答是
/// `{totals: {uncachedInputTokens, outputTokens, cacheReadTokens, cacheWriteTokens},
/// byDay?: [{date, turns, tokens}], bySession: [...], byProject: [...], grandTotal}` ——
/// 逐字段解析在 `model/usage_summary.dart` 的 `UsageSummary.fromWire`。
///
/// **它不是 DSH 的投影**：DSH 的 `tokenUsage` 是单会话的，跨会话汇总由连接器自己遍历
/// `visible` 会话聚出来（连接器那一段的注释记着"为什么不本地记账"）。
/// 所以这里只负责调用与"读不出来要响"，聚合规则不在这层。
///
/// Note: 布局与批次见 `.agents/notes/implemented/2026-10-25-wire-rpc-layer-layout.md`。
library;

import '../../core/sync_client.dart';
import '../../model/usage_summary.dart' show UsageSummary;
import '../reading.dart';

/// 消费方拿齐"三态内核 + 用量面解码"。
export '../reading.dart';

const String _kSummary = 'usage.summary';

/// 拉一次跨会话用量汇总（只读、不落盘：它是"此刻的总量"）。
///
/// [days] 是**按天活动的窗口**：给了才返回 `byDay`，且只覆盖这段时间。
/// 不给时响应里没有 `byDay` 键 —— 总量走清单行的投影提示（一次往返），
/// 按天活动要读每个会话的 `trajectory`（日志），必须按需、按窗口来
/// （`connector/src/handlers.ts` 的 `usage.summary`）。
///
/// 读不出来 ⇒ `null` + 计数一次；调用方显示"拉不到"，**不摆一个 `0 tok`**
/// ——那会把"没数据"说成"用了 0"。
Future<UsageSummary?> loadUsageSummary(SyncClient client, {int? days}) async {
  final result = await client.call<Object?>(_kSummary, {
    // 显式 `if`（不是 null-aware element）：后者会把 key 展开成值的字符串形式。
    // ignore: use_null_aware_elements
    if (days != null) 'days': days,
  });
  return valueOrReport(readUsageSummary(result), _kSummary);
}

/// `usage.summary` 的应答 → [UsageSummary]。
///
/// 形状规则在 `model/usage_summary.dart`（与 `parseTokenUsage` 同一条：
/// 值解析住 `model/`）；这里只负责"读不出来要响"。
WireReading<UsageSummary> readUsageSummary(Object? result) {
  final summary = UsageSummary.fromWire(result);
  if (summary == null) {
    return const WireBad('应答认不出（`usage.summary`）');
  }
  return WireOk(summary);
}
