/// 宽表横向滚动条**不许压住最后一行**。
///
/// 真机现象（2026-11-26 用户原话）：「表格视图，左右滚动的滚动条位置不对，
/// 不在最下面，和最后一排字有点重叠」。
///
/// ## 根因（本机 SDK 源码，行号可核）
///
/// `flutter_markdown_plus` 给宽表套的那层 `Scrollbar`
/// （`flutter_markdown_plus-1.0.12/lib/src/builder.dart:447-463`）是 Material
/// `Scrollbar`，而它把 **`MediaQuery.paddingOf(context)` 原样当成自己的 padding**
/// （`packages/flutter/lib/src/material/scrollbar.dart:360`：`..padding = MediaQuery.paddingOf(context)`）。
/// 横向条画在 `y = size.height - thickness - crossAxisMargin - padding.bottom`
/// （`packages/flutter/lib/src/widgets/scrollbar.dart:606-611`）——
/// **底部安全区越高，条被顶得越靠上，压进最后一行**。
///
/// 安全区属于**页面**（输入栏 / 底部条），不属于表格内部的一次横向滚动。
/// 修法：表格那棵子树里去掉 `padding.bottom`，让条回到盒子底部；内容底部
/// 另留出条高 + 间隙（见 `dsh_markdown.dart` 的 `tablePadding`）。
library;

import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/dsh_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const String _wideTable =
    '| 名称 | 值 | 备注 |\n'
    '|---|---|---|\n'
    '| a | 1 | 这一列故意写得很长很长，把表格撑到屏幕之外 |\n'
    '| b | 2 | 最后一行 |';

typedef _Geom = ({
  double barTop,
  double barBottom,
  double contentBottom,
  double boxBottom,
  double boxLeft,
  double boxWidth,
  double barLeft,
  double barWidth,
});

/// 读一个 `RawScrollbarState` 上公开的 `scrollbarPainter`。
///
/// 单独包成函数并**只在这一处**做 `as dynamic`：State 的 runtimeType 是私有
/// 子类，跨库强转成自定义类型会 `is not a subtype`（实测），而字段本身是公开的。
// ignore: avoid_dynamic_calls
ScrollbarPainter _painterOf(Object state) =>
    ((state as dynamic).scrollbarPainter) as ScrollbarPainter;

/// 从**画笔的公开状态**算条的位置，不依赖像素颜色（主题可能改色）。
///
/// 公式照 `packages/flutter/lib/src/widgets/scrollbar.dart:606-611`：
/// `top/bottom` 方向时 `y = size.height - thickness - crossAxisMargin - padding.bottom`，
/// 条高 = `thickness`。
Future<_Geom> _measure(WidgetTester tester, {required EdgeInsets inset}) async {
  tester.view.physicalSize = const Size(400, 500);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: DshTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(400, 500),
          padding: inset,
          viewPadding: inset,
        ),
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: EdgeInsets.all(16),
              child: DshMarkdown(_wideTable),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  // 表格内容底部 & 横向滚动视图盒子底部（几何真值）。
  double contentBottom = 0;
  double boxBottom = 0;
  for (final e in find.byType(SingleChildScrollView).evaluate()) {
    final w = e.widget as SingleChildScrollView;
    if (w.scrollDirection != Axis.horizontal) continue;
    final r = e.renderObject! as RenderBox;
    boxBottom = r.localToGlobal(Offset.zero).dy + r.size.height;
  }
  for (final e in find.byType(Table).evaluate()) {
    final r = e.renderObject! as RenderBox;
    contentBottom = r.localToGlobal(Offset.zero).dy + r.size.height;
  }

  // 条：读 Scrollbar 的画笔状态（公开 getter），算它在盒子里的行位置。
  //
  // `Scrollbar` 本身是无状态组件（`material/scrollbar.dart:65`），它构造出
  // `_MaterialScrollbar extends RawScrollbar`（`:181`），画笔挂在那份
  // `RawScrollbarState` 上。所以查 `RawScrollbar` 拿 State，再读**公开字段**
  // `scrollbarPainter`（`widgets/scrollbar.dart:1378`）—— 读的是即将被绘制的
  // 那份状态，不是另算一遍。
  // `byType` 只匹配精确 runtimeType，而实际那个是子类
  // `_MaterialScrollbar extends RawScrollbar`（`material/scrollbar.dart:181`），
  // 所以按类型谓词找。
  // 那个 State 的 runtimeType 是私有的（`_MaterialScrollbarState`），
  // 但 `scrollbarPainter` 是 `RawScrollbarState` 上的**公开字段**
  // （`widgets/scrollbar.dart:1378`）。Dart 的私有类型不能跨库强转成一个
  // 自定义 interface（实测 `is not a subtype`），所以这里走公开 API：
  // 用 `Scrollable.of` 拿不到画笔，只能经 `dynamic` —— 下面四行是本文件
  // **唯一**允许的动态访问，并且都是读，不是调用。
  final rawFinder = find.byWidgetPredicate((w) => w is RawScrollbar).first;
  final state = tester.state(rawFinder);
  final painter = _painterOf(state);
  final box = tester.renderObject<RenderBox>(rawFinder);
  final context = tester.element(rawFinder);
  final pad = painter.padding.resolve(Directionality.of(context));
  final thickness = painter.thickness;
  final crossAxisMargin = painter.crossAxisMargin;
  final barTop =
      box.localToGlobal(Offset.zero).dy +
      box.size.height -
      thickness -
      crossAxisMargin -
      pad.bottom;
  // 水平条的水平几何（`widgets/scrollbar.dart:408,413,603`）：
  // x 起点 = 盒子左边 + `pad.left`，轨道长 = 视口宽度 − (`left`+`right`)。
  final barLeft = box.localToGlobal(Offset.zero).dx + pad.left;
  final barWidth = box.size.width - (pad.left + pad.right);

  return (
    barTop: barTop,
    barBottom: barTop + thickness,
    contentBottom: contentBottom,
    boxBottom: boxBottom,
    boxLeft: box.localToGlobal(Offset.zero).dx,
    boxWidth: box.size.width,
    barLeft: barLeft,
    barWidth: barWidth,
  );
}

