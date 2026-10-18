/// 主题模式与亮暗的真值（`model/theme_mode.dart`）。
///
/// ## 为什么是 ChangeNotifier
///
/// 亮暗变化要**全 App 重建**（`MaterialApp.theme` 要换），而 Flutter 官方
/// 给这条路的缝就是 `ValueNotifier` / `ChangeNotifier` + `ListenableBuilder`
/// （`packages/flutter/lib/src/widgets/framework.dart` 的 `ListenableBuilder`）。
/// 自己写事件总线会多一套会与它漂移的机制。
///
/// ## 三档而不是两档
///
/// 照 DSH `ui-theme/src/theme-settings.ts`：**跟随系统 / 浅色 / 深色**。
/// "跟随系统"是默认（DSH 也是），因为它让手机夜间模式自动生效 ——
/// 而我们没有理由比 DSH 少一档。
library;

// **只 import `foundation`，不 import material**：`ChangeNotifier` 与
// `Brightness` 都在 `flutter/foundation.dart` 里，而 `app-platform-boundaries.md`
// §1 的 `core-no-platform-import` 规则禁 `model/` 碰
// `package:flutter/{services,widgets,material}.dart`（纯 Dart 单测要能写）。
// `foundation` 不在那三者里，所以这条路是干净的。
import 'package:flutter/foundation.dart';

import '../theme/dsh_colors.dart';

/// 主题模式在盘上的键（偏好表用）。
const String kThemeModeKey = 'theme.mode';

/// 主题模式 + 当前亮暗的真值。
///
/// ## 两个字段分开的原因
///
/// [mode] 是**用户的选择**（三档，含"跟随系统"），[brightness] 是**当下生效的亮暗**
/// （两值）。混成一个字段会逼调用方自己记"现在是不是在跟随"，
/// 而系统在"跟随"档下随时会变（`WidgetsBindingObserver.didChangePlatformBrightness`）。
class ThemeController extends ChangeNotifier {
  ThemeController({DshThemeMode mode = DshThemeMode.system})
    : _mode = mode,
      _brightness = Brightness.dark;

  /// 从盘上恢复（读不到就"跟随系统"，与 DSH 默认一致）。
  ///
  /// [systemBrightness] 是启动时读到的系统亮暗：没有它时"跟随系统"无从解析，
  /// 于是先按深色兜底（DSH 的 `boot-theme.ts` 同样是先落一个再等系统通知）。
  factory ThemeController.restore(
    String? stored, {
    Brightness? systemBrightness,
  }) {
    final mode = DshThemeMode.fromWire(stored);
    return ThemeController(mode: mode)
      .._brightness = _brightnessOf(mode, systemBrightness ?? Brightness.dark);
  }

  DshThemeMode _mode;

  /// 用户的选择（三档）。
  DshThemeMode get mode => _mode;

  Brightness _brightness;

  /// 当下生效的亮暗（"跟随系统"档下它随系统变）。
  Brightness get brightness => _brightness;

  /// 落盘用的字面量（偏好表存这个）。
  String get wire => _mode.wire;

  /// 换模式。
  ///
  /// [systemBrightness] 只在 [DshThemeMode.system] 档用到（那一档没有自己的亮暗）。
  void setMode(DshThemeMode mode, {Brightness? systemBrightness}) {
    if (mode == _mode) return;
    _mode = mode;
    _brightness = _brightnessOf(mode, systemBrightness ?? _brightness);
    notifyListeners();
  }

  /// 一个模式在给定系统亮暗下**生效的亮暗**。
  ///
  /// "跟随系统"档没有自己的亮暗，用系统那个；浅/深两档用自己那个。
  static Brightness _brightnessOf(DshThemeMode mode, Brightness system) =>
      mode.brightness ?? system;

  /// 系统亮暗变了（只在"跟随系统"档有意义）。
  ///
  /// 非跟随档下**忽略**：用户显式选了浅/深，系统变化不该覆盖它
  /// （DSH 同一条：manual 优先于 system）。
  void onSystemBrightness(Brightness brightness) {
    if (_mode != DshThemeMode.system) return;
    if (brightness == _brightness) return;
    _brightness = brightness;
    notifyListeners();
  }
}

/// 三档各自的亮暗（"跟随系统"没有自己那一档，用 [ThemeController] 现解）。
extension DshThemeModeBrightness on DshThemeMode {
  Brightness? get brightness => switch (this) {
    DshThemeMode.system => null,
    DshThemeMode.light => Brightness.light,
    DshThemeMode.dark => Brightness.dark,
  };

  /// 设置页里那一行的文案（**同一套说法只有这一处**）。
  String get label => switch (this) {
    DshThemeMode.system => '跟随系统',
    DshThemeMode.light => '浅色',
    DshThemeMode.dark => '深色',
  };
}
