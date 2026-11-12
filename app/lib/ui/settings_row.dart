/// 设置页的一行偏好：`[图标 + 名称] [当前值] [箭头]`。
///
/// ## `onTap == null` = **纯展示**：没有箭头、点不动、朗读器不报按钮
///
/// 手机设置页有相当一部分行是"电脑侧的真值，这里只读"（当前模型、可用模型、
/// 连接状态、provider 拉取失败的原话）。那些行原来一律传 `onTap: () {}` ——
/// 结果是一个**行尾带箭头、点了什么都不发生**的按钮：`InkWell` 有水波、
/// 朗读器报"按钮"、语义上还声称会跳转。
///
/// 判据：**箭头是"这一行会带你去别处"的承诺**。没有去处就不画箭头、也不接水波。
///
/// ## 为什么值有 42% 上限
///
/// 基线是原型：`.settings-row .row-value{max-width:42%;white-space:nowrap;
/// text-overflow:ellipsis}`（`mock/proto/styles.css`）。落地端照这组约束：
/// 值最多占行宽 **42%**、单行省略，标题单行省略。
///
/// 不能把长值放进 `ListTile.trailing`：trailing 按**固有宽度**排版，标题只剩一条缝，
/// 中文会一个字一行（`packages/flutter/lib/src/material/list_tile.dart:1515,1552-1558`）。
/// 真机症状与判据见 `.agents/notes/implemented/2026-11-06-settings-row-value-capped.md`。
library;

import 'package:flutter/material.dart';

import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';

/// 一行偏好（`[图标 + 名称] [当前值]`）。
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
  });

  final String icon;
  final String label;
  final String value;

  /// `null` = **纯展示**（没有去处）。见文件头：不画箭头、不接水波、不报按钮。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final tappable = onTap != null;
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            DshIcon(icon, size: 18, color: c.labelSecondary),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, color: c.labelPrimary),
              ),
            ),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: constraints.maxWidth * 0.42,
              ),
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 13, color: c.labelCaption),
              ),
            ),
            if (tappable) ...[
              const SizedBox(width: 4),
              DshIcon('chevronRight', size: 14, color: c.labelTertiary),
            ],
          ],
        ),
      ),
    );
    // 有去处 ⇒ 按钮角色（`InkWell` 只装点击动作，不装 `isButton`）；
    // 没有去处 ⇒ 普通文本节点，不报按钮、也没有点击动作。
    return tappable
        ? Semantics(
            button: true,
            child: InkWell(onTap: onTap, child: row),
          )
        : Semantics(container: true, child: row);
  }
}
