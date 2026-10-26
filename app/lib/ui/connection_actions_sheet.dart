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
///
/// ## 两个形态，同一份内容
///
/// [anchor] 为 `null` ⇒ 底部 sheet（空态出路、抽屉连接行 —— 触发点就在下半屏）；
/// 给了锚点 ⇒ 锚定浮层（顶栏状态点）。用户 2026-10-21 原话：
/// 「这个 APP 还有多少这个种不跟手的操作习惯」—— 顶栏点、底部弹是同一类问题。
/// 内容只画一份：形态不同不该让「重新配对」的入口分成两份。
library;

import 'package:flutter/material.dart';

import '../model/chat_item.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import 'connection_summary_block.dart';
import 'dsh_popover.dart';

/// 弹出连接操作面板。取消（点遮罩 / 「取消」行）不触发任何动作。
///
/// [connection] 是顶部的「当前连接」块（连接方式选择器第 1 步：一眼能看
/// "走的哪条"，不用进设置）。
///
/// **2026-10-18 起它也是切换与重连的入口**（用户："页面的右上角的点最好也可以
/// 点击切换方式重连"）：`onReconnect` / `onPickEndpoint` 两个回调把设置页顶部
/// 块的两个动作也搬到这里 —— 用户不必为了"换一条"专门进设置。
///
/// [anchor]：触发控件的矩形。给了就**长在那个点下面**（顶栏状态点），
/// 不给就是底部 sheet（空态 / 抽屉连接行）。
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

  /// 填一个新地址**只加进表**（换了网络、旧地址全拨不通时的那条出路）。
  /// **不自动拨**：连不连是用户的动作。
  VoidCallback? onManualEndpoint,

  /// 触发点矩形。`null` = 底部 sheet。
  Rect? anchor,
}) {
  final c = context.dshColors;
  // 内容只画一份（形态不同，动作与文案不许漂移）。
  //
  // `inner` 必须是**面板路由自己的** context：行里的 `Navigator.pop()`
  // 要 pop 掉这一层，而不是调用方的页面。
  Widget content(BuildContext inner) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      ConnectionSummaryBlock(
        connection: connection,
        // 块本身在面板里**不可点**：面板已经展开，再点它没有去处。
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
            Navigator.of(inner).pop();
            // 回调必须由**页面**的 context 实现（见下方参数说明）：
            // 它内部要再开一个 sheet，而这个面板的 context 此刻已随路由失效。
            onPickEndpoint();
          },
        ),
      if (onManualEndpoint != null)
        ListTile(
          leading: const DshIcon(
            'plus',
            size: 18,
            color: DshColors.labelSecondary,
          ),
          title: const Text('手动填写电脑地址'),
          subtitle: const Text('换了网络连不上：填新地址，再自己选它连接'),
          onTap: () {
            Navigator.of(inner).pop();
            onManualEndpoint();
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
            Navigator.of(inner).pop();
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
            Navigator.of(inner).pop();
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
          Navigator.of(inner).pop();
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
            Navigator.of(inner).pop();
            onOpenSide();
          },
        ),
      if (onDisconnect != null)
        ListTile(
          leading: const DshIcon('trash', size: 18, color: DshColors.error),
          title: const Text('断开并清掉凭据'),
          onTap: () {
            Navigator.of(inner).pop();
            onDisconnect();
          },
        ),
      ListTile(
        title: const Center(child: Text('取消')),
        onTap: () => Navigator.of(inner).pop(),
      ),
    ],
  );

  if (anchor != null) {
    // **动作菜单给 0.8**（默认 0.55 会把「重新配对」挤到滚动区外，
    // 而它正是这个面板存在的理由之一）。
    return showDshPopover<void>(
      context: context,
      anchor: anchor,
      maxHeightFactor: 0.8,
      body: Builder(builder: content),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: c.layer1,
    builder: (inner) => SafeArea(
      // **可滚动**：2026-10-18 加了「换个连接方式」「重新连接」两行之后，
      // 小屏上会 RenderFlex overflow —— 而"选项多到放不下"不该表现成
      // 一块黄黑条纹。正常屏仍然按内容高度贴底。
      child: SingleChildScrollView(child: content(inner)),
    ),
  );
}
