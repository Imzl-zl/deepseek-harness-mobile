import 'package:flutter/painting.dart';

/// DSH 深色主题真实色板,抽自 `deepseek-harness/packages/client/ui-theme`
/// (design-platform.css 的 `body[data-ds-dark-theme]` 与 diff 暗色块)。
///
/// 改动前先核对源码 token,不要凭感觉调色。
abstract final class DshColors {
  // ---- 背景层 ----
  static const bgBase = Color(0xFF151517); // 根背景 bg-base
  static const sidebar = Color(0xFF1B1B1C); // 侧栏
  static const layer1 = Color(0xFF232324); // 卡片/面板/主表面 bg-layer-1
  static const layer2 = Color(0xFF2C2C2E); // 抬升 bg-layer-2
  static const layer3 = Color(0xFF353638); // 最高/中性 chip bg-layer-3
  static const menu = Color(0xFF43454A); // 浮层/菜单(不透明近似)

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

  // ---- 角色 / 徽标(时间线)----
  static const roleContext = Color(0xFF22C55E);
  static const roleContextBg = Color(0xFF233C2C);
  static const roleAssistant = Color(
    0xFF9E7BAA,
  ); // ≈ lerp(accentBlue, error, .4)
  static const roleTool = Color(0xFFDD8629);
  static const roleToolBg = Color(0xFF27241F);
  static const error = Color(0xFFF25A5A);

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

  /// 分隔线:在层上叠白,alpha 常用 0.06 / 0.12 / 0.16 / 0.20。
  static Color border([double alpha = 0.12]) =>
      Color.fromRGBO(255, 255, 255, alpha);
}
