import 'package:flutter/material.dart';

/// DSH 色板（**深色**，默认套）。
///
/// 抽自 `deepseek-harness/packages/client/ui-theme` 的
/// `design-platform.css` 的 `body[data-ds-dark-theme]` 覆盖块。
/// 改动前先核对源码 token，不要凭感觉调色。
///
/// ## 为什么这些还是 `static const`
///
/// 全 App 有 250+ 处 `DshColors.x`，其中不少在 `const` 上下文里
/// （`const ColoredBox(color: DshColors.ctxSystem)`、
/// `const Divider(..., color: DshColors.layer2)`、
/// `const TextStyle(..., color: DshColors.labelCaption)`）。
/// 把它们整体改成 getter 会让这些 `const` 全部编译失败
/// （2026-10-19 实测：226 处 error）。
/// 所以**这一套保持 const** —— 它是深色，也是默认套。
///
/// 浅色套是 [DshLightColors]；运行时按亮暗取哪一套见 [DshColorTokens]
/// （ThemeExtension，读法是 `context.dshColors`）。
abstract final class DshColors {
  // ---- 背景层 ----
  static const bgBase = Color(0xFF151517); // 根背景 bg-base
  static const sidebar = Color(0xFF1B1B1C); // 侧栏
  static const layer1 = Color(0xFF232324); // 卡片/面板/主表面 bg-layer-1
  static const layer2 = Color(0xFF2C2C2E); // 抬升 bg-layer-2
  static const layer3 = Color(0xFF353638); // 最高/中性 chip bg-layer-3
  static const menu = Color(0xFF43454A); // 浮层/菜单(不透明近似)
  /// 用户消息气泡（`--dsw-specific-bubble`，暗色 = neutral-bluish-850）。
  ///
  /// **不能拿 `layer3` 顶**：浅色主题里 `layer3` 与 `bgBase` **同为纯白**
  /// （见 `DshLightColors` 的说明），气泡会与页面背景同色、完全看不见 ——
  /// 2026-10-19 真机反馈"用户消息我刚开始一直以为渲染问题"。
  /// DSH 因此有**专用**的一个 token（`design-platform.css:386`）。
  static const bubble = Color(0xFF2C2C2E); // neutral-bluish-850

  /// 输入栏卡片的底色（`--dsw-specific-input-major`，暗色 = neutral-bluish-850）。
  ///
  /// DSH 的输入栏用的是**专用** token（`design-platform.css:387`），
  /// 不是 `bg-layer-1` —— 因为它要"浮在会话之上"，与页面底色是两个角色。
  static const composer = Color(0xFF2C2C2E); // neutral-bluish-850

  /// 描边第 2 档（`--dsw-alias-border-l2`，暗色 = 白 12%）。
  ///
  /// 输入栏卡片的 0.5px 发丝环用它（`InputBar.module.css:60` 的
  /// `--dsw-elevation-stroke-color: var(--dsw-alias-border-l2)`）。
  static const borderL2 = Color(0x1FFFFFFF); // rgba(255,255,255,0.12)

  // ---- 文字 ----
  static const labelPrimary = Color(0xFFF9FAFB);
  static const labelSecondary = Color(0xFFCFD3D6);
  static const labelTertiary = Color(0xFFADB2B8);
  static const labelCaption = Color(0xFF81858C);
  static const onAccent = Color(0xFF0F1115); // accent 填充上的文字

  // ---- 强调 / 交互 ----
  static const accentBlue = Color(0xFF5686FE);
  static const businessBlue = Color(0xFF7AAAFF);
  static const hover = Color(0x14FFFFFF); // 白 ~8%
  static const active = Color(0x24FFFFFF); // 白 ~14%

