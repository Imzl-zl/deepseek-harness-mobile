/// 透明度与壁纸的纯逻辑（`model/appearance.dart`）+ 色板派生（`DshColorTokens`）。
///
/// 守四件事：
///
/// 1. **两头都可用**：`0%`（实心）与 `100%`（全透）都不被挡 —— 没有产品下限；
/// 2. **落盘是整数百分数**：`0`..`100` 往返不失真；
/// 3. `100%` 透明度 ⇒ 表面 alpha 0；`0%` ⇒ alpha 1；中间线性；
/// 4. **只降表面，不降文字**：`DshTheme.dark(surfaceAlpha: x)` 里 `bgBase.a` 变了，
///    而 `labelPrimary.a` 必须仍是 1 —— 文字也跟着半透明就等于读不出字。
library;

import 'package:dsh_mobile/model/appearance.dart';
import 'package:dsh_mobile/theme/dsh_colors.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:flutter/material.dart' show Brightness;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('夹取（是取值范围，不是产品下限）', () {
    test('0 与 100 原样通过', () {
      expect(clampTransparency(0), kTransparencyOpaque);
      expect(clampTransparency(100), kTransparencyMax);
      expect(clampTransparency(37), 37);
    });

    test('越界才夹：负数到 0、超过 100 到 100', () {
      expect(clampTransparency(-1), 0);
      expect(clampTransparency(-999), 0);
      expect(clampTransparency(101), 100);
    });
  });

  group('透明度 → 表面 alpha', () {
    test('0% 不透明、100% 全透', () {
      expect(surfaceAlphaOf(0), 1.0);
      expect(surfaceAlphaOf(100), 0.0);
    });

    test('中间线性', () {
      expect(surfaceAlphaOf(25), 0.75);
      expect(surfaceAlphaOf(50), 0.5);
      expect(surfaceAlphaOf(12), closeTo(0.88, 0.0001));
      // 越界也走同一套夹取。
      expect(surfaceAlphaOf(140), 0.0);
      expect(surfaceAlphaOf(-5), 1.0);
    });

    test('"没开"的判据只看 0', () {
      expect(isTransparencyOpaque(0), isTrue);
      expect(isTransparencyOpaque(1), isFalse);
      expect(isTransparencyOpaque(100), isFalse);
    });
  });

  group('落盘值', () {
    test('整数百分数往返不失真（0..100 全跑一遍）', () {
      for (var percent = 0; percent <= 100; percent += 1) {
        expect(clampTransparency(percent), percent, reason: '第 $percent 档');
      }
    });

    test('默认壁纸初始值在范围内且不是"没开"', () {
      expect(clampTransparency(kTransparencyOnWallpaper), kTransparencyOnWallpaper);
      expect(isTransparencyOpaque(kTransparencyOnWallpaper), isFalse);
    });
  });

  test('文案：就是百分数（没有"关闭"这种替用户下的定语）', () {
    expect(transparencyLabel(0), '0%');
    expect(transparencyLabel(37), '37%');
    expect(transparencyLabel(100), '100%');
    expect(transparencyLabel(140), '100%');
  });

  group('色板派生', () {
    test('默认（alpha 1）表面色与两个色板类完全一致', () {
      final tokens = DshTheme.dark().extension<DshColorTokens>()!;
      expect(tokens.bgBase, DshColors.bgBase);
      expect(tokens.layer1, DshColors.layer1);
      expect(tokens.composer, DshColors.composer);
    });

    test('给了 alpha：表面降 alpha、文字保持不透明', () {
      final tokens = DshTheme.dark(
        surfaceAlpha: surfaceAlphaOf(30),
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

    test('100% 透明度：表面 alpha 真的到 0（不偷偷留一点底）', () {
      final tokens = DshTheme.dark(
        surfaceAlpha: surfaceAlphaOf(100),
      ).extension<DshColorTokens>()!;
      expect(tokens.bgBase.a, 0);
      expect(tokens.layer1.a, 0);
      expect(tokens.labelPrimary.a, 1, reason: '文字不跟着消失');
    });

    test('浅色套同样只降表面', () {
      final tokens = DshTheme.light(
        surfaceAlpha: surfaceAlphaOf(40),
      ).extension<DshColorTokens>()!;
      expect(tokens.brightness, Brightness.light);
      expect(tokens.bgBase.a, closeTo(0.6, 0.001));
      expect(tokens.labelPrimary, DshLightColors.labelPrimary);
    });
  });
}
