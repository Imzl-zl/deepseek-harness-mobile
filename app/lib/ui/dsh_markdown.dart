/// DSH 风格的 Markdown 渲染（消息正文用它，而不是纯 `Text`）。
///
/// ## 为什么必须有它
///
/// 第一版把消息正文直接塞进 `SelectableText` —— 于是助手回复里的
/// ```` ```dart ```` 原样显示成三个反引号、`**加粗**` 也原样。
/// 而 DSH 桌面端是**渲染**的：同一段回复在两端长得完全不一样。
///
/// 这个问题是靠产品里的示例数据暴露的（该入口 2026-10-26 已删除）——
/// 在那之前界面锁在配对后面，等于把它藏到了最后才知道。
///
/// ## 选型（`flutter_markdown_plus`）
///
/// `flutter_markdown` 已被官方 discontinued（`app-channel-client.md` §7 记着这件事）。
/// 候选三个，按**依赖面**选：
///
/// | 包 | 传递依赖 |
/// |---|---|
/// | `flutter_markdown_plus` | **1 个**：`markdown`（Dart 官方团队维护，纯 Dart） |
/// | `gpt_markdown` | 4 个：`val_highlight` / `val_highlight_flutter` / `val_latex` / `val_latex_flutter` |
/// | `streamdown` | 15 个 |
///
/// 选依赖面最小且那个依赖归官方的那个。代价：**没有语法高亮** ——
/// 而 `app-channel-client.md` §7 说高亮要"可缓存、可后台预热"，
/// 那是独立的一块（见文件末的"仍未做"），不该由 Markdown 包顺手带进来。
///
/// ## 样式从哪来
///
/// 全部取自 `DshColors` / `DshTheme.mono`（**三端唯一的颜色与字体来源**）。
/// 这里**不写任何字面色值**：那会让主题分叉从这一处开始漏。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../model/file_mentions.dart' show normalizeCodeSpan;
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';
import '../theme/dsh_type.dart';
import 'dsh_code_highlight.dart';

/// 把**常见行内 HTML** 归一成等价的 Markdown 标记。
///
/// ## 为什么需要它（2026-10-20 实测，不是猜）
///
/// `flutter_markdown_plus` 的默认扩展集是 `md.ExtensionSet.gitHubFlavored`
/// （`flutter_markdown_plus/lib/src/widget.dart:289`），它的行内表里**有**
/// `InlineHtmlSyntax`（`markdown-7.3.1/lib/src/extension_set.dart:40`）——
/// 所以 HTML 会被**解析**成元素。但 flutter_markdown 只为自己认识的标签
/// 提供构建器，其余标签会**把原始源码当文本吐出来**：
///
/// 探针（`test/markdown_coverage_test.dart`）实测：正文里 `<b>` 是**可见字符**。
/// 也就是说"HTML 会渲染"这个印象是错的 —— 它现在是**原样露出标签**。
///
/// ## 做法与边界
///
/// 只做**确定等价**的四种，其余标签**去掉**（宁可丢样式，不丢文字）：
///
/// | HTML | 归一为 | 说明 |
/// |---|---|---|
/// | `<br>` `<br/>` | 换行 | `softLineBreak: true` 下换行真的换行 |
/// | `<b>` `<strong>` | `**…**` | 与 `styleSheet.strong` 同一样式 |
/// | `<i>` `<em>` | `*…*` | 与 `styleSheet.em` 同一样式 |
/// | `<code>` | `` `…` `` | 与 `styleSheet.code` 同一样式 |
///
/// **代码块里一个字都不动** —— 那里是用户在看的源码，
/// 把它 `<b>` 改成 `**` 就是改内容。
///
/// ## 围栏怎么认（2026-10-20 更正）
///
/// 第一版用 `source.split('```')` 取奇数段当"围栏内"。那是错的：
/// **CommonMark 的围栏有两种记号**，`~~~` 与 ```` ``` ```` 等价
/// （`markdown-7.3.1/lib/src/block_syntaxes/fenced_code_block_syntax.dart:13` 的
/// "Parses preformatted code blocks between two ~~~ or ``` sequences"，
/// 判据是 `patterns.dart` 的 `codeFencePattern`）。只认反引号 ⇒
/// `~~~` 里的 `<T>` 会被当成 HTML 改写掉，等于**改用户看到的代码**。
///
/// 所以改成**逐行扫描**：遇到 3 个及以上的 `` ` `` 或 `~` 开围栏，
/// 同记号、不短于开围栏、后面只有空白的行才关围栏；
/// **未闭合的围栏一直算围栏内**（流式途中就是这样，与 CommonMark 一致）。
///
/// 没有 `<` 的串**原样返回**（绝大多数消息走这条快路径，不做任何扫描的浪费）。
///
/// Note: 为什么不能按 ``` 切分、`~~~` 从哪来 —— 见
/// `.agents/notes/implemented/2026-10-20-render-alignment-to-dsh-spec.md`。
String normalizeInlineHtml(String source) {
  if (!source.contains('<')) return source;
  final lines = source.split('\n');
  final out = <String>[];
  String? fence; // 开围栏的记号：'`' 或 '~'；null = 正文
  var fenceLength = 0;
  for (final line in lines) {
    final match = _fenceLine.firstMatch(line);
    if (fence == null) {
      if (match != null) {
        fence = match.group(1)![0];
        fenceLength = match.group(1)!.length;
        out.add(line);
      } else {
        out.add(_convertInlineTags(line));
      }
      continue;
    }
    out.add(line);
    // 关围栏：同记号、长度 ≥ 开围栏、记号后只有空白。
    final closing = match?.group(1);
    if (closing != null &&
        closing[0] == fence &&
        closing.length >= fenceLength &&
        match!.group(2)!.trim().isEmpty) {
      fence = null;
      fenceLength = 0;
    }
  }
  return out.join('\n');
}

