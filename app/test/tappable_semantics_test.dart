/// 自绘可点区的**语义角色**：朗读器（TalkBack / VoiceOver）要能说出"这是个按钮"。
///
/// ## 为什么要这条用例
///
/// Flutter 的 Material 控件自带语义，而本仓大量交互是 `InkWell` / `GestureDetector`
/// 手写的 —— 它们只装**点击动作**，不装**角色**：`RawGestureDetector` 的
/// `excludeFromSemantics: false` 走 `_GestureSemantics.assignSemantics`
/// （`packages/flutter/lib/src/widgets/gesture_detector.dart:1591`），
/// 装的是 `onTap` 动作，不是 `SemanticsFlag.isButton`。于是 TalkBack 念完文字就停。
///
/// 这里钉三件事：
///
/// 1. 会话抽屉的行 / 菜单项 / 「展开其余 N 个」是**按钮**；
/// 2. 行的文字**没有被吞掉**（标题仍读得到）；
/// 3. 行尾「…」仍是**独立的**可点节点 —— 整行合成一个节点会让它变得摸不到。
///
/// Note: 为什么不给整行 `MergeSemantics` / `excludeSemantics` —— 见
/// `.agents/notes/implemented/2026-11-10-tappable-semantics.md`。
library;

import 'package:dsh_mobile/model/session_dot.dart';
import 'package:dsh_mobile/ui/dsh_app_bar.dart';
import 'package:dsh_mobile/ui/session_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(SessionDrawer drawer) => MaterialApp(home: Scaffold(body: drawer));

SessionDrawer _drawer(
  List<String> sids, {
  Map<String, bool> pinned = const {},
  int hiddenCount = 0,
  void Function(DrawerSection section)? onRevealMore,
}) => SessionDrawer(
  sections: [
    DrawerSection(
      label: 'dsh-mobile',
      workspaceId: 'w1',
      hiddenCount: hiddenCount,
      sessions: [
        for (final sid in sids)
          DrawerSession(
            sid: sid,
            title: sid.toUpperCase(),
            preview: '预览',
            timeLabel: '10:00',
            isPinned: pinned[sid] ?? false,
            dot: SessionDot.idle,
          ),
      ],
    ),
  ],
  connection: const DrawerConnection(
    name: '我的电脑',
    detail: '已连接',
    platform: 'DSH',
    online: true,
  ),
  footItems: const [],
  onNewSession: () {},
  onOpenSession: (_) {},
  onClose: () {},
  onRevealMore: onRevealMore,
);

void main() {
  testWidgets('会话行：朗读器读得到「按钮」+ 标题', (tester) async {
    await tester.pumpWidget(_host(_drawer(['a'])));

    final node = tester.getSemantics(
      find.byKey(const ValueKey<String>('session-row-a')),
    );
    expect(
      node,
      isSemantics(isButton: true, hasTapAction: true),
      reason: '行是手写的 InkWell：不加 Semantics 就只有点击动作、没有按钮角色',
    );
    expect(
      node.getSemanticsData().label,
      contains('A'),
      reason: '只加角色，不能把行内文字吞掉',
    );
  });

  testWidgets('行尾「…」仍是独立可点节点（不被整行合掉）', (tester) async {
    await tester.pumpWidget(_host(_drawer(['a'])));

    final menu = tester.getSemantics(
      find.byKey(const ValueKey<String>('session-menu-a')),
    );
    expect(
      menu,
      isSemantics(hasTapAction: true),
      reason: '整行合成一个语义节点会让行尾菜单摸不到',
    );
  });

  testWidgets('菜单项：「取消置顶」是按钮，边界项「上移」不是', (tester) async {
    await tester.pumpWidget(_host(_drawer(['a', 'b'], pinned: {'a': true})));

    await tester.tap(find.byKey(const ValueKey<String>('session-menu-a')));
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.text('取消置顶')),
      isSemantics(isButton: true, hasTapAction: true),
    );
    // 边界项保留在菜单里但不可点：它是文字，不是按钮。
    expect(
      tester.getSemantics(find.text('上移')),
      isNot(isSemantics(isButton: true)),
      reason: '点不动的项不该被念成按钮',
    );
  });

  testWidgets('顶栏图标钮（纯图标）：按钮角色 + tooltip 就是名字', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DshAppBarButton(
            icon: 'panelLeft',
            tooltip: '打开会话列表',
            onPressed: () {},
          ),
        ),
      ),
    );

    expect(
      tester.getSemantics(find.byType(DshAppBarButton)),
      isSemantics(isButton: true, hasTapAction: true, tooltip: '打开会话列表'),
      reason: '纯图标钮没有可见文字：名字必须来自 tooltip，角色必须自己报',
    );
  });

  testWidgets('「展开其余 N 个会话」是按钮', (tester) async {
    DrawerSection? revealed;
    await tester.pumpWidget(
      _host(
        _drawer(
          [for (var i = 0; i < 5; i += 1) 's$i'],
          hiddenCount: 4,
          onRevealMore: (section) => revealed = section,
        ),
      ),
    );

    final more = find.textContaining('展开其余');
    expect(more, findsOneWidget);
    expect(
      tester.getSemantics(more),
      isSemantics(isButton: true, hasTapAction: true),
    );

    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(revealed?.label, 'dsh-mobile');
  });
}
