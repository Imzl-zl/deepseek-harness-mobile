/// 字号刻度 —— **base + delta**，不是整体缩放。
///
/// ## DSH 的规范（逐条出处）
///
/// `packages/client/ui-theme/src/styles/gradient-shadow-text.css:47-99`：
///
/// ```
/// --dsh-content-font-delta:            size - 14px
/// --dsh-content-font-size-secondary:   min(size - 1px, max(13px, size - 2px))
/// --dsh-content-font-delta-secondary:  secondary - 13px
/// --dsh-code-font-delta:               codeSize - 11px
/// h1 21/30 + delta · h2 19/28 + delta · h3 18/26 + delta · h4 = 正文 · 正文 size / 24+delta
/// ```
///
/// 设置本身是**一个整数 10–22、默认 14**（`ui-theme/src/theme-settings.ts:24-30`），
/// 写到 `body` 的 `--dsh-content-font-size`（`ui-theme/src/boot-theme.ts:30`）。
///
/// 三条**不许动**的边界：
///
/// 1. **只动"贴着内容"的那一维**：正文、标题阶梯、行高、贴着内容的缩进/图标。
///    caption 与小字**固定不跟 delta**（`:51-55` 的注释原话
///    "Small typography keeps a fixed size"）—— 手机侧同理：顶栏、按钮、徽标、
///    统计条这些 chrome 一律保持字面量。
/// 2. **代码字号是另一个设置**（10–16、默认 11，`:60-63`）。这一版没有做那个设置，
///    代码固定 11 —— 见 `docs/subsystems/type-scale.md`。
/// 3. **不许用 `MediaQuery.textScaler` 或全局 `Transform.scale`**：那会把图标、
///    间距、触达区一起放大 —— 正是"大了样式崩了"的成因。
///    字号只走这里，而且是**逐处**换成语义档位。
///
/// 默认档（size = 14）下本类的每个值都等于改造前手写的那个字面量
/// （正文 14/24、secondary 13/20、h1 21/30、h2 19/28、h3 18/26），
/// 所以"没改字号设置"的设备看到的是**同一套像素**。
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../model/preferences.dart';

/// 一套字号（由设置里的"字号大小"决定）。
@immutable
class DshType {
  const DshType(this.size);

  /// 正文基准（整数 px）。
  final int size;

  /// 设置的下界 / 上界 / 默认值（照 `theme-settings.ts:24-30`）。
  static const int minSize = kContentFontSizeMin;
  static const int maxSize = kContentFontSizeMax;
  static const int defaultSize = kContentFontSizeDefault;

  /// 默认那一档 —— 没有设置时的行为。
  static const DshType standard = DshType(defaultSize);

  /// 正文增量（px）。标题阶梯与行高都跟着它走。
  double get delta => (size - defaultSize).toDouble();

  // ---- 正文 ----
  double get body => size.toDouble();

  /// 正文行高：`calc(24px + delta)`（`:93-97`）。
  double get bodyLine => 24 + delta;

  // ---- secondary（流程行标题 / 工具名 / compact 正文）----
  ///
  /// `min(size - 1, max(13, size - 2))`：10→9 / 14→13 / 15→13 / 22→20（`:58`）。
  double get secondary => math.min(size - 1, math.max(13, size - 2)).toDouble();

  /// secondary 的相对增量（`:59`）。
  double get secondaryDelta => secondary - 13;

  /// secondary 行高：20 + 相对增量（DSH 的 compact 正文是 13/20，
  /// `ui-primitives/src/markdown/MarkdownText.module.css` 的 `.compact`）。
  double get secondaryLine => 20 + secondaryDelta;

  // ---- 标题阶梯（Markdown 的四档）----
  double get h1 => 21 + delta;
  double get h1Line => 30 + delta;
  double get h2 => 19 + delta;
  double get h2Line => 28 + delta;
  double get h3 => 18 + delta;
  double get h3Line => 26 + delta;

  /// h4 与正文同一档（只是字重不同，`:86-91`）。
  double get h4 => body;
  double get h4Line => bodyLine;

  /// 代码字号（另一个设置的另一半；这一版固定 11）。
  static const double code = 11;

  /// 与小字固定的 caption（不跟 delta）。
  static const double caption = 11;

  @override
  bool operator ==(Object other) => other is DshType && other.size == size;

  @override
  int get hashCode => size.hashCode;

  @override
  String toString() => 'DshType($size)';
}

/// 往整棵树上发当前字号。挂在 `MaterialApp.builder` 里一层。
///
/// 找不到（单测直接 pump 某个页面）时 [DshTypeScope.of] 回默认档 ——
/// 与 `DshShimmerHost` 同一条纪律：不挂也不崩，只是不缩放。
class DshTypeScope extends InheritedWidget {
  const DshTypeScope({super.key, required this.type, required super.child});

  final DshType type;

  static DshType of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<DshTypeScope>();
    return scope?.type ?? DshType.standard;
  }

  @override
  bool updateShouldNotify(DshTypeScope oldWidget) => oldWidget.type != type;
}

extension DshTypeContext on BuildContext {
  /// 当前字号刻度（没有 scope 时是默认档 14）。
  DshType get dshType => DshTypeScope.of(this);
}
