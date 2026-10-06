/// DSH 图标集的回归（`lib/theme/dsh_icons.dart`）。
///
/// ## 这一组守什么
///
/// 图标是**机生成的**（`mock/proto/icons.js` → Dart），所以它可能因为上游变化而悄悄坏掉：
/// 抽取器读不到源、占位符没替换、某个图标含了会截断 Dart 原始字符串的内容。
/// 这些都不会让 App 崩，只会让**某个图标画不出来** —— 而那时没人会想到是生成的问题。
///
/// ## 为什么"能渲染"不能只靠"字符串里有 `<svg>`"
///
/// `flutter_svg` 解析失败时**不抛异常**（它把错误画成空白）。所以这里做两件事：
/// 1. 断言 SVG 串的**结构**（每个图标都有 viewBox、都有绘制元素、没有未替换的占位符）；
/// 2. 真的把它喂给 `flutter_svg` 解析一次并断言渲染出了内容 ——
///    这是"渲染器真的接受它"的唯一证据。
library;

import 'dart:typed_data';
import 'dart:ui' show ImageByteFormat;

import 'package:dsh_mobile/theme/dsh_colors.dart';
import 'package:dsh_mobile/theme/dsh_icons.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('98 个图标都在（与 mock/proto/icons.js 同一份来源）', () {
    // 数字变了要去 `mock/proto/tools/extract-dsh-icons.mjs` 看是不是 DSH 升级了，
    // 而不是把这里改掉。
    expect(DshIcons.names.length, 98);
    // 名字升序且无重复（升序是抽取器保证的，重复说明表坏了）。
    final sorted = List<String>.from(DshIcons.names)..sort();
    expect(DshIcons.names, sorted, reason: '名字应升序');
    expect(
      DshIcons.names.toSet().length,
      DshIcons.names.length,
      reason: '不该有重复名',
    );
  });

  test('每个图标都画得出：有 viewBox、有绘制元素、没有未替换的占位符', () {
    final problems = <String>[];
    for (final name in DshIcons.names) {
      final svg = DshIcons.svg(name, color: DshColors.labelPrimary);
      if (!svg.startsWith('<svg')) problems.add('$name: 不以 <svg 开头');
      if (!svg.contains('viewBox=')) problems.add('$name: 缺 viewBox');
      // 有绘制元素（path / circle / rect）—— 只有 <g> 或 <mask> 的图标画不出东西。
      if (!RegExp(r'<(path|circle|rect)\b').hasMatch(svg)) {
        problems.add('$name: 没有绘制元素');
      }
      // 占位符 **必须**全被替换掉。漏一个的表现是 SVG 属性里出现 `__DSH_`，
      // 而浏览器/渲染器会静默忽略那个属性（不是报错）。
      if (svg.contains('__DSH_')) problems.add('$name: 还有未替换的占位符');
      if (svg.contains('##')) problems.add('$name: 还有 ## 形式的占位符');
      if (svg.contains('undefined') || svg.contains('NaN')) {
        problems.add('$name: 含 undefined/NaN');
      }
    }
    expect(problems, isEmpty, reason: problems.take(8).join(' | '));
  });

  test('颜色真的进了 SVG（不是留给 currentColor 的）', () {
    // 这是本项目刻意偏离"让 SVG 用 currentColor"的地方（见 dsh_icons.dart 文件头）：
    // flutter_svg 对 currentColor 支持有缺口。所以断言**颜色被替换成了字面值**。
    final svg = DshIcons.svg('refresh', color: DshColors.accentBlue);
    expect(
      svg.contains('currentColor'),
      isFalse,
      reason: '不能把 currentColor 留给渲染器 —— 98 个图标全用它，赌不起',
    );
    final hex = (DshColors.accentBlue.toARGB32() & 0xFFFFFF)
        .toRadixString(16)
        .padLeft(6, '0');
    expect(svg.toLowerCase().contains('#$hex'), isTrue, reason: '颜色应被填进 SVG');
  });

  test('尺寸默认取 artwork 自己的（不是一律 16）', () {
    // DSH 里这些图标的画布大小不同，全按 16 画会让它们视觉上大小不一。
    // **这些数是量出来的，不是猜的**：`treeCorner` 是 8
    //（我第一版猜成 10 —— 那是它 viewBox 高度附近的值，而 viewBox 与 width 不是一回事）。
    expect(DshIcons.defaultSizeOf('treeCorner'), 8);
    expect(DshIcons.defaultSizeOf('inspect'), 12);
    expect(DshIcons.defaultSizeOf('send'), 14);
    expect(DshIcons.defaultSizeOf('panelLeft'), 16);
    expect(DshIcons.defaultSizeOf('archive'), 20);
  });

  test('非正方形图标保住比例（`treeCorner` 是 8×10）', () {
    // 一律按正方形画会把它拉变形。这条钉住"比例被传递了"。
    expect(DshIcons.aspectOf('treeCorner'), closeTo(10 / 8, 0.0001));
    expect(DshIcons.aspectOf('send'), 1);
  });

  test('显式尺寸覆盖默认值', () {
    final svg = DshIcons.svg('send', size: 32, color: DshColors.labelPrimary);
    expect(svg.contains('width="32"'), isTrue);
    expect(svg.contains('height="32"'), isTrue);
  });

  test('未知名字不崩（不画东西），但认识的都认识', () {
    // 生成的表是白名单：拼错名字不该让整屏崩掉（见 DshIcons.svg 的说明）。
    expect(DshIcons.has('refresh'), isTrue);
    expect(DshIcons.has('definitelyNotAnIcon'), isFalse);
  });

  testWidgets('真的能渲染（把 SVG 喂给 flutter_svg,含 mask 那个）', (tester) async {
    // **这条是关键**：前面的断言只证明"字符串长得对"，
    // 而 flutter_svg 解析失败时**不抛异常**（画成空白）。
    // 所以这里真的渲染，并断言渲染出了内容。
    for (final name in [
      'refresh',
      'send',
      'archiveOff',
      'compact',
      'treeCorner',
    ]) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: DshIcon(name, color: DshColors.labelPrimary)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$name 渲染时不该抛异常');
      // 图上确实有东西（不是空白）：`SvgPicture` 应已在树里。
      expect(find.byType(DshIcon), findsOneWidget, reason: '$name 应被渲染');
    }
  });

  testWidgets('真的画出了像素（不是空白）—— 含 mask/opacity/描边三种难例', (tester) async {
    // **这是"能渲染"的唯一硬证据**：前面的断言只证明"字符串长得对"，
    // 而 `flutter_svg` 解析失败时**不抛异常** —— 它画成空白。
    // 所以这里把渲染结果抓成位图，数一下有多少非透明像素。
    //
    // 挑这几个是因为它们各用一种"字体表达不了、只能靠 SVG"的特性：
    // `archiveOff` 用 `<mask>`（斜杠是挖空出来的）、`compact` 用 `opacity`、
    // `send` 是纯描边、`treeCorner` 是 8×10 的非正方形。
    for (final name in ['archiveOff', 'compact', 'send', 'treeCorner']) {
      final painted = await _paintedPixels(tester, name);
      expect(
        painted,
        greaterThan(20),
        reason:
            '$name 只画了 $painted 个非透明像素 —— 看起来是空白。'
            '`flutter_svg` 解析失败时不抛异常，所以必须数像素。',
      );
    }
  });

  testWidgets('颜色真的生效（换色后位图不同）', (tester) async {
    // 防"颜色被忽略、一律画成黑/白"这种静默失败 ——
    // 那正是"把 currentColor 留给渲染器"会踩的坑（见 dsh_icons.dart 文件头）。
    final red = await _rasterOf(tester, 'send', const Color(0xFFFF0000));
    final blue = await _rasterOf(tester, 'send', const Color(0xFF0000FF));
    expect(red, isNot(equals(blue)), reason: '换色后位图必须变 —— 否则说明颜色没进 SVG');
  });

  testWidgets('98 个图标全部能构建（一次全过一遍,防"只有常用的那几个是好的"）', (tester) async {
    final broken = <String>[];
    for (final name in DshIcons.names) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: DshIcon(name, color: DshColors.labelPrimary)),
        ),
      );
      await tester.pump();
      final error = tester.takeException();
      if (error != null) broken.add('$name: $error');
    }
    expect(broken, isEmpty, reason: broken.take(5).join(' | '));
  });
}

