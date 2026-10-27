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
/// 1. **组头常显会话数**（`WorkspaceBrowser.tsx:640-660` 的溢出行只在折叠时给
///    `hiddenCount`；手机上**展开时也要看得到**"这个项目下有几条" ——
///    用户 2026-10-21 原话：「不是按照工作区分类然后每个工作区下面多少会话？」。
///    这是有意偏离，理由与 `design-and-tech-plan.md` §6 同一条：没有 hover 的界面
///    不该把"有多少"藏在折叠态里）。
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
    this.headerWrapper,
    this.indent = 14,
    required this.children,
  });

  /// 组内行相对组头缩进多少（**层级**靠这个与字重/颜色一起表达）。
  final double indent;

  /// 项目名（工作区标题；`groups` 为空时是「会话」/「未分组」）。
  final String label;

  /// 现在是展开还是折叠。
  final bool expanded;

  /// 点组头（DSH：`setGroupExpanded(key, !group.expanded)`）。
  final VoidCallback onToggle;

  /// 这个组里有几个会话（**常显**，不是只在折叠时）。
  final int childCount;

  /// 当前会话在这个组里（DSH 的 `containsCurrentDescendant`：
  /// 折叠时也高亮，否则用户看不到"我在哪个项目里"）。
  final bool containsCurrent;

  /// 把组头那一行**包一层**（抽屉用它挂"拖动项目头"与落点；
  /// 内联列表不传，行为不变）。
  ///
  /// 做成包装器而不是给这里加拖动逻辑：拖动是**抽屉**的交互，
  /// 而这一层还服务内联列表（`chat_page.dart`）—— 把两处的交互塞进同一个组件
  /// 会让"内联列表能不能拖"变成隐式行为。
  final Widget Function(BuildContext context, Widget header)? headerWrapper;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final header = InkWell(
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
            // 一级菜单（工作区）：**字号/字重/颜色都要压过二级的会话行** ——
            // 2026-10-26 用户原话："谁家一级菜单这样？"（当时是 11px 浅色，看不出来）。
            DshIcon(
              expanded ? 'folderOpen' : 'folderClose',
              size: 15,
              color: containsCurrent ? c.accentBlue : c.labelSecondary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  // 当前所在的项目**用强调色**（DSH 同一条规则）。
                  color: containsCurrent ? c.accentBlue : c.labelPrimary,
                ),
              ),
            ),
            // **组头常显个数**（DSH 只在折叠时给 `hiddenCount`；
            // 手机上展开时也要看得到"这个项目下有几条" —— 有意偏离，
            // 见文件头第 1 条与 `design-and-tech-plan.md` §6）。
            if (childCount > 0) ...[
              const SizedBox(width: 6),
              Text(
                '$childCount',
                style: TextStyle(fontSize: 11, color: c.labelSecondary),
              ),
            ],
            const SizedBox(width: 4),
            // 右三角：展开时转 90°（DSH `Rows.tsx:263` 的 `arrowOpen`）。
            AnimatedRotation(
              turns: expanded ? 0.25 : 0,
              duration: const Duration(milliseconds: 120),
              child: DshIcon('chevronRight', size: 12, color: c.labelCaption),
            ),
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        headerWrapper?.call(context, header) ?? header,
        // 二级（会话行）缩进：层级靠"缩进 + 字重 + 颜色"三样表达，
        // 单靠字号在手机上不够（真机反馈"一眼看过去看不出层级"）。
        if (expanded)
          for (final child in children)
            Padding(
              padding: EdgeInsets.only(left: indent),
              child: child,
            ),
      ],
    );
  }
}
