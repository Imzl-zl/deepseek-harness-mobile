/// 统计条用的三个只读投影值（`tokenUsage` / `sessionStats` / `contextPressure`）
/// 与上下文分段（`contextBreakdown`）。
///
/// ## 为什么单独一个文件
///
/// 这四个值**同一个来源**（`session.projections` 一次读回来），却在三个面上用：
/// 统计条、轨迹页头部、上下文环。放一处是为了让"字段名与 DSH 投影逐字对应"
/// 这条纪律只有一个落点 —— 各面自己抄一份字段名，投影一改就会静默漂移
/// （症状是"显示 0"而不是报错）。
///
/// ## 为什么都是值类型、都可为 null
///
/// `AppModel` 的 getter 在**认不出形状时返回 null**，界面显示空态。
/// 猜一个数字（比如默认 3%）就是把"看起来连着"当成"连着" ——
/// 2026-10-15 之前统计条正是写死的 `302K · 缓存 0%` 与 `3%`，
/// 用户无法分辨哪个是真的。
///
/// Note: 文案/合计/命中率与 Web 逐字一致的原因（含"部分命中绝不显示成
/// 100"那条）—— 见
/// .agents/notes/archived/2026-10-17-stats-bar-aligns-web-and-real-sheets.md
/// （该篇的 Wrap 布局部分已被
/// .agents/notes/implemented/2026-10-17-topbar-single-row-and-stats-scroll.md 取代）。
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

  /// 用量 pill 的合计（Web：`billedInputTokens + outputTokens`，
  /// `StatsPills.tsx:295`）—— **含输出**，与命中率的分母是两回事。
  int get grandTotal => billedInput + outputTokens;

  /// 人类可读的总量（`302K` / `1.2M`）。
  String get totalLabel => formatTokenCount(grandTotal);

  /// 缓存命中文字（`96` / `99.95`）。**算法与 Web 逐字一致**
  /// （`packages/client/ui-chat/src/client/chat/token-format.ts:67-97` 的
  /// `formatCacheHitPercent`）：整数四舍五入（.5 向上），而**部分命中绝不
  /// 显示成 100** —— 差一个 token 也是 99.9x。没有计费输入时 null。
  String? get cacheHitText =>
      formatCacheHitPercent(cacheReadTokens, billedInput);
}

/// 会话统计（DSH 的 `sessionStats` 投影）。
///
/// 字段与投影的 wire view 逐字对应
/// （`packages/session/session-stats/src/projection.ts:72-81`）：
/// `turns` / `steps` / `llmMs` / `toolMs` / `ttftMs` / `ttftSteps` /
/// `decodeMs` / `decodeTokens`。后两个是**输出速率**的唯一来源。
class SessionStats {
  const SessionStats({
    required this.turns,
    required this.steps,
    required this.llmMs,
    required this.toolMs,
    this.ttftMs = 0,
    this.ttftSteps = 0,
    this.decodeMs = 0,
    this.decodeTokens = 0,
  });

  final int turns;
  final int steps;

  /// 模型耗时（毫秒）。
  final int llmMs;

  /// 工具耗时（毫秒）。
  final int toolMs;

  /// 首 token 延迟总和（毫秒）—— TTFT 行的分子。
  final int ttftMs;

  /// 记录过 TTFT 的步数 —— TTFT 行的分母（Web 只在这 > 0 时显示那一行）。
  final int ttftSteps;

  /// 解码总耗时（毫秒）—— 速率的**分母**。
  final int decodeMs;

  /// 解码出的 token 总数 —— 速率的**分子**。
  final int decodeTokens;

  /// `N 轮 M 步`。**轮次为 0 时返回 null** —— 界面该显示空态，
  /// 而不是"0 轮 0 步"（那会让用户以为轮次没在数）。
  ///
  /// 与 Web 逐字一致：`t('stats.counts', {turns, steps})` = `{turns} 轮 {steps} 步`
  /// （`ui-chat/src/client/locale.ts:77`）。**没有「第」、两个数之间没有 `·`** ——
  /// 电脑端此刻显示的就是 `5 轮 73 步 · 77 tok/s`；这里多印一个「第」和一个
  /// 分隔点，同一个会话在两端就是两个字符串（2026-10-17 真机对照查出）。
  String? get turnLabel {
    if (turns <= 0) return null;
    return '$turns 轮 $steps 步';
  }