/// 一行围栏的记号与剩余部分：`^ {0,3}(`{3,}|~{3,})(.*)$`。
///
/// 前导最多 3 个空格是 CommonMark 的规则（`codeFencePattern` 同款），
/// 4 个空格是缩进代码块，不是围栏。
final RegExp _fenceLine = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');

String _convertInlineTags(String text) {
  var out = text;
  // 先去标签→标记，再清掉剩余标签。
  out = out.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  out = out.replaceAll(RegExp(r'</?(b|strong)>', caseSensitive: false), '**');
  out = out.replaceAll(RegExp(r'</?(i|em)>', caseSensitive: false), '*');
  out = out.replaceAll(RegExp(r'</?code>', caseSensitive: false), '`');
  // 其余标签（含 `<p>` `<div>` `<span>` `<u>` `<a href=…>` 等）：去掉标签保文字。
  out = out.replaceAll(RegExp(r'</?[a-zA-Z][^>]*>'), '');
  return out;
}

/// 把一个 Markdown 串渲染成 DSH 风格。
///
/// Note: 为什么正文是 14/24、为什么 compact 是 13/20、为什么表格用
/// `IntrinsicColumnWidth` —— 见
/// `.agents/notes/implemented/2026-10-20-render-alignment-to-dsh-spec.md`。
class DshMarkdown extends StatelessWidget {
  const DshMarkdown(
    this.data, {
    super.key,
    this.baseColor,
    this.compact = false,
    this.fileMentions,
    this.onOpenFile,
  });

  /// Markdown 正文。
  final String data;

  /// `行内代码原文 → 文件路径`：**只认这里面的 token**。
  ///
  /// 表由 `model/file_mentions.dart` 的 `resolveFileMentions` +
  /// `fileMentionTargets` 产出（唯一命中、歧义惰性都在那一层）。
  /// 这一层**不判断**什么像路径 —— 判断写两处必然漂。
  final Map<String, String>? fileMentions;

  /// 点中一处提及。（`null` = 不可点：思考正文这类地方不该长出链接。）
  final void Function(String path)? onOpenFile;

  /// 基准文字色；`null` = 非 compact 用 `labelPrimary`、compact 用 `labelTertiary`。
  ///
  /// 用户气泡里正文在蓝底上，所以那个调用点会传 `onAccent` ——
  /// **不在这里按"谁在用"分支**：颜色是调用方的事，这一层只渲染。
  final Color? baseColor;

