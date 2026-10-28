/// 代码语法高亮：**纯 Dart** 的 `re_highlight`（highlight.js 的逐行翻译）。
///
/// ## 为什么是它
///
/// - 纯 Dart（`TextSpanRenderer` 直接产出 `TextSpan`），没有平台通道，单测能直接跑；
/// - `re_highlight` 是 `highlight.dart` 停更后的替代品（作者原话见其 README），
///   语法规则与 highlight.js 11.9.0 同步；
/// - 只按需注册语言（**不 import `languages/all.dart`**）：那个文件会把几百种语法
///   全打进包里。这里只收常见的一档，认不出的语言退回纯文本。
///
/// ## 判据与边界
///
/// - 语言来自**代码围栏的 info string**（` ```dart `）或文件后缀（`languageForPath`）；
/// - 认不出 / 高亮抛错 ⇒ 返回 `null`，调用方按纯文本渲染（**绝不显示半个高亮**）；
/// - 主题只取亮/暗两套（`githubTheme` / `githubDarkTheme`），与我们的底色同一族，
///   不再自己发明第三套颜色。
///
/// Note: 选型与被否方案（`flutter_highlight` 依赖已停更的 `highlight`）见
/// `.agents/notes/implemented/2026-10-28-code-highlight-with-re-highlight.md`。
library;

import 'package:flutter/material.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/powershell.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/scss.dart';
import 'package:re_highlight/languages/shell.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/github-dark.dart';
import 'package:re_highlight/styles/github.dart';

/// 认识的语法 id（也是代码块头部标签的判据）。
final Map<String, Mode> _languages = <String, Mode>{
  'bash': langBash,
  'c': langC,
  'cpp': langCpp,
  'css': langCss,
  'dart': langDart,
  'diff': langDiff,
  'dockerfile': langDockerfile,
  'go': langGo,
  'ini': langIni,
  'java': langJava,
  'javascript': langJavascript,
  'json': langJson,
  'kotlin': langKotlin,
  'lua': langLua,
  'makefile': langMakefile,
  'markdown': langMarkdown,
  'php': langPhp,
  'powershell': langPowershell,
  'python': langPython,
  'ruby': langRuby,
  'rust': langRust,
  'scss': langScss,
  'shell': langShell,
  'sql': langSql,
  'swift': langSwift,
  'typescript': langTypescript,
  'xml': langXml,
  'yaml': langYaml,
};

/// 认识的语法 id（代码块头部据此报语言名，否则报「代码块」）。
bool isHighlightedLanguage(String? language) =>
    language != null && _languages.containsKey(language.toLowerCase());

Highlight? _engine;
Highlight get _highlightEngine =>
    _engine ??= (Highlight()..registerLanguages(_languages));

/// 文件后缀 → 语法 id（与桌面 viewer 认的后缀同一档；认不出返回 `null`）。
///
/// 只覆盖常见的一档：`.ts`/`.tsx` 都按 typescript，`.mjs`/`.cjs` 按 javascript，
/// `.yml` 按 yaml，`.htm` 按 xml —— 桌面 viewers 也是按族归的。
String? languageForPath(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return null;
  final ext = path.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'bash' || 'sh' || 'zsh' => 'bash',
    'c' || 'h' => 'c',
    'cc' || 'cpp' || 'cxx' || 'hpp' => 'cpp',
    'css' => 'css',
    'dart' => 'dart',
    'diff' || 'patch' => 'diff',
    'go' => 'go',
    'htm' || 'html' || 'xml' || 'svg' => 'xml',
    'ini' || 'cfg' || 'conf' => 'ini',
    'java' => 'java',
    'js' || 'mjs' || 'cjs' => 'javascript',
    'json' => 'json',
    'kt' || 'kts' => 'kotlin',
    'lua' => 'lua',
    'md' || 'markdown' => 'markdown',
    'php' => 'php',
    'ps1' => 'powershell',
    'py' => 'python',
    'rb' => 'ruby',
    'rs' => 'rust',
    'scss' => 'scss',
    'sql' => 'sql',
    'swift' => 'swift',
    'ts' || 'tsx' => 'typescript',
    'yaml' || 'yml' => 'yaml',
    _ => null,
  };
}

/// 把一段代码高亮成 [TextSpan]；认不出语言或高亮抛错时返回 `null`。
///
/// [base] 是**代码块的正文样式**（字号/行高/字体），高亮只覆盖颜色 ——
/// 这样它和纯文本回退的排版逐像素一致。
TextSpan? highlightCode(
  String code,
  String? language, {
  required TextStyle base,
  required bool dark,
}) {
  final key = language?.toLowerCase();
  if (key == null || !_languages.containsKey(key)) return null;
  try {
    final result = _highlightEngine.highlight(code: code, language: key);
    final renderer = TextSpanRenderer(
      base,
      dark ? githubDarkTheme : githubTheme,
    );
    result.render(renderer);
    return renderer.span;
  } catch (_) {
    // 高亮不是正确性前提：一段代码染不上色，仍然要能读。
    return null;
  }
}
