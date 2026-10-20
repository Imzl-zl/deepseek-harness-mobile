/// Markdown / 行内 HTML 的**实际**覆盖度。
///
/// 用户 2026-10-20：「能渲染 md、html 常见的格式嘛？」
///
/// 事实基础（全部来自本地包源码，不是猜）：
/// - `flutter_markdown_plus/lib/src/widget.dart:289` 写明 `extensionSet`
///   **默认是 `md.ExtensionSet.gitHubFlavored`**；
/// - `markdown-7.3.1/lib/src/extension_set.dart`：
///   `gitHubFlavored` 的块级 = FencedCode / **Table** / checkbox 列表 / FootnoteDef，
///   行内 = **InlineHtmlSyntax** / Strikethrough / Autolink；
///   `gitHubWeb` 另外还有 HeaderWithId / **AlertBlockSyntax** / Emoji / ColorSwatch。
///
/// 判据用 `find.textContaining(..., findRichText: true)`：
/// `flutter_markdown` 把强调 / 行内码 / 链接渲染成 `RichText`，
/// 默认的 `find.text` 只看 `Text`（第一次手工收集 `Text.data` 就是这么误判成
/// "什么都没渲染"的）。
library;

import 'package:dsh_mobile/theme/dsh_theme.dart';
import 'package:dsh_mobile/ui/dsh_markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const String _sample = r'''
# 标题一

普通段落，含 **粗体**、*斜体*、~~删除线~~ 与 `行内码`。

| 列 A | 列 B |
|---|---|
| 单元格 | 2 |

- [x] 已完成
- [ ] 未完成

> 引用块

> [!NOTE]
> 警示块内容

行内 HTML：<b>加粗HTML</b> 与 <code>行内码HTML</code>。
''';

Future<void> pumpMarkdown(WidgetTester tester, String data) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: DshTheme.dark(),
      home: Scaffold(body: SingleChildScrollView(child: DshMarkdown(data))),
    ),
  );
  await tester.pumpAndSettle();
}

/// 正文里是否出现这段文字（**同时认 `RichText`**）。
bool rendered(WidgetTester tester, String text) =>
    tester.any(find.textContaining(text, findRichText: true));

void main() {
  setUp(() {});

  testWidgets('Markdown 常见格式逐项确认', (tester) async {
    await pumpMarkdown(tester, _sample);

    expect(rendered(tester, '标题一'), isTrue, reason: 'h1');
    expect(rendered(tester, '普通段落'), isTrue, reason: '段落');
    expect(rendered(tester, '粗体'), isTrue, reason: '**粗体**');
    expect(rendered(tester, '斜体'), isTrue, reason: '*斜体*');
    expect(rendered(tester, '删除线'), isTrue, reason: '~~删除线~~');
    expect(rendered(tester, '行内码'), isTrue, reason: '`行内码`');
    expect(rendered(tester, '列 A'), isTrue, reason: '表格表头');
    expect(rendered(tester, '单元格'), isTrue, reason: '表格单元格');
    expect(rendered(tester, '已完成'), isTrue, reason: '- [x] 任务列表');
    expect(rendered(tester, '引用块'), isTrue, reason: '> 引用');
  });

  testWidgets('行内 HTML：标签被解析掉，文字留下', (tester) async {
    await pumpMarkdown(tester, _sample);

    expect(rendered(tester, '加粗HTML'), isTrue, reason: '<b> 里的文字要在');
    expect(
      rendered(tester, '<b>'),
      isFalse,
      reason: 'InlineHtmlSyntax 默认开着（gitHubFlavored 的行内表），标签不该露出',
    );
    expect(rendered(tester, '行内码HTML'), isTrue, reason: '<code> 里的文字要在');
  });

  testWidgets('GFM 警示块：默认扩展集下 `[!NOTE]` 会原样露出 —— 记录事实', (tester) async {
    await pumpMarkdown(tester, _sample);

    expect(rendered(tester, '警示块内容'), isTrue, reason: '内容必须在');
    // **这是当前事实，不是期望**：AlertBlockSyntax 只在 `gitHubWeb` 里，
    // 而默认是 `gitHubFlavored` ⇒ `[!NOTE]` 被当正文。
    // 要真支持就改 `extensionSet: md.ExtensionSet.gitHubWeb`（见决策笔记）。
    expect(
      rendered(tester, '[!NOTE]'),
      isTrue,
      reason: '默认 gitHubFlavored 不含 AlertBlockSyntax',
    );
  });

  group('normalizeInlineHtml（纯函数）', () {
    test('四种常见标签归一成 Markdown', () {
      expect(normalizeInlineHtml('<b>x</b>'), '**x**');
      expect(normalizeInlineHtml('<strong>x</strong>'), '**x**');
      expect(normalizeInlineHtml('<i>x</i>'), '*x*');
      expect(normalizeInlineHtml('<em>x</em>'), '*x*');
      expect(normalizeInlineHtml('<code>x</code>'), '`x`');
      expect(normalizeInlineHtml('a<br>b'), 'a\nb');
      expect(normalizeInlineHtml('a<br/>b'), 'a\nb');
      // 大小写不敏感（模型常写 `<B>`）
      expect(normalizeInlineHtml('<B>x</B>'), '**x**');
    });

    test('其余标签去掉、文字留下', () {
      expect(normalizeInlineHtml('<p>段落</p>'), '段落');
      expect(normalizeInlineHtml('<span class="k">词</span>'), '词');
    });

    test('**代码块里一个字都不动**（那是用户在看的源码）', () {
      const src = '正文<b>粗</b>\n```dart\nfinal b = <b>x</b>;\n```\n结尾';
      final out = normalizeInlineHtml(src);
      expect(out, contains('正文**粗**'), reason: '围栏外要归一');
      expect(
        out,
        contains('final b = <b>x</b>;'),
        reason: '围栏内必须原样（把它改成 ** 就是改用户的内容）',
      );
    });

    test('没有 `<` 的串原样返回（绝大多数消息的快路径）', () {
      const plain = '# 标题\n\n正文 **粗体** 与 `码`。';
      expect(normalizeInlineHtml(plain), plain);
    });
  });
}