  /// **compact 档**：DSH 的 `MarkdownText variant="compact"`
  /// （`ui-primitives/src/markdown/MarkdownText.module.css:331-424` 的 `.compact`）。
  ///
  /// 唯一用处是**思考过程正文** —— DSH 的 `ReasoningContent` 就是
  /// `<MarkdownText variant="compact" />`（`ui-chat/src/client/chat/ReasoningContent.tsx:16`），
  /// 字号落一档到 secondary 13/20、色用 `label-tertiary`、段距收到 4。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    // 正文字号：DSH 的 markdown base = `--dsh-content-font-size`，
    // 默认 **14px / 24px**（`ui-theme/src/styles/gradient-shadow-text.css:93`，
    // 默认值见 `ui-theme/src/theme-settings.ts:58` 与
    // `ui-layout/tests/theme-presenter.client.spec.ts:86` 的 `14px`）。
    //
    // **2026-10-20 更正**：这里原来是 13/20，注释写"DSH 的正文只有 13"——
    // 那是把 **secondary 档**（13：流程行标题、工具标题、compact 正文）
    // 当成了正文。正文是 14，比原来大一档，与 DSH 一致。
    final color = baseColor ?? (compact ? c.labelTertiary : c.labelPrimary);
    // **字号从刻度来**（`theme/dsh_type.dart`）：正文 = 设置里的基准（默认 14）、
    // 行高 24+delta；compact（思考正文）= secondary 档（默认 13/20）。
    final type = context.dshType;
    final size = compact ? type.secondary : type.body;
    final line = compact ? type.secondaryLine : type.bodyLine;
    final body = TextStyle(fontSize: size, height: line / size, color: color);
    return MarkdownBody(
      // **行内 HTML 先归一成 Markdown**：否则 `<b>` 会原样露出
      //（探针实测，见 `normalizeInlineHtml` 的说明）。
      data: normalizeInlineHtml(data),
      selectable: true,
      // `softLineBreak`：Markdown 里的单个换行**也换行**。
      //
      // 这是刻意的偏离：CommonMark 规定单个换行当空格，而**聊天场景里
      // 用户按回车就是想要换行**。DSH 桌面端的表现也是换行。
      softLineBreak: true,
      // **代码块自己接管**：默认渲染只是一个横滚的 `<pre>`，而 DSH 的代码块
      // 有头部工具条（语言 / 自动换行 / 复制，`ui-primitives/src/CodeBlock.tsx`）。
      // 这跟"有没有语法高亮"是两件事 —— 工具条不需要高亮器。
      builders: {
        'pre': _DshCodeBlockBuilder(),
        // **两个都给才挂**：只有词表没有回调（或反过来）时不该长出点不动的链接
        // —— 那种入口比没有更糟（用户会以为功能坏了）。
        if (fileMentions != null && onOpenFile != null)
          'code': _FileMentionCodeBuilder(
            targets: fileMentions!,
            onOpen: onOpenFile!,
          ),
      },
      styleSheet: _sheet(context, c, body),
    );
  }

  /// 样式表：**非 compact** 照 DSH 的 `.markdown`，**compact** 照 `.compact`
  /// （`ui-primitives/src/markdown/MarkdownText.module.css`，行号逐条写在下面）。
  MarkdownStyleSheet _sheet(
    BuildContext context,
    DshColorTokens c,
    TextStyle body,
  ) {
    const mono = DshTheme.mono;
    final type = context.dshType;
    return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: body,
      // 段距：DSH `p { margin: 16px 0 }`（`:45-47`）在 flutter_markdown 里是
      // 「块间距 8 + 段底 8」两段相加 ⇒ 视觉 16，与 DSH 相同。
      // compact 档 DSH 收到 `margin: 4px 0`（`:345-347`）⇒ 块间距 0 + 段底 4。
      pPadding: EdgeInsets.only(bottom: compact ? 4 : 8),
      blockSpacing: compact ? 0 : 8,
      // 行内代码：等宽 + 底色。用 `roleToolBg`（token 表里的浅底）而不是自造。
      // 非 compact 是 `0.875em`（`:163-174`）⇒ 跟着**正文字号**缩放；
      // compact 是 `font-size: 1em`（`:384-392`）⇒ 跟随 secondary 档。
      code: mono.copyWith(
        fontSize: compact ? type.secondary : type.body * 0.875,
        color: body.color,
        backgroundColor: c.roleToolBg,
      ),
      // 代码块：整块底色 + 圆角。**内边距不在这里** —— 代码块由
      // `_DshCodeBlock` 接管（头部工具条 + 正文），padding 归它管。
      //
      // 规格取自 DSH `ui-primitives/.../CodeBlock.module.css` 的 `.block`：
      //   background: var(--dsw-alias-markdown-code-block);   ← 块底色
      //   border-radius: var(--dsw-radius-lg);                ← 不是 sm
      //   margin: 16px 0;                                     ← 上下各 16
      //   **没有 border**（原来我们多画了一圈 `layer3`，等于给块加了框）
      // `markdown-code-block` 这个 token 名就是为它起的（2026-10-20 加到
      // `DshColors.codeBlock`）。原来用 `c.bgBase` = 页面本色 —— 于是代码块
      // 看着像"没有底"，整块和正文糊在一起（真机截图确认过）。
      codeblockDecoration: const BoxDecoration(),
      codeblockPadding: EdgeInsets.zero,
      blockquote: compact ? body : body.copyWith(color: c.labelSecondary),
      blockquoteDecoration: BoxDecoration(
        border: Border(left: BorderSide(color: c.layer3, width: 3)),
      ),
      blockquotePadding: EdgeInsets.only(left: compact ? 8 : 12),
      // 列表：紧凑一点（聊天里不该像文档那样疏）。
      // 规格照 DSH `ui-primitives/src/markdown/MarkdownText.module.css:102-118`：
      //   `ul, ol { padding-left: 18px }`        → `listIndent: 18` ✓
      //   `li::marker { color: label-secondary }` → **marker 要比正文淡**
      // 原来 `listBullet: body` 用的是正文色，于是 `•` 比正文更抢眼
      // （真机上就是那种"`•` 太重"的感觉）。compact 档 DSH 让 marker
      // `color: inherit`（`:357-360`），所以那里不再淡化。
      listBullet: compact ? body : body.copyWith(color: c.labelSecondary),
      listIndent: 18,
      listBulletPadding: const EdgeInsets.only(right: 6),
      // 强调与链接。
      strong: body.copyWith(fontWeight: FontWeight.w600),
      em: body.copyWith(fontStyle: FontStyle.italic),
      a: compact
          // compact：链接跟随正文色、点线下划线（`:370-382`）。
          ? body.copyWith(decoration: TextDecoration.underline)
          : body.copyWith(
              color: c.accentBlue,
              decoration: TextDecoration.underline,
              decorationColor: c.accentBlue,
            ),
      // 标题：DSH 的字号表在 `gradient-shadow-text.css:65-110`
      // （h1 21/30·700、h2 19/28·700、h3 18/26·700、h4 14/24·600、h5/h6 = base-strong）。
      // 原来我们写 18/16/14 是估的，而注释里"正文只有 13"也是个错前提。
      //
      // 外边距：DSH 是 `32px 0 16px`（h1-h3）与 `16px 0`（h4-h6）
      // （`MarkdownText.module.css:16-39`）。`blockSpacing` 已经给了 8，
      // 所以这里补差值：h1-h3 上 24 / 下 8、h4-h6 上 8 / 下 8。
      // **有意偏离**：DSH 的 32px 标题上边距是文档级留白，手机聊天里
      // 会把一条回复拉得很散 —— 这里保留同样的"标题比正文大"的层级，
      // 但上下留白按聊天的密度收（见 `docs/subsystems/app-channel-client.md`）。
      h1: compact
          ? body.copyWith(fontWeight: FontWeight.w600)
          : body.copyWith(
              fontSize: type.h1,
              height: type.h1Line / type.h1,
              fontWeight: FontWeight.w700,
            ),
      h1Padding: _headingPadding(compact, level: 1),
      h2: compact
          ? body.copyWith(fontWeight: FontWeight.w600)
          : body.copyWith(
              fontSize: type.h2,
              height: type.h2Line / type.h2,
              fontWeight: FontWeight.w700,
            ),
      h2Padding: _headingPadding(compact, level: 2),
      h3: compact
          ? body.copyWith(fontWeight: FontWeight.w600)
          : body.copyWith(
              fontSize: type.h3,
              height: type.h3Line / type.h3,
              fontWeight: FontWeight.w700,
            ),
      h3Padding: _headingPadding(compact, level: 3),
      h4: body.copyWith(fontWeight: FontWeight.w600),
      h4Padding: _headingPadding(compact, level: 4),
      h5: body.copyWith(fontWeight: FontWeight.w600),
      h5Padding: _headingPadding(compact, level: 5),
      h6: body.copyWith(fontWeight: FontWeight.w600),
      h6Padding: _headingPadding(compact, level: 6),
      // 分隔线。
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.layer3)),
      ),
      // ---------------------------------------------------------------------
      // 表格（2026-10-20 第 6 条：宽表横向溢出）
      //
      // DSH 的表格**外面有一层横向滚动容器**：
      //   `.tableScroll { max-width: 100%; overflow-x: auto }`（`MarkdownText.module.css:192-196`）
      // 而多列表格保持自然宽度、在容器里横滚：
      //   `.tableScroll table { width: max-content }`（`:226-233`）
      // 少于四列的表格才铺满整列（`:235-242`）。
      //
      // flutter_markdown_plus 只在 `tableColumnWidth` 是 `IntrinsicColumnWidth`
      // 或 `FixedColumnWidth` 时**才**套那层横向滚动
      // （`flutter_markdown_plus-1.0.12/lib/src/builder.dart:447-463`），
      // 而默认是 `FlexColumnWidth`（`style_sheet.dart:143`）⇒ 我们的宽表
      // 只会在屏幕宽度里被压成一条条窄列，**没有横向出路**。
      // 换成 `IntrinsicColumnWidth` 就同时拿到"自然宽度 + 横滚"。
      //
      // 已知代价（有意偏离，已记在 `docs/subsystems/app-channel-client.md`）：
      // - 只有三列以内的表 DSH 会铺满，我们统一按自然宽度（不铺满）；
      // - DSH 的 `td { max-width: min(30vw, 320px); min-width: 100px }`
      //   （`:250-262`）在 `IntrinsicColumnWidth` 下没有等价物。
      tableColumnWidth: const IntrinsicColumnWidth(),
      tableHead: body.copyWith(fontWeight: FontWeight.w600),
      tableBody: body,
      // DSH `th { text-align: start }`（`:245`）；默认是居中。
      tableHeadAlign: TextAlign.start,
      // 单元格内边距：DSH `10px 16px`（`:244-262`）；compact 档 `4px 8px`
      // （`:421-424`）。**偏离**：DSH 把首列左内边距与末列右内边距归零，
      // flutter_markdown 的 `tableCellsPadding` 是统一值，做不到按列区分。
      tableCellsPadding: compact
          ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
          : const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      // 边框：DSH 只有**行分隔线**（th 下 l3、td 下 l2），没有竖线与外框
      // （`:244-262`）。原来我们画的是全网格 `TableBorder.all`。
      // **偏离**：th 与 td 的线色在同一个 `TableBorder` 里无法分开，
      // 这里统一用 l2。
      tableBorder: TableBorder(
        horizontalInside: BorderSide(color: c.borderL2, width: 0.5),
        bottom: BorderSide(color: c.borderL2, width: 0.5),
      ),
    );
  }

  /// 标题的上下留白：非 compact 补到 DSH 的 32/16（块间距已给 8），
  /// compact 用 DSH 的 `8px 0 4px`（块间距 0）。
  EdgeInsets _headingPadding(bool compact, {required int level}) {
    if (compact) return const EdgeInsets.only(top: 8, bottom: 4);
    return level <= 3
        ? const EdgeInsets.only(top: 24, bottom: 8)
        : const EdgeInsets.only(top: 8, bottom: 8);
  }
}

