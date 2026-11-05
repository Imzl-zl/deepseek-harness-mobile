/// 字号的值域：**正文基准范围**与**App 内的四档倍率**。
///
/// ## 为什么在 `core/`（而不是 `model/preferences.dart` 或 `theme/`）
///
/// 这几个数被**三层同时读**，而它们必须只有一个拼写处：
///
/// | 读者 | 读来做什么 |
/// |---|---|
/// | `theme/dsh_type.dart` | 字号换算的下界 / 上界 / 默认值 |
/// | `data/app_model.dart` | 读盘时把档位下标 clamp 进合法区间 |
/// | `ui/settings_page.dart` | 设置行的四档名字与百分比标签 |
///
/// `theme/` 依赖 `package:flutter/widgets.dart`，而 `data/` 不许 import widgets
/// （`app-platform-boundaries.md` 的 `core-no-platform-import`）⇒ 两边都不能当对方的家。
/// `core/` 是唯一同时被它们依赖、又零平台依赖的一层，所以值域住这里；
/// **文案与档位一一对应，分开就会漂移**（`type_scale_test.dart` 钉着长度相等），所以名字也一起放。
///
/// 倍率而不是 px 的三条理由（两层字号相乘、等比不改变对比关系、与 `TextScaler` 同一条机制）
/// 见 `.agents/notes/implemented/2026-10-22-type-scale-two-layers.md`。
library;

/// 正文基准字号的范围与默认值 —— 照 DSH 的 `fontSize` 设置
/// （`packages/client/ui-theme/src/theme-settings.ts:24-30`：整数 10–22、默认 14）。
const int kContentFontSizeMin = 10;
const int kContentFontSizeMax = 22;
const int kContentFontSizeDefault = 14;

/// **界面字号**档位（App 内的倍率，叠在系统字号之上）。
///
/// 上限 1.3 是实测定的：系统 1.5 时顶栏标题已开始省略、输入框占 1/5 屏；
/// 1.3 在有工具卡 / 代码块 / diff 的会话上仍然舒服（`shots-2026-10-22/sc-1_3-session.png`）。
/// 与系统字号叠加后再整体 clamp 到 2.0（系统 2.0 实测不溢出，只是挤）。
const List<double> kUiScaleSteps = <double>[0.9, 1.0, 1.15, 1.3];

/// 四档的名字（设置行直接用它）。
const List<String> kUiScaleLabels = <String>['较小', '标准', '较大', '特大'];

/// 默认档的下标（`1.0`）。
const int kUiScaleDefaultIndex = 1;