  // ---- 新会话页（hero）用到的两个 token ----
  //
  // 「预览版」徽标（`HeroShell.module.css:62-76`）的底色与文字色。
  // 两者都是**别名 token**，暗色块里的解析链是
  // `--dsw-alias-state-business-tertiary → --dsw-static-deepseek-800 = rgb(52, 65, 91)`
  // （`design-platform.css:359` → `:32/:113`）与
  // `--dsw-alias-label-primary-bluish → --dsw-static-neutral-bluish-50 = rgb(249, 250, 251)`
  // （`:336` → `:64/:145`）。
  //
  // `labelPrimaryBluish` 与上面的 `labelPrimary` **同值不同 token** ——
  // 与 `roleContext` / `stateSuccess` 那一对同一个道理：DSH 换掉其中一个时，
  // 另一个不该跟着变。徽标的描边用 `interactive-bg-hover`，暗色块里就是
  // `rgba(255,255,255,0.08)`（`:331`），即上面的 `hover`，所以不再复制一份。
  static const stateBusinessTertiary = Color(0xFF34415B);
  static const labelPrimaryBluish = Color(0xFFF9FAFB);

  // ---- 角色 / 徽标(时间线)----
  static const roleContext = Color(0xFF22C55E);
  static const roleContextBg = Color(0xFF233C2C);
  static const roleAssistant = Color(
    0xFF9E7BAA,
  ); // ≈ lerp(accentBlue, error, .4)
  static const roleTool = Color(0xFFDD8629);
  static const roleToolBg = Color(0xFF27241F);
  static const error = Color(0xFFF25A5A);

  // ---- 状态点(照 DSH `ui-primitives` 的 `StateDot`)----
  //
  // 三个 token 取暗色块(`design-platform.css` 的 `body[data-ds-dark-theme]`,:284 起):
  // `--dsw-alias-state-success-primary`=green-500(:371)、
  // `--dsw-alias-state-error-primary`=red-400(:368)、
  // `--dsw-alias-state-idle-primary`=neutral-600(:370)。
  // `ongoing`(转圈)不用这三个:DSH 用 `--dsw-alias-label-tertiary`(StateDot.module.css:39)。
  //
  // 与上面的 `roleContext` 是**同值不同 token**:一个是时间线角色徽标,一个是状态点。
  // 分成两个常量是刻意的 —— DSH 升级换掉其中一个时,另一个不该跟着变。
  static const stateSuccess = Color(0xFF22C55E); // green-500
  static const stateError = Color(0xFFF25A5A); // red-400
  static const stateIdle = Color(0xFF545557); // neutral-600
  static const stateWarn = Color(0xFFF59E0B); // amber-500(:375)

  // ---- 上下文用量分段 ----
  static const ctxSystem = Color(0xFFADB2B8);
  static const ctxTools = Color(0xFFA78BFA);
  static const ctxMessages = Color(0xFF4D93F8);

  // ---- diff(代码变更,深色)----
  static const codeDiffAdd = Color(0x1F22C55E); // 绿 @12%
  static const codeDiffDel = Color(0x1FF25A5A); // 红 @12%
  static const fileDiffAddBg = Color(0xFF1F3124);
  static const fileDiffAddMarker = Color(0xFF41C977);
  static const fileDiffDelBg = Color(0xFF3C1F1B);
  static const fileDiffDelMarker = Color(0xFFFA423E);
  // 行号槽的底色（原型 `--fadd-gutter: #132016` / `--fdel-gutter: #28130e`）。
  // **它比正文底更深**：这是 diff 的读法 —— 眼睛沿左边缘扫就能定位增删，
  // 而不必逐行读正文。少了这一列，长 diff 会变成一片同色的墙。
  static const fileDiffAddGutter = Color(0xFF132016);
  static const fileDiffDelGutter = Color(0xFF28130E);

  /// 分隔线:在层上叠白,alpha 常用 0.06 / 0.12 / 0.16 / 0.20。
  static Color border([double alpha = 0.12]) =>
      Color.fromRGBO(255, 255, 255, alpha);
}

/// 主题模式（照 DSH `ui-theme/src/theme-settings.ts` 的三档）。
///
/// 放在 theme 层而不是 model 层：它描述的是"用哪一套色板"，
/// 而色板就在这一层。model 层的 [ThemeController] 持它的真值。
enum DshThemeMode {
  /// 跟随系统（DSH 默认）：手机夜间模式自动生效。
  system,

  /// 浅色（`design-platform.css` 的 `:root`）。
  light,

  /// 深色（`design-platform.css` 的 `body[data-ds-dark-theme]`）。
  dark;

  /// 落盘用的字面量（偏好表存这个，不存枚举下标 —— 下标会随枚举重排而变）。
  String get wire => name;

