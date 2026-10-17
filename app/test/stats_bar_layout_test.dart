/// 统计条（`.stats`）的**排版回归**：三项读数排在一行，放不下就横滑。
///
/// 2026-10-17 真机反馈："APP 最下面的状态换行了" —— 真机截图（1080×2400 @420dpi
/// = **411.4dp 宽**）上 `◔ 42%` 被挤到了第二行，而它是**上下文余量**那一项。
///
/// Flutter 实测三枚 chip：`第 5 轮 · 70 步 · 77 tok/s` = **292.8dp**、
/// `18.2M tok · 缓存命中 94%` = **259.0dp**、`◐ 42%` = **68.8dp**，
/// 合计 **632.6dp**；而可用宽度 = 411.4 − 16 − 4 = **391.4dp**，差 237dp。
/// 缩字号填不平（11px→10px 只省约 47dp，全做完仍要 566dp）——
/// 所以定案是**单行 + 横向滚动**：读数**滑得到**，不是被裁掉，也不是换行。
///
/// 三个读数与 DSH Web 的 composer dock 是**同一组**（`ui-chat/src/client/apply.ts:324-329`
/// 把 activity / usage 两枚 pill 注入 `conversation.composer.dock`，
/// `InputBar.tsx:520-524` 在其后渲染 `ContextMeter`）；DSH 的 dock 本身也是
/// **单行居中 flex**（`InputBar.module.css:13-20`），放不下走省略号。
library;

import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/dsh_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真机逻辑宽度：1080px ÷ (420dpi ÷ 160) = 411.43dp（`adb shell wm size` / `wm density`）。
const double kRealDeviceWidth = 1080 / (420 / 160);

/// 真机 2026-10-17 12:07 截图上的**实际**读数（不是编的极端值）。
const String kTurnText = '5 轮 70 步 · 77 tok/s';
const String kUsageText = '18.2M tok · 缓存命中 94%';
const String kContextText = '42%';

/// 按 `chat_page.dart` 的实际包裹方式渲染统计条：外层 `Padding(horizontal: 8)`。
Future<void> _pumpStats(
  WidgetTester tester, {
  required double width,
  VoidCallback? onTapTurn,
  VoidCallback? onTapUsage,
  VoidCallback? onTapContext,
}) async {
  final view = tester.view;
  view.physicalSize = Size(width, 900);
  view.devicePixelRatio = 1;
  addTearDown(() {
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: DshTheme.dark(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: DshStatsBar(
              turnText: kTurnText,
              usageText: kUsageText,
              contextPercent: 42,
              onTapTurn: onTapTurn,
              onTapUsage: onTapUsage,
              onTapContext: onTapContext,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('411dp（真机宽度）：三项读数排在同一行', (tester) async {
    await _pumpStats(tester, width: kRealDeviceWidth);
    final turn = tester.getRect(find.text(kTurnText));
    final usage = tester.getRect(find.text(kUsageText));
    final context = tester.getRect(find.text(kContextText));
    // 同一行的判据是**顶边相等**，不是"看起来还行"。
    expect(usage.top, equals(turn.top), reason: '横滚行里三项只有一行');
    expect(context.top, equals(turn.top));
    expect(tester.takeException(), isNull, reason: '不许溢出');
  });

  testWidgets('360dp（窄屏）：同样一行，且不溢出', (tester) async {
    await _pumpStats(tester, width: 360);
    final turn = tester.getRect(find.text(kTurnText));
    final usage = tester.getRect(find.text(kUsageText));
    final context = tester.getRect(find.text(kContextText));
    expect(usage.top, equals(turn.top));
    expect(context.top, equals(turn.top));
    expect(tester.takeException(), isNull);
  });

  testWidgets('三项宽于屏幕：滑得到（不是被裁掉）', (tester) async {
    await _pumpStats(tester, width: 360);
    final context = find.text(kContextText);
    final before = tester.getTopLeft(context).dx;
    expect(
      before,
      greaterThanOrEqualTo(360),
      reason: '三项合计 ${632.6}dp 宽于 360dp，第三项一开始在视口外',
    );
    await tester.drag(find.byType(DshStatsBar), const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(context).dx,
      lessThan(before),
      reason: '左滑之后它必须往左走 —— 藏起来不等于滑不到',
    );
    expect(tester.getTopLeft(context).dx, lessThan(360));
  });

  testWidgets('横滑之后点击照样生效（滑动不吃掉点击）', (tester) async {
    var taps = 0;
    await _pumpStats(
      tester,
      width: 360,
      onTapTurn: () => taps += 1,
      onTapContext: () => taps += 1,
    );
    // ① 原地按第一项（不滑动）：要生效。
    await tester.tap(find.text(kTurnText));
    await tester.pumpAndSettle();
    expect(taps, 1, reason: '点击必须落到 chip 的 InkWell 上');

    // ② 滑到第三项可见再点它 —— 这一条钉的是"横滚容器不吞点击"。
    await tester.drag(find.byType(DshStatsBar), const Offset(-400, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text(kContextText));
    await tester.pumpAndSettle();
    expect(taps, 2);
  });
}
