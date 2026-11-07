/// 宽表的横向滚动条：**不常驻**，且粗细/颜色走我们的主题。
///
/// 真机现象（2026-11-07）：Markdown 表格右侧能横向滚动没问题，但表格下面
/// 压着一根又黑又粗的条 —— 那是 `flutter_markdown_plus` 自带的 `Scrollbar`
/// （`builder.dart:451-455`）按 Material 默认值画的：8 px 粗、`onSurface` 全黑，
/// 而且 `thumbVisibility` 被设成了 `true`（一直显示）。
library;

import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/dsh_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _wideTable =
    '| 名称 | 值 | 备注 |\n'
    '|---|---|---|\n'
    '| a | 1 | 这一列故意写得很长很长，把表格撑到屏幕之外，才需要横向滚动 |';

void main() {
  testWidgets('表格的横向 Scrollbar 不常驻，粗细走主题', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: DshTheme.light(),
        home: const Scaffold(
          body: SingleChildScrollView(child: DshMarkdown(_wideTable)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final bars = find.byType(Scrollbar);
    expect(bars, findsWidgets, reason: '宽表必须有横向出路');

    for (final element in bars.evaluate()) {
      expect(
        (element.widget as Scrollbar).thumbVisibility,
        isFalse,
        reason: '常驻拇指会在正文里压一根粗条',
      );
    }

    final context = tester.element(bars.first);
    expect(
      Theme.of(
        context,
      ).scrollbarTheme.thickness?.resolve(const <WidgetState>{}),
      3,
      reason: '粗细由主题给（Material 默认 8）',
    );
    expect(
      Theme.of(
        context,
      ).scrollbarTheme.trackVisibility?.resolve(const <WidgetState>{}),
      isFalse,
      reason: '不要轨道底色',
    );
  });
}
