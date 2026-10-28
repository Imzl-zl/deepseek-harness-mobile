/// 语法高亮：纯 Dart 的 `re_highlight`（highlight.js 的移植）。
///
/// 判据：只覆盖我们注册的那一档语言；认不出/抛错 ⇒ `null`（调用方退回纯文本）。
/// 高亮**只覆盖颜色**，字号/行高/字体由调用方的 `base` 给 —— 于是高亮与
/// 纯文本回退的排版逐像素一致。
library;

import 'package:dsh_mobile/ui/dsh_code_highlight.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 数一数这棵 span 树里出现过几种颜色（高亮真实的证据）。
int _colorCount(TextSpan root) {
  final colors = <int>{};
  void walk(InlineSpan span) {
    if (span is TextSpan) {
      final color = span.style?.color;
      if (color != null) colors.add(color.toARGB32());
      for (final child in span.children ?? const <InlineSpan>[]) {
        walk(child);
      }
    }
  }

  walk(root);
  return colors.length;
}

void main() {
  test('认识的语言：dart 代码被染成多种颜色', () {
    final span = highlightCode(
      'void main() {\n  final x = 1; // 注释\n  print("hi");\n}\n',
      'dart',
      base: const TextStyle(),
      dark: true,
    );
    expect(span, isNotNull);
    expect(_colorCount(span!), greaterThan(1), reason: '关键字/字符串/注释该是不同颜色');
  });

  test('大小写不敏感（```DART 与 ```dart 等价）', () {
    final span = highlightCode(
      'int a = 1;',
      'DART',
      base: const TextStyle(),
      dark: false,
    );
    expect(span, isNotNull);
  });

  test('不认识的语言 / 没有语言 ⇒ null（退回纯文本）', () {
    expect(
      highlightCode('x', 'not-a-language', base: const TextStyle(), dark: true),
      isNull,
    );
    expect(
      highlightCode('x', null, base: const TextStyle(), dark: true),
      isNull,
    );
    expect(isHighlightedLanguage('not-a-language'), isFalse);
    expect(isHighlightedLanguage('DART'), isTrue);
  });

  test('文件后缀 → 语法 id（与桌面 viewer 认的后缀同族）', () {
    expect(languageForPath('lib/main.dart'), 'dart');
    expect(languageForPath(r'C:\w\a.TS'), 'typescript');
    expect(languageForPath('a.yml'), 'yaml');
    expect(languageForPath('page.html'), 'xml');
    expect(languageForPath('README.md'), 'markdown');
    expect(languageForPath('setup.sh'), 'bash');
    expect(languageForPath('x.toml'), isNull, reason: '没注册的语言按纯文本');
    expect(languageForPath('noext'), isNull);
    expect(languageForPath('trailing.'), isNull);
  });
}
