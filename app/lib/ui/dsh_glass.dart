/// 毛玻璃：对**已经画在它下面**的内容做高斯模糊。
///
/// ## 只给小面积固定控件用
///
/// `BackdropFilter` 的代价与面积成正比、且**每帧**都要重算。手机上给整屏做
/// 实时模糊，滚动时掉帧是稳定的（不是偶发）。所以本工程的用法是：
/// 输入栏、文件底栏这种"内容从它后面滚过去"的窄条用它，
/// 壁纸本身**保持清晰**（要模糊就把图模糊好再存，那不是这一层的活）。
///
/// ## 什么时候才挂它
///
/// 没有壁纸时它下面的东西是不透明的，模糊出来的还是同一块纯色 —— 白花 GPU。
/// 调用方的判据只有一条：**表面色是不是半透明**
/// （`context.dshColors.bgBase.a < 1`）。
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/widgets.dart';

import '../model/appearance.dart';

/// 一块毛玻璃。[child] 画在模糊层之上。
class DshGlass extends StatelessWidget {
  const DshGlass({
    super.key,
    required this.child,
    this.sigma = kGlassBlurSigma,
    this.borderRadius,
  });

  final Widget child;

  /// 模糊半径（逻辑像素）。
  final double sigma;

  /// 圆角；`null` 表示直角裁剪。
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    // **必须裁剪**：不裁的话模糊结果会从控件边缘溢出去，
    // 在壁纸上就是一圈糊掉的脏边。
    final blur = BackdropFilter(
      filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      child: child,
    );
    final radius = borderRadius;
    return radius == null
        ? ClipRect(child: blur)
        : ClipRRect(borderRadius: radius, child: blur);
  }
}
