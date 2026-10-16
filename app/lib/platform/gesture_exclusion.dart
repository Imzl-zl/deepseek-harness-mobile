/// 让系统**别在指定区域抢"返回"手势**，把那两块边留给 App 内的边缘滑动。
///
/// ## 为什么要有这个文件
///
/// 左右两条屏幕边是 Android 手势导航里**系统返回**的地盘。App 想在边上做
/// "滑一下开抽屉"，就得先跟系统打个招呼 —— 官方那个招呼叫
/// `View.setSystemGestureExclusionRects` / `Window.setSystemGestureExclusionRects`
/// （Android 10 / API 29 起；见 Android Developers《Gesture Navigation:
/// handling gesture conflicts (III)》，<https://medium.com/androiddevelopers/gesture-navigation-handling-gesture-conflicts-8ee9c2665c69>）。
///
/// 不打招呼会怎样（2026-10-16 实测，小米 `d61cf622`）：从最外缘 ≈15dp 起手往内划，
/// 那一划被系统吃掉，**App 直接退回桌面**；把带子往内缩能躲开，但把手就不在边上了。
///
/// ## 官方限制（照抄，别踩）
///
/// - **每条边最多排除 200dp 的总高度**；请求超了，系统只认"最靠下"的那 200dp。
///   所以调用方给的带子高度是 192dp（4×48dp 触摸目标，留在上限内）。
/// - 这条 API 是**逃生舱**：用它等于声明"我这个手势比系统返回更重要"，
///   所以只该给真正需要的那一小块，不要整条边全包。
/// - 不在屏幕内的矩形不计入；`flutter_window` 之外的平台直接 no-op。
///
/// ## 这一层只做换算与转发
///
/// 入参是**逻辑坐标**（Flutter 的 `Rect`），这里换算成**物理像素**
/// （系统要的是物理像素、以窗口左上角为原点），再经 `dsh/gesture-exclusion` 通道过界。
library;

import 'package:flutter/services.dart';

/// 通道名（Android 侧 `MainActivity.kt` 里的同一个）。
const String _kChannel = 'dsh/gesture-exclusion';

const MethodChannel _channel = MethodChannel(_kChannel);

/// 把这几块**逻辑坐标**的区域声明为"系统手势不抢"。
///
/// @returns `true` = 系统真的收下了（Android 10+）；`false` = 这个平台/版本没有
/// 这条 API（iOS / 鸿蒙 / Android 9 及以下）—— 调用方**不要**据此做分支，
/// 边缘滑动本来就能用，这只是"别被系统抢"的增强。
Future<bool> excludeSystemGestureRects(
  List<Rect> rects, {
  double devicePixelRatio = 1,
}) async {
  final flat = <int>[];
  for (final rect in rects) {
    flat
      ..add((rect.left * devicePixelRatio).round())
      ..add((rect.top * devicePixelRatio).round())
      ..add((rect.right * devicePixelRatio).round())
      ..add((rect.bottom * devicePixelRatio).round());
  }
  try {
    final accepted = await _channel.invokeMethod<bool>('setRects', {
      'rects': flat,
    });
    return accepted ?? false;
  } on MissingPluginException {
    // 单测 / 桌面 / 未接这个通道的平台：如实说"没接"，不假装成功。
    return false;
  }
}
