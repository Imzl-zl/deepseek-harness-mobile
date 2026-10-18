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

/// DSH 主题（深 / 浅两套）。
///
/// 用系统 sans(iOS=PingFang、安卓=系统)保证中文字形,
/// 需要绝对一致时再在 pubspec 里绑定字体。
///
/// ## 两套而不是一套
///
/// DSH 的 `design-platform.css` 一上来就有两套:**浅色是默认**(`:root`),
/// **深色是覆盖块**(`body[data-ds-dark-theme]`)。我们原来只落了深色
/// (2026-10-19 之前 [dark] 是唯一实现),于是浅色下整个 App 是
/// "深色画在浅色底上" —— 图标与文字勉强能看,层级全丢。
abstract final class DshTheme {
  /// 深色（默认套）。
  static ThemeData dark() => _build(Brightness.dark);

  /// 浅色（色值见 `DshLightColors`，出处是 `design-platform.css` 的 `:root`）。
  static ThemeData light() => _build(Brightness.light);

  /// 按亮暗建主题。**色值不在这里写** —— 一律走两个色板类，
  /// 否则会出现第二套色值真值源。
  static ThemeData _build(Brightness brightness) {
    final base = brightness == Brightness.dark
        ? ThemeData.dark(useMaterial3: true)
        : ThemeData.light(useMaterial3: true);
    // **色板按亮暗选一个具名类**。两类的字段名逐字相同，
    // 所以下面的代码不用为每个字段写三元。
    final c = brightness == Brightness.dark
        ? const _DarkPalette()
        : const _LightPalette();
    // 只覆盖我们关心的那一组：其余（onSecondaryContainer 一类）
    // 由 `ThemeData.light/dark` 的 Material 3 默认给，我们不重造一套。
    final scheme = base.colorScheme.copyWith(
      brightness: brightness,
      surface: c.bgBase,
      onSurface: c.labelPrimary,
      primary: c.accentBlue,
      onPrimary: c.onAccent,
      secondary: c.businessBlue,
      error: c.error,
      outline: c.border(0.12),
    );

    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: c.bgBase,
      canvasColor: c.bgBase,
      dividerColor: c.border(0.06),
      // **色板扩展**：UI 经 `context.dshColors` 读当下那一套，
      // 亮暗变化时跟着 `ThemeData` 一起换，不需要自己发通知。
      extensions: <ThemeExtension<Object?>>[
        brightness == Brightness.dark
            ? const DshColorTokens.dark()
            : const DshColorTokens.light(),
      ],
      textTheme: _textTheme(base.textTheme, c),
      splashColor: c.active,
      highlightColor: c.hover,
    );
  }

  /// DSH 排版:body 13/20,次要 12/18,说明 11/14,标题 15 / 20 / 24。
  ///
  /// **两套共用**:排版不随亮暗变(变的只有颜色,而那些由色板给)。
  static TextTheme _textTheme(TextTheme b, _DshPalette c) => b.copyWith(
    bodyMedium: TextStyle(fontSize: 13, height: 20 / 13, color: c.labelPrimary),
    bodySmall: TextStyle(
      fontSize: 12,
      height: 18 / 12,
      color: c.labelSecondary,
    ),
    labelSmall: TextStyle(fontSize: 11, height: 14 / 11, color: c.labelCaption),
    titleSmall: TextStyle(
      fontSize: 13,
      height: 20 / 13,
      fontWeight: FontWeight.w500,
      color: c.labelPrimary,
    ),
    titleMedium: TextStyle(
      fontSize: 15,
      height: 20 / 15,
      fontWeight: FontWeight.w600,
      color: c.labelPrimary,
    ),
    titleLarge: TextStyle(
      fontSize: 20,
      height: 28 / 20,
      fontWeight: FontWeight.w500,
      color: c.labelPrimary,
    ),
  );

  /// 代码 / 工具参数用的等宽样式。
  ///
  /// **它仍然是 const（深色那一版）**：绝大多数调用点在深色下，
  /// 而 `DshTheme.mono` 的调用点全在 `const` 上下文里
  /// （`const TextStyle(...)` 的字段值）。浅色下的等宽文字色
  /// 由 [DshColorTokens] 的调用方自己给 —— 那一处本来就要按亮暗取色。
  static const TextStyle mono = TextStyle(
    fontFamily: 'SF Mono',
    fontFamilyFallback: dshMonoFallback,
    fontSize: 12,
    height: 19 / 12,
    color: DshColors.labelSecondary,
  );
}