  /// 从盘上读回来的值解析；认不出来的退回 [system]（不猜）。
  static DshThemeMode fromWire(String? value) {
    for (final mode in DshThemeMode.values) {
      if (mode.name == value) return mode;
    }
    return DshThemeMode.system;
  }
}

/// DSH **浅色**色板。
///
/// 出处是 `design-platform.css` 的 `:root` 块 —— DSH 的浅色是**默认**，
/// 深色才是覆盖块。所以浅色的每个值都能在 `:root` 里逐字找到，
/// 注释里写的是它落的 static token。
///
/// ## 与深色套的差別不是简单反转
///
/// - **层级靠描边不靠底色**：浅色下 `layer1/2/3` **全是白**
///   （`--dsw-alias-bg-layer-1/2/3` 三条都落 neutral-bluish-00），
///   分层由 `--dsw-alias-border-l1/l2/l3`（4% / 10% / 12% 的黑）做。
///   所以浅色下三个 layer 同值是**有意为之**，不是抄漏。
/// - **次要文字更深而不是更亮**：浅色的 secondary 是 neutral-bluish-**700**，
///   比深色的 500 更暗 —— 白底上靠"更深"分主次。
/// - **error / idle 换档**：浅色 `state-error-primary` 是 red-**600**
///   （`:250`）、`state-idle-primary` 是 neutral-**300**（`:252`）。
abstract final class DshLightColors {
  // ---- 背景层（`:root` 的 `--dsw-alias-bg-*`）----
  static const bgBase = Color(0xFFFFFFFF); // neutral-bluish-00
  static const sidebar = Color(0xFFF1F3F5); // neutral-bluish-75
  // **三层全是白**：`:root` 的 `--dsw-alias-bg-layer-1/2/3` 三条都落
  // neutral-bluish-00（`design-platform.css:171-173`）。浅色靠描边分层
  // （`border-l1/l2/l3` = 4% / 10% / 12% 的黑），不靠底色。
  static const layer1 = Color(0xFFFFFFFF); // neutral-bluish-00
  static const layer2 = Color(0xFFFFFFFF); // neutral-bluish-00
  static const layer3 = Color(0xFFFFFFFF); // neutral-bluish-00
  static const menu = Color(0xFFFFFFFF); // overlay = neutral-bluish-150 近似
  /// 用户消息气泡（`--dsw-specific-bubble`，亮色 = deepseek-50）。
  ///
  /// **浅色必须单独一色**：`layer1/2/3` 三条在亮色全是纯白（靠描边分层），
  /// 而气泡靠的是**底色**—— 用 `layer3` 会让用户消息与背景同色、看不见。
  /// 2026-10-19 真机反馈"用户消息我刚开始一直以为渲染问题"就是它。
  static const bubble = Color(0xFFEDF3FE); // deepseek-50

  /// 输入栏卡片的底色（`--dsw-specific-input-major`，亮色 = neutral-bluish-00）。
  ///
  /// 亮色下它**也是白**（`design-platform.css:269`）—— 所以"卡片看得见"
  /// 靠的不是底色差，而是 `boxShadow` 那层 `elevation-soft`
  /// （`InputBar.module.css:62-63`）。**只改底色是改不出来的。**
  static const composer = Color(0xFFFFFFFF); // neutral-bluish-00

  /// 描边第 2 档（`--dsw-alias-border-l2`，亮色 = 黑 10%）。
  static const borderL2 = Color(0x1A000000); // rgba(0,0,0,0.1)

  // ---- 文字（`:root` 的 `--dsw-alias-label-*`）----
  static const labelPrimary = Color(0xFF0F1115); // neutral-bluish-1000
  static const labelSecondary = Color(0xFF61666B); // neutral-bluish-700
  static const labelTertiary = Color(0xFF81858C); // neutral-bluish-600
  static const labelCaption = Color(0xFFADB2B8); // neutral-bluish-400
  static const onAccent = Color(0xFF0F1115);

