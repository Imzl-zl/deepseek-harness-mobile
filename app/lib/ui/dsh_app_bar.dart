/// DSH 顶栏（照 `mock/proto/index.html` 的 `.appbar`）。
///
/// ## 它长什么样（数值取自 `styles.css`，**不是估的**）
///
/// ```
/// ┌──────────────────────────────────────┐
/// │ ☰  标题(超长省略)  ⑵任务运行中  ⊕   │  height: 56px + safe-top
/// └──────────────────────────────────────┘
/// ```
///
/// - 左：`☰` 开抽屉（`.ib`，`panelLeft` 图标）；
/// - 中：标题，`flex:1` 且 `min-width:0` 好让省略号生效；
/// - **状态位**（`.statuspill`，`min-height:30` / `border-radius:15` /
///   `max-width:42vw`）：有后台任务显任务数，否则显文件变更；点它开右侧抽屉；
/// - 右：`＋` 新建会话（`newChat` 图标）。
///
/// ## 为什么这一条单独成组件
///
/// 三个页面（聊天 / 设置 / 任务）各有一个顶栏，而它们的左右按钮语义相同、
/// 只换标题与中段。分开写会让"抽屉按钮在聊天页是 `panelLeft`、
/// 在设置页是 `chevronLeft`"这类不一致悄悄出现。
library;

import 'package:flutter/material.dart';

import '../model/chat_item.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import 'dsh_state_dot.dart';

/// 顶栏上的一个图标按钮（`.ib`）。
///
/// 尺寸是原型里那个圆钮：`38×38`（`--r-19`），图标 18~20。
class DshAppBarButton extends StatelessWidget {
  const DshAppBarButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.size = 16,
    this.mirrorX = false,
  });

  /// DSH 图标名（必须是 [DshIcons.names] 里的一员）。
  final String icon;

  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;

  /// 把图标**水平镜像**再画。
  ///
  /// 只有右抽屉按钮用：DSH 那个按钮的图形就是左侧栏图标的镜像
  /// （`ui-sidebar-right/src/client/shell/ExpandButton.tsx:13-14` 原注释
  /// "The glyph is the left sidebar's collapse icon mirrored"），
  /// 而图标集里只有 `panelLeft` 一个面板图标 —— 镜像它，不新增字形。
  final bool mirrorX;

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
      width: 38,
      height: 38,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Center(
            child: mirrorX
                ? Transform.flip(
                    flipX: true,
                    child: DshIcon(
                      icon,
                      size: size,
                      color: DshColors.labelSecondary,
                    ),
                  )
                : DshIcon(icon, size: size, color: DshColors.labelSecondary),
          ),
        ),
      ),
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// 顶栏上的**连接状态点**（可点）。
///
/// ## 为什么是点，不是文字胶囊
///
/// 原型原来是 `.statuspill`（文字："已连接" / "重连中…"）。手机顶栏宽度有限，
/// 一行里要塞 `☰ 标题 状态 右抽屉 ＋`，文字状态位把标题挤到只剩一半；
/// 而 DSH Web 那边**连接正常时根本不显示指示器**（`ConnectionIndicator` 只在
/// 异常/重连/刚恢复三态出现，`ui-primitives/src/ConnectionIndicator.tsx:29-45`）。
///
/// 所以这里取中间形态：**点缩小成状态点**（形状与颜色照 DSH 的 `StateDot`，
/// 见 `dsh_state_dot.dart`），文字退进 tooltip。
///
/// ## 点它做什么（照 DSH 的按钮语义）
///
/// DSH 的异常/重连指示器**本身就是"立即重连"按钮**
/// （`ConnectionIndicator.tsx:75-81`：`onClick={onReconnect}`）。
/// 手机上把"点它"统一成**连接操作 sheet**：重试连接 / 重新配对 / 打开侧面板 / 断开。
/// 这样"任何状态 ≤2 步走到重新配对"的硬判据仍然成立（点 1 → sheet 里选 1），
/// 而右抽屉的入口移交给了隔壁那个独立按钮（见 [ChatAppBar.onOpenSide]）。
class DshConnectionDotButton extends StatelessWidget {
  const DshConnectionDotButton({
    super.key,
    required this.state,
    required this.tooltip,
    required this.onPressed,
  });

  /// 点的语义（由调用方按连接状态映射）。
  final DshStateDotState state;

  /// tooltip / 无障碍名。文案由 `model/chat_item.dart` 的 `connectionLabel` 给，
  /// 不在这里另写一套说法。
  final String tooltip;

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        // 与 `DshAppBarButton` 同尺寸的触摸目标（38×38）——点只有 10~14px，
        // 直接点它等于让手指去戳一个 1/4 圆钮大小的东西。
        width: 38,
        height: 38,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Center(child: DshStateDot(state)),
          ),
        ),
      ),
    );
  }
}

