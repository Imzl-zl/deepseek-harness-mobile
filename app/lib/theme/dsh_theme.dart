import 'package:flutter/material.dart';

import 'dsh_colors.dart';

/// DSH 圆角刻度(base.css)。
abstract final class DshRadius {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const panel = 28.0;
}

/// 等宽字体回退栈(代码 / 工具参数)。对应 DSH `--ds-font-family-code`。
/// 若要精确一致,把 JetBrains Mono 打进 pubspec 的 fonts。
const List<String> dshMonoFallback = <String>[
  'SF Mono',
  'JetBrains Mono',
  'Fira Code',
  'Consolas',
  'Menlo',
  'PingFang SC',
];

/// DSH 深色主题。用系统 sans(iOS=PingFang、安卓=系统)保证中文字形,
/// 需要绝对一致时再在 pubspec 里绑定字体。
abstract final class DshTheme {
  static ThemeData dark() {
    final base = ThemeData.dark(useMaterial3: true);
    const scheme = ColorScheme.dark(
      surface: DshColors.bgBase,
      onSurface: DshColors.labelPrimary,
      primary: DshColors.accentBlue,
      onPrimary: DshColors.onAccent,
      secondary: DshColors.businessBlue,
      error: DshColors.error,
      outline: Color(0x1FFFFFFF),
    );

    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: DshColors.bgBase,
      canvasColor: DshColors.bgBase,
      dividerColor: DshColors.border(0.06),
      textTheme: _textTheme(base.textTheme),
      splashColor: DshColors.active,
      highlightColor: DshColors.hover,
    );
  }

  /// DSH 排版:body 13/20,次要 12/18,说明 11/14,标题 15 / 20 / 24。
  static TextTheme _textTheme(TextTheme b) => b.copyWith(
    bodyMedium: const TextStyle(
      fontSize: 13,
      height: 20 / 13,
      color: DshColors.labelPrimary,
    ),
    bodySmall: const TextStyle(
      fontSize: 12,
      height: 18 / 12,
      color: DshColors.labelSecondary,
    ),
    labelSmall: const TextStyle(
      fontSize: 11,
      height: 14 / 11,
      color: DshColors.labelCaption,
    ),
    titleSmall: const TextStyle(
      fontSize: 13,
      height: 20 / 13,
      fontWeight: FontWeight.w500,
      color: DshColors.labelPrimary,
    ),
    titleMedium: const TextStyle(
      fontSize: 15,
      height: 20 / 15,
      fontWeight: FontWeight.w600,
      color: DshColors.labelPrimary,
    ),
    titleLarge: const TextStyle(
      fontSize: 20,
      height: 28 / 20,
      fontWeight: FontWeight.w500,
      color: DshColors.labelPrimary,
    ),
  );

  /// 代码 / 工具参数用的等宽样式。
  static const TextStyle mono = TextStyle(
    fontFamily: 'SF Mono',
    fontFamilyFallback: dshMonoFallback,
    fontSize: 12,
    height: 19 / 12,
    color: DshColors.labelSecondary,
  );
}
