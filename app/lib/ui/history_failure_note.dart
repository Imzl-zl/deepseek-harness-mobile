/// 翻更早的历史失败时的一行（会话流最上端）。
///
/// **为什么它单独一个文件**：`chat_page.dart` 本身 5000+ 行，`verify-size.mjs`
/// 把它钉在上限上（只降不升）。往那儿塞一个新组件会被门禁当场拦下 —— 那正是
/// 那条门禁想说的"别再往这里加东西"。
library;

import 'package:flutter/material.dart';

import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';

/// 翻更早的历史失败时，在**会话流最早那一端**留的一行。
///
/// ## 为什么需要它
///
/// `AppModel.loadOlderHistory` 失败时会把原因记进 `historyFailure`，而那条
/// 判据原来**没有任何界面消费者**（`app.historyFailure` 只在单测里被读过）。
/// 症状：用户往上滑、以为"历史就这么多"——实际上是一次失败的请求，而且
/// `hasOlderHistory` 故意没变假，于是每次滑到顶都会再发一次注定失败的请求。
///
/// ## 为什么这里没有"重试"按钮
///
/// 契约 §3.1 给 `session/window-missed` 的客户端动作是"重新订阅 → 走快照"，
/// 而那个动作就是 `openSession`（重进会话）。在行里放一个只调
/// `loadOlderHistory` 的按钮会**必然再失败一次** —— 那是假入口。
/// 所以这里只说实话：原因 + 怎么恢复。
class HistoryFailureNote extends StatelessWidget {
  const HistoryFailureNote({super.key, required this.reason});

  /// 失败原因（错误码或电脑侧给的一句话）。
  final String reason;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.layer2,
        borderRadius: BorderRadius.circular(DshRadius.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DshIcon('warningTriangle', size: 14, color: c.labelCaption),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '更早的历史没拿到',
                  style: TextStyle(fontSize: 13, color: c.labelPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  '$reason · 重新进入这个会话可恢复',
                  style: TextStyle(fontSize: 11, color: c.labelCaption),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
