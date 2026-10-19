/// 抽屉/内联列表里的**可折叠项目组头**。
///
/// ## 形态照 DSH Web
///
/// `packages/client/ui-workspace/src/client/rows/Rows.tsx:259-263`：
/// 展开时 `IconFolderOpenRegular`、折叠时 `IconFolderCloseRegular`，
/// 右侧一枚 `IconTriangleRightFillRegular`（展开时旋转 90°）。
/// 组头本身是 `aria-expanded` 按钮（`:247`）。
///
/// ## 三条 DSH 也有的细节
///
/// 1. **折叠时把里面的会话数说出来**（`WorkspaceBrowser.tsx:640-660` 的
///    溢出行：`sessions.expand, {n: visible.hiddenCount}`）—— 折叠不是
///    "这里没了"，是"这里收着 N 个"。
/// 2. **当前会话所在的组即使折叠也高亮**（`Rows.tsx:211,236` 的
///    `containsCurrentDescendant`）—— 否则用户看不到"我在哪个项目里"。
/// 3. 折叠状态由**调用方**持有（这里是 widget 内的局部态）：
///    DSH 是 `setGroupExpanded(key, expanded)`（`WorkspaceBrowser.tsx:281`），
///    手机侧一期只做"这一次打开期间的记忆"，不落盘 ——
///    落盘要知道每个 group 的稳定 key，而 `WorkspaceGroup` 没有 id
///    （只有 `workspaceId`，见 `model/workspace.dart`）。
library;

import 'package:flutter/material.dart';

import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';

/// 一个可折叠的项目组。
class CollapsibleGroup extends StatelessWidget {
  const CollapsibleGroup({
    super.key,
    required this.label,
    required this.expanded,
    required this.onToggle,
    required this.childCount,
    this.containsCurrent = false,
    required this.children,
  });

  /// 项目名（工作区标题；`groups` 为空时是「会话」/「未分组」）。
  final String label;

  /// 现在是展开还是折叠。
  final bool expanded;

  /// 点组头（DSH：`setGroupExpanded(key, !group.expanded)`）。
  final VoidCallback onToggle;

  /// 这个组里有几个会话（**折叠时显示成"收着 N 个"**）。
  final int childCount;

  /// 当前会话在这个组里（DSH 的 `containsCurrentDescendant`：
  /// 折叠时也高亮，否则用户看不到"我在哪个项目里"）。
  final bool containsCurrent;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            // `.dsec` 的左右 8 + 上下 12/4 照原分组标题；
            // 上下加满到 8 是为了命中区不小于 32px（触摸目标）。
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
            child: Row(
              children: [
                // **开/关两个文件夹图标**（DSH `Rows.tsx:259-261`）：
                // 折叠态用关着的那个，"这里收着一份东西"。
                DshIcon(
                  expanded ? 'folderOpen' : 'folderClose',
                  size: 13,
                  color: containsCurrent ? c.accentBlue : c.labelCaption,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      // 当前所在的项目**用强调色**（DSH 同一条规则）。
                      color: containsCurrent ? c.accentBlue : c.labelCaption,
                    ),
                  ),
                ),
                // **折叠时把收着的个数说出来**（DSH `WorkspaceBrowser.tsx:640-660`）。
                if (!expanded && childCount > 0) ...[
                  const SizedBox(width: 6),
                  Text(
                    '$childCount',
                    style: TextStyle(fontSize: 10, color: c.labelCaption),
                  ),
                ],
                const SizedBox(width: 4),
                // 右三角：展开时转 90°（DSH `Rows.tsx:263` 的 `arrowOpen`）。
                AnimatedRotation(
                  turns: expanded ? 0.25 : 0,
                  duration: const Duration(milliseconds: 120),
                  child: DshIcon(
                    'chevronRight',
                    size: 12,
                    color: c.labelCaption,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (expanded) ...children,
      ],
    );
  }
}
