/// 「能不能直接把新版本下下来」的装配点：**只有 Android 有 `DownloadManager`**。
///
/// ## 为什么这个判断必须住在 `platform/`
///
/// `node app/tools/verify-platform-boundary.mjs` 的 `branch-whitelist` 规定：
/// `defaultTargetPlatform` / `Platform.` 只能出现在 `app/lib/platform/**` 与
/// `app/lib/ui/adaptive/**`。`main.dart` 是装配点，但它**不是**放平台分支的地方
/// —— 与 `notify_factory.dart` / `transport_factory.dart` 同一条纪律。
///
/// ## 返回 `null` 是"这台设备没有这个能力"，不是兜底实现
///
/// 非 Android（桌面调试 / 将来鸿蒙）返回 `null`：`AppModel` 据此把动作退成
/// **复制下载链接**（`ui/settings_page.dart` 里如实说"这台设备不能直接下载"），
/// 而不是造一个假装能下载的空实现。判据属于"能力在不在"，不属于"失败兜底"。
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;

import 'app_update_downloader.dart';

/// 造一个"交给系统下载器"的动作；`null` = 这台设备不能直接下载 APK。
Future<void> Function({required Uri url, required String fileName})?
createAppUpdateDownloader() => defaultTargetPlatform == TargetPlatform.android
    ? startAppUpdateDownload
    : null;