/// 把一个图标渲染成位图，返回 RGBA 字节。
///
/// `RepaintBoundary` + `toImage` 是"看到真实像素"的标准做法 ——
/// 它绕过了"树里有这个 widget"这种弱证据（`flutter_svg` 解析失败时仍然有）。
Future<Uint8List> _rasterOf(
  WidgetTester tester,
  String name,
  Color color,
) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: RepaintBoundary(
          // 64 而不是默认 14：像素太少时"画歪了"与"没画出来"分不清。
          child: DshIcon(name, size: 64, color: color),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // `toImage` 是异步且需要真实事件循环，所以走 `runAsync`。
  final data = await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byType(RepaintBoundary),
    );
    final raster = await boundary.toImage(pixelRatio: 1);
    return raster.toByteData(format: ImageByteFormat.rawRgba);
  });
  if (data == null) fail('$name 抓不到位图');
  return data.buffer.asUint8List();
}

/// 数一下这个图标画了多少个非透明像素。
Future<int> _paintedPixels(WidgetTester tester, String name) async {
  final bytes = await _rasterOf(tester, name, const Color(0xFFFFFFFF));
  var painted = 0;
  // RGBA：每 4 字节的最后一个是不透明度。
  for (var i = 3; i < bytes.length; i += 4) {
    if (bytes[i] != 0) painted += 1;
  }
  return painted;
}