  /// 平均 TTFT（毫秒）；没有记录过就是 null。
  double? get averageTtftMs {
    if (ttftSteps <= 0 || ttftMs <= 0) return null;
    return ttftMs / ttftSteps;
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

/// 上下文三段分段（DSH 的 `contextBreakdown` 投影，wire view 就是这三项）。
///
/// `packages/llm/token-meter/src/breakdown-projection.ts:24-28,77-80`：
/// `{systemTokens, toolsTokens, messageTokens}`，**启发式**估算
/// （Web 的 `ContextMeter` 面板同样标着 `~`）。
class ContextBreakdown {
  const ContextBreakdown({
    required this.systemTokens,
    required this.toolsTokens,
    required this.messageTokens,
  });

  final int systemTokens;
  final int toolsTokens;
  final int messageTokens;

  int get total => systemTokens + toolsTokens + messageTokens;
}

// ---------------------------------------------------------------------------
// 格式化（与 Web 逐字一致的几个纯函数）
// ---------------------------------------------------------------------------

/// 把 token 数格式化成 `517` / `12.2K` / `517K` / `1.2M`。
///
/// **与 Web 的 `formatTokens` 逐字一致**
/// （`packages/client/ui-chat/src/client/chat/token-format.ts:9-15`）：
/// 小于 1K 原样；K/M 下**大于等于 100 取整、否则保留一位小数**。
/// 手机原来在 `[10K, 100K)` 区间直接取整，于是 `12.2K` 显示成 `12K` ——
/// 同一个会话两个端两个数。
///
/// **不放 `ui/`**：它在 `model/` 是领域规则（"多大算 K"），
/// 而 `ui/` 只负责摆位置。放 UI 里会让"同一个数两种写法"有出现的可能。
String formatTokenCount(int tokens) {
  if (tokens < 1000) return '$tokens';
  if (tokens < 1000000) return '${_scaled(tokens / 1000)}K';
  return '${_scaled(tokens / 1000000)}M';
}

/// Web 的 `scaled`：`>= 100` 取整，否则一位小数（`token-format.ts:10-11`）。
String _scaled(double candidate) {
  if (candidate >= 100) return '${candidate.round()}';
  return _trimZero((candidate * 10).round() / 10);
}

/// 紧凑时长：`45.2秒` / `2分42秒`。
///
/// 与 Web 的 `formatDuration` 同一条链
/// （`StatsPills.tsx:91-99` + `locale.ts:74-75` 的中文模板）。
String formatCompactDuration(int ms) {
  final s = ms / 1000;
  if (s < 60) {
    final rounded = (s * 10).round() / 10;
    return '${_trimZero(rounded)}秒';
  }
  final whole = s.round();
  final m = whole ~/ 60;
  final sec = whole % 60;
  return '$m分$sec秒';
}

/// 精确 token 数（千分位分组）：`12,480`。
///
/// 与 Web 的 `formatExactTokens` 一致
/// （`token-format.ts:23-30` + `locale.ts:73` 的 `number.groupSeparator` = `,`）。
/// 统计 sheet 里用它（pill 上用紧凑的 [formatTokenCount]）。
String formatExactTokens(int tokens) {
  final digits = tokens.abs().toString();
  final groups = <String>[];
  for (var end = digits.length; end > 0; end -= 3) {
    groups.insert(0, digits.substring(end - 3 < 0 ? 0 : end - 3, end));
  }
  final grouped = groups.join(',');
  return tokens < 0 ? '-$grouped' : grouped;
}

/// 输出速率数字（不带单位）：`75` / `4.2`。
///
/// 与 Web 的 `formatTokensPerSecond` 逐字一致
/// （`message-chrome.ts:71-74`）：**十个以上取整、十个以下一位小数**。
/// 手机原来一律 `.round()`，于是 4.2 tok/s 显示成 `4`。
String formatTokensPerSecond(double tps) {
  final clamped = tps < 0 ? 0 : tps;
  return clamped >= 10
      ? '${clamped.round()}'
      : _trimZero((clamped * 10).round() / 10);
}

/// 一位小数去掉 `.0`（`12.0` → `12`）。
String _trimZero(double v) {
  final text = v.toStringAsFixed(1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

/// 缓存命中百分比文字，**算法与 Web 逐字一致**。
///
/// 端口自 `packages/client/ui-chat/src/client/chat/token-format.ts:67-97`：
/// 整数百分比四舍五入（.5 向上），而**部分命中绝不四舍五入成 100** ——
/// 那会对用户说谎（"全命中了"其实差着 token 呢）。此时按需要补小数位，
/// 直到四舍五入后仍小于 100（`99.9` / `99.95` …）。
///
/// 没有 prompt 输入（分母 0）返回 null；全命中返回 `100`。
String? formatCacheHitPercent(int cacheReadTokens, int promptTokens) {
  if (promptTokens == 0) return null;
  final missedInputTokens = promptTokens - cacheReadTokens;
  if (missedInputTokens == 0) return '100';

  // 整数单位、四舍五入且 .5 向上：
  // floor((2*read*100 + denom) / (2*denom))。
  final units = (200 * cacheReadTokens + promptTokens) ~/ (2 * promptTokens);
  if (units < 100) return '$units';

  // 会进位成 100：补小数位直到它诚实。
  var distinguishingPlaces = 1;
  var scaledDoubleGap = missedInputTokens * 200;
  final denominatorTens = promptTokens ~/ 10;
  while (scaledDoubleGap <= denominatorTens) {
    scaledDoubleGap *= 10;
    distinguishingPlaces += 1;
  }
  final denominatorOnes = promptTokens % 10;
  var roundedLoss = 5;
  for (var loss = 1; loss < 5; loss += 1) {
    final factor = loss * 2 + 1;
    final threshold =
        factor * denominatorTens + (factor * denominatorOnes) ~/ 10;
    if (scaledDoubleGap <= threshold) {
      roundedLoss = loss;
      break;
    }
  }
  return '99.${'9' * (distinguishingPlaces - 1)}${10 - roundedLoss}';
}
