/// 背景与通透度（手机侧自有的外观扩展）。
///
/// ## 为什么这是"有意偏离 DSH"
///
/// DSH 的外观只有三档（`跟随系统 / 浅色 / 深色`）加字号字体
/// （`packages/client/ui-theme/src/theme-settings.ts:9`），**没有背景图、没有透明度**。
/// 桌面上那点"通透"来自 macOS 窗口材质（`vibrancy: 'sidebar'` + 透明窗口，
/// `apps/desktop/renderer/assets/window-material.css:3`），是 Electron 窗口属性，
/// 不是主题能给的东西，Windows / 网页版也没有。
///
/// 手机上没有宿主材质可借，但整个界面是自己画的，于是"壁纸 + 表面半透明"
/// 可以自己做出来 —— 这是手机侧**新增**的一项外观偏好，不是搬 DSH 的设置项。
/// 取舍与代价见 `.agents/notes/implemented/2026-10-31-wallpaper-and-surface-alpha.md`。
///
/// ## 这一层只放纯值逻辑
///
/// 不 import `material`（`app-platform-boundaries.md` §1 的 `core-no-platform-import`），
/// 所以 `test/appearance_test.dart` 能用纯 Dart 跑：夹取、落盘值、文案、遮罩换算。
library;

/// 不通透：表面完全不透明，就是加这个功能之前的样子。
const double kSurfaceAlphaOpaque = 1.0;

/// 最通透的下限。
///
/// **不是 0**：表面 alpha 再低，卡片上的 `labelPrimary` 就直接压在壁纸上了 ——
/// 无论遮罩怎么加，深色字压浅色壁纸、或反过来，都会出现成片不可读的区域。
/// 0.55 是"看得透但不糊"的那条线（真机对过三张图：浅色风景 / 深色夜景 / 高对比街拍）。
const double kSurfaceAlphaMin = 0.55;

/// 刚设好壁纸时给的通透度。
///
/// **不这么做就是空操作**：表面不透明时壁纸整张被盖住，用户会以为"设了没反应"。
/// 0.88 是"一眼能看出换了背景、正文仍清晰"的那一档。
const double kSurfaceAlphaOnWallpaper = 0.88;

/// 壁纸之上遮罩的最大不透明度（通透度拉到最通透时）。
///
/// **遮罩是功能不是保险**：表面越透明，壁纸越"真"，文字对比就越差。
/// 遮罩随通透度反向增长，把最坏情况压回可读区间。
const double kScrimOpacityMax = 0.40;

/// 输入栏那块毛玻璃的模糊半径（逻辑像素）。
///
/// 只给小面积固定控件用（输入栏 / 底栏）。**全屏实时模糊不给**：手机上每帧
/// 对整窗口走一遍高斯，滚动必掉帧；壁纸本身保持清晰，观感并不差。
const double kGlassBlurSigma = 20.0;

/// 把通透度夹进合法区间。`NaN` 当"不通透"（盘上坏值不该把界面画没）。
double clampSurfaceAlpha(double value) {
  if (value.isNaN) return kSurfaceAlphaOpaque;
  return value.clamp(kSurfaceAlphaMin, kSurfaceAlphaOpaque);
}

/// 落盘用：整数百分数（55..100）。
///
/// 存整数而不是 `double.toString()`：偏好表里出现 `0.7000000000000001`
/// 这种尾巴时，下一次夹取会把 70% 读成 69%。
int surfaceAlphaToWire(double value) => (clampSurfaceAlpha(value) * 100).round();

/// 从盘上读回；`null`（没存过）等于"不通透"。
double surfaceAlphaFromWire(int? percent) {
  if (percent == null) return kSurfaceAlphaOpaque;
  return clampSurfaceAlpha(percent / 100);
}

/// 设置页那一行右端的文案（**同一套说法只有这一处**）。
String surfaceAlphaLabel(double value) {
  final alpha = clampSurfaceAlpha(value);
  if (alpha >= kSurfaceAlphaOpaque) return '关闭';
  return '${surfaceAlphaToWire(alpha)}%';
}

/// 遮罩不透明度：越通透，遮罩越重。
///
/// 线性：`关闭` → 0（表面本来就不透明，遮罩没有意义）；
/// `最通透` → [kScrimOpacityMax]。没有壁纸时调用方不该用它（没有东西可透）。
double scrimOpacityFor(double surfaceAlpha) {
  final alpha = clampSurfaceAlpha(surfaceAlpha);
  const span = kSurfaceAlphaOpaque - kSurfaceAlphaMin;
  return (kSurfaceAlphaOpaque - alpha) / span * kScrimOpacityMax;
}
