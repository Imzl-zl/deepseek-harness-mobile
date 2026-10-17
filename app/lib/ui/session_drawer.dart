/// 会话抽屉（照 `mock/proto/index.html` 的 `aside.drawer`）。
///
/// ## 它是主入口，不是"次要菜单"
///
/// `design-and-tech-plan.md` §6：**主屏 = 聊天页；会话历史在左侧抽屉**。
/// 所以这一层承载：新建会话、连接状态、搜索、按日期分组的会话列表、
/// 以及底栏的出口（文件 / 归档 / 设置）。
///
/// Note: 「演示」「自动化」2026-10-16 从底栏删除（前者配对后无用，后者是
/// C 类死桩）—— 见 `.agents/notes/implemented/2026-10-16-drawer-foot-drops-demo-and-automation.md`。
///
/// ## 数值（取自 `styles.css`，不是估的）
///
/// - 宽度 `min(86%, 360px)`；
/// - 会话行 `.drow`：`min-height:56`、`padding:11px 12px`、`gap:11`；
///   行内有 `dot`（活跃指示）+ 标题/副标题两行 + 右侧时间；
/// - 分区标题 `.dsec`（今天 / 昨天 / 更早）；
/// - 底栏 `.drawer-foot` 出口（2026-10-16 起三项：文件 / 归档 / 设置）。
///
/// ## 左缘跟手拖出 / 拖回关闭
///
/// 原型有（`.edge--open` 手势带）。Flutter 用 `Drawer` 的 `drawerEdgeDragWidth`
/// 得到同等效果 —— **不自己写手势**：`Drawer` 已经处理了
/// "拖动中改变遮罩透明度""松手回弹"这些细节，自写必漏。
library;

import 'package:flutter/material.dart';

import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';

/// 抽屉里的一行会话。
class DrawerSession {
  const DrawerSession({
    required this.sid,
    required this.title,
    required this.preview,
    required this.timeLabel,
    this.isActive = false,
  });

  final String sid;
  final String title;

  /// 副标题（原型是最后一条消息的摘要，或"已完成 · N 轮"）。
  final String preview;

  /// 右侧时间（`3 分钟` / `14:20` / `昨天`）。
  final String timeLabel;

  /// 当前正在看的那个（`is-on`：左侧有活跃点、底色高亮）。
  final bool isActive;
}

/// 按日期分组的会话（`.dsec` + 若干 `.drow`）。
class DrawerSection {
  const DrawerSection({required this.label, required this.sessions});

  /// `今天` / `昨天` / `更早`。
  final String label;

  final List<DrawerSession> sessions;
}

/// 连接状态（`.conn`）。
class DrawerConnection {
  const DrawerConnection({
    required this.name,
    required this.detail,
    required this.platform,
    this.online = false,
  });

  /// 设备名（`我的电脑`）。
  final String name;

  /// 状态描述（`中转已连接 · 空闲` / `未连接`）。
  final String detail;

  /// 平台（`Windows`）。
  final String platform;

  final bool online;
}

/// 抽屉底栏的一个出口（`.fitem`）。
class DrawerFootItem {
  const DrawerFootItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final String icon;
  final String label;
  final VoidCallback onTap;
}

/// 会话抽屉。
class SessionDrawer extends StatefulWidget {
  const SessionDrawer({
    super.key,
    required this.sections,
    required this.connection,
    required this.footItems,
    required this.onNewSession,
    required this.onOpenSession,
    required this.onClose,
    this.onArchive,
    this.onDelete,
    this.onSearch,
  });

  final List<DrawerSection> sections;
  final DrawerConnection connection;
  final List<DrawerFootItem> footItems;

  final VoidCallback onNewSession;
  final void Function(DrawerSession session) onOpenSession;
  final VoidCallback onClose;

  /// 左滑行露出的两个动作（`.drow-actions`）。
  final void Function(DrawerSession session)? onArchive;
  final void Function(DrawerSession session)? onDelete;

  final ValueChanged<String>? onSearch;

  @override
  State<SessionDrawer> createState() => _SessionDrawerState();
}

