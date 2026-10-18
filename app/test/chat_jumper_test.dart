/// 对话流快速跳转钮（rikkahub `MessageJumper` 的移植）。
///
/// ## 这一组守什么
///
/// 用户 2026-10-19 原话："rikkahub 滑动右侧还有快速滚动的按钮那些，就是能直接到顶，
/// 直接到底，还有两个我没用不确定的，你可以看看"。
///
/// 查了 rikkahub 源码后那"两个没用不确定的"是**上一条 / 下一条**（按条目挪，
/// 不按像素）：`ChatList.kt:791` 的 `animateScrollToItem(firstVisibleItemIndex - 1)`。
///
/// 四条判据：
/// 1. **四个动作都真的发得出**（到顶 / 上一条 / 下一条 / 到底）——
///    少一个就是一个点了没反应的钮；
/// 2. **空会话不占位**（0 条目时整列消失）；
/// 3. **滚动后显示、停 1.5 秒后淡出**（rikkahub `isRecentScroll` 的同一判据）；
/// 4. **淡出后点不到**（`IgnorePointer`）—— 否则会出现"看不见但挡着手"的鬼钮。
library;

import 'package:dsh_mobile/ui/chat_jumper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// `onStep` / `onEdge` 的空实现（顶层函数：`const` 构造里不能引用局部函数）。
void _noopInt(int _) {}

void _noopBool(bool _) {}

void main() {
  group('四个动作都发得出', () {
    testWidgets('到顶 / 上一条 / 下一条 / 到底', (tester) async {
      final steps = <int>[];
      final edges = <bool>[];
      // 默认不可见（没滚过）—— 先滚一下让它出来。
      // `_ChatJumperState` 是私有的，所以经 `onCreated` 拿公开的控制器：
      // 这条路与生产代码（对话流的滚动监听）走的是同一条。
      ChatJumperController? controller;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatJumper(
              itemCount: 12,
              onStep: steps.add,
              onEdge: edges.add,
              onCreated: (c) => controller = c,
            ),
          ),
        ),
      );
      controller!.notifyScrolled();
      await tester.pump(const Duration(milliseconds: 250));

      await tester.tap(find.byTooltip('跳到最早一条'));
      await tester.tap(find.byTooltip('上一条'));
      await tester.tap(find.byTooltip('下一条'));
      await tester.tap(find.byTooltip('跳到最新一条'));
      await tester.pump();

      expect(steps, [-1, 1], reason: '上一条 / 下一条按条目挪一格');
      expect(edges, [false, true], reason: '先最早、后最新（false = 最早一端）');
    });
  });

  group('空会话不占位', () {
    testWidgets('0 条目时整列消失', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChatJumper(itemCount: 0, onStep: _noopInt, onEdge: _noopBool),
          ),
        ),
      );
      expect(find.byType(ChatJumper), findsOneWidget);
      expect(find.byTooltip('上一条'), findsNothing);
      expect(find.byTooltip('跳到最新一条'), findsNothing);
    });
  });

  group('滚动后显示、停 1.5 秒淡出', () {
    testWidgets('没滚过 = 透明且点不到', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ChatJumper(itemCount: 5, onStep: _noopInt, onEdge: _noopBool),
          ),
        ),
      );
      final opacity = tester.widget<AnimatedOpacity>(
        find.byKey(const Key('chat-jumper-opacity')),
      );
      expect(opacity.opacity, 0.0, reason: '没滚过不该占着屏幕');
      expect(
        tester
            .widget<IgnorePointer>(find.byKey(const Key('chat-jumper-pointer')))
            .ignoring,
        isTrue,
        reason: '看不见时也不能挡住对话流的触摸',
      );
    });

    testWidgets('滚一下 = 显示；1.5 秒后 = 淡出', (tester) async {
      ChatJumperController? controller;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatJumper(
              itemCount: 5,
              onStep: _noopInt,
              onEdge: _noopBool,
              onCreated: (c) => controller = c,
            ),
          ),
        ),
      );
      controller!.notifyScrolled();
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const Key('chat-jumper-opacity')),
            )
            .opacity,
        1.0,
      );

      // 1.5 秒静置后淡出（rikkahub `ChatList.kt:296` 的 `delay(1500)`）。
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const Key('chat-jumper-opacity')),
            )
            .opacity,
        0.0,
      );
    });

    testWidgets('淡出后点不到', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatJumper(
              itemCount: 5,
              onStep: (_) => tapped += 1,
              onEdge: _noopBool,
            ),
          ),
        ),
      );
      // 不滚 → 淡出态 → 点 "上一条" 不该计数。
      await tester.tap(find.byTooltip('上一条'), warnIfMissed: false);
      await tester.pump();
      expect(tapped, 0, reason: '看不见的钮不能响应触摸');
    });
  });
}
