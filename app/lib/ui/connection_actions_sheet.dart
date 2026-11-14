/// 连接操作 sheet —— 顶栏状态点 / 空态 / 抽屉连接行三处共用的一份内容。
///
/// ## 形状（2026-11-13 收窄）
///
/// 一级只放「当前 + 四个动作」：
///
/// ```
/// 当前连接块（走哪条 + 回落原因）
/// 切换电脑 / 切回上一台      ← 多台时才有
/// 换个连接方式
/// 重新连接（放弃自动重连后标题变「重试连接」）
/// 添加电脑
/// 重新配对（换一台电脑）
/// 断开连接
/// ```
///
/// 删掉的三条与理由：
///
/// - **「打开侧面板」**：右侧内容抽屉本来就能从右缘跟手拖出
///   （`chat_page.dart` 的 `endDrawer`），连接面板不该是它的第二个入口；
/// - **「手动填写电脑地址」**：挪进「换个连接方式」那张列表的末尾
///   （`+ 添加地址`）—— 那里才是"选哪条地址"的上下文；
/// - **「重试连接」单独一行**：与「重新连接」同义，现在只剩一行、按状态换标题。
///
/// 小字（副标题）只保留**不可从标题推断的后果**：会清凭据 / 保留这台 / 配对保留。
/// 其余说明一律删。取舍见 `.agents/notes/proposed/2026-11-13-connection-ux-redesign.md`。
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

/// 连接 sheet 里"换电脑"那几行需要的缝（装配层注入，页面只转发）。
///
/// 收成一条记录而不是四个参数：**它们总是一起出现**（有台数才有入口，
/// 有入口才谈得上"切回上一台"），拆开传只会多三处可能漏。
typedef HostSwitchSeam = ({
  /// 除了当前这台还有几台（0 = 不给「切换电脑」这一行）。
  int otherHostCount,
  VoidCallback? onSwitch,
  VoidCallback? onSwitchBack,
  String? switchBackLabel,
});

