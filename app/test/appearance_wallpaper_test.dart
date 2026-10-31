/// 壁纸层（`ui/dsh_wallpaper.dart`）+ 主题接线。
///
/// 守四件事：
///
/// 1. **没有壁纸时这一层不存在**（不画 `Image`、不画遮罩）—— 它不该在任何
///    "没设壁纸"的界面上留下痕迹；
/// 2. 有壁纸时**图在遮罩下面、内容在遮罩上面**（顺序错了就是内容被压暗或者图被盖住）；
/// 3. 遮罩不透明度走 `scrimOpacityFor`，不是各写一份；
/// 4. `DshTheme.*(surfaceAlpha:)` 的 `scaffoldBackgroundColor` 必须跟着半透明 ——
///    它不透明的话页面底色这一整层就把壁纸盖住了。
library;

import 'dart:convert' show base64Decode;
import 'dart:typed_data' show Uint8List;

import 'package:dsh_mobile/model/appearance.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/dsh_wallpaper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 1×1 的合法 PNG（够让 `Image` 有东西可解，又不必往仓库塞素材）。
final Uint8List _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Widget _host({
  required bool withWallpaper,
  required double surfaceAlpha,
  required bool dark,
}) => MaterialApp(
  theme: dark
      ? DshTheme.dark(surfaceAlpha: surfaceAlpha)
      : DshTheme.light(surfaceAlpha: surfaceAlpha),
  home: DshWallpaperLayer(
    wallpaper: withWallpaper ? MemoryImage(_onePixelPng) : null,
    surfaceAlpha: surfaceAlpha,
    dark: dark,
    child: Builder(
      builder: (context) => Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: const Center(child: Text('内容')),
      ),
    ),
  ),
);

void main() {
  testWidgets('没设壁纸：不画图、不画遮罩，内容照常', (tester) async {
    await tester.pumpWidget(
      _host(withWallpaper: false, surfaceAlpha: 0.7, dark: true),
    );
    await tester.pump();

    expect(find.byType(Image), findsNothing);
    expect(find.text('内容'), findsOneWidget);
    // **没有任何一层是"壁纸遮罩"**：按 `Scaffold` 自己的底色会画出 `ColoredBox`
    // （那是它内部实现），所以判据不是"有没有 ColoredBox"，而是"有没有那一档 alpha"。
    final scrims = tester
        .widgetList<ColoredBox>(find.byType(ColoredBox))
        .where((box) => (box.color.a - scrimOpacityFor(0.7)).abs() < 0.001);
    expect(scrims, isEmpty);
  });

  testWidgets('有壁纸：图在最底下、内容在最上面', (tester) async {
    await tester.pumpWidget(
      _host(withWallpaper: true, surfaceAlpha: 0.7, dark: true),
    );
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('内容'), findsOneWidget);

    // **顺序判据**：`Stack` 的孩子里 Image 在前、`Scaffold` 在后。
    final stack = tester.widget<Stack>(find.byType(Stack).first);
    final imageIndex = stack.children.indexWhere(
      (child) => child is RepaintBoundary,
    );
    final contentIndex = stack.children.length - 1;
    expect(imageIndex, 0, reason: '壁纸必须是第一层');
    expect(contentIndex, greaterThan(imageIndex));
  });

  testWidgets('遮罩不透明度来自 scrimOpacityFor，且压黑/压白跟着亮暗', (tester) async {
    const alpha = 0.7;
    await tester.pumpWidget(
      _host(withWallpaper: true, surfaceAlpha: alpha, dark: true),
    );
    await tester.pump();

    final scrim = tester.widget<ColoredBox>(
      find
          .descendant(
            of: find.byType(DshWallpaperLayer),
            matching: find.byType(ColoredBox),
          )
          .first,
    );
    expect(scrim.color.a, closeTo(scrimOpacityFor(alpha), 0.001));
    expect(scrim.color, const Color(0x00000000).withValues(alpha: scrim.color.a));
    // 深色主题压黑（R=G=B=0），不是压白。
    expect(scrim.color.r, 0);
    expect(scrim.color.g, 0);
    expect(scrim.color.b, 0);

    await tester.pumpWidget(
      _host(withWallpaper: true, surfaceAlpha: alpha, dark: false),
    );
    await tester.pump();
    final lightScrim = tester.widget<ColoredBox>(
      find
          .descendant(
            of: find.byType(DshWallpaperLayer),
            matching: find.byType(ColoredBox),
          )
          .first,
    );
    expect(lightScrim.color.r, 1);
    expect(lightScrim.color.a, closeTo(scrimOpacityFor(alpha), 0.001));
  });

  testWidgets('Scaffold 底色跟着通透度半透明（否则壁纸被整块盖住）', (tester) async {
    await tester.pumpWidget(
      _host(withWallpaper: true, surfaceAlpha: 0.6, dark: true),
    );
    await tester.pump();

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor!.a, closeTo(0.6, 0.001));
  });
}
