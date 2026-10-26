/// 正文提及的**渲染**：可点的只有解析器认出来的那些
/// （`lib/ui/dsh_markdown.dart` 的 `fileMentions` / `onOpenFile`）。
///
/// ## 这一层只画，不判断
///
/// 词表与唯一命中都在 `model/file_mentions.dart`（纯函数，见 `file_mentions_test.dart`）。
/// 这里钉三件事：
///
/// 1. 命中的行内代码带一个可点的手势（用 tooltip 定位，不给测试塞字面量坐标）；
/// 2. **没命中的保持普通代码**（点不动，也没有"打开"的提示）；
/// 3. **围栏代码块里的内容永远不变成链接** —— 那里是用户要读的源码。
library;

import 'package:dsh_mobile/theme/dsh_colors.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/dsh_markdown.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(
  WidgetTester tester,
  String markdown, {
  Map<String, String>? fileMentions,
  void Function(String path)? onOpenFile,
  bool compact = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: DshTheme.dark(),
      home: Scaffold(
        backgroundColor: DshColors.bgBase,
        body: SingleChildScrollView(
          child: DshMarkdown(
            markdown,
            compact: compact,
            fileMentions: fileMentions,
            onOpenFile: onOpenFile,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('命中的行内代码可点：点它把路径交给回调', (tester) async {
    final opened = <String>[];
    await _pump(
      tester,
      '改了 `src/a.ts` 里的两行。',
      fileMentions: const {'src/a.ts': 'src/a.ts'},
      onOpenFile: opened.add,
    );
    // 定位点用 tooltip（无障碍也需要它 —— 一枚只有图标的按钮没有可读文本）。
    final mention = find.byTooltip('打开 src/a.ts');
    expect(mention, findsOneWidget);
    await tester.tap(mention);
    expect(opened, ['src/a.ts']);
  });

  testWidgets('没命中的 token 保持普通代码：点不动，也没有"打开"提示', (tester) async {
    final opened = <String>[];
    await _pump(
      tester,
      '看 `nope.txt` 与 `src/a.ts`。',
      fileMentions: const {'src/a.ts': 'src/a.ts'},
      onOpenFile: opened.add,
    );
    expect(find.byTooltip('打开 nope.txt'), findsNothing);
    expect(find.byTooltip('打开 src/a.ts'), findsOneWidget);
    expect(opened, isEmpty);
  });

  testWidgets('围栏代码块里的路径不算提及（源码不是链接）', (tester) async {
    final opened = <String>[];
    await _pump(
      tester,
      '示例：\n\n```ts\nimport x from "src/a.ts"\n```\n',
      fileMentions: const {'src/a.ts': 'src/a.ts'},
      onOpenFile: opened.add,
    );
    expect(find.byTooltip('打开 src/a.ts'), findsNothing);
    expect(find.textContaining('src/a.ts'), findsOneWidget);
  });

  testWidgets('没有回调（思考正文 / compact）时不可点：只有画，没有手势', (tester) async {
    await _pump(
      tester,
      '看 `src/a.ts`。',
      fileMentions: const {'src/a.ts': 'src/a.ts'},
      compact: true,
    );
    expect(find.byTooltip('打开 src/a.ts'), findsNothing);
  });

  testWidgets('行内代码的原有样式不丢：命中后框里仍是等宽代码，不出现反引号', (tester) async {
    await _pump(
      tester,
      '看 `src/a.ts`。',
      fileMentions: const {'src/a.ts': 'src/a.ts'},
      onOpenFile: (_) {},
    );
    expect(find.textContaining('`'), findsNothing);
    expect(find.textContaining('src/a.ts'), findsOneWidget);
  });
}
