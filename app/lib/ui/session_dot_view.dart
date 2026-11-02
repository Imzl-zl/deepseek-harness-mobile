/// 会话行首那枚状态点的**画法**：运行中转圈，其余三态是实心点。
///
/// ## 为什么运行中要转圈
///
/// 桌面就是这么画的：`ui-primitives/src/StateDot.tsx:51-68` 对 `ongoing`
/// 渲染一个 SVG spinner（轨道 + 弧，14px），其余状态是 10px 实心点。
/// 手机原来只有一枚**静态蓝点** —— 语义是对的，但"它在动"这件事看不出来，
/// 与桌面不一致（用户原话：「桌面的运行中的会话前面有个转圈圈…这个细节 APP 有没有？」）。
///
/// ## 尺寸照桌面
///
/// ongoing 14px、其余 8px（桌面是 10px；手机行高更紧，沿用本页原来的 8px，
/// 而转圈需要能看出弧，按桌面的 14px）。
///
/// ## 为什么不直接用 `CircularProgressIndicator`
///
/// Material 那枚带自己的厚度/留白与主题色（而且默认在浅色主题下是主色蓝，
/// 与 DSH 的 accent 不是同一个值）。这里 12 行 `CustomPaint` 就能照桌面的
/// "轨道 + 弧"画准，也不引视觉上的第二套语言。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../model/session_dot.dart';
import '../theme/dsh_colors.dart';

/// 一枚状态点。[SessionDot.ongoing] 画成旋转的弧，其余是实心圆。
class SessionDotView extends StatefulWidget {
  const SessionDotView({super.key, required this.dot});

  final SessionDot dot;

  @override
  State<SessionDotView> createState() => _SessionDotViewState();
}

class _SessionDotViewState extends State<SessionDotView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    // 桌面那枚 spinner 的节奏没写死在 props 里（CSS 变量），这里取 1.1s/圈：
    // 再快像卡住，再慢像没在转。
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    _syncSpin();
  }

  @override
  void didUpdateWidget(covariant SessionDotView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.dot != widget.dot) _syncSpin();
  }

  void _syncSpin() {
    // **只有运行中转**：其余三态不占 ticker（也不让测试里的 pumpAndSettle 卡住）。
    if (widget.dot == SessionDot.ongoing) {
      if (!_spin.isAnimating) unawaited(_spin.repeat());
    } else {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final color = switch (widget.dot) {
      SessionDot.warning => c.stateWarn,
      SessionDot.ongoing => c.accentBlue,
      SessionDot.done => c.stateSuccess,
      SessionDot.idle => c.stateIdle,
    };
    if (widget.dot != SessionDot.ongoing) {
      return Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      );
    }
    return RotationTransition(
      turns: _spin,
      child: CustomPaint(
        size: const Size.square(14),
        painter: _SpinnerPainter(color: color),
      ),
    );
  }
}

/// 轨道 + 弧（照桌面 `StateDot` 的两个 `<circle>`：轨道淡、弧实）。
class _SpinnerPainter extends CustomPainter {
  const _SpinnerPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(1, 1, size.width - 2, size.height - 2);
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = color.withValues(alpha: 0.22);
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawArc(rect, 0, math.pi * 2, false, track);
    // 四分之一圈：与桌面 spinner 的弧长同量级，转起来能看出方向。
    canvas.drawArc(rect, -math.pi / 2, math.pi / 2, false, arc);
  }

  @override
  bool shouldRepaint(covariant _SpinnerPainter oldDelegate) =>
      oldDelegate.color != color;
}
