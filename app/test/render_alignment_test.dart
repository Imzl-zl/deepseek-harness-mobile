/// 会话页渲染与 DSH 规格的对齐判据（2026-10-20 第二批）。
///
/// 每一条都对应一个**具体行号**的规格，不是"看起来差不多"：
///
/// | 判据 | 规格 |
/// |---|---|
/// | 助手正文 14/24 | `ui-theme/src/styles/gradient-shadow-text.css:93` + `ui-chat/src/client/chat/AssistantMarkdown.module.css:1-14` |
/// | 工具卡正文 11/16 等宽、上限 150 | `ui-tool/src/client/tool/components/ToolRow.module.css:181-201` |
/// | 系统提示词正文 11/16 等宽、上限 141 | `ui-chat/src/client/chat/ContextInjectionRow.module.css:50-64` |
/// | 宽表横向滚动、自然宽度 | `ui-primitives/src/markdown/MarkdownText.module.css:192-233` + `flutter_markdown_plus-1.0.12/lib/src/builder.dart:447-463` |
/// | 用户消息不跑 Markdown | `ui-primitives/src/user-text.tsx:18-20` |
library;

import 'package:dsh_mobile/model/chat_item.dart';
import 'package:dsh_mobile/theme/dsh_colors.dart';
import 'package:dsh_mobile/theme/dsh_icons.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/chat_turns.dart';
import 'package:dsh_mobile/ui/dsh_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: DshTheme.dark(),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
  await tester.pumpAndSettle();
}

/// 正文段落实际用的字号 / 行高（`MarkdownBody` 产出 `SelectableText.rich`）。
TextStyle bodyStyleOf(WidgetTester tester) {
  final widget = tester.widget<SelectableText>(
    find.byType(SelectableText).first,
  );
  final style = widget.textSpan?.style;
  expect(style, isNotNull, reason: '正文样式要在 textSpan 上');
  return style!;
}

