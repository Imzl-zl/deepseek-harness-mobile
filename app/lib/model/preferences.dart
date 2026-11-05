/// 手机本地的界面偏好（DSH 的"纯 UI 偏好"在**手机侧落地**，是有意偏离）。
///
/// ## 为什么存在这个文件
///
/// DSH 把外观/字号/工作步骤展示/性能与用量这些偏好存在**电脑上**
/// （Host user-settings，`docs/settings-porting-notes.md` §7.1 有逐条出处），
/// 目的是跨浏览器跟随。手机端**改存本地**：这些偏好只影响这台手机的呈现，
/// 下发到电脑既无意义也会和电脑上的设置互相覆盖。这是设计文档写明了的
/// **有意偏离**，不是漏做。
///
/// 持久化走 `meta` 表（`AppModel` 的 `PreferenceStore` 缝）—— 与发送模式
/// 同一条路（`kSendModeKey`）。
library;

// 字号的值域（正文基准范围 + App 内四档倍率）住在 `core/type_scale.dart`：
// 它被 `theme/`（换算）、`data/`（读盘 clamp）与 `ui/`（设置行）三层同时读，
// 而 `theme/` 依赖 widgets、`data/` 又不许 import 它 —— `core/` 是唯一的共同底。
// 本文件只放**偏好本身**（枚举与键名），不放值域。

/// 工作步骤展示密度（DSH `settings.transcript`，四档）。
///
/// 文案照 DSH：`简洁` / `标准` / `详细` / `完全展开`
/// （`ui-chat/src/client/locale.ts:103-108`）。
enum TranscriptView {
  /// 只看结论，工具调用折叠成一行。
  compact('简洁'),

  /// 默认密度：工具调用折叠、可展开。
  standard('标准'),

  /// 运行中的轮次直接展开工具明细。
  detailed('详细'),

  /// 一律展开工具明细。
  fullyOpen('完全展开');

  const TranscriptView(this.label);

  final String label;

  /// 盘上的值 → 枚举；认不出返回 null（调用方保持默认，不猜）。
  static TranscriptView? fromWire(String? wire) => switch (wire) {
    'compact' => TranscriptView.compact,
    'standard' => TranscriptView.standard,
    'detailed' => TranscriptView.detailed,
    'fully-open' => TranscriptView.fullyOpen,
    _ => null,
  };

  String get wire => switch (this) {
    TranscriptView.compact => 'compact',
    TranscriptView.standard => 'standard',
    TranscriptView.detailed => 'detailed',
    TranscriptView.fullyOpen => 'fully-open',
  };
}

/// 工作步骤**收起时机**（DSH `ui-chat.collapseTiming`，两档）。
///
/// 文案照 DSH：`回答结束后` / `下次有新消息时`
/// （`packages/client/ui-chat/src/chat-settings.ts:15,21`，默认 `completion`）。
///
/// **它只在有轮组之后才有语义**：说的是"一轮收口之后，那一轮的过程什么时候收起来"。
/// 见 `docs/subsystems/turn-groups.md`。
enum CollapseTiming {
  /// 轮次一收口就收起（默认）。
  completion('回答结束后'),

  /// 收口后仍展开，直到用户发了下一句（那时它变成"上一轮"）。
  nextInput('下次有新消息时');

  const CollapseTiming(this.label);

  final String label;

  /// 盘上的值 → 枚举；认不出返回 null（调用方保持默认，不猜）。
  static CollapseTiming? fromWire(String? wire) => switch (wire) {
    'completion' => CollapseTiming.completion,
    'next-input' => CollapseTiming.nextInput,
    _ => null,
  };

  String get wire => switch (this) {
    CollapseTiming.completion => 'completion',
    CollapseTiming.nextInput => 'next-input',
  };
}

/// 性能与用量信息的详细程度（DSH `settings.performance`，二档）。
///
/// `简洁` 时统计 pill 只留**输出速率与缓存命中**两个读数（照 Web 的
/// `usePerformanceUsage === 'compact'`，`StatsPills.tsx:242,291-293`）；
/// `详细` 时才有轮次步数、合计与可点开的浮层。
enum PerformanceUsage {
  compact('简洁'),
  detailed('详细');

  const PerformanceUsage(this.label);

  final String label;

  static PerformanceUsage? fromWire(String? wire) => switch (wire) {
    'compact' => PerformanceUsage.compact,
    'detailed' => PerformanceUsage.detailed,
    _ => null,
  };

  String get wire => name;
}