  // ---- 强调 / 交互 ----
  static const accentBlue = Color(0xFF5686FE); // blue-500（两套同源）
  static const businessBlue = Color(0xFF7AAAFF);
  // hover/active 两套**同族不同 alpha**：DSH 浅色块是
  // `rgba(38,49,72,0.06)` / `rgba(38,49,72,0.10)`（`:209-213`），
  // 深色块是 0.08 / 0.14。方向都是"叠深"（不是深色套那样叠白）。
  static const hover = Color(0x0F263148); // 38,49,72 @ 6%
  static const active = Color(0x1A263148); // 38,49,72 @ 10%

  // ---- hero 两个 token ----
  // `:241` 的 `state-business-tertiary → deepseek-100`、
  // `:218` 的 `label-primary-bluish → blue-900`。
  static const stateBusinessTertiary = Color(0xFFEDF3FE); // deepseek-100
  static const labelPrimaryBluish = Color(0xFF1E3A8A); // blue-900

  // ---- 角色 / 徽标 ----
  // 角色**前景**色两套同源（语义色不随亮暗反转）；只有**底色**换浅。
  static const roleContext = Color(0xFF22C55E); // green-500
  static const roleContextBg = Color(0xFFE6FAED); // green-100
  static const roleAssistant = Color(0xFF7C5A8A); // 同族压暗（白底上原色发灰）
  static const roleTool = Color(0xFFDD8629);
  static const roleToolBg = Color(0xFFFBF3E8); // amber-100 近似
  static const error = Color(0xFFEC1313); // red-600

  // ---- 状态点 ----
  static const stateSuccess = Color(0xFF22C55E); // green-500
  static const stateError = Color(0xFFEC1313); // red-600（`:250`）
  static const stateIdle = Color(0xFFD4D4D4); // neutral-300（`:252`）
  static const stateWarn = Color(0xFFF59E0B); // amber-500

  // ---- 上下文用量分段 ----
  static const ctxSystem = Color(0xFF81858C);
  static const ctxTools = Color(0xFF7C5CD6);
  static const ctxMessages = Color(0xFF2563EB);

  // ---- diff（`:root` 的 `--dsw-alias-{code,file}-diff-*`，:242-249）----
  static const codeDiffAdd = Color(0x1422C55E); // green-500 @8%
  static const codeDiffDel = Color(0x14EC1313); // red-600 @8%
  static const fileDiffAddBg = Color(0xFFE6F4E7); // rgb(230,244,231)
  static const fileDiffAddMarker = Color(0xFF01A241); // rgb(1,162,65)
  static const fileDiffDelBg = Color(0xFFFCE6E2); // rgb(252,230,226)
  static const fileDiffDelMarker = Color(0xFFBA2723); // rgb(186,39,35)
  // 行号槽：浅色下**比正文底更浅**（`file-diff-added-gutter: rgb(237,247,237)`）——
  // 深色是更深，浅色是更淡，都是"沿左缘扫能定位增删"。
  static const fileDiffAddGutter = Color(0xFFEDF7ED);
  static const fileDiffDelGutter = Color(0xFFFDECE9);

  /// 分隔线：浅色**叠黑**（`--dsw-alias-border-l1..l4` = 4/10/12/16% 的黑）。
  static Color border([double alpha = 0.12]) => Color.fromRGBO(0, 0, 0, alpha);
}

/// 运行时的色板（ThemeExtension）。
///
/// ## 为什么需要它
///
/// `DshColors`（深色）与 `DshLightColors`（浅色）都是 const 类，
/// 而 UI 要知道"当下用哪一套"。Flutter 给这条路的缝是
/// [ThemeExtension]（`packages/flutter/lib/src/material/theme.dart`）：
/// 它随 `ThemeData` 一起下发，`Theme.of(context)` 一读就到，
/// 亮暗变化时**自动跟着重建**（不需要自己发通知）。
///
/// 读法：`Theme.of(context).dshColors`（见下面的扩展 getter）。
///
/// ## 与两个 const 类的关系
///
/// 它是**同一组 token 的第三份列举**，但只做"选一套"这一件事：
/// 每个字段的值取自 `DshColors` 或 `DshLightColors`，自己不定义色值。
/// 所以核对 DSH 源码时仍然只有两处（两个 const 类）。
class DshColorTokens extends ThemeExtension<DshColorTokens> {
  const DshColorTokens._({
    required this.brightness,
    required this.bgBase,
    required this.sidebar,
    required this.layer1,
    required this.layer2,
    required this.layer3,
    required this.menu,
    required this.bubble,
    required this.composer,
    required this.borderL2,
    required this.labelPrimary,
    required this.labelSecondary,
    required this.labelTertiary,
    required this.labelCaption,
    required this.onAccent,
    required this.accentBlue,
    required this.businessBlue,
    required this.hover,
    required this.active,
    required this.stateBusinessTertiary,
    required this.labelPrimaryBluish,
    required this.roleContext,
    required this.roleContextBg,
    required this.roleAssistant,
    required this.roleTool,
    required this.roleToolBg,
    required this.error,
    required this.stateSuccess,
    required this.stateError,
    required this.stateIdle,
    required this.stateWarn,
    required this.ctxSystem,
    required this.ctxTools,
    required this.ctxMessages,
    required this.codeDiffAdd,
    required this.codeDiffDel,
    required this.fileDiffAddBg,
    required this.fileDiffAddMarker,
    required this.fileDiffDelBg,
    required this.fileDiffDelMarker,
    required this.fileDiffAddGutter,
    required this.fileDiffDelGutter,
  });

