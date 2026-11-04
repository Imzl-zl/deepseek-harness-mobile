/// 输入法高度：**从原生量**，不信 `MediaQuery.viewInsets`。
///
/// ## 为什么要有这个文件
///
/// 2026-11-04 真机（Android 15+）：清单已改成 `adjustNothing`、页面也显式按
/// `viewInsets.bottom` 上移，输入栏**仍然**被键盘盖住。实测结论是
/// `MediaQuery.viewInsets.bottom` 在那台机器上恒为 0 —— edge-to-edge 下这个
/// Flutter 版本的引擎没把 IME inset 报上来。**Dart 侧再怎么写都没用**，高度只能
/// 由 `MainActivity` 从 `WindowInsetsCompat.Type.ime()` 直接量，再经这条通道报过来。
///
/// ## 为什么是 `max` 而不是"直接用它"
///
/// 别的机型上 `viewInsets` 是**正常有值**的（那时引擎报 24dp、原生也报 24dp）。
/// 调用方取两者的最大值，于是：
/// - 引擎不报（这台机器）→ 用原生的；
/// - 引擎报（其它机器）→ 两个相等，取谁都一样，**不会叠成两倍**。
///
/// 判据与取舍见 `.agents/notes/implemented/2026-11-04-ime-insets-on-android-15.md`。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 原生报上来的输入法高度（dp，未开时为 0）。
///
/// 是 `ValueNotifier` 而不是普通字段：键盘升降是**异步事件**，页面要靠它重建，
/// 而这是唯一的重建信号（没有第二处判据）。
class ImeInset {
  ImeInset._();

  static const MethodChannel _channel = MethodChannel('dsh/ime');

  /// 当前输入法高度（dp）。
  static final ValueNotifier<double> bottom = ValueNotifier<double>(0);

  /// 挂上回调。**只在装配点调一次**（`main()`），别在页面里调 ——
  /// 重复设置 handler 会让前一次静默失效。
  static void attach() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'inset') return null;
      final args = call.arguments;
      if (args is num) bottom.value = args.toDouble();
      return null;
    });
  }
}
