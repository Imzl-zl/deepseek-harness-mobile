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
    this.size = 18,
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

/// 顶栏标题的**硬上限**。
///
/// 数值照 DSH 的 `.crumb { max-width: 220px }`
/// （`ui-conversation/src/client/skeleton/ConversationRoot.module.css:125-139`）——
/// 同一条"标题可以省略，但不许吃掉整行"的规矩。用户原话：
/// *"手机屏小,你需要限制大小,给子智能体,后台任务,这些留位置"*。
/// 390px 竖屏下，`☰ + 状态点 + 右抽屉 + ＋` 之后正好还放得下 220。
const double kDshTitleMaxWidth = 220;

/// 聊天页顶栏。
///
/// ```
/// ┌──────────────────────────────────────────┐
/// │ ☰  标题(≤220,超长省略)    ●   ▷   ⊕      │  height: 56px + safe-top
/// └──────────────────────────────────────────┘
/// ```
///
/// 每个位置只做一件事，**不互相抢占**（DSH 的分法：`.titleCluster{flex:1;min-width:0}`
/// 与 `.headerActions{flex:none}`，`ConversationRoot.module.css:83-89`、`:156-161`）：
///
/// - `☰` 开左抽屉；`＋` 新建会话；
/// - `●` 连接状态点 —— 点它弹**连接操作** sheet（重试 / 重新配对 / 断开）；
/// - `▷` **右抽屉入口**（`panelLeft` 镜像，照 DSH `ExpandButton` 的同一招）——
///   它原来是挂在状态位上的，状态位缩成点之后必须有自己的席位。
class ChatAppBar extends StatelessWidget implements PreferredSizeWidget {
  const ChatAppBar({
    super.key,
    required this.title,
    required this.onOpenDrawer,
    required this.onNewSession,
    required this.connectionState,
    required this.connectionTooltip,
    required this.onConnectionTap,
    required this.onOpenSide,
  });

  final String title;

  /// `☰` —— 主入口（会话抽屉）。
  final VoidCallback onOpenDrawer;

  /// `＋` —— 新建会话。
  final VoidCallback onNewSession;

  /// 连接状态点的语义（由调用方按 `ConnectionStateView` 映射）。
  final DshStateDotState connectionState;

  /// 状态点的 tooltip：文案来自 `model/chat_item.dart` 的 `connectionLabel` ——
  /// **同一个状态只有一套说法**（抽屉连接行、设置页、这里共用）。
  final String connectionTooltip;

  final VoidCallback onConnectionTap;

  /// 打开右抽屉（文件 / 任务 / 子智能体）。
  final VoidCallback onOpenSide;

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
          // `ConstrainedBox` 给标题**上限**（否则长标题吃光整行）。
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: kDshTitleMaxWidth),
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // **14px / w500：照 DSH Web 的 `.crumb`**（`ConversationRoot.module.css:125-139`
                  // 的 `font-size: 14px; line-height: 20px`，当前那条 `crumbCurrent` 是 w500）。
                  // 手机原来写 16 / w600 —— 比 Web 大一档、更重，用户点了名：
                  // "会话名字不能小点"（2026-10-16 真机反馈）。
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: DshColors.labelPrimary,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 2),
          DshConnectionDotButton(
            state: connectionState,
            tooltip: connectionTooltip,
            onPressed: onConnectionTap,
          ),
          DshAppBarButton(
            icon: 'panelLeft',
            mirrorX: true,
            tooltip: '打开右侧面板（文件 / 任务 / 子智能体）',
            onPressed: onOpenSide,
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