/// 弹出连接操作面板。取消（点遮罩 / 「取消」行）不触发任何动作。
///
/// [connection] 是顶部的「当前连接」块（一眼能看"走的哪条"，不用进设置）。
///
/// [anchor]：触发控件的矩形。给了就**长在那个点下面**（顶栏状态点），
/// 不给就是底部 sheet（空态 / 抽屉连接行）。
Future<void> showConnectionActionsSheet(
  BuildContext context, {
  required ConnectionSummary connection,
  required VoidCallback onRePair,
  VoidCallback? onDisconnect,

  /// **放弃自动重连**之后的那一条：给了它，「重新连接」这一行改标题为
  /// 「重试连接」并调它；两个回调不再各占一行。
  VoidCallback? onRetry,

  /// 重新拨一次（不改偏好）。
  VoidCallback? onReconnect,

  /// **换一条并进"连接方式"页**（策略三档 + 地址列表）。
  ///
  /// 2026-11-13 之前这里是「换个连接方式」= 只弹地址列表；策略三档没有入口，
  /// 且"先试哪条"藏在设置页第二组。两者合成一页后，这里只剩一个去处。
  VoidCallback? onOpenMode,

  /// 当前策略的名字（`自动` / `只用直连` / `只用中转`），做成右侧的值。
  String? routePolicyLabel,

  /// **切换电脑**的入口与"切回上一台"（`HostSwitchSeam`）。
  ///
  /// 切换是**用户动作**（方案决策 6/9）：这里只给入口，不自动挑一台、
  /// 也不在"连不上"时偷偷换 —— 那会变成"手机自己换了个电脑"。
  HostSwitchSeam? hostSwitch,

  /// **添加电脑**：进配对页**但不清凭据**（`null` = 不画这一行）。
  ///
  /// 与下面那行「重新配对（换一台电脑）」是两条路：那一条先 `clear()` 当前槽
  /// 再进页面（同一台换身份 / 身份被拒后重来），这一条**只加不删** ——
  /// `PairingStore.save` 按 `pcSignPubHex` 分槽写，另一台原样留着。
  ///
  /// 只在**已配对**时给：没配对时"添加"与"连电脑"是同一件事，多一行只会让人
  /// 在两个同义入口之间多看一眼。
  ///
  /// Note: 为什么它必须是"只加不删"的那一条 —— 见
  /// `.agents/notes/implemented/2026-11-08-add-computer-without-clearing.md`
  VoidCallback? onAddHost,

  /// 触发点矩形。`null` = 底部 sheet。
  Rect? anchor,
}) {
  final c = context.dshColors;
  // 只在确实有"上一台"时才有这一行（`null` / 空串都不给）。
  final switchBackLabel = hostSwitch?.switchBackLabel;
  // 两个回调合成一行：放弃自动重连时标题换成「重试连接」。
  final reconnectAction = onRetry ?? onReconnect;
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
        // 动作在下面各有自己的一行，比"点块里某处"更好找。
      ),
      // **切换电脑**排在最前：多机之后它比"换个连接方式"更常被用
      // （换的是"连哪台"，那一步同时换了凭据、端点表与界面桶）。
      if (hostSwitch != null &&
          hostSwitch.otherHostCount > 0 &&
          hostSwitch.onSwitch != null)
        ListTile(
          leading: const DshIcon(
            'workspaceTree',
            size: 18,
            color: DshColors.labelSecondary,
          ),
          title: const Text('切换电脑'),
          // 台数是**动态事实**，做成右侧的值，不写成一句副标题。
          trailing: Text(
            '${hostSwitch.otherHostCount} 台',
            style: TextStyle(fontSize: 13, color: c.labelSecondary),
          ),
          onTap: () {
            Navigator.of(inner).pop();
            hostSwitch.onSwitch?.call();
          },
        ),
      if (hostSwitch?.onSwitchBack != null)
        ListTile(
          leading: const DshIcon(
            'chevronLeft',
            size: 18,
            color: DshColors.labelSecondary,
          ),
          title: const Text('切回上一台'),
          // 电脑名是**动态事实**：不写名字这一行就只剩一个抽象动作。
          subtitle: Text(
            switchBackLabel == null || switchBackLabel.isEmpty
                ? '回到刚才那台电脑'
                : '回到「$switchBackLabel」',
          ),
          onTap: () {
            Navigator.of(inner).pop();
            hostSwitch?.onSwitchBack?.call();
          },
        ),
      if (onOpenMode != null)
        ListTile(
          leading: const DshIcon(
            'chevronsUpDown',
            size: 18,
            color: DshColors.labelSecondary,
          ),
          title: const Text('连接方式'),
          // 策略名是**动态事实**：做成右侧的值，不写一句副标题。
          trailing: routePolicyLabel == null
              ? null
              : Text(
                  routePolicyLabel,
                  style: TextStyle(fontSize: 13, color: c.labelSecondary),
                ),
          onTap: () {
            Navigator.of(inner).pop();
            // 回调必须由**页面**的 context 实现：这个面板的 context 此刻已随路由失效。
            onOpenMode();
          },
        ),
      if (reconnectAction != null)
        ListTile(
          leading: const DshIcon(
            'refresh',
            size: 18,
            color: DshColors.labelSecondary,
          ),
          // 同义动作只留一行：放弃自动重连（gaveUp）时它就是"再试一轮"。
          title: Text(onRetry != null ? '重试连接' : '重新连接'),
          onTap: () {
            Navigator.of(inner).pop();
            reconnectAction();
          },
        ),
      // **「添加电脑」紧挨在「重新配对」上面**：两行的后果相反（一个保留、
      // 一个清掉），分开摆等于让用户靠回忆区分。副标题那句"保留这台"
      // 是这一行的全部价值 —— 不写，它和下面那行在标题上看不出差别。
      if (onAddHost != null)
        ListTile(
          leading: const DshIcon(
            'projectAdd',
            size: 18,
            color: DshColors.labelSecondary,
          ),
          title: const Text('添加电脑'),
          subtitle: const Text('保留这台'),
          onTap: () {
            Navigator.of(inner).pop();
            onAddHost();
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
      if (onDisconnect != null)
        ListTile(
          // **只断链，不动凭据**：清凭据是「重新配对」的事。以前这一行写的是
          // "断开并清掉凭据"——一个日常动作顺手把配对抹了，误触之后得重新扫码
          // （用户原话："一般人谁会断开并清掉？误触怎么办？"）。
          leading: const DshIcon(
            'link',
            size: 18,
            color: DshColors.labelSecondary,
          ),
          title: const Text('断开连接'),
          subtitle: const Text('配对保留'),
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
      // **可滚动**：小屏上会 RenderFlex overflow —— 而"选项多到放不下"
      // 不该表现成一块黄黑条纹。正常屏仍然按内容高度贴底。
      child: SingleChildScrollView(child: content(inner)),
    ),
  );
}
