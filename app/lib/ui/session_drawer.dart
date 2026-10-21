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

import 'dart:async';

import 'package:flutter/material.dart';

import '../model/workspace.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';
import 'collapsible_group.dart';
import 'dsh_sheet.dart';

/// 抽屉里的一行会话。
class DrawerSession {
  const DrawerSession({
    required this.sid,
    required this.title,
    required this.preview,
    required this.timeLabel,
    this.isActive = false,
    this.isPinned = false,
  });

  final String sid;
  final String title;

  /// 副标题（原型是最后一条消息的摘要，或"已完成 · N 轮"）。
  final String preview;

  /// 右侧时间（`3 分钟` / `14:20` / `昨天`）。
  final String timeLabel;

  /// 当前正在看的那个（`is-on`：左侧有活跃点、底色高亮）。
  final bool isActive;

  /// 在 `workspace.list` 的 `pinnedSessionIds` 里。显示时排在分组最前，
  /// 行尾还有一枚小图钉（DSH Web 的 `PinnedIndicator`，`Rows.tsx:660`）。
  final bool isPinned;
}

/// 一个分组（`.dsec` + 若干 `.drow`）。`label` 由调用方给：
/// 现在按**工作区**分（`bucketSessionsByWorkspace`），不是按日期。
class DrawerSection {
  const DrawerSection({
    required this.label,
    required this.sessions,
    this.workspaceId,
  });

  /// 工作区标题（`dsh-mobile` / `未分组` / `会话`）。
  final String label;

  final List<DrawerSession> sessions;

  /// 这个分组对应的 Host 工作区 id。`null` = **不是真工作区**（「未分组」兜底桶，
  /// 或拿不到工作区清单时的单桶「会话」）。
  ///
  /// 它只做一个判断：**组内上移/下移可不可点**。`workspace.insertSessionBefore`
  /// 要求 `workspaceId`，而这些桶里的会话没有归属 —— 菜单项留着但不可点，
  /// 与"边界项保留但不可点"同一条理由（菜单项跳位会让人点错）。
  /// 判据来自 `bucketSessionsByWorkspace` 的同一字段，不在这里重算归属。
  final String? workspaceId;

  /// 组内排序是否可用。
  bool get canReorder => workspaceId != null;
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
    this.onPin,
    this.onUnpin,
    this.onMove,
    this.onSearch,
  });

  final List<DrawerSection> sections;
  final DrawerConnection connection;
  final List<DrawerFootItem> footItems;

  final VoidCallback onNewSession;
  final void Function(DrawerSession session) onOpenSession;
  final VoidCallback onClose;

  /// 行动作（长按菜单）。`onMove` 的第二个参数是 Host 的 `beforeSid`：
  /// `null` = 移到末尾。
  ///
  /// **Web 的拖动排序在触屏上换成菜单里的「上移 / 下移」**（有意偏离：
  /// 长按菜单不会在滚动列表里误触发拖动；DSH 的拖动还要求"同置顶分区内"，
  /// 菜单用同样的门禁）。见 `docs/design-and-tech-plan.md` §6。
  final void Function(DrawerSession session)? onArchive;
  final void Function(DrawerSession session)? onPin;
  final void Function(DrawerSession session)? onUnpin;
  final void Function(DrawerSession session, String? beforeSid)? onMove;

  final ValueChanged<String>? onSearch;

  @override
  State<SessionDrawer> createState() => _SessionDrawerState();
}

class _SessionDrawerState extends State<SessionDrawer> {
  final _search = TextEditingController();