/// 顶栏上的**计数 chip**（子智能体 / 后台任务）。
///
/// ## 为什么是"图标 + 计数"，没有文字
///
/// DSH Web 把这两枚放在 header 的 actions band 里，是**全文本**的
/// （`ui-subagent` 的 `{count} 个子智能体`、`ui-jobs` 的 `{count} 个后台任务运行中`，
/// `ui-conversation/src/client/skeleton/ConversationSession.tsx:127-129`）。
/// 手机放不下：411.4dp 屏上顶栏留给「标题 + chip」的只有 285.4dp，而
/// 单枚全文本 chip 实测 **137.8dp** / **174.5dp**（`topbar_chips_test.dart` 里记着这两个数）。
///
/// 所以手机上留**形态**（同一行、可点、在跑时画转圈点），把**全文本退进
/// aria/tooltip** —— 文案仍与 DSH 逐字一致，只是不再占顶栏宽度。
/// 取舍见 `.agents/notes/implemented/2026-10-17-topbar-single-row-and-stats-scroll.md`。
class DshCountChip extends StatelessWidget {
  const DshCountChip({
    super.key,
    required this.count,
    required this.running,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  /// 显示的数字（子智能体报总数、后台任务在跑时报在跑数 —— 由调用方按
  /// `subagentChipLabel` / `jobChipLabel` 算好，这里不重算一遍）。
  final int count;

  /// 在跑的个数；> 0 时前导槽画转圈点（DSH 的 `activitySlot`）。
  final int running;

  /// 不在跑时前导槽里的图标（触屏没有 hover，图标是"这是哪一类"的唯一线索）。
  final String icon;

  /// aria / tooltip：与 DSH 逐字一致的那句全文本。
  final String label;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final live = running > 0;
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        button: true,
        child: Material(
          color: DshColors.layer2,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              // 28 高：与状态点、`＋` 这些 38px 触摸目标同处一行时不吃高度。
              height: 28,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (live)
                      const DshStateDot(DshStateDotState.ongoing)
                    else
                      DshIcon(icon, size: 13, color: DshColors.labelSecondary),
                    const SizedBox(width: 5),
                    Text(
                      '$count',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: DshColors.labelTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 顶栏标题的**硬上限**。
///
/// DSH 的 `.crumb { max-width: 220px }`
/// （`ui-conversation/src/client/skeleton/ConversationRoot.module.css:125-139`）
/// 是**桌面**尺度：那边 header 的计数 chip 与标题同行、宽屏放得下。
/// 手机上同一行还要塞两枚计数 chip（`☰`+`●`+`⊕` 已占 126dp），
/// 所以按同一形态**收窄一档**到 140 —— 标题仍可省略，但给 chip 让出位置。
/// 411.4dp 屏上的账：126（按钮）+ 140（标题）+ 100（两枚 chip）≈ 366，留 45dp 余量。
const double kDshTitleMaxWidth = 140;

/// 聊天页顶栏。
///
/// ```
/// ┌────────────────────────────────────────────┐
/// │ ☰  标题(≤140,13px,省略)  👥3 ☑2   ●   ⊕  │  height: 56px + safe-top
/// └────────────────────────────────────────────┘
/// ```
///
/// 顶栏左侧是 `☰`（照 DSH Web 的 sidebar toggle：`ui-sidebar/src/client/SidebarRoot.tsx:178-197`
/// 的 `IconPanelLeftOutlineRegular`）—— **图标就该在顶栏左侧**，这是用户 2026-10-16 纠正的：
/// 我曾把它移到屏幕左缘当"把手"，那是自创的形态。
///
/// **计数 chip 与标题同一行**（2026-10-17）：DSH 就是把子智能体 / 后台任务放在 header 的
/// actions band 里；手机原来让它们**另起一行**，因为按全文本 chip 算，360~390px 上确实放不下。
/// 换成图标 + 计数后每枚约 50dp，同一条宽度够用了 —— 于是那一行撤销，省下约 34dp 的对话高度。
///
/// 左抽屉同时支持**从屏幕左缘跟手拖出**（`Scaffold.drawerEdgeDragWidth`，Flutter 自带的
/// 跟手拖动）；右抽屉（`SidePane`）走 `Scaffold.endDrawer`，从右缘跟手拖出，
/// 右缘那条**棒棒**是它的标识（抽屉开着时消失）。与系统返回手势的冲突用
/// `platform/gesture_exclusion.dart` 解决（只排除上半屏 192dp）。
class ChatAppBar extends StatelessWidget implements PreferredSizeWidget {
  const ChatAppBar({
    super.key,
    required this.title,
    required this.onOpenDrawer,
    required this.onNewSession,
    required this.connectionState,
    required this.connectionTooltip,
    required this.onConnectionTap,
    this.subagentCount = 0,
    this.subagentRunning = 0,
    this.jobCount = 0,
    this.jobRunning = 0,
    this.onTapSubagents,
    this.onTapJobs,
  });

  final String title;

  /// `☰` —— 左抽屉（会话历史）。
  final VoidCallback onOpenDrawer;

  /// `＋` —— 新建会话。
  final VoidCallback onNewSession;

  /// 连接状态点的语义（由调用方按 `ConnectionStateView` 映射）。
  final DshStateDotState connectionState;

  /// 状态点的 tooltip：文案来自 `model/chat_item.dart` 的 `connectionLabel` ——
  /// **同一个状态只有一套说法**（抽屉连接行、设置页、这里共用）。
  final String connectionTooltip;

  final VoidCallback onConnectionTap;

  /// 子智能体总数 / 在跑数；`0` = 不显示这枚 chip。
  final int subagentCount;
  final int subagentRunning;

  /// 后台任务总数 / 在跑数；`0` = 不显示这枚 chip。
  final int jobCount;
  final int jobRunning;

  /// 点 chip 开右抽屉对应面板。**为 `null` 时那枚 chip 不可点**（只读计数）。
  final VoidCallback? onTapSubagents;
  final VoidCallback? onTapJobs;

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    return Container(
      color: DshColors.sidebar,
      padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
      height: 56 + MediaQuery.of(context).padding.top,
      child: Row(
        children: [
          const SizedBox(width: 4),
          DshAppBarButton(
            icon: 'panelLeft',
            tooltip: '打开会话抽屉',
            onPressed: onOpenDrawer,
          ),
          const SizedBox(width: 2),
          // 两件事都要：`Expanded` 把右簇钉在右边（否则右簇跟着标题长度漂），
          // `ConstrainedBox` 给标题**上限**（否则长标题吃光整行、把计数 chip
          // 挤到没位置）。
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: kDshTitleMaxWidth),
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // **13px / w500**：形态照 DSH Web 的 `.crumb`
                  // （`ConversationRoot.module.css:125-139` 的
                  // `font-size: 14px; line-height: 20px`，当前那条是 w500），
                  // 手机上收窄一档 —— 同一行还要放两枚计数 chip。
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: DshColors.labelPrimary,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 2),
          // **计数 chip**：有才显示（0 时整枚不占位，不是显示"0 个子智能体"）。
          // 文案（全文本那句）走 `subagentChipLabel` / `jobChipLabel`，
          // 与 Web 逐字一致，只是退进了 aria/tooltip。
          if (subagentCount > 0) ...[
            DshCountChip(
              count: subagentCount,
              running: subagentRunning,
              icon: 'users',
              label: subagentChipAria(
                total: subagentCount,
                running: subagentRunning,
              ),
              onTap: onTapSubagents ?? () {},
            ),
            const SizedBox(width: 4),
          ],
          if (jobCount > 0) ...[
            DshCountChip(
              count: jobRunning > 0 ? jobRunning : jobCount,
              running: jobRunning,
              icon: 'checklist',
              label: jobChipLabel(live: jobRunning, total: jobCount),
              onTap: onTapJobs ?? () {},
            ),
            const SizedBox(width: 4),
          ],
          DshConnectionDotButton(
            state: connectionState,
            tooltip: connectionTooltip,
            onPressed: onConnectionTap,
          ),
          DshAppBarButton(
            icon: 'newChat',
            tooltip: '新建会话',
            onPressed: onNewSession,
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

/// 顶部分段控件（`.seg`，对话 / 轨迹）。
///
/// 数值取自原型：`padding:3` / `border-radius:999`，
/// 滑块（`.seg-ind`）随选中项平移 —— **这是动画，不是两个静态高亮**。
class DshSegmented extends StatelessWidget {
  const DshSegmented({
    super.key,
    required this.labels,
    required this.index,
    required this.onChanged,
  });

  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: DshColors.layer1,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i += 1)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(i),
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOutCubic,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    // 选中项有底色滑块（未选中透明）—— 这就是 `seg-ind`。
                    color: i == index ? DshColors.layer3 : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    labels[i],
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: i == index
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: i == index
                          ? DshColors.labelPrimary
                          : DshColors.labelSecondary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
