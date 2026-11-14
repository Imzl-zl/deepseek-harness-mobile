/// 开/关开关：**本项目的开关基线**（`mock/proto/styles.css` 的 `.settings-toggle`）。
///
/// ## 几何与颜色（逐项照原型，不是照 DSH 的 Web 开关）
///
/// | 量 | 值 | 出处 |
/// |---|---|---|
/// | 轨道 | 42 × 25，圆角 13 | `styles.css` 的 `.settings-toggle` |
/// | 关着的轨道 | `layer3` | 同处 `background: var(--layer3)` |
/// | 开着的轨道 | `accentBlue` | `.is-on { background: var(--accent) }` |
/// | 滑块 | 19 × 19，四周内缩 3 | `top:3px; left:3px; width:19px; height:19px` |
/// | 关着的滑块 | `labelTertiary` | `background: var(--on3)` |
/// | 开着的滑块 | 白 | `.is-on::after { background: #fff }` |
/// | 位移 | 开态右移 **17** | `translateX(17px)` |
/// | 动效 | 0.1 s，`cubic-bezier(.4,0,.2,1)` | `--d1` / `--ease` |
///
/// ## 为什么不用 Material 的 `Switch` / `SwitchListTile`
///
/// 它按 M3 画 52×32、自带 48 高热区与自己的色板；放进本项目的行里（14px 标题 +
/// 11px 说明）会明显偏大、颜色也不在 token 体系里（2026-11-14 真机反馈：
/// 「挺丑挺别扭，风格不符」）。原型这一版 42×25 才是手机该有的比例，
/// 而且三个颜色全部来自 `DshColors`，深浅两套主题自动成立。
///
/// **一个组件、三处用**：设置页的行尾、插件页的逐行启停、模型菜单里的团队开关 ——
/// 开关只有一个样子（`AGENTS.md` 的「一件事只有一处判据」）。
///
/// Note: 该组件为什么存在、被哪三处用 —— 见
/// `.agents/notes/implemented/2026-11-14-agent-team-integration.md`。
library;

import 'package:flutter/material.dart';

import '../theme/dsh_colors.dart';

/// 原型规格的两态开关。**完全受控**：要变就由 [onChanged] 的调用者改数据。
class DshSwitch extends StatelessWidget {
  const DshSwitch({
    super.key,
    required this.checked,
    required this.onChanged,
    required this.label,
    this.enabled = true,
  });

  /// 当前状态。
  final bool checked;

  /// 被点时要去的目标态。
  final ValueChanged<bool> onChanged;

  /// 可访问名（读屏读它；`SwitchListTile` 那套是自动的，这里必须显式给）。
  final String label;

  /// 是否可点。**写在飞时也要置假**（防连点）。
  final bool enabled;

  // 原型 `.settings-toggle`：42×25、圆角 13、滑块 19 内缩 3。
  static const double _width = 42;
  static const double _height = 25;
  static const double _inset = 3;
  static const double _thumb = 19;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Semantics(
      button: true,
      toggled: checked,
      enabled: enabled,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // 触摸热区补到 44 高：42×25 的控件本身在手机上偏小，而视觉尺寸不变。
        onTap: enabled ? () => onChanged(!checked) : null,
        child: SizedBox(
          width: _width + 8,
          height: 44,
          child: Center(
            child: Opacity(
              // 禁用态：原型 `.switch:disabled { opacity: .5 }` 的同一条意图。
              opacity: enabled ? 1 : 0.5,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                curve: const Cubic(0.4, 0, 0.2, 1),
                width: _width,
                height: _height,
                decoration: BoxDecoration(
                  color: checked ? c.accentBlue : c.layer3,
                  borderRadius: BorderRadius.circular(_height / 2),
                ),
                child: AnimatedAlign(
                  duration: const Duration(milliseconds: 100),
                  curve: const Cubic(0.4, 0, 0.2, 1),
                  alignment: checked
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: _inset),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 100),
                      curve: const Cubic(0.4, 0, 0.2, 1),
                      width: _thumb,
                      height: _thumb,
                      decoration: BoxDecoration(
                        // 开：白；关：`on3`（原型的 `.settings-toggle::after`）。
                        color: checked ? Colors.white : c.labelTertiary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
