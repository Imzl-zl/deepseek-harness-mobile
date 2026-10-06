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

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../theme/dsh_colors.dart';
import '../theme/dsh_theme.dart';

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
    final color = baseColor ?? DshColors.labelPrimary;
    final body = TextStyle(fontSize: 13, height: 20 / 13, color: color);
    return MarkdownBody(
      data: data,
      selectable: true,
      // `softLineBreak`：Markdown 里的单个换行**也换行**。
      //
      // 这是刻意的偏离：CommonMark 规定单个换行当空格，而**聊天场景里
      // 用户按回车就是想要换行**。DSH 桌面端的表现也是换行。
      softLineBreak: true,
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: body,
        // 段落间距：默认偏大，聊天里会显得散。
        pPadding: const EdgeInsets.only(bottom: 8),
        // 行内代码：等宽 + 底色。用 `roleToolBg`（token 表里的浅底）而不是自造。
        code: DshTheme.mono.copyWith(
          fontSize: 12,
          color: color,
          backgroundColor: DshColors.roleToolBg,
        ),
        // 代码块：整块底色 + 圆角 + 内边距。
        codeblockDecoration: BoxDecoration(
          color: DshColors.bgBase,
          borderRadius: BorderRadius.circular(DshRadius.sm),
          border: Border.all(color: DshColors.layer3),
        ),
        codeblockPadding: const EdgeInsets.all(10),
        blockquote: body.copyWith(color: DshColors.labelSecondary),
        blockquoteDecoration: const BoxDecoration(
          border: Border(left: BorderSide(color: DshColors.layer3, width: 3)),
        ),
        blockquotePadding: const EdgeInsets.only(left: 12),
        // 列表：紧凑一点（聊天里不该像文档那样疏）。
        listBullet: body,
        listIndent: 18,
        listBulletPadding: const EdgeInsets.only(right: 6),
        // 强调与链接。
        strong: body.copyWith(fontWeight: FontWeight.w600),
        em: body.copyWith(fontStyle: FontStyle.italic),
        a: body.copyWith(
          color: DshColors.accentBlue,
          decoration: TextDecoration.underline,
          decorationColor: DshColors.accentBlue,
        ),
        // 标题：DSH 的正文只有 13，标题不该大到喧宾夺主。
        h1: body.copyWith(fontSize: 18, fontWeight: FontWeight.w600),
        h2: body.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
        h3: body.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
        h4: body.copyWith(fontWeight: FontWeight.w600),
        h5: body.copyWith(fontWeight: FontWeight.w600),
        h6: body.copyWith(
          fontWeight: FontWeight.w600,
          color: DshColors.labelSecondary,
        ),
        // 分隔线。
        horizontalRuleDecoration: const BoxDecoration(
          border: Border(top: BorderSide(color: DshColors.layer3)),
        ),
        // 表格：窄屏会横向溢出，所以给边框与紧凑内边距。
        tableHead: body.copyWith(fontWeight: FontWeight.w600),
        tableBody: body,
        tableBorder: TableBorder.all(color: DshColors.layer3, width: 1),
        tableCellsPadding: const EdgeInsets.symmetric(
          horizontal: 6,
          vertical: 4,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 仍未做（如实记录，见 `app-channel-client.md` §7 与 §4 的性能对策）
//
// 1. **代码语法高亮**：§7 的候选是 `highlight`（纯 Dart）或 shiki 的 Dart 移植，
//    要求"只在条目首次可见时高亮一次并缓存 token 结果，不随流式每帧重算"。
//    这需要给 `MarkdownBody` 传 `syntaxHighlighter`，而高亮器本身要有缓存 ——
//    工作量独立，不该塞进"把 Markdown 渲染出来"这件事里。
//
// 2. **分块渲染**（§4 的"长 Markdown 按段落切"）：现在整段交给 `MarkdownBody`，
//    而它在长文上要一次排版完 —— 那正是 §4 想避免的（`dart:ui` 排版只能在主 isolate）。
//    配对真连上、有真实长回复之后再按实测数据决定切法。
//
// 3. **代码块的操作**（复制/折叠/横滑）：DSH 有，这里还没有。
// ---------------------------------------------------------------------------
