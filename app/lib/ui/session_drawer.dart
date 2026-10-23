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
import 'dsh_brand.dart';
import 'dsh_popover.dart';

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
    this.onMoveWorkspace,
    this.onSearch,
  });

  final List<DrawerSection> sections;
  final DrawerConnection connection;
  final List<DrawerFootItem> footItems;

  final VoidCallback onNewSession;
  final void Function(DrawerSession session) onOpenSession;
  final VoidCallback onClose;

  /// 行动作（「…」菜单）。`onMove` 的第二个参数是 Host 的 `beforeSid`：
  /// `null` = 移到末尾。
  ///
  /// **排序的主路径是拖动**（与 Web 的 `Rows.tsx:249/602` 同一条）：
  /// 长按行开始拖、落到目标行的上半/下半决定插在它前/后。菜单里仍保留
  /// 「上移 / 下移」—— 拖动在滚动列表里对手指不友好，精确移动留一条退路。
  final void Function(DrawerSession session)? onArchive;
  final void Function(DrawerSession session)? onPin;
  final void Function(DrawerSession session)? onUnpin;
  final void Function(DrawerSession session, String? beforeSid)? onMove;

  /// 把一个**工作区**挪到 `beforeWorkspaceId` 之前（`null` = 移到末尾）。
  ///
  /// 与 [onMove] 是两条：那条改组内会话顺序，这条改**工作区自己**的顺序
  /// （侧栏项目头的上下位置）。走 `workspace.insertBefore`。
  final void Function(String workspaceId, String? beforeWorkspaceId)?
  onMoveWorkspace;

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

  /// 拖动时"最后扫过的那一格"（标记 + 松手提交）。会话行与项目头共用一份 ——
  /// 同一时刻只可能有一次拖动。机制见 [_DropHover]。
  final _DropHover _hover = _DropHover();

  @override
  void dispose() {
    _search.dispose();
    _hover.dispose();
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
            // ---- 头部：logo + App 名 + 新建 ----
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  // logo = **DSH 的图标**（与启动图标、助手头像同一枚图）。
                  const DshBrandMark(size: 28),
                  const SizedBox(width: 10),
                  Text(
                    'DeepSeek Harness',
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
                  child: ConstrainedBox(
                    // minHeight：界面字号放大后「新建会话」的文字行高会超过 44。
                    constraints: const BoxConstraints(minHeight: 44),
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
                // minHeight：搜索框里是输入文字，放大后行高会超过 36。
                constraints: const BoxConstraints(minHeight: 36),
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
                        for (var i = 0; i < widget.sections.length; i += 1) ...[
                          // **可折叠的项目组头**（2026-10-19 用户原话：
                          // 「这个侧边栏会话列表，人家的每个项目的会话可以折叠的，
                          // 你没有啊」）。形态照 DSH Web 的
                          // `ui-workspace/src/client/rows/Rows.tsx:259-263`。
                          //
                          // **项目头可拖**（2026-10-21 用户原话：「会话和工作区
                          // 都可以拖拽换位置而不是弹框啊」）：落到另一个头的
                          // 上半 = 插在它前面，下半 = 插在它后面（后者用
                          // "下一个工作区"当锚点，没有下一个就是移到末尾）。
                          CollapsibleGroup(
                            label: widget.sections[i].label,
                            expanded:
                                _expanded[widget.sections[i].label] ?? true,
                            onToggle: () => setState(
                              () => _expanded[widget.sections[i].label] =
                                  !(_expanded[widget.sections[i].label] ??
                                      true),
                            ),
                            childCount: widget.sections[i].sessions.length,
                            // 当前会话在这个组里 ⇒ 折叠时也高亮
                            // （DSH 的 `containsCurrentDescendant`）。
                            containsCurrent: widget.sections[i].sessions.any(
                              (s) => s.isActive,
                            ),
                            headerWrapper: _headerDragFor(i),
                            children: [
                              for (final session in widget.sections[i].sessions)
                                _SessionDrag(
                                  session: session,
                                  order: [
                                    for (final row
                                        in widget.sections[i].sessions)
                                      row.sid,
                                  ],
                                  pinned: {
                                    for (final row
                                        in widget.sections[i].sessions)
                                      if (row.isPinned) row.sid,
                                  },
                                  hover: _hover,
                                  onMove: widget.onMove,
                                  child: _SessionRow(
                                    session: session,
                                    onTap: () => widget.onOpenSession(session),
                                    onMenu: (anchor) => unawaited(
                                      _showSessionMenu(session, anchor),
                                    ),
                                  ),
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

  /// 项目头的拖动/落点包装。`null` = 这个组不是真工作区（「未分组」/ 没有
  /// 工作区清单），既不能拖也不能当落点 —— 与「上移/下移不可点」同一条理由：
  /// `workspace.insertBefore` 要 workspaceId，硬发只会失败。
  Widget Function(BuildContext, Widget)? _headerDragFor(int index) {
    final workspaceId = widget.sections[index].workspaceId;
    final onMove = widget.onMoveWorkspace;
    if (workspaceId == null || onMove == null) return null;
    return (context, header) => _WorkspaceDrag(
      workspaceId: workspaceId,
      nextWorkspaceId: _nextWorkspaceIdAfter(index),
      hover: _hover,
      onMove: onMove,
      child: header,
    );
  }

  /// 这个组**之后**第一个真工作区的 id（落到"下半"时的锚点；没有就是末尾）。
  String? _nextWorkspaceIdAfter(int index) {
    for (var i = index + 1; i < widget.sections.length; i += 1) {
      final id = widget.sections[i].workspaceId;
      if (id != null) return id;
    }
    return null;
  }

  /// 行长按菜单。动作与 Web 的会话菜单同义（置顶 / 归档），
  /// 加上触屏需要的「上移 / 下移」。
  ///
  /// **锚在那一行下面**（[anchor] 由 `_SessionRow` 自己量）：
  /// 长按的是列表里的某一行，菜单从屏幕底部升起来就是"点在上面、弹在下面"
  /// （用户 2026-10-21 对顶栏那条的原话，同一类问题）。
  ///
  /// Note: 为什么是菜单不是拖动、为什么没有删除 —— 见
  /// `.agents/notes/implemented/2026-10-21-sidebar-session-pin-and-reorder.md`。
  Future<void> _showSessionMenu(DrawerSession session, Rect anchor) async {
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

    final action = await showDshPopover<_SessionMenuAction>(
      context: context,
      anchor: anchor,
      title: session.title,
      // 菜单 4 行 + 标题：默认 0.55 足够，但行贴在屏幕底部时会翻到上方。
      body: Builder(
        builder: (inner) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SessionMenuRow(
              icon: session.isPinned ? 'pinFill' : 'pin',
              label: session.isPinned ? '取消置顶' : '置顶会话',
              onTap: () => Navigator.of(inner).pop(
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
                  : () => Navigator.of(inner).pop(_SessionMenuAction.moveUp),
            ),
            _SessionMenuRow(
              icon: 'chevronDown',
              label: '下移',
              onTap: down == null
                  ? null
                  : () => Navigator.of(inner).pop(_SessionMenuAction.moveDown),
            ),
            _SessionMenuRow(
              icon: 'archive',
              label: '归档',
              onTap: () => Navigator.of(inner).pop(_SessionMenuAction.archive),
            ),
          ],
        ),
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
    required this.onMenu,
  });

  final DrawerSession session;
  final VoidCallback onTap;

  /// 行尾「…」开行动作菜单（置顶 / 上移 / 下移 / 归档）。
  ///
  /// **长按不再开菜单**：长按现在是**拖动排序**（与 Web 的 `Rows.tsx:602` 同一条）。
  /// 两个手势不能抢同一个动作，所以菜单挪到行尾那枚「…」（Web 侧是 hover 出的
  /// 行内动作按钮，触屏上它得常显）。
  ///
  /// **回调带锚点矩形**：菜单要长在**被点的那一行**下面。锚点必须由这一行
  /// 自己量 —— 用抽屉或屏幕当锚点都会把菜单弹到别处（用户 2026-10-21 对顶栏
  /// 那条的原话「点击在上面，下面弹出你不觉得不跟手吗」，同一类问题）。
  ///
  /// **不是删除**：DSH 的会话面没有删除方法（`workspace-controller` 只有
  /// 归档 / 取消归档 / 置顶 / 取消置顶）。
  final void Function(Rect anchor) onMenu;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    // `Builder` 让下面这一行拿到**自己的** `RenderBox`（见 [dshAnchorOf]）。
    return Builder(
      builder: (row) => Material(
        color: session.isActive ? c.layer2 : Colors.transparent,
        borderRadius: BorderRadius.circular(DshRadius.sm),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.fromLTRB(12, 11, 4, 11),
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
                            DshIcon(
                              'pinFill',
                              size: 12,
                              color: c.labelTertiary,
                            ),
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
                const SizedBox(width: 6),
                Text(
                  session.timeLabel,
                  style: TextStyle(fontSize: 11, color: c.labelTertiary),
                ),
                // **行尾「…」**：菜单的唯一入口（长按已经给拖动了）。
                // 36×36 是触摸目标；`key` 让用例能按 sid 定位到具体那一行。
                SizedBox(
                  width: 36,
                  height: 36,
                  child: Material(
                    color: Colors.transparent,
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      key: ValueKey<String>('session-menu-${session.sid}'),
                      onTap: () => onMenu(dshAnchorOf(row)),
                      child: Center(
                        child: DshIcon(
                          'ellipsis',
                          size: 16,
                          color: c.labelTertiary,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 拖动时"最后扫过的那一格"：插入线画在哪、松手提交什么。
///
/// ## 为什么需要它（框架行为，2026-10-22 探针抓到）
///
/// Flutter 的 `DragTarget` 只在指针**进入**目标时问一次 `onWillAcceptWithDetails`
/// （`packages/flutter/lib/src/widgets/drag_target.dart:752-774` 的 `didEnter`），
/// 在目标内继续移动只走 `onMove`（`:804-808` 的 `didMove`）。
/// 所以"落在目标行的上半还是下半"**必须**在 `onMove` 里持续更新 ——
/// 只在 `onWillAccept` 里算，拿到的永远是"刚进入那一刻"的那一半。
///
/// 真机现象（`d61cf622`，探针日志见
/// `.agents/notes/implemented/2026-10-22-drawer-drag-insertion-line.md`）：
/// 往上拖时指针从**下方**进入上一行 ⇒ 那一刻是"下半" ⇒ 锚点 = 原地 ⇒ 静默拒绝；
/// 之后移到上半不再回调，于是一直拒绝 —— 用户读成"往上不动"。
///
/// 提交语义照 DSH Web：松手提交**最后扫过的那一格**
/// （`ui-workspace/src/client/WorkspaceBrowser.tsx:618` 的 `commitSessionDrag(drag, drag.over)`），
/// 即使松手时指针已经不在任何行上。
class _DropMark {
  const _DropMark(this.targetId, this.after);

  /// 被落上的那一行（会话 sid 或工作区 id）。
  final String targetId;

  /// 落在它的**下半**（= 插到它后面）。
  final bool after;

  @override
  bool operator ==(Object other) =>
      other is _DropMark && other.targetId == targetId && other.after == after;

  @override
  int get hashCode => Object.hash(targetId, after);
}

class _DropHover {
  /// 当前要画插入线的那一格；`null` = 没有标记。
  final ValueNotifier<_DropMark?> mark = ValueNotifier<_DropMark?>(null);

  /// 松手时提交的动作 —— 由**被扫到的那一行**提供：它知道自己的顺序与锚点。
  VoidCallback? _commit;

  void take(_DropMark next, VoidCallback commit) {
    _commit = commit;
    if (mark.value != next) mark.value = next;
  }

  /// 松手在空白 / 行间：提交最后扫过的那一格。
  void commitLast() => _commit?.call();

  void clear() {
    if (mark.value != null) mark.value = null;
    _commit = null;
  }

  void dispose() => mark.dispose();
}

/// 插入线 —— 照 DSH 的 `.workspaceDropBefore::before` / `.workspaceDropAfter::after`
/// （`packages/client/ui-workspace/src/client/rows/WorkspaceBrowser.module.css:451-493`）：
///
/// - 12px 高的带子画在落行的 `top: -8px`（前）/ `bottom: -8px`（后）；
/// - 左端一个 5×7 的斜角：55° 与 125° 两条 1px 斜线拼成「〈」；
/// - 从 `x = 4px` 到右边缘一条 2px 横线；
/// - 颜色 `--dsw-alias-state-business-primary`（= [DshColors.businessBlue]）。
/// 插入线的 key —— 用例靠它量"线画在哪一行、在那一行的上边还是下边"。
const Key sessionDropLineKey = ValueKey<String>('session-drop-line');

class _DropLine extends StatelessWidget {
  const _DropLine();

  @override
  Widget build(BuildContext context) => CustomPaint(
    key: sessionDropLineKey,
    painter: _DropLinePainter(context.dshColors.businessBlue),
    size: Size.infinite,
  );
}

class _DropLinePainter extends CustomPainter {
  const _DropLinePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    // 「〈」：两臂在左端 (0.8, 6) 交汇，上臂到 (5, 0.4)、下臂到 (5, 11.6)。
    canvas.drawLine(const Offset(0.8, 6), const Offset(5, 0.4), stroke);
    canvas.drawLine(const Offset(0.8, 6), const Offset(5, 11.6), stroke);
    // 2px 横线：从 x=4 到右边缘，压在这条带的 y=5..7。
    final width = size.width > 4 ? size.width - 4 : 0.0;
    canvas.drawRect(Rect.fromLTWH(4, 5, width, 2), Paint()..color = color);
  }

  @override
  bool shouldRepaint(_DropLinePainter oldDelegate) =>
      oldDelegate.color != color;
}

/// 会话行的**拖动 + 落点**。
///
/// - 长按行开始拖（`LongPressDraggable`，锚点用 `pointerDragAnchorStrategy`：
///   `DragTargetDetails.offset` 就是**手指位置**，不是被拖卡片左上角 ——
///   后者带一段触摸偏移，会让"落在上半还是下半"判错）；
/// - **落点跟着手指走**：`onMove` 里持续更新插入线与锚点，不是等松手（见 [_DropHover]）；
/// - 落在哪一行的上半/下半 → 插在它前/后（`dropAnchorInDisplayOrder`）；
/// - 置顶分区由模型函数挡：跨分区直接不接受（与 Web 的 `drag.pinned === node.pinned`
///   同一条），不弹错、不发请求。
class _SessionDrag extends StatefulWidget {
  const _SessionDrag({
    required this.session,
    required this.order,
    required this.pinned,
    required this.hover,
    required this.onMove,
    required this.child,
  });

  final DrawerSession session;

  /// 本组当前的显示顺序（已分区：置顶在前）。
  final List<String> order;

  /// 本组里置顶的 sid。
  final Set<String> pinned;

  /// 标记 + 松手提交的共用状态（抽屉一份）。
  final _DropHover hover;

  final void Function(DrawerSession session, String? beforeSid)? onMove;

  final Widget child;

  @override
  State<_SessionDrag> createState() => _SessionDragState();
}

class _SessionDragState extends State<_SessionDrag> {
  final _key = GlobalKey();

  /// 落点是**这一行**的哪一半（指针位置 vs 行矩形中线）。
  bool _afterAt(Offset pointer) {
    final context = _key.currentContext;
    if (context == null) return false;
    return pointer.dy > dshAnchorOf(context).center.dy;
  }

  /// "能不能落"**与指针落在哪一半无关**。
  ///
  /// 旧写法把 `dropAnchorInDisplayOrder` 塞进 `onWillAcceptWithDetails`，
  /// 而框架只在指针**进入**目标时问这一次（`packages/flutter/lib/src/widgets/drag_target.dart:752-774`）。
  /// 往上拖时指针一定从下方进入上一行 ⇒ 那一刻算出的永远是"落在它下半 = 原地"
  /// ⇒ 静默拒绝；之后移到上半**再也不会回调**（`:804-808` 只有 `onMove`）——
  /// 这就是真机上"往上不动"的机械原因（2026-10-22 探针日志见决策笔记）。
  bool _canAccept(DrawerSession data) {
    if (widget.onMove == null) return false;
    if (data.sid == widget.session.sid) return false;
    // 跨组（= 跨工作区）不做：宿主的重排按工作区账本，跨组没有对应方法。
    if (!widget.order.contains(data.sid)) return false;
    final pinned = widget.pinned;
    return pinned.contains(data.sid) == pinned.contains(widget.session.sid);
  }

  void _commit(DrawerSession data, bool after) {
    final anchor = dropAnchorInDisplayOrder(
      displayOrder: widget.order,
      sid: data.sid,
      targetSid: widget.session.sid,
      after: after,
      pinnedSessionIds: widget.pinned,
    );
    if (anchor == null) return;
    widget.onMove?.call(data, anchor.beforeSid);
  }

  @override
  Widget build(BuildContext context) {
    final onMove = widget.onMove;
    final canMove = onMove != null;
    // 行内容只建一次：标记变化只重建这个 `Stack`（同一个 widget 实例 ⇒
    // 行子树不会重建）。抽屉几十行，每次移动都重建整棵树会掉帧。
    final rowChild = SizedBox(key: _key, child: widget.child);
    final row = ValueListenableBuilder<_DropMark?>(
      valueListenable: widget.hover.mark,
      builder: (context, mark, _) => Stack(
        // 用例靠它量"这一行的矩形"（插入线是 Positioned，不影响 Stack 尺寸）。
        key: ValueKey<String>('session-drop-row-${widget.session.sid}'),
        clipBehavior: Clip.none,
        children: [
          rowChild,
          if (mark != null && mark.targetId == widget.session.sid)
            Positioned(
              left: 0,
              right: 0,
              height: 12,
              top: mark.after ? null : -8,
              bottom: mark.after ? -8 : null,
              child: const IgnorePointer(child: _DropLine()),
            ),
        ],
      ),
    );
    if (!canMove) return row;
    return DragTarget<DrawerSession>(
      onWillAcceptWithDetails: (details) => _canAccept(details.data),
      // **扫到就更新**：标记与锚点都在这里改（不是等松手）。
      onMove: (details) {
        final after = _afterAt(details.offset);
        final data = details.data;
        widget.hover.take(
          _DropMark(widget.session.sid, after),
          () => _commit(data, after),
        );
      },
      onAcceptWithDetails: (details) {
        final after = _afterAt(details.offset);
        widget.hover.clear();
        _commit(details.data, after);
      },
      builder: (context, candidates, rejected) =>
          LongPressDraggable<DrawerSession>(
            data: widget.session,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            feedback: _DragChip(label: widget.session.title),
            onDragEnd: (details) {
              // **松手在空白 / 行间也要提交**：提交"最后扫过的那一格"
              //（DSH `ui-workspace/src/client/WorkspaceBrowser.tsx:618` 同一条）。
              if (!details.wasAccepted) widget.hover.commitLast();
              widget.hover.clear();
            },
            childWhenDragging: Opacity(opacity: 0.35, child: row),
            child: row,
          ),
    );
  }
}

/// 项目头的**拖动 + 落点**（工作区排序）。
///
/// 落点是**另一个项目头**：上半 = 插到它前面，下半 = 插到它后面
/// （后者用"这个组之后第一个工作区"当锚点，没有下一个就是移到末尾）。
class _WorkspaceDrag extends StatefulWidget {
  const _WorkspaceDrag({
    required this.workspaceId,
    required this.nextWorkspaceId,
    required this.hover,
    required this.onMove,
    required this.child,
  });

  final String workspaceId;

  /// 这个组之后第一个真工作区的 id（落到下半时的锚点；`null` = 移到末尾）。
  final String? nextWorkspaceId;

  /// 标记 + 松手提交的共用状态（抽屉一份，与会话行同一个）。
  final _DropHover hover;

  final void Function(String workspaceId, String? beforeWorkspaceId) onMove;

  final Widget child;

  @override
  State<_WorkspaceDrag> createState() => _WorkspaceDragState();
}

class _WorkspaceDragState extends State<_WorkspaceDrag> {
  final _key = GlobalKey();

  /// 落点是**这个头**的哪一半（指针位置 vs 行矩形中线）。
  bool _afterAt(Offset pointer) {
    final context = _key.currentContext;
    if (context == null) return false;
    return pointer.dy > dshAnchorOf(context).center.dy;
  }

  void _commit(String draggedId, bool after) {
    final before = after ? widget.nextWorkspaceId : widget.workspaceId;
    // 落点就是自己"后面那一个" ⇒ 顺序不变，不发请求。
    if (before == draggedId) return;
    widget.onMove(draggedId, before);
  }

  @override
  Widget build(BuildContext context) {
    final headerChild = SizedBox(key: _key, child: widget.child);
    final header = ValueListenableBuilder<_DropMark?>(
      valueListenable: widget.hover.mark,
      builder: (context, mark, _) => Stack(
        clipBehavior: Clip.none,
        children: [
          headerChild,
          if (mark != null && mark.targetId == widget.workspaceId)
            Positioned(
              left: 0,
              right: 0,
              height: 12,
              top: mark.after ? null : -8,
              bottom: mark.after ? -8 : null,
              child: const IgnorePointer(child: _DropLine()),
            ),
        ],
      ),
    );
    return DragTarget<String>(
      // 拖到自己身上不接受（也不当落点高亮）。
      onWillAcceptWithDetails: (details) => details.data != widget.workspaceId,
      // **扫到就更新**：与 `_SessionDrag` 同一条（见 [_DropHover]）。
      onMove: (details) {
        final after = _afterAt(details.offset);
        final data = details.data;
        widget.hover.take(
          _DropMark(widget.workspaceId, after),
          () => _commit(data, after),
        );
      },
      onAcceptWithDetails: (details) {
        final after = _afterAt(details.offset);
        widget.hover.clear();
        _commit(details.data, after);
      },
      builder: (context, candidates, rejected) => LongPressDraggable<String>(
        data: widget.workspaceId,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: const _DragChip(label: '移动项目'),
        onDragEnd: (details) {
          if (!details.wasAccepted) widget.hover.commitLast();
          widget.hover.clear();
        },
        childWhenDragging: Opacity(opacity: 0.35, child: header),
        child: header,
      ),
    );
  }
}

/// 拖动时跟着手指的小卡片（**不是整行**：整行会挡住落点）。
class _DragChip extends StatelessWidget {
  const _DragChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Transform.translate(
      // `pointerDragAnchorStrategy` 把卡片左上角放在手指上；挪一截让它跟手。
      offset: const Offset(-16, -16),
      child: Material(
        color: c.layer1,
        elevation: 6,
        borderRadius: BorderRadius.circular(DshRadius.sm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: c.labelPrimary),
            ),
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