/// 两个色板类的**共同读法**（字段名逐字相同，所以一个接口就够）。
///
/// 存在的理由：`DshColors` 与 `DshLightColors` 是两个无关的类，
/// 而 `_build` 不想为每个字段写 `brightness == dark ? … : …`（那是 38 个三元）。
/// 这两个实现只做转发，**不定义任何色值** —— 色值的唯一出处仍是两个色板类。
abstract class _DshPalette {
  Color get bgBase;
  Color get sidebar;
  Color get layer1;
  Color get layer2;
  Color get layer3;
  Color get menu;
  Color get labelPrimary;
  Color get labelSecondary;
  Color get labelTertiary;
  Color get labelCaption;
  Color get onAccent;
  Color get accentBlue;
  Color get businessBlue;
  Color get hover;
  Color get active;
  Color get stateBusinessTertiary;
  Color get labelPrimaryBluish;
  Color get roleContext;
  Color get roleContextBg;
  Color get roleAssistant;
  Color get roleTool;
  Color get roleToolBg;
  Color get error;
  Color get stateSuccess;
  Color get stateError;
  Color get stateIdle;
  Color get stateWarn;
  Color get ctxSystem;
  Color get ctxTools;
  Color get ctxMessages;
  Color get codeDiffAdd;
  Color get codeDiffDel;
  Color get fileDiffAddBg;
  Color get fileDiffAddMarker;
  Color get fileDiffDelBg;
  Color get fileDiffDelMarker;
  Color get fileDiffAddGutter;
  Color get fileDiffDelGutter;
  Color border([double alpha]);
}

class _DarkPalette implements _DshPalette {
  const _DarkPalette();
  @override
  Color get bgBase => DshColors.bgBase;
  @override
  Color get sidebar => DshColors.sidebar;
  @override
  Color get layer1 => DshColors.layer1;
  @override
  Color get layer2 => DshColors.layer2;
  @override
  Color get layer3 => DshColors.layer3;
  @override
  Color get menu => DshColors.menu;
  @override
  Color get labelPrimary => DshColors.labelPrimary;
  @override
  Color get labelSecondary => DshColors.labelSecondary;
  @override
  Color get labelTertiary => DshColors.labelTertiary;
  @override
  Color get labelCaption => DshColors.labelCaption;
  @override
  Color get onAccent => DshColors.onAccent;
  @override
  Color get accentBlue => DshColors.accentBlue;
  @override
  Color get businessBlue => DshColors.businessBlue;
  @override
  Color get hover => DshColors.hover;
  @override
  Color get active => DshColors.active;
  @override
  Color get stateBusinessTertiary => DshColors.stateBusinessTertiary;
  @override
  Color get labelPrimaryBluish => DshColors.labelPrimaryBluish;
  @override
  Color get roleContext => DshColors.roleContext;
  @override
  Color get roleContextBg => DshColors.roleContextBg;
  @override
  Color get roleAssistant => DshColors.roleAssistant;
  @override
  Color get roleTool => DshColors.roleTool;
  @override
  Color get roleToolBg => DshColors.roleToolBg;
  @override
  Color get error => DshColors.error;
  @override
  Color get stateSuccess => DshColors.stateSuccess;
  @override
  Color get stateError => DshColors.stateError;
  @override
  Color get stateIdle => DshColors.stateIdle;
  @override
  Color get stateWarn => DshColors.stateWarn;
  @override
  Color get ctxSystem => DshColors.ctxSystem;
  @override
  Color get ctxTools => DshColors.ctxTools;
  @override
  Color get ctxMessages => DshColors.ctxMessages;
  @override
  Color get codeDiffAdd => DshColors.codeDiffAdd;
  @override
  Color get codeDiffDel => DshColors.codeDiffDel;
  @override
  Color get fileDiffAddBg => DshColors.fileDiffAddBg;
  @override
  Color get fileDiffAddMarker => DshColors.fileDiffAddMarker;
  @override
  Color get fileDiffDelBg => DshColors.fileDiffDelBg;
  @override
  Color get fileDiffDelMarker => DshColors.fileDiffDelMarker;
  @override
  Color get fileDiffAddGutter => DshColors.fileDiffAddGutter;
  @override
  Color get fileDiffDelGutter => DshColors.fileDiffDelGutter;
  @override
  Color border([double alpha = 0.12]) => DshColors.border(alpha);
}