  /// 深色那一套。
  const DshColorTokens.dark()
    : this._(
        brightness: Brightness.dark,
        bgBase: DshColors.bgBase,
        sidebar: DshColors.sidebar,
        layer1: DshColors.layer1,
        layer2: DshColors.layer2,
        layer3: DshColors.layer3,
        menu: DshColors.menu,
        bubble: DshColors.bubble,
        composer: DshColors.composer,
        borderL2: DshColors.borderL2,
        labelPrimary: DshColors.labelPrimary,
        labelSecondary: DshColors.labelSecondary,
        labelTertiary: DshColors.labelTertiary,
        labelCaption: DshColors.labelCaption,
        onAccent: DshColors.onAccent,
        accentBlue: DshColors.accentBlue,
        businessBlue: DshColors.businessBlue,
        hover: DshColors.hover,
        active: DshColors.active,
        stateBusinessTertiary: DshColors.stateBusinessTertiary,
        labelPrimaryBluish: DshColors.labelPrimaryBluish,
        roleContext: DshColors.roleContext,
        roleContextBg: DshColors.roleContextBg,
        roleAssistant: DshColors.roleAssistant,
        roleTool: DshColors.roleTool,
        roleToolBg: DshColors.roleToolBg,
        error: DshColors.error,
        stateSuccess: DshColors.stateSuccess,
        stateError: DshColors.stateError,
        stateIdle: DshColors.stateIdle,
        stateWarn: DshColors.stateWarn,
        ctxSystem: DshColors.ctxSystem,
        ctxTools: DshColors.ctxTools,
        ctxMessages: DshColors.ctxMessages,
        codeDiffAdd: DshColors.codeDiffAdd,
        codeDiffDel: DshColors.codeDiffDel,
        fileDiffAddBg: DshColors.fileDiffAddBg,
        fileDiffAddMarker: DshColors.fileDiffAddMarker,
        fileDiffDelBg: DshColors.fileDiffDelBg,
        fileDiffDelMarker: DshColors.fileDiffDelMarker,
        fileDiffAddGutter: DshColors.fileDiffAddGutter,
        fileDiffDelGutter: DshColors.fileDiffDelGutter,
      );

