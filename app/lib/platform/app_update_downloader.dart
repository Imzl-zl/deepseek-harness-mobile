/// 把新版本**直接下载**到系统下载目录（Android `DownloadManager`），以及本机 ABI。
///
/// ## 为什么自己写通道，不引第三方插件
///
/// 与 `platform/photo_picker.dart` 同一条理由：`app/` 下只有 `android/` / `ios/` /
/// `windows/` 三个工程（**没有 `ohos/`**），而本仓 Flutter 版本的上界是留给鸿蒙 fork 的
/// —— 引一个走平台通道的第三方插件，等于把"鸿蒙能不能编过"交给别人的发布节奏。
/// 而这件事在 Android 侧只有几十行（`MainActivity.kt` 的 `registerAppUpdate`）。
///
/// ## 为什么不是"打开浏览器"
///
/// 浏览器能不能落地一个 APK，取决于用户装了哪个浏览器、有没有下载权限；
/// 而 `DownloadManager` 一定落到 `Downloads/`、一定发通知、点开就是系统安装器。
/// "直接下载"这件事在 Android 上有标准答案，不要退化成跳网页。
///
/// ## ABI 从 `dart:ffi` 取，不新增通道
///
/// 发布物是按 ABI 拆包的（`release.yml` 的 `--split-per-abi`），装错 ABI 装不上。
/// 而 `Abi.current()` 在编译期就定死了目标 ABI —— 比在 Kotlin 侧再暴露一次
/// `Build.SUPPORTED_ABIS` 少一个通道、少一处能漂的映射。
library;

import 'dart:ffi' show Abi;

import 'package:flutter/services.dart';

/// 通道名（Android 侧 `MainActivity.kt` 的同一个）。
const String _kChannel = 'dsh/app-update';

const MethodChannel _channel = MethodChannel(_kChannel);

/// 本机 ABI 的**发布物后缀名**（`arm64-v8a` / `armeabi-v7a` / `x86_64`）。
///
/// 认不出（桌面 / 未来新增的 ABI）⇒ 空串 —— 挑包那时退到"任意 `.apk`"，
/// 判据在 `core/app_update.dart` 的 `apkAssetFor`。**这里不猜一个 ABI**。
String deviceAbiName() => switch (Abi.current()) {
  Abi.androidArm64 => 'arm64-v8a',
  Abi.androidArm => 'armeabi-v7a',
  Abi.androidX64 => 'x86_64',
  // iOS 永远装不了 APK；桌面同理。空串让挑包走兜底而不是给一个错的后缀。
  _ => '',
};

/// 交给系统下载器。**入队即返回**（不等下载完）：进度与完成通知都归系统。
///
/// 失败**抛异常**（`MissingPluginException` = 非 Android；`PlatformException` =
/// 原生侧拒了），由 `AppModel.downloadAppUpdate` 收成一句人话给界面。
Future<void> startAppUpdateDownload({
  required Uri url,
  required String fileName,
}) async {
  await _channel.invokeMethod<String>('download', {
    'url': url.toString(),
    'fileName': fileName,
  });
}
