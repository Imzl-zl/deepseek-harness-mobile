/// DSH 风格的 Markdown 渲染（消息正文用它，而不是纯 `Text`）。
///
/// ## 为什么必须有它
///
/// 第一版把消息正文直接塞进 `SelectableText` —— 于是助手回复里的
/// ```` ```dart ```` 原样显示成三个反引号、`**加粗**` 也原样。
/// 而 DSH 桌面端是**渲染**的：同一段回复在两端长得完全不一样。
///
/// 这个问题是靠"看示例数据"暴露的（`data/preview_data.dart`）——
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

import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';

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
/// **代码块（```…```）里一个字都不动** —— 那里是用户在看的源码，
/// 把它 `<b>` 改成 `**` 就是改内容。围栏按"成对出现"切分，奇数段落是正文。
///
/// 没有 `<` 的串**原样返回**（绝大多数消息走这条快路径，不做任何正则扫描的浪费）。
String normalizeInlineHtml(String source) {
  if (!source.contains('<')) return source;
  final parts = source.split('```');
  for (var i = 0; i < parts.length; i += 2) {
    // 偶数段 = 围栏之外（正文）；奇数段 = 代码块内部，跳过。
    if (i < parts.length) parts[i] = _convertInlineTags(parts[i]);
  }
  return parts.join('```');
}

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
class DshMarkdown extends StatelessWidget {
  const DshMarkdown(this.data, {super.key, this.baseColor});

  /// Markdown 正文。
  final String data;

  /// 基准文字色；`null` = `labelPrimary`。
  ///
  /// 用户气泡里正文在蓝底上，所以那个调用点会传 `onAccent` ——
  /// **不在这里按"谁在用"分支**：颜色是调用方的事，这一层只渲染。
  final Color? baseColor;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final color = baseColor ?? c.labelPrimary;
    final body = TextStyle(fontSize: 13, height: 20 / 13, color: color);
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
      builders: {'pre': _DshCodeBlockBuilder()},
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: body,
        // 段落间距：默认偏大，聊天里会显得散。
        pPadding: const EdgeInsets.only(bottom: 8),
        // 行内代码：等宽 + 底色。用 `roleToolBg`（token 表里的浅底）而不是自造。
        code: DshTheme.mono.copyWith(
          fontSize: 12,
          color: color,
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
        blockquote: body.copyWith(color: c.labelSecondary),
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(color: c.layer3, width: 3)),
        ),
        blockquotePadding: const EdgeInsets.only(left: 12),
        // 列表：紧凑一点（聊天里不该像文档那样疏）。
        // 规格照 DSH `ui-primitives/src/markdown/MarkdownText.module.css:102-118`：
        //   `ul, ol { padding-left: 18px }`        → `listIndent: 18` ✓
        //   `li::marker { color: label-secondary }` → **marker 要比正文淡**
        // 原来 `listBullet: body` 用的是正文色，于是 `•` 比正文更抢眼
        // （真机上就是那种"`•` 太重"的感觉）。
        listBullet: body.copyWith(color: c.labelSecondary),
        listIndent: 18,
        listBulletPadding: const EdgeInsets.only(right: 6),
        // 强调与链接。
        strong: body.copyWith(fontWeight: FontWeight.w600),
        em: body.copyWith(fontStyle: FontStyle.italic),
        a: body.copyWith(
          color: c.accentBlue,
          decoration: TextDecoration.underline,
          decorationColor: c.accentBlue,
        ),
        // 标题：DSH 的正文只有 13，标题不该大到喧宾夺主。
        h1: body.copyWith(fontSize: 18, fontWeight: FontWeight.w600),
        h2: body.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
        h3: body.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
        h4: body.copyWith(fontWeight: FontWeight.w600),
        h5: body.copyWith(fontWeight: FontWeight.w600),
        h6: body.copyWith(fontWeight: FontWeight.w600, color: c.labelSecondary),
        // 分隔线。
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: c.layer3)),
        ),
        // 表格：窄屏会横向溢出，所以给边框与紧凑内边距。
        tableHead: body.copyWith(fontWeight: FontWeight.w600),
        tableBody: body,
        tableBorder: TableBorder.all(color: c.layer3, width: 1),
        tableCellsPadding: const EdgeInsets.symmetric(
          horizontal: 6,
          vertical: 4,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 代码块：头部工具条 + 正文（照 DSH `ui-primitives` 的 CodeBlock / CodeToolbar）
// ---------------------------------------------------------------------------

/// 语言标签的兜底文案：**照 DSH**，`CodeToolbar.tsx:44` 是
/// `supportsHighlighting(lang) ? lang : codeLabel`，而 zh 里 `codeBlock.title` = `代码块`
/// （`packages/client/locale/src/locales/zh.ts:7`）。
const String _codeBlockLabel = '代码块';

/// 我们**真能高亮**的语言集合。
///
/// 现在是空的（高亮还没接，见文件末"仍未做"）—— 于是标签恒为 [codeBlockLabel]，
/// 与 DSH 对一个"它不高亮的语言"（比如 ```` ```rust ````）的表现**完全同形**。
/// 接上高亮后只填这张表，判断处不用改（DSH 支持的是 ts / bash / json 三种，
/// `markdown/highlight.ts:42`）。
const Set<String> _highlightedLanguages = <String>{};

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
  String get _languageLabel {
    final language = widget.language;
    if (language != null && _highlightedLanguages.contains(language)) {
      return language;
    }
    return _codeBlockLabel;
  }

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
    final body = SelectableText(
      widget.code,
      style: DshTheme.mono.copyWith(
        fontSize: 12,
        height: 1.5,
        color: c.labelPrimary,
      ),
    );
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
// 1. **代码语法高亮**：DSH 用 shiki（JS 引擎）高亮 **ts / bash / json** 三种
//    （`markdown/highlight.ts:42`），**只在代码块首次进入视口时高亮一次并缓存**
//    （`useViewportHighlighting.ts:17,48`），未知语言退纯文本（`:17`），
//    单行超长（>1000 字符）不 tokenize（`highlight.ts:286`）。手机侧候选仍是
//    `highlight`（纯 Dart）；接的时候照这三条做，别每次重建就重算。
//    接上后把语言填进 `_highlightedLanguages`，标签与高亮就一起生效。
//
// 2. **分块渲染**（§4 的"长 Markdown 按段落切"）：现在整段交给 `MarkdownBody`，
//    而它在长文上要一次排版完 —— 那正是 §4 想避免的（`dart:ui` 排版只能在主 isolate）。
//    查过 DSH 的做法供参考：它**没有**正文虚拟化/段落切分，只在流式期间
//    冻结除末尾两块以外的所有块（`ui-chat/conversation-nodes/incremental.ts:9,38`
//    的 `UNSTABLE_TAIL_BLOCKS = 2`）。所以手机侧的对策应是"流式期间只重排末尾"，
//    不是引入虚拟列表。
//
// 3. **数学公式**：DSH 支持 `$…$` 行内与 ```` ```math ```` 围栏（KaTeX，
//    `MarkdownText.tsx:36` 的 `parseGfmWithMath`、`render.tsx:388`），手机侧没有。
//    这是独立一块（要么纯 Dart 的数学排版，要么放弃），不在"把 Markdown 渲染出来"里。
// ---------------------------------------------------------------------------