  /// 浅色那一套。
  const DshColorTokens.light()
    : this._(
        brightness: Brightness.light,
        bgBase: DshLightColors.bgBase,
        sidebar: DshLightColors.sidebar,
        layer1: DshLightColors.layer1,
        layer2: DshLightColors.layer2,
        layer3: DshLightColors.layer3,
        menu: DshLightColors.menu,
        bubble: DshLightColors.bubble,
        composer: DshLightColors.composer,
        borderL2: DshLightColors.borderL2,
        labelPrimary: DshLightColors.labelPrimary,
        labelSecondary: DshLightColors.labelSecondary,
        labelTertiary: DshLightColors.labelTertiary,
        labelCaption: DshLightColors.labelCaption,
        onAccent: DshLightColors.onAccent,
        accentBlue: DshLightColors.accentBlue,
        businessBlue: DshLightColors.businessBlue,
        hover: DshLightColors.hover,
        active: DshLightColors.active,
        stateBusinessTertiary: DshLightColors.stateBusinessTertiary,
        labelPrimaryBluish: DshLightColors.labelPrimaryBluish,
        roleContext: DshLightColors.roleContext,
        roleContextBg: DshLightColors.roleContextBg,
        roleAssistant: DshLightColors.roleAssistant,
        roleTool: DshLightColors.roleTool,
        roleToolBg: DshLightColors.roleToolBg,
        error: DshLightColors.error,
        stateSuccess: DshLightColors.stateSuccess,
        stateError: DshLightColors.stateError,
        stateIdle: DshLightColors.stateIdle,
        stateWarn: DshLightColors.stateWarn,
        ctxSystem: DshLightColors.ctxSystem,
        ctxTools: DshLightColors.ctxTools,
        ctxMessages: DshLightColors.ctxMessages,
        codeDiffAdd: DshLightColors.codeDiffAdd,
        codeDiffDel: DshLightColors.codeDiffDel,
        fileDiffAddBg: DshLightColors.fileDiffAddBg,
        fileDiffAddMarker: DshLightColors.fileDiffAddMarker,
        fileDiffDelBg: DshLightColors.fileDiffDelBg,
        fileDiffDelMarker: DshLightColors.fileDiffDelMarker,
        fileDiffAddGutter: DshLightColors.fileDiffAddGutter,
        fileDiffDelGutter: DshLightColors.fileDiffDelGutter,
      );

  final Brightness brightness;
  final Color bgBase;
  final Color sidebar;
  final Color layer1;
  final Color layer2;
  final Color layer3;
  final Color menu;
  final Color bubble;
  final Color composer;
  final Color borderL2;
  final Color labelPrimary;
  final Color labelSecondary;
  final Color labelTertiary;
  final Color labelCaption;
  final Color onAccent;
  final Color accentBlue;
  final Color businessBlue;
  final Color hover;
  final Color active;
  final Color stateBusinessTertiary;
  final Color labelPrimaryBluish;
  final Color roleContext;
  final Color roleContextBg;
  final Color roleAssistant;
  final Color roleTool;
  final Color roleToolBg;
  final Color error;
  final Color stateSuccess;
  final Color stateError;
  final Color stateIdle;
  final Color stateWarn;
  final Color ctxSystem;
  final Color ctxTools;
  final Color ctxMessages;
  final Color codeDiffAdd;
  final Color codeDiffDel;
  final Color fileDiffAddBg;
  final Color fileDiffAddMarker;
  final Color fileDiffDelBg;
  final Color fileDiffDelMarker;
  final Color fileDiffAddGutter;
  final Color fileDiffDelGutter;

  /// 分隔线（深色叠白 / 浅色叠黑）。
  Color border([double alpha = 0.12]) => brightness == Brightness.dark
      ? Color.fromRGBO(255, 255, 255, alpha)
      : Color.fromRGBO(0, 0, 0, alpha);

