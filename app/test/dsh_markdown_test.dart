/// Markdown 渲染的回归（`lib/ui/dsh_markdown.dart`）。
///
/// ## 这一组守的是什么
///
/// 第一版把消息正文直接塞进 `SelectableText` —— 于是助手回复里的
/// ```` ```dart ```` 原样显示成三个反引号、`**加粗**` 也原样，
/// 而 **DSH 桌面端是渲染的**：同一段回复在两端长得完全不一样。
///
/// 这个问题**只有看界面才会发现** —— 它不报错、不影响数据、其它测试也全绿
///（它是靠"看示例数据"暴露的，见 `data/preview_data.dart`）。
///
/// ## 断言为什么这样写
///
/// 只断言**用户看得见的东西**：原文里的 Markdown 记号**不该**出现在界面上，
/// 而内容**该**出现。不去断言 widget 类型 —— `MarkdownBody` 内部的
/// 渲染结构是它的实现细节（第一版断言 `Text`/`RichText`，两个都找到 0 个，
/// 于是测试报"没换行"，其实是我找错了对象；那类断言既脆又没意义）。
library;

import 'package:dsh_mobile/theme/dsh_colors.dart';
import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/dsh_markdown.dart';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(
  WidgetTester tester,
  String markdown, {
  Color? baseColor,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: DshTheme.dark(),
      home: Scaffold(
        backgroundColor: DshColors.bgBase,
        body: SingleChildScrollView(
          child: DshMarkdown(markdown, baseColor: baseColor),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('代码块被渲染：反引号不出现，内容出现', (tester) async {
    await _pump(tester, '看这段：\n\n```dart\nvoid main() {}\n```\n');
    expect(
      find.textContaining('```'),
      findsNothing,
      reason: '反引号出现在界面上 = 没渲染 Markdown（第一版的症状）',
    );
    expect(find.textContaining('void main()'), findsOneWidget);
  });

  testWidgets('加粗被渲染：`**` 不出现', (tester) async {
    await _pump(tester, '这是**加粗**的字。');
    expect(find.textContaining('**'), findsNothing);
    expect(find.textContaining('加粗'), findsOneWidget);
  });

  testWidgets('行内代码被渲染：反引号不出现', (tester) async {
    await _pump(tester, '调用 `_res.dispose()` 作废资源。');
    expect(find.textContaining('`'), findsNothing);
    expect(find.textContaining('_res.dispose()'), findsOneWidget);
  });

  testWidgets('列表被渲染：`-` 不残留', (tester) async {
    await _pump(tester, '- 第一项\n- 第二项\n');
    expect(find.textContaining('- 第一项'), findsNothing, reason: '记号不该残留');
    expect(find.textContaining('第一项'), findsOneWidget);
    expect(find.textContaining('第二项'), findsOneWidget);
  });

  testWidgets('标题被渲染：`#` 不残留', (tester) async {
    await _pump(tester, '# 一级标题\n\n正文。');
    expect(find.textContaining('#'), findsNothing);
    expect(find.textContaining('一级标题'), findsOneWidget);
  });

  testWidgets('单个换行也换行（聊天场景的刻意偏离）', (tester) async {
    // CommonMark 规定单个换行当空格，而**聊天里用户按回车就是想要换行**。
    // DSH 桌面端的表现也是换行 —— 这里钉住它，别哪天被"改回标准"。
    await _pump(tester, '第一行\n第二行');
    expect(find.textContaining('第一行'), findsOneWidget);
    expect(
      find.textContaining('第一行 第二行'),
      findsNothing,
      reason: 'softLineBreak 应让单换行真的换行，而不是并成一行',
    );
  });

  testWidgets('长中文不溢出（没有空格可断的语言）', (tester) async {
    // 中文没有空格，如果渲染器按"空格断词"处理就会横向溢出。
    const long =
        '这一条是故意写得很长来验换行的连接层拆分之后每连接资源束把密码器握手会话'
        '订阅计数器窗口分帧器六项收在一处于是建一份与作废一份各只有一处不会再漏。';
    await _pump(tester, long);
    expect(tester.takeException(), isNull);
    // 没有横向溢出：`RenderFlex` 会抛 overflow 异常，这里应无异常。
  });

  testWidgets('空串不崩（流式刚开始时正文可能为空）', (tester) async {
    await _pump(tester, '');
    expect(tester.takeException(), isNull);
  });

  testWidgets('未闭合的代码块不崩（流式半句话）', (tester) async {
    // 流式期间 Markdown 常常是半截的（```` ``` ```` 刚写了一半）。
    // `_LiveBar` 不渲染 Markdown 就是为了这个，但**持久路径也可能收到**
    //（比如中断后落盘的内容），所以这里确认渲染器自己能扛住。
    await _pump(tester, '看这段：\n\n```dart\nvoid main() {');
    expect(tester.takeException(), isNull);
  });

  testWidgets('baseColor 被接受且不崩（用户气泡在蓝底上）', (tester) async {
    await _pump(tester, '你好', baseColor: DshColors.onAccent);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('你好'), findsOneWidget);
  });
}
