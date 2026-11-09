/// 选哪个通知实现。
///
/// **为什么选择点住在 `lib/platform/`**：`verify-platform-boundary.mjs` 的
/// `branch-whitelist` 只允许 `Platform.` 出现在 `lib/platform/**`
/// 与 `lib/ui/adaptive/**` —— `main.dart` 里写 `Platform.isAndroid` 会被判违规。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kReleaseMode;

import '../core/notify.dart';
import 'notify_android.dart';
import 'notify_memory.dart';

/// 安卓走真通道；非安卓宿主只有 debug 构建能用内存实现。
///
/// **release 下不静默降级**：iOS / 鸿蒙的通知实现还没落地，若 release 也回落到
/// [MemoryNotify]，手机上看不到任何提醒、日志里却一切正常 —— 那正是最难查的
/// "功能不存在"。所以 release 的非安卓宿主在**装配时**就抛 [UnsupportedError]。
///
/// `kReleaseMode` 是**编译期常量**，debug 构建里这个分支的结果在编译期就定了，
/// 所以"release 会抛"没有可执行的行为测试（`flutter test` 永远是 debug）。
/// 判据因此是源码形状断言：`test/assembly_invariants_test.dart` 的
/// 「notify 装配在 release 下不许静默降级」。判断不许挪到运行时变量上 ——
/// 那样 release 与 debug 的差别就不再是编译期事实，而是一份可以被读错的配置。
///
/// Note: 为什么 release 非安卓必须抛而不是回落 —— 见
/// `.agents/notes/implemented/2026-11-09-notify-release-throws-instead-of-degrading.md`
NotifyPort createNotifyPort() {
  if (Platform.isAndroid) return AndroidNotify();
  if (kReleaseMode) {
    throw UnsupportedError(
      '非 Android 宿主还没有通知实现：release 不许回落到 MemoryNotify'
      '（桌面调试请用 debug 构建）',
    );
  }
  return MemoryNotify();
}
