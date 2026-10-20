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

  group('流式：未闭合围栏（2026-10-20 第 7 条）', () {
    // 判据来源：DSH 的流式 arm **也**把未闭合围栏渲染成代码块，并逐块冻结、
    // 逐行增量高亮（`ui-primitives/src/markdown/incremental.ts:10-14`、
    // `tests/markdown.client.spec.tsx:281` 的 "a growing unclosed fence
    // extends highlighting"）。所以"途中显示成代码块"不是缺陷；
    // 要证的是**围栏闭合那一帧形态不变**（不变就不会抖）。
    const open = '前言\n```dart\nvoid main() {}';
    const closed = '前言\n```dart\nvoid main() {}\n```';

    /// 只数**我们自己的代码正文**（`SelectableText` 的 data 分支）；
    /// 段落是 `SelectableText.rich`（textSpan 分支），不算。
    List<String> codeBodies(WidgetTester tester) => tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .where((w) => w.data != null)
        .map((w) => w.data!)
        .toList();

    testWidgets('未闭合围栏：一块代码块 + 前置段落仍在', (tester) async {
      await pumpMarkdown(tester, open);
      expect(find.text('代码块'), findsOneWidget, reason: 'banner 要在');
      expect(codeBodies(tester), ['void main() {}'], reason: '围栏内容进代码块');
      expect(rendered(tester, '前言'), isTrue, reason: '前置段落不该被吞进代码块');
    });

    testWidgets('围栏闭合前后：代码块数量与正文一模一样（不抖）', (tester) async {
      await pumpMarkdown(tester, open);
      final before = codeBodies(tester);
      final bannersBefore = tester.widgetList(find.text('代码块')).length;
      await pumpMarkdown(tester, closed);
      final after = codeBodies(tester);
      final bannersAfter = tester.widgetList(find.text('代码块')).length;
      expect(after, before, reason: '闭合只多了三个反引号，正文不该变');
      expect(bannersAfter, bannersBefore, reason: 'banner 不该出现/消失');
    });
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

    // CommonMark 的围栏记号有两种：``` 与 ~~~（`markdown-7.3.1/lib/src/
    // block_syntaxes/fenced_code_block_syntax.dart:13`）。第一版只按 ```
    // 切分，于是 ~~~ 里的 `<T>` 会被当 HTML 改写 —— 那是改用户的代码。
    test('~~~ 围栏里也一个字都不动', () {
      const src = '正文<b>粗</b>\n~~~ts\nconst a = <T>x</T>;\n~~~\n结尾';
      final out = normalizeInlineHtml(src);
      expect(out, contains('正文**粗**'));
      expect(out, contains('const a = <T>x</T>;'), reason: '~~~ 是围栏');
    });

    test('四个反引号围栏里的三反引号**不改变围栏内外**', () {
      // 这一条专门盯"按 ``` 切分"的旧实现：四个反引号开围栏时，
      // 里面的 ``` 会让奇偶段翻转，于是围栏内的 `<T>` 被当 HTML 改写。
      const src =
          '````md\n```dart\nconst a = <T>x</T>;\n```\n````\n后面<b>要归一</b>';
      final out = normalizeInlineHtml(src);
      expect(out, contains('const a = <T>x</T>;'), reason: '四反引号围栏内一律原样');
      expect(out, contains('后面**要归一**'));
    });

    test('**未闭合的围栏一直算围栏内**（流式途中就是这个形状）', () {
      const src = '正文\n```dart\nfinal b = <b>x</b>;';
      expect(normalizeInlineHtml(src), src, reason: '没闭合就没有"围栏外"可言');
    });

    test('比开围栏短的记号不能关围栏', () {
      const src = '```\ncode\n``\n<b>仍在围栏内</b>\n```\n<b>围栏外</b>';
      final out = normalizeInlineHtml(src);
      expect(out, contains('<b>仍在围栏内</b>'));
      expect(out, contains('**围栏外**'));
    });

    test('没有 `<` 的串原样返回（绝大多数消息的快路径）', () {
      const plain = '# 标题\n\n正文 **粗体** 与 `码`。';
      expect(normalizeInlineHtml(plain), plain);
    });
  });
}
