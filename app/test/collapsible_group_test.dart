/// 可折叠项目组头的回归。
///
/// ## 这一组守什么
///
/// 2026-10-19 用户原话：「这个侧边栏会话列表，人家的每个项目的会话可以折叠的，
/// 你没有啊」。查证：DSH Web 有（`ui-workspace/.../WorkspaceBrowser.tsx:281,484,564-565`），
/// rikkahub **没有**（它用一排横向筛选 chip，`ChatDrawer.kt:789-856`）。
/// 所以照 DSH。
///
/// 三条 DSH 也有的细节，各有判据：
/// 1. 折叠时**里面的会话不渲染**（`WorkspaceBrowser.tsx:484` 的
///    `group.expanded ? children.map(...) : []`）；
/// 2. **折叠时把收着的个数说出来**（`:640-660` 的溢出行
///    `sessions.expand, {n: visible.hiddenCount}`）；
/// 3. **当前会话所在的组即使折叠也高亮**（`Rows.tsx:211,236` 的
///    `containsCurrentDescendant`）。
library;

import 'package:dsh_mobile/ui/collapsible_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host({
    required bool expanded,
    required VoidCallback onToggle,
    bool containsCurrent = false,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: CollapsibleGroup(
          label: 'dsh-mobile',
          expanded: expanded,
          onToggle: onToggle,
          childCount: 3,
          containsCurrent: containsCurrent,
          children: const [
            ListTile(title: Text('会话 A')),
            ListTile(title: Text('会话 B')),
            ListTile(title: Text('会话 C')),
          ],
        ),
      ),
    );
  }

  testWidgets('展开：组头 + 三个会话都在', (tester) async {
    await tester.pumpWidget(host(expanded: true, onToggle: () {}));
    await tester.pumpAndSettle();

    expect(find.text('dsh-mobile'), findsOneWidget);
    expect(find.text('会话 A'), findsOneWidget);
    expect(find.text('会话 C'), findsOneWidget);
    // 展开时**不显示个数**（DSH 只在折叠时给溢出行）。
    expect(find.text('3'), findsNothing);
  });

  testWidgets('折叠：会话不渲染，但把收着的个数说出来', (tester) async {
    // DSH `WorkspaceBrowser.tsx:484`（折叠不渲染子行）+
    // `:640-660`（折叠时给 "展开 N 个" 的溢出行）。
    await tester.pumpWidget(host(expanded: false, onToggle: () {}));
    await tester.pumpAndSettle();

    expect(find.text('dsh-mobile'), findsOneWidget);
    expect(find.text('会话 A'), findsNothing);
    expect(find.text('会话 B'), findsNothing);
    // **收着的个数看得见** —— 折叠不是"这里没了"。
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('点组头：回调真的响了', (tester) async {
    var toggled = 0;
    await tester.pumpWidget(host(expanded: true, onToggle: () => toggled++));
    await tester.pumpAndSettle();

    await tester.tap(find.text('dsh-mobile'));
    await tester.pumpAndSettle();
    expect(toggled, 1);
  });

  testWidgets('当前会话所在的组：折叠也高亮（强调色）', (tester) async {
    // DSH `Rows.tsx:211,236` 的 `containsCurrentDescendant`：
    // 折叠时也高亮，否则用户看不到"我在哪个项目里"。
    await tester.pumpWidget(
      host(expanded: false, onToggle: () {}, containsCurrent: true),
    );
    await tester.pumpAndSettle();

    final label = tester.widget<Text>(find.text('dsh-mobile'));
    final color = label.style?.color;
    // 与"不高亮"那份不同（后者是 labelCaption 的灰）。
    expect(color, isNot(null));

    await tester.pumpWidget(
      host(expanded: false, onToggle: () {}, containsCurrent: false),
    );
    await tester.pumpAndSettle();
    final plain = tester.widget<Text>(find.text('dsh-mobile'));
    expect(plain.style?.color, isNot(color));
  });
}
