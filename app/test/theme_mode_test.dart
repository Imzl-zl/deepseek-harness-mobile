/// 主题模式与亮暗的真值（`model/theme_mode.dart`）。
///
/// ## 这一组守什么
///
/// 2026-10-19 用户原话："对了还有暗浅色主题设置"。DSH 的
/// `design-platform.css` 一上来就有两套（浅色是 `:root`、深色是覆盖块），
/// 我们原先只落了深色；这一组守补齐之后的**三档语义**：
///
/// 1. **三档各自解析出确定的亮暗**（"跟随系统"用系统那个，不猜）；
/// 2. **显式选了浅/深时，系统变化不覆盖它**（DSH 的 manual 优先）；
/// 3. **盘上读回认不出的值退回"跟随系统"**（不猜、不崩）；
/// 4. **同一档重复切是空操作**（不通知、不落盘）；
/// 5. **浅色套的 token 与深色套不是简单反转** —— 层级靠描边不靠底色，
///    所以浅色下三个 layer 同值是有意为之（这条由 `DshColorTokens` 钉）。
library;

import 'package:dsh_mobile/model/theme_mode.dart';
import 'package:dsh_mobile/theme/dsh_colors.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('三档解析成确定的亮暗', () {
    test('跟随系统：用系统那一档', () {
      final c = ThemeController.restore(
        null,
        systemBrightness: Brightness.light,
      );
      expect(c.mode, DshThemeMode.system);
      expect(c.brightness, Brightness.light);
    });

    test('跟随系统 + 读不到系统亮暗：退深色（不猜）', () {
      final c = ThemeController.restore(null);
      expect(c.brightness, Brightness.dark);
    });

    test('显式浅色：无视系统', () {
      final c = ThemeController.restore(
        DshThemeMode.light.wire,
        systemBrightness: Brightness.dark,
      );
      expect(c.brightness, Brightness.light);
    });

    test('显式深色：无视系统', () {
      final c = ThemeController.restore(
        DshThemeMode.dark.wire,
        systemBrightness: Brightness.light,
      );
      expect(c.brightness, Brightness.dark);
    });
  });

  group('盘上读回', () {
    test('认不出的值退回"跟随系统"', () {
      final c = ThemeController.restore('nonsense-mode');
      expect(c.mode, DshThemeMode.system);
    });

    test('空值同样退回默认', () {
      final c = ThemeController.restore('');
      expect(c.mode, DshThemeMode.system);
    });

    test('落盘字面量往返', () {
      for (final mode in DshThemeMode.values) {
        expect(DshThemeMode.fromWire(mode.wire), mode);
      }
    });
  });

  group('系统变化', () {
    test('跟随系统档下跟着变', () {
      final c = ThemeController.restore(
        null,
        systemBrightness: Brightness.dark,
      );
      var notified = 0;
      c.addListener(() => notified += 1);
      c.onSystemBrightness(Brightness.light);
      expect(c.brightness, Brightness.light);
      expect(notified, 1, reason: '亮暗真的变了才通知');
    });

    test('显式选了浅/深时忽略系统变化（manual 优先）', () {
      final c = ThemeController.restore(
        DshThemeMode.dark.wire,
        systemBrightness: Brightness.dark,
      );
      var notified = 0;
      c.addListener(() => notified += 1);
      c.onSystemBrightness(Brightness.light);
      expect(c.brightness, Brightness.dark, reason: '用户显式选的不被覆盖');
      expect(notified, 0, reason: '没变就不通知');
    });

    test('同一个系统亮暗重复报是空操作', () {
      final c = ThemeController.restore(
        null,
        systemBrightness: Brightness.light,
      );
      var notified = 0;
      c.addListener(() => notified += 1);
      c.onSystemBrightness(Brightness.light);
      expect(notified, 0);
    });
  });

  group('切模式', () {
    test('同一档重复切是空操作', () {
      final c = ThemeController.restore(null);
      var notified = 0;
      c.addListener(() => notified += 1);
      c.setMode(DshThemeMode.system);
      expect(notified, 0);
    });

    test('切到浅色并带系统亮暗', () {
      final c = ThemeController.restore(
        null,
        systemBrightness: Brightness.dark,
      );
      c.setMode(DshThemeMode.light, systemBrightness: Brightness.light);
      expect(c.mode, DshThemeMode.light);
      expect(c.brightness, Brightness.light);
    });
  });

  group('浅色套的 token 与深色套不是简单反转', () {
    test('浅色下三个 layer 同值（层级靠描边不靠底色）', () {
      // DSH `:root` 的 `--dsw-alias-bg-layer-1/2/3` 三条都落 neutral-bluish-00。
      // 这不是抄漏：浅色用 `border-l1/l2/l3`（4/10/12% 的黑）分层。
      expect(DshLightColors.layer1, DshLightColors.layer2);
      expect(DshLightColors.layer2, DshLightColors.layer3);
      // 而深色套三层是递进的。
      expect(DshColors.layer1, isNot(DshColors.layer2));
    });

    test('浅色的次要文字比深色的次要文字更暗（不是反转）', () {
      // 浅色 secondary = neutral-bluish-700（rgb 97,102,107）；
      // 深色 secondary = neutral-bluish-500（rgb 207,211,214）。
      // 白底上靠"更深"分主次，所以浅色那一个**更暗**。
      final lightLuminance = DshLightColors.labelSecondary.computeLuminance();
      final darkLuminance = DshColors.labelSecondary.computeLuminance();
      expect(lightLuminance, lessThan(darkLuminance));
    });

    test('分隔线：深色叠白、浅色叠黑', () {
      // 用 `fromRGBO` 构造期望值来比：字面量 `0x1FFFFFFF` 的 alpha 是
      // 31/255 = 0.1216，而 `border(0.12)` 走的是 `fromRGBO(255,255,255,0.12)`
      // = 30.6/255。两个数不一样，直接比字面量会红。
      expect(DshColors.border(0.12), const Color.fromRGBO(255, 255, 255, 0.12));
      expect(DshLightColors.border(0.12), const Color.fromRGBO(0, 0, 0, 0.12));
    });

    test('两个 ThemeData 都挂着色板扩展', () {
      // UI 经 `context.dshColors` 读当下那一套；只挂一个的话，
      // 另一个亮暗下会读 null 退深色（静默错）。
      expect(
        DshTheme.dark().extension<DshColorTokens>(),
        isA<DshColorTokens>(),
      );
      expect(
        DshTheme.light().extension<DshColorTokens>(),
        isA<DshColorTokens>(),
      );
    });

    test('两个 ThemeData 的色板扩展各带各的亮暗', () {
      final dark = DshTheme.dark().extension<DshColorTokens>()!;
      final light = DshTheme.light().extension<DshColorTokens>()!;
      expect(dark.brightness, Brightness.dark);
      expect(light.brightness, Brightness.light);
      expect(dark.bgBase, isNot(light.bgBase));
    });
  });
}
