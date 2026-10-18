# Agent Note: 浅色主题（DSH 的 `:root` 套）+ 三档主题模式

Status: implemented

## Problem

真机反馈（2026-10-19，用户原话）："对了还有暗浅色主题设置"。

DSH 的 `design-platform.css` 一上来就有两套:**浅色是默认**(`:root`),
**深色是覆盖块**(`body[data-ds-dark-theme]`)。我们只落了深色那一套
(`DshColors` 是一堆 `static const`，`DshTheme.dark()` 是唯一实现) ——
于是浅色下整个 App 是"深色画在浅色底上"，图标与文字勉强能看，层级全丢。

## Decision

### 1. 两套色板，`DshColors` 保持 const

第一版想把 `DshColors` 改成 getter + 一个全局 `_brightness` 开关
（"引用点一行不改"）。**实测不可行**:全 App 有 250+ 处 `DshColors.x`,
其中不少在 `const` 上下文里（`const ColoredBox(color: DshColors.ctxSystem)`、
`const Divider(..., color: DshColors.layer2)`、
`const TextStyle(..., color: DshColors.labelCaption)`），改成 getter 后
**226 处编译错误**。

所以:`DshColors`(深色)保持 `static const` 不动,新增 `DshLightColors`(浅色,
同样是 const 类)。运行时用哪一套由 `DshColorTokens`(ThemeExtension)携带,
读法是 `context.dshColors`。

**ThemeExtension 而不是全局变量**:Flutter 官方给"随主题下发的数据"的缝
(`packages/flutter/lib/src/material/theme_data.dart:131`),它跟着 `ThemeData`
一起换,亮暗变化时自动重建 —— 不需要自己发通知,也不会有第二套真值源。

### 2. 三档模式 + 系统亮暗监听

照 DSH `ui-theme/src/theme-settings.ts` 的三档:**跟随系统 / 浅色 / 深色**。
"跟随系统"是默认(DSH 也是),因为它让手机夜间模式自动生效。

- `DshThemeMode` 枚举放 `theme/dsh_colors.dart`(它描述"用哪套色板",
  而色板就在那一层);
- `ThemeController`(`model/theme_mode.dart`)持真值:`mode`(用户的三档选择)
  与 `brightness`(当下生效的两值)**分开** —— 混成一个字段会逼调用方
  自己记"现在是不是在跟随",而系统在跟随档下随时会变;
- 系统亮暗经 `WidgetsBindingObserver.didChangePlatformBrightness` 进来
  (`widgets/binding.dart:346`)。**它不带参数**,新值要从 `PlatformDispatcher` 读;
- 显式选了浅/深时**忽略**系统变化(DSH 的 manual 优先)。

### 3. 浅色 token 逐字照 `:root`

| 组 | 浅色 | 深色 | 出处 |
|---|---|---|---|
| bg-base / layer-1/2/3 | **全是白** | 四层递进 | `:171-173` 三条都落 neutral-bluish-00 |
| label-primary | `#0F1115`(bluish-1000) | `#F9FAFB`(bluish-50) | `:222` / 深色块 |
| label-secondary | `#61666B`(bluish-**700**) | `#CFD3D6`(bluish-500) | `:223` / 深色块 |
| state-error | `#EC1313`(red-**600**) | `#F25A5A`(red-400) | `:250` / `:368` |
| state-idle | `#D4D4D4`(neutral-**300**) | `#545557`(neutral-600) | `:252` / `:370` |
| hover / active | `rgba(38,49,72,.06)` / `.10` | `rgba(38,49,72,.08)` / `.14` | `:213` / `:209-213` |
| code-diff-add/del | green/red @**8%** | @12% | `:242-243` / 深色块 |
| file-diff 四实底 | 浅色实底 | 深色实底 | `:244-249` |

**浅色不是深色的反转**:次要文字在白底上要**更暗**(700 vs 500)才分得出主次;
层级靠描边(`border-l1/l2/l3` = 4/10/12% 的黑)不靠底色,所以三个 layer 同值。

### 4. `model/` 层只 import `foundation`

`ThemeController` 第一版 import 了 material(为了 `ChangeNotifier`),
被 `core-no-platform-import` 规则当场拦下(`model/` 禁
`package:flutter/{services,widgets,material}.dart`,纯 Dart 单测要能写)。
`ChangeNotifier` 与 `Brightness` 都在 `flutter/foundation.dart` 里,
而 `foundation` **不在**那三者里 —— 换 import 即可,类一行不用改。

## Alternatives considered（否掉的）

- **`DshColors` 改 getter + 全局开关**(引用点零改动):226 处 const 编译错误,
  见上。否。
- **`DshColors.of(context)` 抽象类**:每处引用都要改,而且
  `DshColors.border(0.06)` 带参的、`DshTheme.mono` 跨文件的都要动 ——
  一次动上百个文件的 diff,回归面太大。否。
- **只做"跟随系统 + 深色"两档**:DSH 是三档,少一档就让"手动锁浅色"
  (比如白天户外)做不到。否。
- **`ColorScheme.fromSeed` 生成浅色**:那会得到一套 Material 默认色,
  与 DSH 的 token 无关 —— 我们要的是"和电脑上一样",不是"看起来还行"。否。

## Consequences

- 收益:浅色主题首次可用;三档与 DSH 一致;切换即时(ThemeData 换 +
  ThemeExtension 跟着换)。
- 代价:`DshColorTokens` 是同一组 token 的**第三份列举**(38 个字段),
  但它只做"选一套"这一件事,每个值取自两个 const 类之一 —— 核对 DSH 源码时
  仍然只有两处。`copyWith` / `lerp` 的签名被基类约束
  (`ThemeExtension<T> copyWith()`,`lerp(covariant ThemeExtension<T>?)`),
  `copyWith` 因此返回 `ThemeExtension<DshColorTokens>` 而非具体类型。
- `lerp` **不做逐色插值**:亮暗切换是"换套"不是渐变,逐个 `Color.lerp`
  会在中途产生一堆两套都不是的颜色(发灰的层级),DSH 也是瞬时切
  (`boot-theme.ts` 直接改 data 属性)。过半就整体换。
- `DshTheme.mono` 仍是 const(深色版):它的调用点全在 const 上下文里。
  浅色下的等宽文字色由 `DshColorTokens` 的调用方自己给。
- 测试:`theme_mode_test.dart` 17 项(三档解析 / 盘上读回 / 系统变化 /
  切模式 / 浅色 token 不是反转 / 两个 ThemeData 都挂扩展)。
- **未做**:UI 的 250 处 `DshColors.x` 仍读深色常量。浅色下这些位置
  **不会跟着变**(它们绕过了 ThemeExtension)。要全量迁移到
  `context.dshColors`,那是独立一批(逐面迁 + 每面截图对比)。
