/// 锚定浮层：**从触发点长出来**的下拉卡片（不是从屏幕底部升上来的 sheet）。
///
/// ## 为什么要有这一层（2026-10-21 用户当场指出）
///
/// 原话：「点击切换智能体的弹出抽屉，点击在上面，下面弹出你不觉得不跟手吗？
/// 差太远了吧？」。点的是顶栏标题，卡片却从屏幕最底下滑上来 ——
/// 视线要跨过大半屏去找那个面板，**点击位置与结果位置对不上**。
///
/// DSH 的对应形态本来就是锚定下拉（`SubagentHeaderLineage.tsx:802-821` 的
/// 336px 浮层，挂在标题下方）。手机上没有 hover，但"浮层长在触发点旁边"
/// 这件事与有没有鼠标无关，只与视线有关。
///
/// 分工（**按触发点位置选，不按内容选**）：
///
/// | 触发点 | 形态 |
/// |---|---|
/// | 顶栏 / 列表上方（视线在上半屏） | [showDshPopover] |
/// | 输入栏 / 屏幕下半部 | `showDshSheet`（底部 sheet，拇指本来就够得着） |
///
/// ## 形态
///
/// 与 sheet 用同一套 token：`layer-1` 底、`border-l2` 发丝边、`r-lg` 圆角。
/// 宽度夹在 `[minWidth, maxWidth]` 之间并按锚点左对齐，**整块永远在屏内**
/// （窄屏上 360 的卡片贴着右边会溢出）。放不下就翻到锚点上方 ——
/// 顶栏下方的空间通常够，但顶栏在横屏/大字号下会变高。
library;

import 'package:flutter/material.dart';

import '../theme/dsh_colors.dart';
import '../theme/dsh_theme.dart';

/// 一个 `BuildContext` 在**屏幕坐标**里的矩形（锚定浮层用它定位）。
///
/// 锚点必须由**触发控件自己**量（只有它知道自己在哪）：调用点用 `Builder`
/// 拿到那枚控件的 context，再把它交给这里。
///
/// 拿不到（还没布局、或不在有 overlay 的树里）就给一个退化矩形 ——
/// 浮层会退到左上角贴边，仍然可读可点，而不是抛。
///
/// 坐标是**相对 overlay** 的：`showGeneralDialog` 的 `Stack` 铺在 overlay 上，
/// 用全局坐标在有状态栏 / 键盘的屏上会整体偏一段。
Rect dshAnchorOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return Rect.zero;
  final overlay = Navigator.of(context).overlay?.context.findRenderObject();
  final origin = overlay is RenderBox && overlay.hasSize
      ? box.localToGlobal(Offset.zero, ancestor: overlay)
      : box.localToGlobal(Offset.zero);
  return origin & box.size;
}

/// 浮层面板本体的 key（测试量矩形用）。
const Key popoverPanelKey = ValueKey<String>('dsh-popover-panel');

/// 弹出锚定浮层。点遮罩 / 返回键关闭；`Navigator.pop(value)` 带回结果。
///
/// [maxHeightFactor] 是面板最高占屏比：默认 `0.55`（再高就不像"从某处长出来的"，
/// 而像换了半屏内容）。**动作菜单**可以给更高（`0.8`）—— 那里内容是一串行，
/// 被截断的代价是"重新配对"要滚动才能点到。
Future<T?> showDshPopover<T>({
  required BuildContext context,
  required Rect anchor,
  required Widget body,
  String? title,
  double maxWidth = 360,
  double maxHeightFactor = 0.55,
}) {
  final size = MediaQuery.of(context).size;
  // 两侧各留 12：既贴不进安全区外，也让"这是浮层不是页面"看得出来。
  final width = (size.width - 24).clamp(0.0, maxWidth);
  final left = anchor.left.clamp(12.0, size.width - width - 12.0).toDouble();
  final maxHeight = size.height * maxHeightFactor;
  const gap = 6.0;
  final below = size.height - (anchor.bottom + gap) - 16;
  final above = anchor.top - gap - 16;
  // 下方放得下一张"够读"的卡片就不翻：翻转会让面板跳离视线。
  final fitsBelow = below >= 200 || below >= above;
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭',
    // **不要深色遮罩**：锚定下拉是"就地展开"，压暗整屏会把它读成一次跳转
    // （FSD 的 `ModalRoute` 默认会加遮罩，这里显式吃掉）。
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (context, _, _) => Stack(
      children: [
        Positioned(
          left: left,
          width: width,
          // 两个方向各用一个边：下方用 `top`、翻到上方用 `bottom`，
          // 这样"卡片多高"由内容决定，不需要先量一次。
          top: fitsBelow ? anchor.bottom + gap : null,
          bottom: fitsBelow ? null : size.height - anchor.top + gap,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: _PopoverFrame(title: title, child: body),
          ),
        ),
      ],
    ),
    transitionBuilder: (context, animation, _, child) {
      // 从**锚点那一侧**展开：120ms、8px 位移，够读出自哪来又不拖沓。
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: Offset(0, fitsBelow ? -0.04 : 0.04),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _PopoverFrame extends StatelessWidget {
  const _PopoverFrame({required this.title, required this.child});

  final String? title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final heading = title;
    // **必须是 `Material`，不是 `DecoratedBox`**：面板里放的是目录树，
    // 树行是 `InkWell` —— 没有 `Material` 祖先时它会在 build 期抛
    // 「No Material widget found」，整块面板连同行的文字一起消失
    // （2026-10-21 换锚定浮层时踩到，两条 sheet 用例当场红）。
    return Material(
      // 测试用它量面板矩形（跟手判据：面板顶边与触发点的距离）。
      // 同一时刻只会有一层浮层，所以固定 key 不会撞。
      key: popoverPanelKey,
      color: c.layer1,
      elevation: 8,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DshRadius.lg),
        side: BorderSide(color: c.borderL2, width: 0.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (heading != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
              child: Text(
                heading,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: c.labelSecondary,
                ),
              ),
            ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 8),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}