// ---------------------------------------------------------------------------
// 代码块：头部工具条 + 正文（照 DSH `ui-primitives` 的 CodeBlock / CodeToolbar）
// ---------------------------------------------------------------------------

/// 语言标签的兜底文案：**照 DSH**，`CodeToolbar.tsx:44` 是
/// `supportsHighlighting(lang) ? lang : codeLabel`，而 zh 里 `codeBlock.title` = `代码块`
/// （`packages/client/locale/src/locales/zh.ts:7`）。
const String _codeBlockLabel = '代码块';

/// 我们**真能高亮**的语言集合 —— 定义在 `dsh_code_highlight.dart` 一处
/// （`isHighlightedLanguage`，语言表只有一份），判断处不用改。
///
/// DSH 只高亮 ts / bash / json 三种（`markdown/highlight.ts:42`），手机侧接了
/// 28 种（`re_highlight` 按需注册）；对表外的语言（比如 ```` ```rust ```` 之外
/// 的 ```` ```toml ````）标签仍报 [codeBlockLabel]，与 DSH 同形。
// 认识的语法 id 在 `dsh_code_highlight.dart` 一处定义（语言表只有一份）。

/// `pre` → DSH 风格的代码块。
///
/// flutter_markdown 的 `builders` 里给 `pre` 注册的构建器**整体接管**这个块：
/// 拿到的是 `<pre><code class="language-xxx">…</code></pre>`，
/// 返回的 widget 会被它外面那层 `codeblockDecoration` 容器包住
/// （`lib/src/builder.dart` 的 `visitElementAfter`，`pre` 分支），
/// 所以这里只画"头部 + 正文"，边框圆角仍由样式表那一处负责。
class _DshCodeBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    // 语言来自 `code` 子元素的 `class="language-xxx"`（CommonMark 的 info string）。
    final code = element.children?.whereType<md.Element>().firstOrNull;
    final infoString = code?.attributes['class'];
    final language = infoString == null
        ? null
        // DSH 同样用 `/^[\w-]+/` 从 class 里取语法 id（`markdown/render.tsx:387`）。
        : RegExp(r'^language-([\w-]+)').firstMatch(infoString)?.group(1);
    // 尾部换行是围栏语法的一部分，不显示（DSH 也 trim，`CodeBlock.tsx:118`）。
    final text = (code?.textContent ?? element.textContent).trimRight();
    return _DshCodeBlock(code: text, language: language);
  }
}

