/// 锚定浮层的**落点**（不是"看起来像"）。
///
/// 守两条：
///
/// 1. 下方放得下 ⇒ 面板顶边 = `anchor.bottom + 6`（长在触发点下面）；
/// 2. 下方放不下 ⇒ 翻到上方，面板底边 = `anchor.top − 6`，且**不超出屏幕**。
///
/// 判据用的是 `popoverPanelKey` 量的矩形，不是截图目测 ——
/// 用户 2026-10-21 原话「点击在上面，下面弹出你不觉得不跟手吗？差太远了吧」，
/// 可量的那条是"触发点矩形与面板矩形的距离"。
library;

import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/dsh_popover.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 把 `showDshPopover` 挂在一次点击上（浮层要一个 Navigator）。
Widget _host(Rect anchor) => MaterialApp(
  theme: DshTheme.dark(),
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () => showDshPopover<void>(
          context: context,
          anchor: anchor,
          title: '面板标题',
          body: const Padding(padding: EdgeInsets.all(12), child: Text('面板内容')),
        ),
        child: const Text('open'),
      ),
    ),
  ),
);

void main() {
  testWidgets('下方放得下：面板顶边贴着锚点下沿（gap 6）', (tester) async {
    tester.view.physicalSize = const Size(400, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // 上沿 10、下沿 40 —— 下方剩 244，够放。
    const anchor = Rect.fromLTWH(40, 10, 120, 30);
    await tester.pumpWidget(_host(anchor));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final panel = tester.getRect(find.byKey(popoverPanelKey));
    expect(
      panel.top,
      moreOrLessEquals(anchor.bottom + 6, epsilon: 0.5),
      reason: '面板必须长在触发点下面（底部 sheet 会差出一整屏）',
    );
    expect(panel.top - anchor.bottom, lessThan(80), reason: '跟手判据');
  });

  testWidgets('下方放不下：翻到锚点上方，底边贴着锚点上沿（gap 6）', (tester) async {
    tester.view.physicalSize = const Size(400, 300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // 上沿 240、下沿 270 —— 下方只剩 8，必须翻到上方。
    const anchor = Rect.fromLTWH(40, 240, 120, 30);
    await tester.pumpWidget(_host(anchor));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final panel = tester.getRect(find.byKey(popoverPanelKey));
    expect(
      panel.bottom,
      moreOrLessEquals(anchor.top - 6, epsilon: 0.5),
      reason: '翻到上方时底边贴着锚点上沿，而不是从屏幕顶开始',
    );
    expect(
      panel.bottom,
      lessThanOrEqualTo(anchor.top),
      reason: '翻上去的面板不许压住触发点',
    );
    expect(panel.top, greaterThanOrEqualTo(0), reason: '整块仍在屏内');
  });
}
