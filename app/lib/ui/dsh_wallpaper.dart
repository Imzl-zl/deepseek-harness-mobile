/// 壁纸层：一张图垫在**整个 App** 下面。
///
/// 它挂在 `MaterialApp.builder` 里（`main.dart`），所以所有路由、所有 sheet
/// 都在它上面 —— 不需要每个页面各铺一次壁纸。
///
/// ## 不叠遮罩
///
/// 壁纸就是壁纸：这里不在图上压黑/压白。表面调到多透明、照片亮到什么程度，
/// 都由用户自己决定（透明度在设置里，`model/appearance.dart`）。
library;

import 'package:flutter/material.dart';

import '../theme/dsh_colors.dart';

/// 壁纸 + 内容。
class DshWallpaperLayer extends StatelessWidget {
  const DshWallpaperLayer({
    super.key,
    required this.wallpaper,
    required this.child,
  });

  /// 壁纸图；`null` = 没设（此时这一层**完全不画**，等于没有它）。
  ///
  /// 收 `ImageProvider` 而不是 `File`：`ui/` 不许 import `dart:io`
  /// （`app/tools/verify-platform-boundary.mjs` 的 `ui-no-platform-import`），
  /// 「图从哪来」属于装配层的事。
  final ImageProvider? wallpaper;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final image = wallpaper;
    if (image == null) return child;
    // 按屏幕像素宽解码：4K 原图整张进内存是几十 MB，而壁纸只会被铺满屏幕。
    final media = MediaQuery.maybeOf(context);
    final cacheWidth = media == null
        ? null
        : (media.size.width * media.devicePixelRatio).round();
    // 原始 `ImageProvider` 上没有 `cacheWidth` 这个开关（那是 `Image.file` 一类
    // 具名构造替你包的 `ResizeImage`）。这里自己包一层：
    // `resizeIfNeeded` 在两个值都为 null 时原样返回 provider。
    return Stack(
      fit: StackFit.expand,
      children: [
        // **独立的重绘边界**：壁纸一辈子不变，滚动时不该跟着重画。
        RepaintBoundary(
          child: Image(
            image: ResizeImage.resizeIfNeeded(cacheWidth, null, image),
            fit: BoxFit.cover,
            // 文件被外部改坏（清数据、写了一半）时的退路：退回页面底色。
            // 选图保存**之前**已经解码验证过一次（`main.dart` 的 `_pickWallpaper`），
            // 所以走到这里只可能是磁盘上的图后来坏了。
            errorBuilder: (context, error, stack) =>
                ColoredBox(color: context.dshColors.bgBase),
          ),
        ),
        child,
      ],
    );
  }
}
