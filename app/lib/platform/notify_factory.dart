/// 选哪个通知实现。
///
/// **为什么选择点住在 `lib/platform/`**：`verify-platform-boundary.mjs` 的
/// `branch-whitelist` 只允许 `Platform.` 出现在 `packages/**`、`lib/platform/**`
/// 与 `lib/ui/adaptive/**` —— `main.dart` 里写 `Platform.isAndroid` 会被判违规。
library;

import 'dart:io' show Platform;

import '../core/notify.dart';
import 'notify_android.dart';
import 'notify_memory.dart';

/// 安卓走真通道；其余宿主（`flutter run -d windows` 调试）用内存实现。
///
/// **不留"假成功"**：桌面调试时通知不会真的出现，但 `MemoryNotify` 会把每次
/// 调用记下来，所以"该贴的贴了没有"仍然可查（只是一眼看不出观感）。
NotifyPort createNotifyPort() =>
    Platform.isAndroid ? AndroidNotify() : MemoryNotify();