  /// 每个项目组的展开态（`label → 展开?`）。
  ///
  /// **缺省视为展开**：`_expanded[key] ?? true`。第一次看到就展开，
  /// 不要"默认全折叠"—— 那会让用户以为会话少了一半。
  ///
  /// **不落盘**：DSH 是 `setGroupExpanded(key, expanded)`
  /// （`ui-workspace/.../WorkspaceBrowser.tsx:281`），手机侧一期只记
  /// 这一次打开期间的记忆。落盘要知道每个组的稳定 key，而
  /// `WorkspaceGroup` 没有 id（只有 `workspaceId`，见 `model/workspace.dart`）。
  final Map<String, bool> _expanded = <String, bool>{};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Drawer(
      // 宽度 `min(86%, 360px)`：留一条缝能看见背后的聊天页，
      // 让"这是浮在上面的"这件事成立。
      width: MediaQuery.of(context).size.width * 0.86 > 360
          ? 360
          : MediaQuery.of(context).size.width * 0.86,
      backgroundColor: c.sidebar,
      // **右侧圆角 + 右边框**（`.drawer { border-right:1px solid l1;
      //   border-radius: 0 var(--r-panel) var(--r-panel) 0 }`）——
      // 少了这两样，抽屉看起来就是"整屏换了一页"，而不是"浮在聊天页上的面板"
      //（`--r-panel` = 28）。
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(DshRadius.panel),
          bottomRight: Radius.circular(DshRadius.panel),
        ),
        side: BorderSide(color: c.layer1),
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
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [c.accentBlue, c.roleAssistant],
                      ),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: const Center(
                      child: DshIcon('sparkle', size: 16, color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'DSH',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: c.labelPrimary,
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
                color: c.accentBlue,
                borderRadius: BorderRadius.circular(DshRadius.md),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: widget.onNewSession,
                  child: SizedBox(
                    height: 44,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        DshIcon('newChat', size: 18, color: c.onAccent),
                        const SizedBox(width: 8),
                        Text(
                          '新建会话',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: c.onAccent,
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
                  color: c.layer1,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  children: [
                    DshIcon('search', size: 15, color: c.labelCaption),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _search,
                        onChanged: widget.onSearch,
                        style: TextStyle(fontSize: 13, color: c.labelPrimary),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: '搜索会话',
                          hintStyle: TextStyle(
                            fontSize: 13,
                            color: c.labelCaption,
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
                  ? Center(
                      child: Text(
                        '还没有会话。',
                        style: TextStyle(fontSize: 13, color: c.labelTertiary),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      children: [
                        for (final section in widget.sections) ...[
                          // **可折叠的项目组头**（2026-10-19 用户原话：
                          // 「这个侧边栏会话列表，人家的每个项目的会话可以折叠的，
                          // 你没有啊」）。形态照 DSH Web 的
                          // `ui-workspace/src/client/rows/Rows.tsx:259-263`。
                          CollapsibleGroup(
                            label: section.label,
                            expanded: _expanded[section.label] ?? true,
                            onToggle: () => setState(
                              () => _expanded[section.label] =
                                  !(_expanded[section.label] ?? true),
                            ),
                            childCount: section.sessions.length,
                            // 当前会话在这个组里 ⇒ 折叠时也高亮
                            // （DSH 的 `containsCurrentDescendant`）。
                            containsCurrent: section.sessions.any(
                              (s) => s.isActive,
                            ),
                            children: [
                              for (final session in section.sessions)
                                _SessionRow(
                                  session: session,
                                  onTap: () => widget.onOpenSession(session),
                                  onLongPress: () =>
                                      unawaited(_showSessionMenu(session)),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
            ),

            // ---- 底栏五个出口 ----
            Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.layer1)),
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
                                color: c.labelSecondary,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                item.label,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: c.labelSecondary,
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

  /// 找会话所在的分组（行动作要在组内算上下邻）。
  DrawerSection? _sectionOf(String sid) {
    for (final section in widget.sections) {
      if (section.sessions.any((s) => s.sid == sid)) return section;
    }
    return null;
  }

  /// 行长按菜单。动作与 Web 的会话菜单同义（置顶 / 归档），
  /// 加上触屏需要的「上移 / 下移」。
  ///
  /// Note: 为什么是菜单不是拖动、为什么没有删除 —— 见
  /// `.agents/notes/implemented/2026-10-21-sidebar-session-pin-and-reorder.md`。
  Future<void> _showSessionMenu(DrawerSession session) async {
    final section = _sectionOf(session.sid);
    final rows = section?.sessions ?? const <DrawerSession>[];
    final pinned = {
      for (final row in rows)
        if (row.isPinned) row.sid,
    };
    final display = [for (final row in rows) row.sid];
    // 不是真工作区的组（「未分组」/ 没有工作区清单）**不能重排**：
    // `workspace.insertSessionBefore` 要 workspaceId，而这些会话没有归属。
    // 硬发出去只会得到一句失败 —— 所以菜单项留着但不可点，与边界项同一条理由。
    final reorderable = section?.canReorder ?? false;
    final up = !reorderable
        ? null
        : moveAnchorInDisplayOrder(
            displayOrder: display,
            sid: session.sid,
            delta: -1,
            pinnedSessionIds: pinned,
          );
    final down = !reorderable
        ? null
        : moveAnchorInDisplayOrder(
            displayOrder: display,
            sid: session.sid,
            delta: 1,
            pinnedSessionIds: pinned,
          );

    final action = await showDshSheet<_SessionMenuAction>(
      context: context,
      title: session.title,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SessionMenuRow(
            icon: session.isPinned ? 'pinFill' : 'pin',
            label: session.isPinned ? '取消置顶' : '置顶会话',
            onTap: () => Navigator.of(context).pop(
              session.isPinned
                  ? _SessionMenuAction.unpin
                  : _SessionMenuAction.pin,
            ),
          ),
          _SessionMenuRow(
            icon: 'chevronUp',
            label: '上移',
            onTap: up == null
                ? null
                : () => Navigator.of(context).pop(_SessionMenuAction.moveUp),
          ),
          _SessionMenuRow(
            icon: 'chevronDown',
            label: '下移',
            onTap: down == null
                ? null
                : () => Navigator.of(context).pop(_SessionMenuAction.moveDown),
          ),
          _SessionMenuRow(
            icon: 'archive',
            label: '归档',
            onTap: () => Navigator.of(context).pop(_SessionMenuAction.archive),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _SessionMenuAction.pin:
        widget.onPin?.call(session);
      case _SessionMenuAction.unpin:
        widget.onUnpin?.call(session);
      case _SessionMenuAction.moveUp:
        widget.onMove?.call(session, up?.beforeSid);
      case _SessionMenuAction.moveDown:
        widget.onMove?.call(session, down?.beforeSid);
      case _SessionMenuAction.archive:
        // 与 `ChatPageState._afterCurrentSheet` 同一条：归档失败会接着弹
        // 「停止并归档」对话框，而 sheet 的退出动画还没走完就开下一个浮层，
        // 后开的那个会被前一个的 pop 一起带走（真机踩过两次）。
        await Future<void>.delayed(const Duration(milliseconds: 260));
        if (mounted) widget.onArchive?.call(session);
    }
  }
}

/// 行长按菜单的一项。
enum _SessionMenuAction { pin, unpin, moveUp, moveDown, archive }

class _SessionMenuRow extends StatelessWidget {
  const _SessionMenuRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final String icon;
  final String label;

  /// `null` = 不可用（置顶分区边界）；**保留行**而不是隐藏 ——
  /// 隐藏会让菜单项在边界前后跳位，用户点错。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final enabled = onTap != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(DshRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
        child: Row(
          children: [
            DshIcon(
              icon,
              size: 18,
              color: enabled ? c.labelSecondary : c.labelTertiary,
            ),
            const SizedBox(width: 12),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: enabled ? c.labelPrimary : c.labelTertiary,
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
    final c = context.dshColors;
    final online = connection.online;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Material(
        color: c.layer1,
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
                    color: online ? c.roleContext : c.labelTertiary,
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
                        style: TextStyle(fontSize: 13, color: c.labelPrimary),
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
                          color: online ? c.labelCaption : c.roleTool,
                        ),
                      ),
                    ],
                  ),
                ),
                Text(
                  connection.platform,
                  style: TextStyle(fontSize: 11, color: c.labelCaption),
                ),
                const SizedBox(width: 4),
                DshIcon('chevronRight', size: 16, color: c.labelTertiary),
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
    required this.onLongPress,
  });

  final DrawerSession session;
  final VoidCallback onTap;

  /// 长按开行动作菜单（置顶 / 上移 / 下移 / 归档）。
  ///
  /// **不是删除**：DSH 的会话面没有删除方法（`workspace-controller` 只有
  /// 归档 / 取消归档 / 置顶 / 取消置顶）。旧代码把长按接到 `onDelete`，
  /// 而那个回调从未接线 —— 长按一直是死的。
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Material(
      color: session.isActive ? c.layer2 : Colors.transparent,
      borderRadius: BorderRadius.circular(DshRadius.sm),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
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
                  color: session.isActive ? c.accentBlue : Colors.transparent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            session.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              color: c.labelPrimary,
                            ),
                          ),
                        ),
                        // 置顶标记：DSH Web 的 `PinnedIndicator`（`Rows.tsx:660`）
                        // 是一枚**非交互**的小图钉，动作在菜单里。
                        if (session.isPinned) ...[
                          const SizedBox(width: 6),
                          DshIcon('pinFill', size: 12, color: c.labelTertiary),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      session.preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: c.labelCaption),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                session.timeLabel,
                style: TextStyle(fontSize: 11, color: c.labelTertiary),
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
    final c = context.dshColors;
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
            child: DshIcon(icon, size: 18, color: c.labelSecondary),
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