  /// 逐字段复制。
  ///
  /// 返回类型收到 [ThemeExtension] 的签名约束（`ThemeExtension<T> copyWith()`），
  /// 调用方按需向下转型。字段全可选项：无参调用时所有字段都取原值。
  @override
  ThemeExtension<DshColorTokens> copyWith({
    Brightness? brightness,
    Color? bgBase,
    Color? sidebar,
    Color? layer1,
    Color? layer2,
    Color? layer3,
    Color? menu,
    Color? bubble,
    Color? composer,
    Color? borderL2,
    Color? labelPrimary,
    Color? labelSecondary,
    Color? labelTertiary,
    Color? labelCaption,
    Color? onAccent,
    Color? accentBlue,
    Color? businessBlue,
    Color? hover,
    Color? active,
    Color? stateBusinessTertiary,
    Color? labelPrimaryBluish,
    Color? roleContext,
    Color? roleContextBg,
    Color? roleAssistant,
    Color? roleTool,
    Color? roleToolBg,
    Color? error,
    Color? stateSuccess,
    Color? stateError,
    Color? stateIdle,
    Color? stateWarn,
    Color? ctxSystem,
    Color? ctxTools,
    Color? ctxMessages,
    Color? codeDiffAdd,
    Color? codeDiffDel,
    Color? fileDiffAddBg,
    Color? fileDiffAddMarker,
    Color? fileDiffDelBg,
    Color? fileDiffDelMarker,
    Color? fileDiffAddGutter,
    Color? fileDiffDelGutter,
  }) => DshColorTokens._(
    brightness: brightness ?? this.brightness,
    bgBase: bgBase ?? this.bgBase,
    sidebar: sidebar ?? this.sidebar,
    layer1: layer1 ?? this.layer1,
    layer2: layer2 ?? this.layer2,
    layer3: layer3 ?? this.layer3,
    menu: menu ?? this.menu,
    bubble: bubble ?? this.bubble,
    composer: composer ?? this.composer,
    borderL2: borderL2 ?? this.borderL2,
    labelPrimary: labelPrimary ?? this.labelPrimary,
    labelSecondary: labelSecondary ?? this.labelSecondary,
    labelTertiary: labelTertiary ?? this.labelTertiary,
    labelCaption: labelCaption ?? this.labelCaption,
    onAccent: onAccent ?? this.onAccent,
    accentBlue: accentBlue ?? this.accentBlue,
    businessBlue: businessBlue ?? this.businessBlue,
    hover: hover ?? this.hover,
    active: active ?? this.active,
    stateBusinessTertiary: stateBusinessTertiary ?? this.stateBusinessTertiary,
    labelPrimaryBluish: labelPrimaryBluish ?? this.labelPrimaryBluish,
    roleContext: roleContext ?? this.roleContext,
    roleContextBg: roleContextBg ?? this.roleContextBg,
    roleAssistant: roleAssistant ?? this.roleAssistant,
    roleTool: roleTool ?? this.roleTool,
    roleToolBg: roleToolBg ?? this.roleToolBg,
    error: error ?? this.error,
    stateSuccess: stateSuccess ?? this.stateSuccess,
    stateError: stateError ?? this.stateError,
    stateIdle: stateIdle ?? this.stateIdle,
    stateWarn: stateWarn ?? this.stateWarn,
    ctxSystem: ctxSystem ?? this.ctxSystem,
    ctxTools: ctxTools ?? this.ctxTools,
    ctxMessages: ctxMessages ?? this.ctxMessages,
    codeDiffAdd: codeDiffAdd ?? this.codeDiffAdd,
    codeDiffDel: codeDiffDel ?? this.codeDiffDel,
    fileDiffAddBg: fileDiffAddBg ?? this.fileDiffAddBg,
    fileDiffAddMarker: fileDiffAddMarker ?? this.fileDiffAddMarker,
    fileDiffDelBg: fileDiffDelBg ?? this.fileDiffDelBg,
    fileDiffDelMarker: fileDiffDelMarker ?? this.fileDiffDelMarker,
    fileDiffAddGutter: fileDiffAddGutter ?? this.fileDiffAddGutter,
    fileDiffDelGutter: fileDiffDelGutter ?? this.fileDiffDelGutter,
  );

  /// 主题切换时的插值。
  ///
  /// **不做逐色插值**：亮暗切换是一次"换套"，不是渐变 ——
  /// 逐个 `Color.lerp` 会在中途产生一堆两套都不是的颜色（发灰的层级），
  /// 而 DSH 的换主题也是瞬时切换（`boot-theme.ts` 直接改 data 属性）。
  /// 所以过半就整体换成另一套。
  @override
  ThemeExtension<DshColorTokens> lerp(
    covariant ThemeExtension<DshColorTokens>? other,
    double t,
  ) {
    if (other is! DshColorTokens) return this;
    return t < 0.5 ? this : other;
  }
}

/// 读当前色板：`Theme.of(context).dshColors`。
///
/// **拿不到就退深色**（`Theme.of(context).extension<DshColorTokens>()`
/// 在没挂扩展时返回 null）：深色是默认套，而"取不到色板"不该让界面崩。
/// 这不是静默兜底 —— 装配点（`main.dart`）一定挂扩展，走到这里只可能是
/// 测试里忘了挂 theme。
extension DshColorTokensContext on BuildContext {
  DshColorTokens get dshColors =>
      Theme.of(this).extension<DshColorTokens>() ?? const DshColorTokens.dark();
}
