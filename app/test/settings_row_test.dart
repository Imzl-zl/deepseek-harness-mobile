/// 设置行排版回归：**长值不许把标题挤成竖排**。
///
/// ## 这一组守什么
///
/// 真机（2026-11-05 截图）上「当前模型」四个字被挤成一列，因为值
/// `DeepSeek V4.1 Flash · WorkBuddy · magpie · workbuddy` 塞在
/// `ListTile.trailing` 里 —— trailing 按**固有宽度**排版，标题只剩一条缝
/// （`packages/flutter/lib/src/material/list_tile.dart:1515,1552-1558`），
/// 中文于是逐字换行。
///
/// 基线是原型：`.settings-row .row-value{max-width:42%;white-space:nowrap;
/// text-overflow:ellipsis}`（`mock/proto/styles.css`）。落地端同等约束：
/// 值最多占行宽 42%、单行省略；标题单行省略。
library;

import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/settings_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真机那张截图里的值（模型 id + provider）。
const _longValue = 'DeepSeek V4.1 Flash · WorkBuddy · magpie · workbuddy';

Widget _host({double width = 390}) => MaterialApp(
  theme: DshTheme.dark(),
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: width,
        child: SettingsRow(
          icon: 'sparkle',
          label: '当前模型',
          value: _longValue,
          onTap: () {},
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('当前模型：长值不把标题挤成竖排（42% 上限 + 单行省略）', (tester) async {
    await tester.pumpWidget(_host());

    final label = find.text('当前模型');
    final value = find.text(_longValue);
    expect(label, findsOneWidget);
    expect(value, findsOneWidget);

    // 标题必须单行：旧实现（ListTile.trailing）这里是 4 行。
    expect(tester.getSize(label).height, lessThan(30), reason: '标题被值挤成竖排 = 回归');

    expect(
      tester.widget<Text>(value).maxLines,
      1,
      reason: '值必须单行（基线：row-value 的 nowrap）',
    );
    expect(
      tester.widget<Text>(value).overflow,
      TextOverflow.ellipsis,
      reason: '值超宽要省略（基线：row-value 的 text-overflow:ellipsis）',
    );
    // 行宽 390 − 左右各 16 = 358；42% = 150.4。
    expect(
      tester.getSize(value).width,
      lessThanOrEqualTo(151),
      reason: '值最多占行宽 42%，不许吃满整行',
    );
  });

  testWidgets('窄屏也不许把值撑爆行宽', (tester) async {
    await tester.pumpWidget(_host(width: 320));
    final value = find.text(_longValue);
    expect(
      tester.getSize(value).width,
      lessThanOrEqualTo((320 - 32) * 0.42 + 1),
    );
    expect(find.text('当前模型'), findsOneWidget);
  });
}
