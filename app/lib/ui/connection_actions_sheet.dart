/// 连接操作 sheet —— 议题 3「重新配对」的落点，形状照 `main.dart` 原有的
/// `_showConnectionSheet`（几个 `ListTile`，无标题框）。
///
/// ## 为什么单独一个件
///
/// "重新配对"有三个入口：**顶栏连接状态位**、**空态出路**、**抽屉连接行**。
/// 三者共用同一个 sheet —— 否则"重新配对"的入口会画成三份，迟早有一处漂移
/// （多一个选项 / 少一句后果 / 文案不一致），而用户卡住时看到的正是漂移的那一处。
///
/// 每个入口按自己够得着的缝传回调：
/// - `onRePair`：重新配对（换一台电脑）—— 清凭据 + 回配对页（装配层注入）。
/// - `onOpenSide`：打开右侧面板（聊天页内部够得着；抽屉入口也够得着）。
/// - `onDisconnect`：断开并清掉凭据，但**不**进配对页（装配层注入；聊天页不给）。
library;

import 'package:flutter/material.dart';

import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';

/// 弹出连接操作 sheet。取消（点遮罩 / 「取消」行）不触发任何动作。
Future<void> showConnectionActionsSheet(
  BuildContext context, {
  required VoidCallback onRePair,
  VoidCallback? onOpenSide,
  VoidCallback? onDisconnect,
  VoidCallback? onRetry,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: DshColors.layer1,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 「重试连接」只在**已经放弃自动重连**时给：那是"再试一轮"，
          // 与「重新配对（换一台电脑）」是两件事 —— 前者不动物料，后者清凭据。
          if (onRetry != null)
            ListTile(
              leading: const DshIcon(
                'refresh',
                size: 18,
                color: DshColors.labelSecondary,
              ),
              title: const Text('重试连接'),
              subtitle: const Text('电脑侧不动，只是再试一轮'),
              onTap: () {
                Navigator.of(context).pop();
                onRetry();
              },
            ),
          ListTile(
            leading: const DshIcon(
              'refresh',
              size: 18,
              color: DshColors.labelSecondary,
            ),
            title: const Text('重新配对（换一台电脑）'),
            subtitle: const Text('会清掉本机凭据，需要重新扫码'),
            onTap: () {
              Navigator.of(context).pop();
              onRePair();
            },
          ),
          if (onOpenSide != null)
            ListTile(
              leading: const DshIcon(
                'panelLeft',
                size: 18,
                color: DshColors.labelSecondary,
              ),
              title: const Text('打开侧面板'),
              onTap: () {
                Navigator.of(context).pop();
                onOpenSide();
              },
            ),
          if (onDisconnect != null)
            ListTile(
              leading: const DshIcon('trash', size: 18, color: DshColors.error),
              title: const Text('断开并清掉凭据'),
              onTap: () {
                Navigator.of(context).pop();
                onDisconnect();
              },
            ),
          ListTile(
            title: const Center(child: Text('取消')),
            onTap: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    ),
  );
}
