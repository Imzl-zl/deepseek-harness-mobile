/// 右缘那条「棒棒」：告诉用户**这一侧能划**，并顺手把两块边报给系统。
///
/// ## 它为什么只是一条棒棒
///
/// 用户原话（2026-10-16 第三轮）："右边的侧滑可以加一个之前那个棒棒啊，侧滑之后棒要消失啊"
/// —— 左边有顶栏的 `☰` 当入口，右边没有图标，所以右边只留一条**4×40 的半透明小棒**
/// 当标识；右抽屉（`Scaffold.endDrawer`）**开着的时候它消失**（那时它挡在抽屉上只会碍事）。
///
/// ## 手势是谁在管
///
/// 不是这里。两边都是 Flutter 原生的 `DrawerController`：
/// 左 = `Scaffold.drawer`、右 = `Scaffold.endDrawer`，`drawerEdgeDragWidth: 32` ——
/// **跟手**（手指拖多少抽屉走多少）、松手按位置/速度决定开还是回弹、遮罩点一下关闭，
/// 全是 `material/drawer.dart` 的 `_move` / `_settle`。这里只画那条棒棒。
///
/// ## 与系统返回手势的冲突
///
/// 靠**官方排除 API**，不是把棒棒往里挪（挪进去那一版被用户否了）：
/// `platform/gesture_exclusion.dart` 把左右各一块 32×192dp 的上半屏边带报给系统
/// （`View.setSystemGestureExclusionRects`，API 29+）。
///
/// 真机实测（小米 `d61cf622`，2026-10-16）：
/// - 不报 → 从最外缘（≈2dp）划一下，**系统返回把 App 退回桌面**；
/// - 报了 → 同一坐标稳稳开抽屉；
/// - 下半屏（y≈610dp）划一下 → 仍然归系统返回（App 退回桌面）—— 我们没抢它的活。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../platform/gesture_exclusion.dart';
import '../theme/dsh_colors.dart';

/// 报给系统的边带宽度（逻辑像素）。与 `Scaffold.drawerEdgeDragWidth` 同量级。
const double _kBandWidth = 32;

/// 边带高度。**必须 ≤ 200dp**：系统每条边最多排除 200dp 总高度
/// （超了只认"最靠下"的那 200dp）。192 = 4×48dp 触摸目标，留在上限内。
const double _kBandHeight = 192;

/// 棒棒：4×40 的圆角小条。
const double _kStickWidth = 4;
const double _kStickHeight = 40;

/// 右缘的标识 + 系统手势排除的报送。
///
/// 它应当放在**主内容之上**（`chat_page.dart` 的 `Stack` 里），
/// 且只在右抽屉关着时渲染。
class DshRightEdgeStick extends StatefulWidget {
  const DshRightEdgeStick({super.key, required this.topInset});

  /// 边带从哪开始（顶栏高度 + 状态栏）—— 顶栏自己那一条不抢。
  final double topInset;

  @override
  State<DshRightEdgeStick> createState() => _DshRightEdgeStickState();
}

class _DshRightEdgeStickState extends State<DshRightEdgeStick> {
  /// 上一次报给系统的矩形（串起来当键），同一组只报一次 —— build 会因各种原因重跑。
  String? _reportedKey;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bandTop = widget.topInset;
        final bandHeight = (constraints.maxHeight * 0.5).clamp(
          0.0,
          _kBandHeight,
        );
        if (bandHeight <= 0) return const SizedBox.shrink();
        // 左右两条边都报给系统：左抽屉靠它才能从最外缘跟手拖出，
        // 右抽屉（endDrawer）同理。矩形用**逻辑坐标**，换算在 platform 层。
        final left = Rect.fromLTWH(0, bandTop, _kBandWidth, bandHeight);
        final right = Rect.fromLTWH(
          constraints.maxWidth - _kBandWidth,
          bandTop,
          _kBandWidth,
          bandHeight,
        );
        _report(left, right);
        // 棒棒在带子里偏上一点 —— 拇指天然落点，不压住内容正中。
        final stickTop = bandTop + bandHeight * 0.35 - _kStickHeight / 2;
        return Stack(
          children: [
            Positioned(
              right: _kStickWidth + 2,
              top: stickTop,
              child: const _Stick(),
            ),
          ],
        );
      },
    );
  }

  /// 把两块边带报给系统："这两块别抢"。实测见文件头。
  void _report(Rect left, Rect right) {
    final key =
        '${left.left},${left.top},${left.right},${left.bottom}|'
        '${right.left},${right.top},${right.right},${right.bottom}';
    if (key == _reportedKey) return;
    _reportedKey = key;
    unawaited(
      excludeSystemGestureRects([
        left,
        right,
      ], devicePixelRatio: MediaQuery.of(context).devicePixelRatio),
    );
  }
}

/// 那条棒棒本身：半透明、不抢触摸（`IgnorePointer`）——它是**标识**，不是按钮。
///
/// 右边不加图标（用户："右侧侧滑不加图标啊"），所以它既不点也不亮，
/// 只是"这一侧能划"的一句话。
class _Stick extends StatelessWidget {
  const _Stick();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: _kStickWidth,
        height: _kStickHeight,
        decoration: BoxDecoration(
          color: DshColors.layer3,
          borderRadius: BorderRadius.circular(_kStickWidth / 2),
        ),
      ),
    );
  }
}
