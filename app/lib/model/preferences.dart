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

/// 正文基准字号的范围与默认值 —— 照 DSH 的 `fontSize` 设置
/// （`packages/client/ui-theme/src/theme-settings.ts:24-30`：整数 10–22、默认 14）。
///
/// 常量放在这里（纯 Dart）而不是 `theme/dsh_type.dart`：`data/app_model.dart`
/// 要读它，而 `theme/` 那个文件依赖 `package:flutter/widgets.dart` ——
/// `data/` 层不许 import widgets（`app-platform-boundaries.md` 的
/// `core-no-platform-import`）。
const int kContentFontSizeMin = 10;
const int kContentFontSizeMax = 22;
const int kContentFontSizeDefault = 14;

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
