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
  const SessionListPage({
    super.key,
    required this.app,
    this.paired = true,
    this.onConnect,
    this.onUnpaired,
  });

  final AppModel app;

  /// 是否已经配对（没配对时给一条"连电脑"的提示条）。
  final bool paired;

  /// 进配对页（**用户主动**）。
  final VoidCallback? onConnect;

  /// 清掉配对（换设备 / 连不上时重来）。
  final Future<void> Function()? onUnpaired;

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
    //
    // **没配对时不拉**：没有可信的电脑身份，那一定会失败并把
    // `relay/offline` 记进 `lastError` —— 而那条错误会盖住"你还没配对"这个真因。
    if (widget.paired) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(widget.app.refreshSessions());
      });
    }
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
          body: Column(
            children: [
              // 没配对时给一条**能点**的提示（而不是把界面挡住）：
              // 界面本来就该能看，只是数据要连上电脑才有。
              if (!widget.paired) _ConnectBanner(onConnect: widget.onConnect),
              if (widget.app.isPreview) _PreviewBanner(app: widget.app),
              Expanded(
                child: sessions.isEmpty
                    ? _EmptyBody(
                        app: widget.app,
                        paired: widget.paired,
                        onConnect: widget.onConnect,
                      )
                    : ListView.separated(
                        itemCount: sessions.length,
                        separatorBuilder: (_, _) => const Divider(
                          height: 1,
                          thickness: 1,
                          color: DshColors.layer2,
                        ),
                        itemBuilder: (context, index) => _SessionTile(
                          app: widget.app,
                          session: sessions[index],
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// "还没连电脑"的提示条（**能点**，不挡界面）。
class _ConnectBanner extends StatelessWidget {
  const _ConnectBanner({required this.onConnect});

  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: DshColors.layer1,
      child: InkWell(
        onTap: onConnect,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              DshIcon('globe', size: 16, color: DshColors.labelSecondary),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '还没连电脑：数据要连上才有。界面可以先看。',
                  style: TextStyle(
                    fontSize: 12,
                    color: DshColors.labelSecondary,
                  ),
                ),
              ),
              Text(
                '去配对',
                style: TextStyle(
                  fontSize: 12,
                  color: DshColors.accentBlue,
                  fontWeight: FontWeight.w600,
                ),
              ),
              DshIcon('chevronRight', size: 14, color: DshColors.accentBlue),
            ],
          ),
        ),
      ),
    );
  }
}

/// "这是示例数据"的提示条（**必须显眼**：不然会以为连上了）。
class _PreviewBanner extends StatelessWidget {
  const _PreviewBanner({required this.app});

  final AppModel app;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: DshColors.layer2,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const DshIcon('info', size: 14, color: DshColors.roleTool),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '示例数据（不是真实会话）',
              style: TextStyle(fontSize: 12, color: DshColors.roleTool),
            ),
          ),
          GestureDetector(
            onTap: () => app.clearPreview(),
            child: const Text(
              '清掉',
              style: TextStyle(fontSize: 12, color: DshColors.labelSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// 列表为空 / 出错时的提示。
///
/// **三种空要分开**（"真没有会话" / "还没配对" / "请求失败了"）：
/// 它们对用户是**三件不同的事**，混成一句会让人往错的方向查。
class _EmptyBody extends StatelessWidget {
  const _EmptyBody({required this.app, this.paired = true, this.onConnect});

  final AppModel app;

  /// 是否已配对（没配对时"空"的原因是"还没连"，不是"真没有"）。
  final bool paired;

  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) {
    final error = app.lastError;
    // **三种空分开说**（这一段是本页最有价值的文案）：
    // - 还没配对 → 原因是"没连电脑"，动作是"去配对"；
    // - 请求失败 → 原因是连接/中转，动作是"看错误码"；
    // - 真没有   → 原因是 DSH 里还没会话，动作是"去电脑上开一个"。
    final (icon, title, detail) = !paired
        ? ('globe', '还没连电脑', '界面可以先看。要看到真实会话，得先配对（在电脑上出码）。')
        : error != null
        ? (
            'warningTriangle',
            '没能取到会话列表',
            '${error.message}（${error.code.wire}）',
          )
        : ('newChat', '还没有会话', '在 DSH 里开一个会话，它会出现在这里');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            DshIcon(icon, size: 48, color: DshColors.labelTertiary),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(
                fontSize: 15,
                color: DshColors.labelSecondary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                color: DshColors.labelTertiary,
              ),
            ),
            const SizedBox(height: 24),
            // **两个入口，都不需要连电脑**：
            // "看示例数据"回答"这一版做出来是什么样"（那是布局问题唯一能更早暴露的方式）；
            // "去配对"是真正的下一步。
            if (app.sessions.isEmpty)
              OutlinedButton.icon(
                onPressed: () => app.loadPreview(),
                icon: const DshIcon(
                  'sparkle',
                  size: 14,
                  color: DshColors.labelSecondary,
                ),
                label: const Text('看示例数据'),
              ),
            if (!paired && onConnect != null) ...[
              const SizedBox(height: 8),
              FilledButton(
                onPressed: onConnect,
                style: FilledButton.styleFrom(
                  backgroundColor: DshColors.accentBlue,
                  foregroundColor: DshColors.onAccent,
                ),
                child: const Text('连电脑（配对）'),
              ),
            ],
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