void main() {
  group('助手正文：DSH 的 markdown base 是 14/24', () {
    testWidgets('段落字号 14、行高 24', (tester) async {
      await pump(tester, const DshMarkdown('一段正文'));
      final style = bodyStyleOf(tester);
      expect(style.fontSize, 14);
      // height 是倍数：24/14。
      expect(style.height, closeTo(24 / 14, 1e-9));
    });

    testWidgets('compact 档（思考正文）：13/20、淡一档', (tester) async {
      await pump(tester, const DshMarkdown('一段思考', compact: true));
      final style = bodyStyleOf(tester);
      expect(style.fontSize, 13);
      expect(style.height, closeTo(20 / 13, 1e-9));
      expect(
        style.color,
        const DshColorTokens.dark().labelTertiary,
        reason:
            'DSH compact 正文是 label-tertiary（MarkdownText.module.css:331-336）',
      );
    });
  });

  group('工具卡展开正文：照 .ioCard/.ioSection/.ioText', () {
    testWidgets('11/16 等宽 + 上限 150 + 自己滚动', (tester) async {
      await pump(
        tester,
        const ToolCard(
          name: 'bash',
          status: ToolCallStatus.completed,
          argument: 'ls',
          detail: 'a.txt\nb.txt',
        ),
      );
      await tester.tap(find.text('bash'));
      await tester.pumpAndSettle();

      final text = tester.widget<SelectableText>(
        find.byType(SelectableText).first,
      );
      final style = text.style!;
      expect(
        style.fontFamily,
        'monospace',
        reason: 'ioCard 是 code-block-small 字体族',
      );
      expect(
        style.fontSize,
        11,
        reason: '--dsw-font-markdown-code-block-small 字号 11',
      );
      expect(style.height, closeTo(16 / 11, 1e-9), reason: '同一 token 的行高 16');

      // `.ioSection { max-height: 150px }`：一条长输出不许把对话顶走。
      final box = tester.widget<ConstrainedBox>(
        find
            .ancestor(
              of: find.byType(SelectableText).first,
              matching: find.byType(ConstrainedBox),
            )
            .first,
      );
      expect(box.constraints.maxHeight, 150);
    });
  });

  group('系统提示词 / 上下文注入：照 ContextInjectionRow .body', () {
    testWidgets('11/16 等宽 + 上限 141 + 代码块底色', (tester) async {
      await pump(tester, const SystemTurn('一整份系统提示词'));
      expect(find.text('系统提示词'), findsOneWidget);

      await tester.tap(find.text('系统提示词'));
      await tester.pumpAndSettle();

      final text = tester.widget<SelectableText>(
        find.byType(SelectableText).first,
      );
      expect(text.style!.fontSize, 11);
      expect(text.style!.height, closeTo(16 / 11, 1e-9));

      final box = tester.widget<ConstrainedBox>(
        find
            .ancestor(
              of: find.byType(SelectableText).first,
              matching: find.byType(ConstrainedBox),
            )
            .first,
      );
      expect(
        box.constraints.maxHeight,
        141,
        reason: 'Figma 10:2482 的 141px 代码块上限',
      );
    });

    // 图标是"这两行不是同一种东西"的判据：系统提示词用 browse、
    // 上下文注入用 contextInjection（`SystemPromptRow.tsx:30`、
    // `ContextInjectionRow.tsx:55`）。原来系统提示词用的是我们自己挑的 info。
    testWidgets('标题行图标跟节点类型走（browse / contextInjection）', (tester) async {
      await pump(tester, const SystemTurn('提示词正文'));
      expect(tester.widget<DshIcon>(find.byType(DshIcon).first).name, 'browse');

      await pump(tester, const SystemTurn('注入正文', label: '上下文注入'));
      expect(
        tester.widget<DshIcon>(find.byType(DshIcon).first).name,
        'contextInjection',
      );
    });

    // 上下文行的生产者显示在标题后的分隔点之后（`ContextInjectionRow.tsx:63-69`）。
    testWidgets('上下文行带生产者标签', (tester) async {
      await pump(
        tester,
        const SystemTurn(
          'Current runtime context. …',
          label: '上下文注入',
          hint: 'runtime-context',
        ),
      );
      expect(find.text('上下文注入'), findsOneWidget);
      expect(find.text('runtime-context'), findsOneWidget);
    });
  });

  group('表格：宽表要有横向出路', () {
    const wide = '''
| 列一 | 列二 | 列三 | 列四 | 列五 | 列六 |
|---|---|---|---|---|---|
| 第一列的单元格 | 第二列的单元格 | 第三列的单元格 | 第四列的单元格 | 第五列的单元格 | 第六列的单元格 |
''';

    testWidgets('窄屏（360）六列表格：自然宽度 + 横向滚动容器', (tester) async {
      // 真机竖屏宽度；默认 800 的测试视口下这张表根本不"宽"，测不出问题。
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pump(tester, const DshMarkdown(wide));

      // `IntrinsicColumnWidth` 是 flutter_markdown_plus 唯一两种会套横滚的
      // 列宽之一（`builder.dart:447-463`）。
      final horizontal = tester
          .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .where((w) => w.scrollDirection == Axis.horizontal);
      expect(
        horizontal,
        isNotEmpty,
        reason: '宽表必须有横向滚动容器（DSH .tableScroll 的 overflow-x: auto）',
      );
      // 自然宽度：不被屏幕宽度压扁 ⇒ 比 360 的视口宽，靠横滚看全。
      expect(tester.getSize(find.byType(Table)).width, greaterThan(360));
      expect(tester.takeException(), isNull, reason: '不能靠溢出条纹"解决"');
    });
  });

  group('用户消息：DSH 不跑 Markdown', () {
    testWidgets('`**加粗**` 原样显示（与 UserTextRun 一致）', (tester) async {
      await pump(tester, const UserTurn('这是 **加粗** 的原文'));
      expect(
        find.text('这是 **加粗** 的原文'),
        findsOneWidget,
        reason: '用户打的是纯文本（user-text.tsx:18-20），不该被渲染成粗体',
      );
    });
  });
}
