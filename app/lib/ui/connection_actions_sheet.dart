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

import '../model/chat_item.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import 'connection_summary_block.dart';

/// 弹出连接操作 sheet。取消（点遮罩 / 「取消」行）不触发任何动作。
///
/// [connection] 是顶部的「当前连接」块（连接方式选择器第 1 步：一眼能看
/// "走的哪条"，不用进设置）。
///
/// **2026-10-18 起它也是切换与重连的入口**（用户："页面的右上角的点最好也可以
/// 点击切换方式重连"）：`onReconnect` / `onPickEndpoint` 两个回调把设置页顶部
/// 块的两个动作也搬到这里 —— 用户不必为了"换一条"专门进设置。
Future<void> showConnectionActionsSheet(
  BuildContext context, {
  required ConnectionSummary connection,
  required VoidCallback onRePair,
  VoidCallback? onOpenSide,
  VoidCallback? onDisconnect,
  VoidCallback? onRetry,

  /// 重新拨一次（不改偏好）。
  VoidCallback? onReconnect,

  /// 换一条并直接连（弹选择框的动作由调用方实现 —— 它持有 `AppModel`）。
  VoidCallback? onPickEndpoint,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: DshColors.layer1,
    builder: (context) => SafeArea(
      // **可滚动**：2026-10-18 加了「换个连接方式」「重新连接」两行之后，
      // 小屏上会 RenderFlex overflow —— 而"选项多到放不下"不该表现成
      // 一块黄黑条纹。正常屏仍然按内容高度贴底。
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConnectionSummaryBlock(
              connection: connection,
              // 块本身在 sheet 里**不可点**：sheet 已经展开，再点它没有去处。
              // 两个动作在下面各有自己的一行，比"点块里某处"更好找。
            ),
            if (onPickEndpoint != null)
              ListTile(
                leading: const DshIcon(
                  'chevronsUpDown',
                  size: 18,
                  color: DshColors.labelSecondary,
                ),
                title: const Text('换个连接方式'),
                subtitle: const Text('选一条并立刻用它连'),
                onTap: () {
                  Navigator.of(context).pop();
                  // 回调必须由**页面**的 context 实现（见下方参数说明）：
                  // 它内部要再开一个 sheet，而这个 sheet 的 context 此刻已随路由失效。
                  onPickEndpoint();
                },
              ),
            if (onReconnect != null)
              ListTile(
                leading: const DshIcon(
                  'refresh',
                  size: 18,
                  color: DshColors.labelSecondary,
                ),
                title: const Text('重新连接'),
                subtitle: const Text('电脑侧不动，按当前方式再拨一次'),
                onTap: () {
                  Navigator.of(context).pop();
                  onReconnect();
                },
              ),
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
                leading: const DshIcon(
                  'trash',
                  size: 18,
                  color: DshColors.error,
                ),
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
    ),
  );
}