void main() {
  /// 条顶与**表格底边**之间至少要空出这么多。
  ///
  /// 基准用 `contentBottom`（Table 的底边）而不是文字底边：文字的渲染盒
  /// 只占行高，与单元格的 `vertical` 内边距（10）之间本来就差一截，
  /// 拿它做基准时"留白被改回 4"也能满足阈值（实测 bodyBottom=138 而
  /// Table 底边 148，差 10 全部来自内边距）—— 那等于没测到留白。
  ///
  /// 条的几何：`barTop = boxBottom - thickness(3) - tablePadding.bottom`。
  /// 想在条与 Table 底边之间留出净空 G，就需要
  /// `tablePadding.bottom = 3 + G`。取 G ≥ 4 ⇒ bottom ≥ 7，当前 8（净空 5）。
  const double minGap = 4;

  /// 三个方向的共同断言（条在内容下方 + 与表格底边的净空 + 水平上对齐盒左缘）。
  ///
  /// **左右也要断言**：`padding.left` 会把条整体右移、`padding.right` 会缩短轨道
  /// （`widgets/scrollbar.dart:408,413,603`）—— 横屏刘海 44 时条右移 44、缩短 88，
  /// 与表格左缘错位。只测 bottom 的版本抓不到这一半（实测）。
  void expectBarOk(_Geom g, String label) {
    expect(
      g.barTop,
      greaterThanOrEqualTo(g.contentBottom),
      reason:
          '[$label] 条压住了最后一行（真机 2026-11-26 的现象）：'
          'barTop=${g.barTop} contentBottom=${g.contentBottom}',
    );
    expect(
      g.barTop - g.contentBottom,
      greaterThanOrEqualTo(minGap),
      reason:
          '[$label] 条贴着表格底边：'
          'barTop=${g.barTop} tableBottom=${g.contentBottom}',
    );
    expect(
      g.barLeft,
      moreOrLessEquals(g.boxLeft, epsilon: 0.01),
      reason:
          '[$label] 条没和内容左缘对齐（`padding.left` 漏进来了）：'
          'barLeft=${g.barLeft} boxLeft=${g.boxLeft}',
    );
    expect(
      g.barWidth,
      moreOrLessEquals(g.boxWidth, epsilon: 0.01),
      reason:
          '[$label] 轨道比内容窄（`padding.left/right` 漏进来了）：'
          'barWidth=${g.barWidth} boxWidth=${g.boxWidth}',
    );
  }

  testWidgets('底部安全区 48（手势导航）：横向条在内容下方', (tester) async {
    expectBarOk(
      await _measure(tester, inset: const EdgeInsets.only(bottom: 48)),
      'inset-bottom-48',
    );
  });

  testWidgets('底部安全区 34（Home 指示条）：横向条在内容下方', (tester) async {
    expectBarOk(
      await _measure(tester, inset: const EdgeInsets.only(bottom: 34)),
      'inset-bottom-34',
    );
  });

  testWidgets('左右安全区 44（横屏刘海）：条与内容左右对齐', (tester) async {
    expectBarOk(
      await _measure(tester, inset: const EdgeInsets.only(left: 44, right: 44)),
      'inset-lr-44',
    );
  });

  testWidgets('四边都有安全区：条仍在内容下方且左右对齐', (tester) async {
    expectBarOk(
      await _measure(tester, inset: const EdgeInsets.fromLTRB(44, 24, 44, 48)),
      'inset-all',
    );
  });

  testWidgets('没有安全区：横向条也在内容下方', (tester) async {
    expectBarOk(await _measure(tester, inset: EdgeInsets.zero), 'inset-none');
  });
}
