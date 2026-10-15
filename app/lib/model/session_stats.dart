/// 统计条用的三个只读投影值（`tokenUsage` / `sessionStats` / `contextPressure`）。
///
/// ## 为什么单独一个文件
///
/// 这三个值**同一个来源**（`session.projections` 一次读回来），却在三个面上用：
/// 统计条、轨迹页头部、上下文环。放一处是为了让"字段名与 DSH 投影逐字对应"
/// 这条纪律只有一个落点 —— 各面自己抄一份字段名，投影一改就会静默漂移
/// （症状是"显示 0"而不是报错）。
///
/// ## 为什么都是值类型、都可为 null
///
/// `AppModel` 的三个 getter 在**认不出形状时返回 null**，界面显示空态。
/// 猜一个数字（比如默认 3%）就是把"看起来连着"当成"连着" ——
/// 2026-10-15 之前统计条正是写死的 `302K · 缓存 0%` 与 `3%`，
/// 用户无法分辨哪个是真的。
library;

/// token 用量（DSH 的 `tokenUsage` 投影）。
class TokenUsage {
  const TokenUsage({
    required this.uncachedInputTokens,
    required this.outputTokens,
    required this.cacheReadTokens,
    required this.cacheWriteTokens,
  });

  final int uncachedInputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;

  /// 总输入（未缓存 + 缓存读 + 缓存写）。
  int get totalInput =>
      uncachedInputTokens + cacheReadTokens + cacheWriteTokens;

  /// **计费输入**：三个互不重叠的 prompt 侧桶之和。
  ///
  /// 与 Web 的 `billedInputTokens` 逐字一致
  /// （`packages/client/ui-chat/src/client/chat/StatsPills.tsx:118-120`）——
  /// 缓存命中率的分母是它，**不含输出**：输出不计入"输入侧命中"。
  /// 手机原来把 `outputTokens` 也算进分母，于是同一个会话在手机与 Web 上
  /// 显示两个不同的命中率（真机实测：手机 97% / Web 99%）。
  int get billedInput => totalInput;

  /// 缓存命中率（0..1）。**没有计费输入时是 null** —— 除零会得到 NaN，
  /// 而那会一路传到界面上显示成一个 `NaN%`。
  double? get cacheHitRate {
    final total = billedInput;
    if (total == 0) return null;
    return cacheReadTokens / total;
  }

  /// 人类可读的总量（`302K` / `1.2M`）。
  String get totalLabel => formatTokenCount(totalInput + outputTokens);
}

/// 会话统计（DSH 的 `sessionStats` 投影）。
///
/// 字段与投影的 `viewSchema` 逐字对应
/// （`packages/session/session-stats/src/projection.ts:72-81`）：
/// `turns` / `steps` / `llmMs` / `toolMs` / `ttftMs` / `ttftSteps` /
/// `decodeMs` / `decodeTokens`。后两个是**输出速率**的唯一来源。
class SessionStats {
  const SessionStats({
    required this.turns,
    required this.steps,
    required this.llmMs,
    required this.toolMs,
    this.decodeMs = 0,
    this.decodeTokens = 0,
  });

  final int turns;
  final int steps;

  /// 模型耗时（毫秒）。
  final int llmMs;

  /// 工具耗时（毫秒）。
  final int toolMs;

  /// 解码总耗时（毫秒）—— 速率的**分母**。
  final int decodeMs;

  /// 解码出的 token 总数 —— 速率的**分子**。
  final int decodeTokens;

  /// `第 N 轮 · M 步`。**轮次为 0 时返回 null** —— 界面该显示空态，
  /// 而不是"第 0 轮"（那会让用户以为轮次没在数）。
  String? get turnLabel {
    if (turns <= 0) return null;
    return '第 $turns 轮 · $steps 步';
  }

  /// 输出速率（tok/s）。**算法与 Web 逐字一致**：
  /// `decodeTokens / (decodeMs / 1000)`
  /// （`packages/client/ui-chat/src/client/chat/StatsPills.tsx:166-170`）。
  ///
  /// `decodeMs` 为 0（还没有任何一步解码完）时给 null —— 除零会得到
  /// `Infinity`，显示成 `Inf tok/s` 比不显示更糟。
  double? get tokensPerSecond {
    if (decodeMs <= 0 || decodeTokens <= 0) return null;
    return decodeTokens / (decodeMs / 1000);
  }
}

/// 上下文占用压力（DSH 的 `contextPressure` 投影）。
///
/// 字段与投影的 wire view 对应
/// （`packages/llm/token-meter/src/usage-projection.ts:67-75`）：
/// `pressureTokens?` / `projectedTokens?` / `contextWindow?`。
class ContextPressure {
  const ContextPressure({
    this.pressureTokens,
    this.projectedTokens,
    this.contextWindow,
  });

  final int? pressureTokens;
  final int? projectedTokens;

  /// 路由容量（分母）。**没有它就算不出百分比** —— 只给 token 数时
  /// "占了多少"是无解的问题。
  final int? contextWindow;

  /// 占用读数：百分比 + 用量 + 窗口。**算法与 Web 逐字一致**：
  /// `usedTokens = projectedTokens ?? pressureTokens`，
  /// `percent = min(100, round(used / window * 100))`
  /// （`packages/client/ui-conversation/src/client/context-occupancy.ts:15-25`）。
  ///
  /// 分子或分母任一缺失就是 `null`（Web 的 `ContextMeter` 同样此时不渲染）。
  ContextOccupancy? get occupancy {
    final used = projectedTokens ?? pressureTokens;
    final window = contextWindow;
    if (used == null || window == null || window <= 0) return null;
    final percent = (used / window * 100).round();
    return ContextOccupancy(
      percent: percent > 100 ? 100 : percent,
      usedTokens: used,
      contextWindow: window,
    );
  }
}

/// 上下文占用读数（照 Web 的 `ContextOccupancy`）。
class ContextOccupancy {
  const ContextOccupancy({
    required this.percent,
    required this.usedTokens,
    required this.contextWindow,
  });

  /// 0..100 的整数百分比。
  final int percent;

  /// 占用的 token 数（`projectedTokens` 优先）。
  final int usedTokens;

  /// 路由容量。
  final int contextWindow;
}

/// 把 token 数格式化成 `302K` / `1.2M`。
///
/// **不放 `ui/`**：它在 `model/` 是领域规则（"多大算 K"），
/// 而 `ui/` 只负责摆位置。放 UI 里会让"同一个数两种写法"有出现的可能。
String formatTokenCount(int tokens) {
  if (tokens < 1000) return '$tokens';
  if (tokens < 1_000_000) {
    final k = tokens / 1000;
    return k < 10 ? '${k.toStringAsFixed(1)}K' : '${k.round()}K';
  }
  final m = tokens / 1_000_000;
  return m < 10 ? '${m.toStringAsFixed(1)}M' : '${m.round()}M';
}
