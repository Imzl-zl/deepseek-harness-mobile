/// 壁纸层（`ui/dsh_wallpaper.dart`）+ 主题接线。
///
/// 守三件事：
///
/// 1. **没有壁纸时这一层不存在**（不画 `Image`）—— 它不该在任何"没设壁纸"的
///    界面上留下痕迹；
/// 2. 有壁纸时**图在内容下面**（顺序错了就是内容被盖住）；
/// 3. `DshTheme.*(surfaceAlpha:)` 的 `scaffoldBackgroundColor` 跟着透明度走 ——
///    它不透明的话页面底色这一整层就把壁纸盖住了。
///
/// **不在壁纸上叠遮罩**：那是 App 替用户决定"照片不够格"，已经删掉了。
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
  required int transparency,
  required bool dark,
}) => MaterialApp(
  theme: dark
      ? DshTheme.dark(surfaceAlpha: surfaceAlphaOf(transparency))
      : DshTheme.light(surfaceAlpha: surfaceAlphaOf(transparency)),
  home: DshWallpaperLayer(
    wallpaper: withWallpaper ? MemoryImage(_onePixelPng) : null,
    child: Builder(
      builder: (context) => Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: const Center(child: Text('内容')),
      ),
    ),
  ),
);

void main() {
  testWidgets('没设壁纸：不画图，内容照常', (tester) async {
    await tester.pumpWidget(
      _host(withWallpaper: false, transparency: 30, dark: true),
    );
    await tester.pump();

    expect(find.byType(Image), findsNothing);
    expect(find.text('内容'), findsOneWidget);
  });

  testWidgets('有壁纸：图在最底下、内容在最上面', (tester) async {
    await tester.pumpWidget(
      _host(withWallpaper: true, transparency: 30, dark: true),
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

  testWidgets('图上没有遮罩层（只有图 + 内容两件）', (tester) async {
    await tester.pumpWidget(
      _host(withWallpaper: true, transparency: 100, dark: true),
    );
    await tester.pump();
    final stack = tester.widget<Stack>(find.byType(Stack).first);
    expect(stack.children, hasLength(2), reason: '图 + 内容，没有第三层压暗');
  });

  testWidgets('Scaffold 底色跟着透明度走（否则壁纸被整块盖住）', (tester) async {
    await tester.pumpWidget(
      _host(withWallpaper: true, transparency: 40, dark: true),
    );
    await tester.pump();

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor!.a, closeTo(0.6, 0.001));

    // 100% 透明度：底色全透（不偷偷留一点底）。
    await tester.pumpWidget(
      _host(withWallpaper: true, transparency: 100, dark: true),
    );
    // `MaterialApp` 把主题包在 `AnimatedTheme` 里，换主题是一段补间 ——
    // 只 `pump()` 一帧仍读到旧值（实测拿到 0.6），要等它走完。
    await tester.pumpAndSettle();
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor!.a,
      0,
    );
  });
}
