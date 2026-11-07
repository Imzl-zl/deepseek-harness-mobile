import 'package:flutter/material.dart';

/// 三横线（`☰`）—— 顶栏开左抽屉那枚图标。
///
/// ## 为什么不进 `theme/dsh_icons.dart`
///
/// 那是**机生成**文件（DSH 图标集 → 原型 `icons.js` → Dart），手写进去会在下次
/// 抽取时被抹掉；而 DSH 的图标集里**没有** `☰`：桌面顶栏开的是"侧栏折叠"，
/// 用的是 `panelLeft`（`ui-sidebar/src/client/SidebarRoot.tsx:178-197`）。
///
/// ## 为什么不用 `panelLeft`
///
/// 手机这一步开的是**会话列表抽屉**，不是折叠侧栏；而 16px 的面板图标在 24dp 下
/// 就是一个空方框，认不出"点它会出去一张列表"（2026-11-07 真机："左上角图标有点丑"）。
/// 设计基线里这一格画的本来也是 `☰`（`dsh_app_bar.dart` 顶部的线框图）。
/// 于是这一枚**按基线画**，不进图标表；原型同一个按钮用的是同一组坐标的 inline SVG
/// （`mock/proto/index.html`），两边形状一致。
///
/// 尺寸与线宽按图标集的规矩走：16 的坐标系、线宽随尺寸等比（16 → 1.5，
/// 与 `panelLeft` 在 24dp 下的观感同重）。
class DshMenuGlyph extends StatelessWidget {
  const DshMenuGlyph({super.key, required this.size, required this.color});

  /// 目标边长（dp）。内部按 16 的坐标系等比缩放。
  final double size;

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _MenuPainter(color: color, strokeWidth: size * 1.5 / 16),
      ),
    );
  }
}

class _MenuPainter extends CustomPainter {
  const _MenuPainter({required this.color, required this.strokeWidth});

  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 16;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    // 16 坐标系：x 2.5 → 13.5，三条线 y = 4.5 / 8 / 11.5（等距、居中）。
    for (final y in const <double>[4.5, 8, 11.5]) {
      canvas.drawLine(
        Offset(2.5 * scale, y * scale),
        Offset(13.5 * scale, y * scale),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_MenuPainter old) =>
      old.color != color || old.strokeWidth != strokeWidth;
}
