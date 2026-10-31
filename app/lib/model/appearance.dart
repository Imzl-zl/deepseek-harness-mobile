/// 背景与透明度（手机侧自有的外观扩展）。
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
/// ## 透明度就是透明度，不夹、不挡
///
/// 用户把表面调到多透明是用户的事：这里**没有下限**（`0%`..`100%` 全开），
/// 也**不叠遮罩**去"保可读性"。自作主张加下限或遮罩，等于替用户决定
/// "你的照片不够格当背景" —— 项目规则里那条"不新增宿主没有的边界"说的就是这件事。
///
/// ## 这一层只放纯值逻辑
///
/// 不 import `material`（`app-platform-boundaries.md` §1 的 `core-no-platform-import`），
/// 所以 `test/appearance_test.dart` 能用纯 Dart 跑。
library;

/// 完全不透明：表面实心，就是加这个功能之前的样子。
const int kTransparencyOpaque = 0;

/// 完全透明：表面一点底色都不留，只剩壁纸。
const int kTransparencyMax = 100;

/// 刚设好壁纸时的初始透明度。
///
/// **只当初始值**：不透明时壁纸整张被表面盖住，用户会以为"设了没反应"；
/// 给一个一眼看得见的值起步，之后想调到多少都是用户的自由（包括调回 0）。
const int kTransparencyOnWallpaper = 12;

/// 输入卡那块毛玻璃的模糊半径（逻辑像素）。
///
/// 只给小面积固定控件用（输入栏 / 底栏）。**全屏实时模糊不给**：手机上每帧
/// 对整窗口走一遍高斯，滚动必掉帧。
const double kGlassBlurSigma = 20.0;

/// 把透明度夹进合法区间（整数百分数）。
///
/// 这是**取值范围**，不是产品下限：`0` 与 `100` 两端都真的可用。
int clampTransparency(int percent) => percent.clamp(
  kTransparencyOpaque,
  kTransparencyMax,
);

/// 透明度 → 表面 alpha（`1.0` 不透明、`0.0` 全透）。
double surfaceAlphaOf(int transparencyPercent) =>
    1 - clampTransparency(transparencyPercent) / 100;

/// `100`（不透明）算不算"没开"。
bool isTransparencyOpaque(int transparencyPercent) =>
    clampTransparency(transparencyPercent) == kTransparencyOpaque;

/// 设置页那一行与滑杆右端的文案（**同一套说法只有这一处**）。
String transparencyLabel(int percent) => '${clampTransparency(percent)}%';
