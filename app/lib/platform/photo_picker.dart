/// 选一张图（Android 系统照片选择器，经 `dsh/photo-picker` 通道）。
///
/// ## 为什么自己写通道，不引第三方 picker 插件
///
/// `app/` 下只有 `android/` / `ios/` / `windows/` 三个工程（**没有 `ohos/`**），
/// 而本仓 Flutter 版本的上界是留给鸿蒙 fork 的 —— 引一个走平台通道的第三方
/// 插件，等于把"鸿蒙能不能编过"交给别人的发布节奏。先例是
/// `platform/gesture_exclusion.dart`（同样是几十行的通道）。
///
/// ## 它只负责"拿到字节"，不负责业务判断
///
/// DSH 的图片 part 是 `{type:'image', mediaType, data(base64), name?}`
/// （`packages/api/session-controller/src/types.ts:90-98`，内联直发，
/// 不需要先 `uploadFile`）。本文件把原生回的那一包**校验成合法形状**
/// 并过滤掉 DSH 不认的媒体类型 —— 这两件事是纯函数，可单测。
///
/// **限额不在这里猜**：`ImageAttachmentLimits` 是电脑侧"部署解析"的
/// （`attachment/src/types.ts:74-82`），手机不知道，所以不预判大小；
/// 超了让电脑侧拒，把它的话如实显示。
library;

import 'package:flutter/services.dart';

/// 通道名（Android 侧 `MainActivity.kt` 里的同一个）。
const String _kChannel = 'dsh/photo-picker';

const MethodChannel _channel = MethodChannel(_kChannel);

/// DSH 认的图片媒体类型（`attachment/src/types.ts:8` 的 `ImageMediaType`）。
///
/// **只管这四个**：其余（heic / bmp / svg…）电脑侧会在准入时拒
/// （`types.ts:85-92` 的注释 "verified against the decoded bytes during
/// admission"），发过去只会多一次往返。
const Set<String> kSupportedImageMediaTypes = {
  'image/png',
  'image/jpeg',
  'image/webp',
  'image/gif',
};

/// 选图的来源。
enum PhotoSource {
  /// 系统相册 / 照片选择器（**不需要任何权限**）。
  gallery,

  /// 拍照。
  ///
  /// **它要 CAMERA 权限**：本 App 已经为配对页的扫一扫声明了 CAMERA，
  /// 而 Android 的规矩是"一旦声明，`ACTION_IMAGE_CAPTURE` 就要求它已授予"
  /// （否则 `SecurityException`）。原生侧会先查、没授予就申请。
  camera,
}

/// 选图的结果。
sealed class PhotoPickResult {
  const PhotoPickResult();
}

/// 选到了一张，且媒体类型受支持。
class PhotoPicked extends PhotoPickResult {
  const PhotoPicked({
    required this.mediaType,
    required this.data,
    required this.name,
    required this.byteCount,
  });

  final String mediaType;

  /// 规范 base64（无换行）—— 直接塞进图片 part 的 `data`。
  final String data;

  /// 显示名；原生取不到时是空串（不编一个）。
  final String name;

  final int byteCount;
}

/// 用户取消了（**不是错误**，界面什么都不用做）。
class PhotoPickCancelled extends PhotoPickResult {
  const PhotoPickCancelled();
}

/// 这个平台没有这个能力（桌面 / 未接通道 / 设备上没有可处理的选择器）。
class PhotoPickUnavailable extends PhotoPickResult {
  const PhotoPickUnavailable(this.reason);

  final String reason;
}

/// 选到了，但媒体类型 DSH 不认 —— **明确说出来**，而不是发过去被拒。
class PhotoPickUnsupportedType extends PhotoPickResult {
  const PhotoPickUnsupportedType(this.mediaType);

  final String mediaType;
}

/// 选图失败（读字节出错等）。[reason] 是原生给的原话。
class PhotoPickFailed extends PhotoPickResult {
  const PhotoPickFailed(this.reason);

  final String reason;
}

/// 拍照要相机权限，而用户没给（或拒了）。
///
/// **单独一种而不是并进 [PhotoPickFailed]**：恢复动作不同 ——
/// 这个要去系统设置里开权限，[reason] 只是原生的原话。
class PhotoPickPermissionDenied extends PhotoPickResult {
  const PhotoPickPermissionDenied(this.reason);

  final String reason;
}

/// 把原生回的那一包解析成结果。**纯函数**（单测直接喂各种形状）。
///
/// 认不出的形状一律 [PhotoPickFailed]：那是"原生实现与这边的约定不符"，
/// 不是"用户取消了" —— 两种混在一起会让"点了没反应"永远查不出来。
PhotoPickResult parsePhotoPickReply(Object? reply) {
  if (reply == null) return const PhotoPickCancelled();
  if (reply is! Map) {
    return const PhotoPickFailed('原生返回的形状不可识别');
  }
  final mediaType = reply['mediaType'];
  final data = reply['data'];
  if (mediaType is! String || mediaType.isEmpty) {
    return const PhotoPickFailed('原生没给 mediaType');
  }
  if (data is! String || data.isEmpty) {
    return const PhotoPickFailed('原生没给图片字节');
  }
  if (!kSupportedImageMediaTypes.contains(mediaType.toLowerCase())) {
    return PhotoPickUnsupportedType(mediaType);
  }
  final name = reply['name'];
  final byteCount = reply['byteCount'];
  return PhotoPicked(
    mediaType: mediaType.toLowerCase(),
    data: data,
    name: name is String ? name : '',
    // 原生给了就用它，没给按 base64 长度估（`4/3` 取整；只是显示用的提示，
    // 不参与任何判断）。
    byteCount: byteCount is int && byteCount >= 0
        ? byteCount
        : (data.length * 3) ~/ 4,
  );
}

/// 通道调用的注入点（只为测试）。参数是 `(method, args)`。
typedef PhotoPickInvoker =
    Future<Object?> Function(String method, Map<String, Object?> args);

/// 拉起相册或相机，拿一张图。
///
/// [invoke] 只为测试注入（默认走真通道）。**取消**、**平台没有**、
/// **权限被拒**都回确定的结果类型，不抛异常 —— 调用方按类型分支，
/// 不必 try/catch。
Future<PhotoPickResult> pickPhoto({
  PhotoSource source = PhotoSource.gallery,
  PhotoPickInvoker? invoke,
}) async {
  final call =
      invoke ?? (method, args) => _channel.invokeMethod<Object?>(method, args);
  try {
    return parsePhotoPickReply(
      await call('pickImage', {'source': source.name}),
    );
  } on MissingPluginException {
    // 单测 / 桌面 / 未接这个通道的平台：如实说"没接"。
    return const PhotoPickUnavailable('这个平台没有接选图通道');
  } on PlatformException catch (error) {
    // 原生明确报的错 —— 照它的原话，但把"权限"单独分出来
    // （它的恢复动作是进系统设置，不是重试）。
    if (error.code == 'camera-permission') {
      return PhotoPickPermissionDenied(error.message ?? error.code);
    }
    return PhotoPickFailed(error.message ?? error.code);
  }
}
