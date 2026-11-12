/// 设置行的两种形态：**有去处**（可点 + 箭头 + 按钮角色）与**纯展示**（都没有）。
///
/// ## 为什么这条用例值得有
///
/// 手机设置页有一批行是"电脑侧的真值，这里只读"（当前模型 / 可用模型 / 连接状态 /
/// provider 拉取失败的原话）。它们原来一律传 `onTap: () {}`，于是看起来是
/// **行尾带箭头、点了什么都不发生**的按钮：有 `InkWell` 水波、朗读器报"按钮"、
/// 箭头还在承诺"会带你到别处"。
///
/// 箭头是承诺。没有去处就不该画它 —— 这条用例把三种表现绑在一起钉住：
/// 箭头、水波（`InkWell`）、按钮角色，**要么全有、要么全无**。
library;

import 'package:dsh_mobile/theme/dsh_icons.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/settings_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
  theme: DshTheme.dark(),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('有去处：可点 + 箭头 + 按钮角色', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        SettingsRow(
          icon: 'settings',
          label: '界面字号',
          value: '标准',
          onTap: () => taps += 1,
        ),
      ),
    );

    expect(find.byType(InkWell), findsOneWidget);
    expect(_chevronCount(tester), 1, reason: '箭头是"会带你去别处"的承诺');

    await tester.tap(find.byType(SettingsRow));
    expect(taps, 1);
    expect(
      tester.getSemantics(find.byType(SettingsRow)),
      isSemantics(isButton: true, hasTapAction: true),
      reason: '有去处的行对朗读器是一个按钮',
    );
  });

  testWidgets('纯展示（onTap == null）：不接水波、不画箭头、不报按钮', (tester) async {
    await tester.pumpWidget(
      _host(
        const SettingsRow(icon: 'sparkle', label: '当前模型', value: 'free · x2.6'),
      ),
    );

    expect(
      find.byType(InkWell),
      findsNothing,
      reason: '没有去处就不该有水波（水波本身就是"能点"的承诺）',
    );
    expect(_chevronCount(tester), 0, reason: '没有去处就不画箭头');
    expect(
      tester.getSemantics(find.byType(SettingsRow)),
      isNot(isSemantics(isButton: true)),
      reason: '纯展示的行不该被念成按钮',
    );
    expect(
      tester.getSemantics(find.byType(SettingsRow)),
      isNot(isSemantics(hasTapAction: true)),
      reason: '点了什么都不会发生 ⇒ 不该有点击动作',
    );
  });
}

/// 这一行里画了几个 `chevronRight`（箭头只有一个来源：`DshIcons`）。
int _chevronCount(WidgetTester tester) => tester
    .widgetList<DshIcon>(find.byType(DshIcon))
    .where((icon) => icon.name == 'chevronRight')
    .length;
