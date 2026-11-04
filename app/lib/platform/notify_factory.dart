/// 选哪个通知实现。**这是 `notify` 能力的唯一装配点。**
///
/// 为什么选择点住在 `lib/platform/`：`verify-platform-boundary.mjs` 的
/// `branch-whitelist` 只允许 `Platform.` 出现在 `lib/platform/**` 与
/// `lib/ui/adaptive/**` —— `main.dart` 里写 `Platform.isAndroid` 会被判违规。
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kReleaseMode;

import '../core/notify.dart';
import 'notify_android.dart';
import 'notify_memory.dart';

/// 安卓走真通道；debug / profile 的其它宿主（`flutter run -d windows`）用内存实现。
///
/// **release 里不许静默降级**（C1：通知属于"App 不在前台也要存在"的能力，每端必须真实现，
/// 见 `docs/subsystems/app-platform-boundaries.md` §3）。缺实现就在**启动那一刻**失败，
/// 而不是发版之后让用户等到"该响没响"才发现 —— 那种缺陷没有任何日志会指出来。
///
/// 用 `kReleaseMode` 而不是 `kDebugMode`：profile 构建（性能调试）不是发货产物，
/// 让它继续跑内存实现；只有 release 才是"用户手里那一份"。
///
/// 取舍见 `.agents/notes/implemented/2026-11-04-notify-fallback-fails-fast-in-release.md`。
NotifyPort createNotifyPort() {
  if (Platform.isAndroid) return AndroidNotify();
  if (!kReleaseMode) return MemoryNotify();
  throw UnsupportedError(
    '这一端还没有通知实现（C1 能力必须每端实现）。'
    '调试请用 debug / profile 构建；release 不允许静默降级成内存实现。',
  );
}