class _SessionDrawerState extends State<SessionDrawer> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      // 宽度 `min(86%, 360px)`：留一条缝能看见背后的聊天页，
      // 让"这是浮在上面的"这件事成立。
      width: MediaQuery.of(context).size.width * 0.86 > 360
          ? 360
          : MediaQuery.of(context).size.width * 0.86,
      backgroundColor: DshColors.sidebar,
      // **右侧圆角 + 右边框**（`.drawer { border-right:1px solid l1;
      //   border-radius: 0 var(--r-panel) var(--r-panel) 0 }`）——
      // 少了这两样，抽屉看起来就是"整屏换了一页"，而不是"浮在聊天页上的面板"
      //（`--r-panel` = 28）。
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topRight: Radius.circular(DshRadius.panel),
          bottomRight: Radius.circular(DshRadius.panel),
        ),
        side: BorderSide(color: DshColors.layer1),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ---- 头部：logo + DSH + 新建 ----
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [DshColors.accentBlue, DshColors.roleAssistant],
                      ),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const Center(
                      child: DshIcon('sparkle', size: 16, color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'DSH',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: DshColors.labelPrimary,
                    ),
                  ),
                  const Spacer(),
                  _Ib(
                    icon: 'newChat',
                    tooltip: '新建会话',
                    onPressed: widget.onNewSession,
                  ),
                ],
              ),
            ),

            // ---- 新建会话（主按钮）----
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Material(
                color: DshColors.accentBlue,
                borderRadius: BorderRadius.circular(DshRadius.md),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: widget.onNewSession,
                  child: const SizedBox(
                    height: 44,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        DshIcon('newChat', size: 18, color: DshColors.onAccent),
                        SizedBox(width: 8),
                        Text(
                          '新建会话',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: DshColors.onAccent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // ---- 连接状态（离线要显眼）----
            _ConnectionRow(
              connection: widget.connection,
              onTap: widget.onClose,
            ),

            // ---- 搜索 ----
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: DshColors.layer1,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  children: [
                    const DshIcon(
                      'search',
                      size: 15,
                      color: DshColors.labelCaption,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _search,
                        onChanged: widget.onSearch,
                        style: const TextStyle(
                          fontSize: 13,
                          color: DshColors.labelPrimary,
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: '搜索会话',
                          hintStyle: TextStyle(
                            fontSize: 13,
                            color: DshColors.labelCaption,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ---- 分组会话列表 ----
            Expanded(
              child: widget.sections.isEmpty
                  ? const Center(
                      child: Text(
                        '还没有会话。',
                        style: TextStyle(
                          fontSize: 13,
                          color: DshColors.labelTertiary,
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      children: [
                        for (final section in widget.sections) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                            child: Text(
                              section.label,
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: DshColors.labelCaption,
                              ),
                            ),
                          ),
                          for (final session in section.sessions)
                            _SessionRow(
                              session: session,
                              onTap: () => widget.onOpenSession(session),
                              onArchive: widget.onArchive == null
                                  ? null
                                  : () => widget.onArchive!(session),
                              onDelete: widget.onDelete == null
                                  ? null
                                  : () => widget.onDelete!(session),
                            ),
                        ],
                      ],
                    ),
            ),

            // ---- 底栏五个出口 ----
            Container(
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: DshColors.layer1)),
              ),
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  for (final item in widget.footItems)
                    Expanded(
                      child: InkWell(
                        onTap: item.onTap,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              DshIcon(
                                item.icon,
                                size: 18,
                                color: DshColors.labelSecondary,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                item.label,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: DshColors.labelSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 连接状态行（`.conn`）。
class _ConnectionRow extends StatelessWidget {
  const _ConnectionRow({required this.connection, required this.onTap});

  final DrawerConnection connection;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final online = connection.online;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Material(
        color: DshColors.layer1,
        borderRadius: BorderRadius.circular(DshRadius.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                // 状态点：在线绿、离线灰（原型 `.conn .g` / `.conn.is-off .g`）。
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: online
                        ? DshColors.roleContext
                        : DshColors.labelTertiary,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        connection.name,
                        style: const TextStyle(
                          fontSize: 13,
                          color: DshColors.labelPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        connection.detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          // 离线时用告警色：**"没连上"必须显眼**，
                          // 否则用户会把"空列表"当成"DSH 里没会话"。
                          color: online
                              ? DshColors.labelCaption
                              : DshColors.roleTool,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  connection.platform,
                  style: const TextStyle(
                    fontSize: 11,
                    color: DshColors.labelCaption,
                  ),
                ),
                const SizedBox(width: 4),
                const DshIcon(
                  'chevronRight',
                  size: 16,
                  color: DshColors.labelTertiary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 会话行（`.drow`）。
class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    required this.onTap,
    this.onArchive,
    this.onDelete,
  });

  final DrawerSession session;
  final VoidCallback onTap;
  final VoidCallback? onArchive;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: session.isActive ? DshColors.layer2 : Colors.transparent,
      borderRadius: BorderRadius.circular(DshRadius.sm),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        // 左滑露出归档 / 删除（`.drow-actions`）。
        onLongPress: onDelete,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              // 活跃点（`.drow .dot`）：正在看的那个有。
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: session.isActive
                      ? DshColors.accentBlue
                      : Colors.transparent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        color: DshColors.labelPrimary,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      session.preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: DshColors.labelCaption,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                session.timeLabel,
                style: const TextStyle(
                  fontSize: 11,
                  color: DshColors.labelTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 抽屉里的图标钮。
class _Ib extends StatelessWidget {
  const _Ib({required this.icon, required this.onPressed, this.tooltip});

  final String icon;
  final VoidCallback onPressed;
  final String? tooltip;

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
            child: DshIcon(icon, size: 18, color: DshColors.labelSecondary),
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
