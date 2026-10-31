/// 通透度与壁纸的纯逻辑（`model/appearance.dart`）+ 色板派生（`DshColorTokens`）。
///
/// 守四件事：
///
/// 1. **夹取**：低于下限夹到下限、高于 1 夹到 1、坏值（NaN）当"关闭"；
/// 2. **落盘是整数百分数**：55..100 往返不失真（浮点尾数不许把 70% 读成 69%）；
/// 3. **遮罩随通透度反向增长**：关闭时是 0（表面本来就不透明），最通透时最大；
/// 4. **只降表面，不降文字**：`DshTheme.dark(surfaceAlpha: x)` 里 `bgBase.a` 变了，
///    而 `labelPrimary.a` 必须仍是 1 —— 文字也跟着半透明就等于读不出字。
library;

import 'package:dsh_mobile/model/appearance.dart';
import 'package:dsh_mobile/theme/dsh_colors.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:flutter/material.dart' show Brightness;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('夹取', () {
    test('落在区间内的值原样返回', () {
      expect(clampSurfaceAlpha(0.7), 0.7);
      expect(clampSurfaceAlpha(kSurfaceAlphaOpaque), kSurfaceAlphaOpaque);
    });

    test('低于下限夹到下限、高于 1 夹到 1', () {
      expect(clampSurfaceAlpha(0.1), kSurfaceAlphaMin);
      expect(clampSurfaceAlpha(-5), kSurfaceAlphaMin);
      expect(clampSurfaceAlpha(3), kSurfaceAlphaOpaque);
    });

    test('NaN 当关闭（盘上坏值不该把界面画没）', () {
      expect(clampSurfaceAlpha(double.nan), kSurfaceAlphaOpaque);
    });
  });

  group('落盘值', () {
    test('整数百分数往返不失真', () {
      for (var percent = 55; percent <= 100; percent += 1) {
        final alpha = surfaceAlphaFromWire(percent);
        expect(surfaceAlphaToWire(alpha), percent, reason: '第 $percent 档');
      }
    });

    test('没存过等于关闭（默认不变样）', () {
      expect(surfaceAlphaFromWire(null), kSurfaceAlphaOpaque);
      expect(surfaceAlphaFromWire(0), kSurfaceAlphaMin);
      expect(surfaceAlphaFromWire(999), kSurfaceAlphaOpaque);
    });

    test('默认壁纸档位也在合法区间内', () {
      expect(clampSurfaceAlpha(kSurfaceAlphaOnWallpaper), kSurfaceAlphaOnWallpaper);
    });
  });

  test('文案：关闭 / 百分数', () {
    expect(surfaceAlphaLabel(kSurfaceAlphaOpaque), '关闭');
    expect(surfaceAlphaLabel(1.4), '关闭');
    expect(surfaceAlphaLabel(0.7), '70%');
    expect(surfaceAlphaLabel(0.1), '55%');
  });

  group('遮罩', () {
    test('关闭时为 0，最通透时为最大值', () {
      expect(scrimOpacityFor(kSurfaceAlphaOpaque), 0);
      expect(scrimOpacityFor(kSurfaceAlphaMin), kScrimOpacityMax);
    });

    test('随通透度反向增长（越透遮罩越重）', () {
      final tight = scrimOpacityFor(0.95);
      final mid = scrimOpacityFor(0.75);
      final loose = scrimOpacityFor(kSurfaceAlphaMin);
      expect(tight, lessThan(mid));
      expect(mid, lessThan(loose));
    });
  });

  group('色板派生', () {
    test('默认（不通透）表面色与两个色板类完全一致', () {
      final tokens = DshTheme.dark().extension<DshColorTokens>()!;
      expect(tokens.bgBase, DshColors.bgBase);
      expect(tokens.layer1, DshColors.layer1);
      expect(tokens.composer, DshColors.composer);
    });

    test('给了通透度：表面降 alpha、文字保持不透明', () {
      final tokens = DshTheme.dark(
        surfaceAlpha: 0.7,
      ).extension<DshColorTokens>()!;
      // RGB 不变（还是那个色），只有 alpha 变 —— 否则整套配色就漂了。
      expect(tokens.bgBase.a, closeTo(0.7, 0.001));
      expect(tokens.layer1.a, closeTo(0.7, 0.001));
      expect(tokens.composer.a, closeTo(0.7, 0.001));
      expect(tokens.bgBase.r, DshColors.bgBase.r);
      expect(tokens.labelPrimary, DshColors.labelPrimary);
      expect(tokens.labelPrimary.a, 1);
      expect(tokens.accentBlue.a, 1);
    });

    test('浅色套同样只降表面', () {
      final tokens = DshTheme.light(
        surfaceAlpha: 0.6,
      ).extension<DshColorTokens>()!;
      expect(tokens.brightness, Brightness.light);
      expect(tokens.bgBase.a, closeTo(0.6, 0.001));
      expect(tokens.labelPrimary, DshLightColors.labelPrimary);
    });
  });
}