class _LightPalette implements _DshPalette {
  const _LightPalette();
  @override
  Color get bgBase => DshLightColors.bgBase;
  @override
  Color get sidebar => DshLightColors.sidebar;
  @override
  Color get layer1 => DshLightColors.layer1;
  @override
  Color get layer2 => DshLightColors.layer2;
  @override
  Color get layer3 => DshLightColors.layer3;
  @override
  Color get menu => DshLightColors.menu;
  @override
  Color get labelPrimary => DshLightColors.labelPrimary;
  @override
  Color get labelSecondary => DshLightColors.labelSecondary;
  @override
  Color get labelTertiary => DshLightColors.labelTertiary;
  @override
  Color get labelCaption => DshLightColors.labelCaption;
  @override
  Color get onAccent => DshLightColors.onAccent;
  @override
  Color get accentBlue => DshLightColors.accentBlue;
  @override
  Color get businessBlue => DshLightColors.businessBlue;
  @override
  Color get hover => DshLightColors.hover;
  @override
  Color get active => DshLightColors.active;
  @override
  Color get stateBusinessTertiary => DshLightColors.stateBusinessTertiary;
  @override
  Color get labelPrimaryBluish => DshLightColors.labelPrimaryBluish;
  @override
  Color get roleContext => DshLightColors.roleContext;
  @override
  Color get roleContextBg => DshLightColors.roleContextBg;
  @override
  Color get roleAssistant => DshLightColors.roleAssistant;
  @override
  Color get roleTool => DshLightColors.roleTool;
  @override
  Color get roleToolBg => DshLightColors.roleToolBg;
  @override
  Color get error => DshLightColors.error;
  @override
  Color get stateSuccess => DshLightColors.stateSuccess;
  @override
  Color get stateError => DshLightColors.stateError;
  @override
  Color get stateIdle => DshLightColors.stateIdle;
  @override
  Color get stateWarn => DshLightColors.stateWarn;
  @override
  Color get ctxSystem => DshLightColors.ctxSystem;
  @override
  Color get ctxTools => DshLightColors.ctxTools;
  @override
  Color get ctxMessages => DshLightColors.ctxMessages;
  @override
  Color get codeDiffAdd => DshLightColors.codeDiffAdd;
  @override
  Color get codeDiffDel => DshLightColors.codeDiffDel;
  @override
  Color get fileDiffAddBg => DshLightColors.fileDiffAddBg;
  @override
  Color get fileDiffAddMarker => DshLightColors.fileDiffAddMarker;
  @override
  Color get fileDiffDelBg => DshLightColors.fileDiffDelBg;
  @override
  Color get fileDiffDelMarker => DshLightColors.fileDiffDelMarker;
  @override
  Color get fileDiffAddGutter => DshLightColors.fileDiffAddGutter;
  @override
  Color get fileDiffDelGutter => DshLightColors.fileDiffDelGutter;
  @override
  Color border([double alpha = 0.12]) => DshLightColors.border(alpha);
}
