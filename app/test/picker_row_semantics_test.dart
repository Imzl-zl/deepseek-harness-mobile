/// 选择类列表行（`DshPickerRow`）的语义：**角色 + 勾选态**，两者都要说出口。
///
/// ## 为什么这一条值得单独钉
///
/// §7.9 的行结构是 `[名称 / 其下标签组] [勾位]`，而"当前项"只画成一个勾字形。
/// 朗读器看不到字形 —— 所以只画勾时，读屏用户听到的是一行普通文字：
/// 既不知道**能点**，也不知道**它已经是当前项**。
///
/// 反过来，正在用的那条连接是 `selected: true` + `enabled: false`（点它没有去处，
/// 那是重连不是换）：它**不该**被念成按钮，但**必须**念出"已选中"。
/// 判据在这里被拆成两条用例，就是为了不让"打勾"悄悄变成唯一表达。
///
/// 位置与理由见 `.agents/notes/implemented/2026-11-12-a11y-sheet-and-trajectory.md`。
library;

import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/dsh_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
  theme: DshTheme.dark(),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('选中且可点：按钮 + 已选中，名字与标签都在', (tester) async {
    await tester.pumpWidget(
      _host(
        DshPickerRow(
          key: const ValueKey<String>('picker-row-a'),
          name: 'DeepSeek V4',
          tags: const <String>['高性价比'],
          selected: true,
          onTap: () {},
        ),
      ),
    );

    final node = tester.getSemantics(
      find.byKey(const ValueKey<String>('picker-row-a')),
    );
    expect(
      node,
      isSemantics(isButton: true, isSelected: true, hasTapAction: true),
      reason: '勾位是画给人看的；朗读器只有角色与选中态两个入口',
    );
    expect(
      node.getSemanticsData().label,
      allOf(contains('DeepSeek V4'), contains('高性价比')),
      reason: '只加属性，不能把行的文字吞掉（标签组也是这行的信息）',
    );
  });

  testWidgets('当前项（勾着但点不动）：是「已选中」，**不是**按钮', (tester) async {
    await tester.pumpWidget(
      _host(
        DshPickerRow(
          key: const ValueKey<String>('picker-row-current'),
          name: '中转',
          tags: const <String>['ws://127.0.0.1:8787'],
          // 端点选择器里"正在用的那条"就是这个形态：打勾 + 置灰。
          selected: true,
          enabled: false,
          onTap: () {},
        ),
      ),
    );

    final node = tester.getSemantics(
      find.byKey(const ValueKey<String>('picker-row-current')),
    );
    expect(
      node,
      isSemantics(isSelected: true),
      reason: '当前项那个事实必须说出口 —— 只画勾等于没说',
    );
    expect(
      node,
      isNot(isSemantics(isButton: true)),
      reason: '点不动的行不该被念成按钮（点它没有去处）',
    );
  });

  testWidgets('未选中且可点：按钮（未选中那一位是 `selected: false`，不做断言）', (tester) async {
    await tester.pumpWidget(
      _host(
        DshPickerRow(
          key: const ValueKey<String>('picker-row-b'),
          name: '直连',
          selected: false,
          onTap: () {},
        ),
      ),
    );

    // `isSemantics(isSelected: false)` **与“没有这一位”同义**（matcher 只看标志位），
    // 所以这里不断言它 —— 一条分不出两种情形的断言是装饰，不是证据。
    // “当前项”那一条（上一格）才是选中位的判据。
    final node = tester.getSemantics(
      find.byKey(const ValueKey<String>('picker-row-b')),
    );
    expect(node, isSemantics(isButton: true, hasTapAction: true));
  });
}
