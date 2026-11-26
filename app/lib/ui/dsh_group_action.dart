/// 抽屉组头那两枚紧凑动作钮（「＋」新建会话、「…」更多操作）。
///
/// 从 `session_drawer.dart` 抽出来是因为**它服务的是组头，不是抽屉**：
/// 内联列表（`chat_page.dart` 的 `CollapsibleGroup`）将来要挂同样的动作时，
/// 不该 import 整个抽屉。
///
/// 尺寸 32×32 是**触摸目标下限**：组头整行只有 32 高，塞 38 的图标钮会把行撑开、
/// 也让两枚钮挤掉标题宽度。图标仍是 15（与组头的文件夹图标同档），所以不抢戏。
library;

import 'package:flutter/material.dart';

import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';

/// 组头的一枚动作钮。
class DshGroupAction extends StatelessWidget {
  const DshGroupAction({
    super.key,
    required this.icon,
    required this.onTap,
    required this.semanticLabel,
  });

  /// 图标名（`theme/dsh_icons.dart` 的键）。
  final String icon;

  final VoidCallback onTap;

  /// 读屏与自动化测试用的名字（纯图标钮必须自己报出来）。
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Semantics(
      // 纯图标钮：角色自己报（`InkWell` 只装点击动作，不装 `isButton`）。
      // 判据与验证见 `app/test/tappable_semantics_test.dart`。
      button: true,
      label: semanticLabel,
      child: SizedBox(
        width: 32,
        height: 32,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Center(
              child: DshIcon(icon, size: 15, color: c.labelSecondary),
            ),
          ),
        ),
      ),
    );
  }
}
