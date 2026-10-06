/// 会话列表页（`design-and-tech-plan.md` §7 的"会话列表"）。
///
/// ## 数据来源
///
/// `session.list` 的快照 + 本地条目表推导出的标题与待处理计数
/// （`app-channel-client.md` §6 的接线表）。**电脑侧不返回标题**，
/// 所以列表里的标题都来自本地（见 `SessionSummary.title`）。
///
/// ## 为什么这一页不认识帧
///
/// 它只读 `AppState` 的只读投影（`sessions` / `connection`）。
/// 认识帧、认识事件类型是 `core/` 与 `data/` 的事 —— UI 层一旦开始解析帧，
/// 同一件事就会在两个地方各写一遍，而它们迟早不一致。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/app_model.dart';
import '../../model/chat_item.dart';
import '../../theme/dsh_colors.dart';
import '../../theme/dsh_icons.dart';
import '../../theme/dsh_theme.dart';
import 'chat_page.dart';

/// 会话列表。
class SessionListPage extends StatefulWidget {
  const SessionListPage({super.key, required this.app});

  final AppModel app;

  @override
  State<SessionListPage> createState() => _SessionListPageState();
}

class _SessionListPageState extends State<SessionListPage> {
  @override
  void initState() {
    super.initState();
    // 进页面就拉一次列表（`session.list` 是只读方法，不需要幂等键）。
    // 放在首帧之后：`refreshSessions` 会 `notifyListeners`，而在 `initState` 里
    // 同步触发重建会让 Flutter 报"setState during build"。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(widget.app.refreshSessions());
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.app,
      builder: (context, _) {
        final sessions = widget.app.sessions;
        return Scaffold(
          backgroundColor: DshColors.bgBase,
          appBar: AppBar(
            backgroundColor: DshColors.sidebar,
            foregroundColor: DshColors.labelPrimary,
            title: const Text('会话'),
            // 连接状态放在标题栏：它是"这一页的数据可不可信"的前提。
            actions: [
              _ConnectionChip(state: widget.app.connection),
              IconButton(
                tooltip: '刷新',
                onPressed: () => unawaited(widget.app.refreshSessions()),
                icon: const DshIcon('refresh', color: DshColors.labelPrimary),
              ),
            ],
          ),
          body: sessions.isEmpty
              ? _EmptyBody(app: widget.app)
              : ListView.separated(
                  itemCount: sessions.length,
                  separatorBuilder: (_, _) => const Divider(
                    height: 1,
                    thickness: 1,
                    color: DshColors.layer2,
                  ),
                  itemBuilder: (context, index) =>
                      _SessionTile(app: widget.app, session: sessions[index]),
                ),
        );
      },
    );
  }
}

/// 列表为空 / 出错时的提示。
///
/// **两种空要分开**（`data/app_model.dart` 的 `lastError` 就是为此存在的）：
/// "真没有会话"与"请求失败了"对用户是两件事，混成一句会让人以为 DSH 里没有会话。
class _EmptyBody extends StatelessWidget {
  const _EmptyBody({required this.app});

  final AppModel app;

  @override
  Widget build(BuildContext context) {
    final error = app.lastError;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // **两种空用两个图标分开**：`newChat`（真没有会话，动作是"去建一个"）
            // 与 `warningTriangle`（取不到，动作是"检查连接"）。
            // DSH 图标集里没有"云断开"那个语义 —— 用它的告警三角形，
            // 而不是从 Material 借一个（那会破坏"图标只有一个来源"）。
            DshIcon(
              error == null ? 'newChat' : 'warningTriangle',
              size: 48,
              color: DshColors.labelTertiary,
            ),
            const SizedBox(height: 16),
            Text(
              error == null ? '还没有会话' : '没能取到会话列表',
              style: const TextStyle(
                fontSize: 15,
                color: DshColors.labelSecondary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error == null
                  ? '在 DSH 里开一个会话，它会出现在这里'
                  : '${error.message}（${error.code.wire}）',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                color: DshColors.labelTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 列表里的一行。
class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.app, required this.session});

  final AppModel app;
  final SessionSummary session;

  @override
  Widget build(BuildContext context) {
    final title = session.title.isEmpty ? '（未命名会话）' : session.title;
    return ListTile(
      tileColor: DshColors.bgBase,
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 15,
          color: DshColors.labelPrimary,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        session.itemCount == 0 ? session.sid : '${session.itemCount} 条',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, color: DshColors.labelCaption),
      ),
      trailing: session.pendingCount > 0
          ? _Badge(count: session.pendingCount)
          : const DshIcon(
              'chevronRight',
              size: 20,
              color: DshColors.labelTertiary,
            ),
      onTap: () async {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ChatPage(app: app, sid: session.sid),
          ),
        );
      },
    );
  }
}

/// 待处理角标。
class _Badge extends StatelessWidget {
  const _Badge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: DshColors.accentBlue,
        borderRadius: BorderRadius.circular(DshRadius.sm),
      ),
      child: Text(
        '$count',
        style: const TextStyle(
          fontSize: 12,
          color: DshColors.onAccent,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 连接状态 chip。
class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip({required this.state});

  final ConnectionStateView state;

  @override
  Widget build(BuildContext context) {
    final (color, dot) = switch (state) {
      ConnectionStateView.serving => (DshColors.roleContext, true),
      ConnectionStateView.backoff ||
      ConnectionStateView.connecting ||
      ConnectionStateView.handshaking => (DshColors.roleTool, false),
      _ => (DshColors.labelTertiary, false),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            connectionLabel(state),
            style: TextStyle(
              fontSize: 12,
              color: dot ? color : DshColors.labelSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