/// 行内代码 → **文件提及**（可点）。
///
/// ## 为什么返回 `Text.rich` + `WidgetSpan`
///
/// `flutter_markdown_plus` 的段落最终是一个 `Wrap`（`builder.dart:778-796`），
/// 非文本 widget 会**单独占一个 Wrap 子项** —— 直接返回一个 `Container`
/// 会让它前后的文字各成一段（"改了 / [chip] / 里的两行"三行）。
/// 返回 `Text.rich` 时它会被并进段落的那一个 `RichText`（`builder.dart:801-820`
/// 的 `_getInlineSpanFromText`），`WidgetSpan` 于是落在文字中间。
///
/// Note: 为什么提及表由调用方给、这一层不解析 —— 见
/// `.agents/notes/implemented/2026-10-26-file-mentions-and-open-file.md`
///
/// ## 它不认识路径
///
/// 只查 `token → path` 表；表是 `model/file_mentions.dart` 的唯一产出。
/// 查不到**返回 `null`** —— 该 token 保持普通行内代码（认不出就保持惰性）。
class _FileMentionCodeBuilder extends MarkdownElementBuilder {
  _FileMentionCodeBuilder({required this.targets, required this.onOpen});

  final Map<String, String> targets;
  final void Function(String path) onOpen;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final raw = element.textContent;
    // Markdown 解析器多半已经归一过，但也可能没有 —— 两次归一用同一条规则
    // （`normalizeCodeSpan`），否则表查不中而链接静默消失。
    final path = targets[raw] ?? targets[normalizeCodeSpan(raw)];
    if (path == null) return null;
    final c = context.dshColors;
    final token = normalizeCodeSpan(raw);
    return Text.rich(
      TextSpan(
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Tooltip(
              message: '打开 $path',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onOpen(path),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: c.roleToolBg,
                    borderRadius: BorderRadius.circular(DshRadius.sm),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 一枚链形图标：与 DSH 的 `fileMention` 按钮同义
                      // （`ui-primitives/src/markdown/render.tsx:349-363`）。
                      DshIcon('link', size: 11, color: c.accentBlue),
                      const SizedBox(width: 3),
                      Text(token, style: preferredStyle ?? DshTheme.mono),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一个 DSH 风格代码块：头部 `[语言] … [自动换行][复制]` + 正文。
///
/// 与 DSH 逐条对齐：
/// - **默认自动换行**（`CodeBlock.tsx:157` 的 `useState(true)`），按钮在
///   `nowrapFill` / `wrapFill` 之间切（`CodeToolbar.tsx:51`）；
/// - 复制成功后在 1 秒内切成对勾（`:168` 的 `setTimeout(…, 1000)`）；
/// - 文案逐字照 zh 词典：`复制` / `复制成功` / `自动换行` / `取消自动换行`
///   （`packages/client/locale/src/locales/zh.ts:6,8-9`）；
/// - 图标全部走 [DshIcon]（`copy` / `check` / `nowrapFill` / `wrapFill`）。
///
/// **不做**：行号（DSH 默认也关，`CodeBlock.tsx:72`）与折叠（DSH 的正文代码块没有折叠，
/// 折叠只出现在 diff / 读文件卡里）。
class _DshCodeBlock extends StatefulWidget {
  const _DshCodeBlock({required this.code, this.language});

  final String code;
  final String? language;

  @override
  State<_DshCodeBlock> createState() => _DshCodeBlockState();
}

class _DshCodeBlockState extends State<_DshCodeBlock> {
  bool _wrapped = true;
  bool _copied = false;
  Timer? _copiedReset;

  @override
  void dispose() {
    _copiedReset?.cancel();
    super.dispose();
  }

  /// 头部左侧那句话：支持高亮就报语言，否则报"代码块"（见 [_codeBlockLabel]）。
  String get _languageLabel => isHighlightedLanguage(widget.language)
      ? widget.language!
      : _codeBlockLabel;

  /// 复制正文。**成功后才切成"复制成功"** —— DSH 同款（`CodeBlock.tsx:165-169`）。
  Future<void> _copy() async {
    if (_copied) return;
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    _copiedReset?.cancel();
    _copiedReset = Timer(const Duration(seconds: 1), () {
      if (!mounted) return;
      setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    // **换行与否由布局决定，不是 `softWrap`**：`SelectableText` 没有这个参数。
    // 自动换行时它拿到的是有界宽度（照常折行）；关掉换行时它被放进横向滚动区，
    // 宽度约束是无界的 —— 于是整块按内在宽度排成一行，横向滚动看。
    final codeStyle = DshTheme.mono.copyWith(
      // DSH 的代码正文是 `--dsw-font-markdown-code-block` = **11/19**
      // （`ui-theme/src/styles/gradient-shadow-text.css:170`）。
      // **有意偏离**：手机上一行代码 11px 太小，这里用 12/18
      // （比 DSH 大一档、行高略紧），与正文 14/24 的比例仍接近 DSH。
      fontSize: 12,
      height: 1.5,
      color: c.labelPrimary,
    );
    // **高亮只覆颜色**，字号/行高/字体仍用上面这一份 —— 认不出语言时退回纯文本，
    // 两种形态的排版逐像素一致（`dsh_code_highlight.dart`）。
    final highlighted = highlightCode(
      widget.code,
      widget.language,
      base: codeStyle,
      dark: Theme.of(context).brightness == Brightness.dark,
    );
    final body = highlighted == null
        ? SelectableText(widget.code, style: codeStyle)
        : SelectableText.rich(highlighted);
    // **整块的容器与 16px 外边距都在这里**（2026-10-20）。
    //
    // 为什么不靠 `styleSheet.codeblockDecoration`：
    // - `BoxDecoration` **没有 margin**，DSH 的 `.block { margin: 16px 0 }`
    //   在 Flutter 侧只能靠外面包 `Padding` —— 而 decoration 是
    //   flutter_markdown 包在**我们返回的 widget 外面**的，它包不到这个
    //   Padding 之外，所以外边距只能由我们自己出。
    // - 于是 `codeblockDecoration` 退化成**空装饰**（见 styleSheet 处），
    //   底色 / 圆角 / 裁切全由这一层画，语义才与 DSH 的 `.block` 一一对应。
    return Padding(
      // DSH `.block { margin: 16px 0 }`（`CodeBlock.module.css:15`）。
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(DshRadius.lg),
        child: Container(
          color: c.codeBlock,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // banner 自己的底色：`--dsw-alias-markdown-code-block-banner`
              // （`CodeBlock.module.css:5,38`）。**亮色下它与块底同色**
              // （都是 neutral-bluish-50），只有暗色分得开 —— 这是 DSH 的既定
              // 行为，不是我们没配好。
              Container(color: c.codeBlockBanner, child: _banner(c)),
              _body(c, body),
            ],
          ),
        ),
      ),
    );
  }

  Widget _banner(DshColorTokens c) => Padding(
    // DSH `.banner { padding: 9px 14px }`（`CodeBlock.module.css:40-46`）。
    padding: const EdgeInsets.fromLTRB(14, 9, 10, 9),
    child: Row(
      children: [
        Expanded(
          child: Text(
            _languageLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: c.labelCaption),
          ),
        ),
        _CodeToolButton(
          icon: _wrapped ? 'nowrapFill' : 'wrapFill',
          tooltip: _wrapped ? '取消自动换行' : '自动换行',
          onPressed: () => setState(() => _wrapped = !_wrapped),
        ),
        _CodeToolButton(
          icon: _copied ? 'check' : 'copy',
          tooltip: _copied ? '复制成功' : '复制',
          onPressed: () => unawaited(_copy()),
        ),
      ],
    ),
  );

  /// 正文区。DSH `.content { padding: 0 14px 10px }` 一类的内边距由我们给。
  Widget _body(DshColorTokens c, Widget body) => Padding(
    padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
    // 关掉自动换行时给一条横向出路（DSH 是 `data-code-wrap=false` + 横滚）。
    child: _wrapped
        ? body
        : SingleChildScrollView(scrollDirection: Axis.horizontal, child: body),
  );
}

/// 代码块头部的一个图标按钮（28×28，够手指点）。
class _CodeToolButton extends StatelessWidget {
  const _CodeToolButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final String icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 28,
        height: 28,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: Center(
              child: DshIcon(icon, size: 14, color: c.labelSecondary),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 仍未做（如实记录，见 `app-channel-client.md` §7 与 §4 的性能对策）
//
// 1. **分块渲染**（§4 的"长 Markdown 按段落切"）：现在整段交给 `MarkdownBody`，
//    而它在长文上要一次排版完 —— 那正是 §4 想避免的（`dart:ui` 排版只能在主 isolate）。
//    查过 DSH 的做法供参考：它**没有**正文虚拟化/段落切分，只在流式期间
//    冻结除末尾两块以外的所有块（`ui-primitives/src/markdown/incremental.ts:9-14,38`
//    的 `UNSTABLE_TAIL_BLOCKS = 2`）。所以手机侧的对策应是"流式期间只重排末尾"，
//    不是引入虚拟列表。
//
// 2. **数学公式**：DSH 支持 `$…$` 行内与 ```` ```math ```` 围栏（KaTeX，
//    `MarkdownText.tsx:36` 的 `parseGfmWithMath`、`render.tsx:388`），手机侧没有。
//    这是独立一块（要么纯 Dart 的数学排版，要么放弃），不在"把 Markdown 渲染出来"里。
//
// 3. **代码高亮已接**（2026-10-28，`dsh_code_highlight.dart`）：纯 Dart 的
//    `re_highlight`，28 种语言按需注册；未知语言退纯文本（与 DSH 的
//    `useViewportHighlighting.ts:17` 同一条）。仍与 DSH 差的两处：
//    ① DSH **只在代码块首次进入视口时高亮一次并缓存**（`highlight.ts:286` 的单行
//    1000 字符上限也在那条路上），手机侧是构建时算 —— 长会话里重复构建会重复算；
//    ② DSH 的 shiki 语言集与我们不同（ts/bash/json 对 28 种），于是"报语言名还是
//    报「代码块」"的判定在边缘语言上会不同。
// ---------------------------------------------------------------------------
