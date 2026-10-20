/// 对话流里的条目（照 `mock/proto` 的结构，数值取自 `styles.css`）。
///
/// ## 三个组件各自的结构（我的第一版全做错了）
///
/// | | 原型 | 我第一版做错的 |
/// |---|---|---|
/// | 用户消息 | `.turn--u .b`：**右对齐气泡**、`max-width:82%`、`padding:11×15`、`border-radius:22/22/6/22`、`font-size:14.5` | 气泡对了，但圆角/字号是估的 |
/// | 助手消息 | `.a-head`（26×26 渐变头像 + 「助手」+ `· 模型名`）**在正文之上**，正文是 Markdown | ❌ 只有气泡，**没有头像与模型名** |
/// | 工具调用 | `.tool` **卡片**：`min-height:52`、`border-radius:16`、图标块 24×24 圆角 8、名字等宽字体橙色、参数可省略、右侧状态/chevron；**可展开**（`.tool-body`） | ❌ 一行小字 |
///
/// 差别不是"好不好看"，而是**信息密度与层级完全不同**：
/// 原型一眼能看出"这是谁说的、用的哪个模型、这个工具在干什么"，
/// 我的版本把三者都压成了一行。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/projection.dart';
import '../model/chat_item.dart';
import '../model/session_stats.dart'
    show formatCacheHitPercent, formatTokenCount;
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';
import 'dsh_markdown.dart';
import 'dsh_sheet.dart';

/// 用户消息（`.turn--u`）。
class UserTurn extends StatelessWidget {
  const UserTurn(
    this.text, {
    super.key,
    this.attachmentCount = 0,
    this.steering = false,
  });

  final String text;

  /// 附件个数（图片 + 文件）。**只计数不渲染**（读附件要 `session/attachment`，
  /// 本期未接）—— 但"带了 2 张图"这个事实必须说出来。
  final int attachmentCount;

  /// 这是一条插话（轮次跑到一半插进去的）。
  final bool steering;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Padding(
      // `.turn { margin: 18px 0 }`
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Flexible(
            child: Container(
              // `.turn--u .b { max-width:82%; padding:11px 15px;
              //   border-radius:22px 22px 6px 22px; font-size:14.5px }`
              // 右下角 6px 是"贴着发送者"的那一角 —— 这是聊天气泡的惯例，
              // 四角同圆会看不出是谁说的。
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.82,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
              decoration: BoxDecoration(
                // **`bubble` 而不是 `layer3`**（2026-10-19 真机反馈
                // "用户消息我刚开始一直以为渲染问题，后来才发现这个是用户消息"）：
                // 浅色主题里 `layer1/2/3` 三条**全是纯白**（靠描边分层，
                // 见 `dsh_colors.dart` 的 `DshLightColors`），气泡用 `layer3`
                // 会与页面背景同色、完全看不见。DSH 因此有**专用**的
                // `--dsw-specific-bubble`（`design-platform.css:268` 亮 =
                // deepseek-50 `#EDF3FE`、`:386` 暗 = neutral-bluish-850
                // `#2C2C2E`），我们照抄成 `bubble` token。
                //
                // 插话用工具色底：它是"轮次跑到一半的输入"，与开轮输入
                // 视觉上分开（DSH Web 同样把 steering 与 user 分成两类节点）。
                color: steering ? c.roleToolBg : c.bubble,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(22),
                  topRight: Radius.circular(22),
                  bottomLeft: Radius.circular(22),
                  bottomRight: Radius.circular(6),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (steering)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DshIcon('queue', size: 11, color: c.roleTool),
                          const SizedBox(width: 4),
                          Text(
                            '插话',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: c.roleTool,
                            ),
                          ),
                        ],
                      ),
                    ),
                  // **纯 `Text`，不跑 Markdown** —— 2026-10-20 查过 DSH：
                  // 用户消息的正文走 `conversation.user.text` Factory，最终落到
                  // `UserTextRun`（`ui-primitives/src/user-text.tsx:18-20`，
                  // "Render an uninterpreted inline text run … without Markdown
                  // or reference recognition"），外层气泡只负责
                  // `white-space: pre-wrap`（`MessageItem.module.css` 的 `.bubble`）。
                  // 所以这里与 DSH **一致，不是缺口**：用户打的是纯文本。
                  // 我们比 DSH 少的只是引用 chip（`@文件`/`/skill`），那是
                  // 另一条线（见 `.agents/notes/proposed/2026-10-20-rendering-issues-todo.md`）。
                  Text(
                    text,
                    style: TextStyle(
                      fontSize: 14.5,
                      height: 21 / 14.5,
                      color: c.labelPrimary,
                    ),
                  ),
                  if (attachmentCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '$attachmentCount 个附件（手机上不显示）',
                        style: TextStyle(fontSize: 11, color: c.labelTertiary),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 助手消息（`.turn.a` + `.a-head` + `.md`）。
class AssistantTurn extends StatelessWidget {
  const AssistantTurn({
    super.key,
    required this.text,
    this.modelName,
    this.reasoning = '',
  });

  final String text;

  /// 模型名（显示成 `· claude-opus`）；`null` = 不显示。
  ///
  /// **原型有它**，而它是重要信息：同一会话里可能换过模型，
  /// 而"这段是哪個模型答的"事后无法从内容判断。
  final String? modelName;

  /// 思考过程（`{type:'reasoning'}` 块；空 = 不显示）。
  final String reasoning;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AssistantHead(modelName: modelName),
          // **思考过程**：折叠在正文上方。默认收起 —— 它经常比正文还长，
          // 全展开会把对话冲掉（DSH 桌面端同样把它归入"过程"分组）。
          if (reasoning.isNotEmpty) _ReasoningBlock(text: reasoning),
          // `.md`：Markdown 正文（代码块、列表、加粗都渲染）。
          DshMarkdown(text),
        ],
      ),
    );
  }
}

/// 助手消息的头部：26×26 品牌渐变头像 + 「助手」+ 可选 `· 模型名`。
///
/// 抽出来是因为**流式尾条目与持久条目必须是同一个头**：原来
/// `_LiveTurn` 自己抄了一份（还写死了颜色），于是流结束、条目从
/// "虚拟尾"换成持久消息的那一帧，头像行的构造与上下留白都换了一套
/// —— 那就是流式结束时的"跳一下"。
class AssistantHead extends StatelessWidget {
  const AssistantHead({super.key, this.modelName});

  /// 模型名（显示成 `· claude-opus`）；`null` = 不显示。
  final String? modelName;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final modelName = this.modelName;
    // `.a-head { display:flex; align-items:center; gap:8px; margin-bottom:8px }`
    // —— 那个 8 在 Flutter 里只能自己出（Row 没有 margin）。
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const _AssistantAvatar(),
          const SizedBox(width: 8),
          Text(
            '助手',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: c.labelPrimary,
            ),
          ),
          if (modelName != null && modelName.isNotEmpty) ...[
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                '· $modelName',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: c.labelCaption),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 思考过程块（可折叠）。
///
/// 与系统提示词**共用同一个折叠行**（DSH 也是共用 `DisclosureRow`），
/// 但正文形态不同：DSH 的思考正文是 `MarkdownText variant="compact"`
/// （`ui-chat/src/client/chat/ReasoningContent.tsx:16`），系统提示词是
/// 代码字体的 141px 滚动区（`ContextInjectionRow.module.css:50-64`）。
class _ReasoningBlock extends StatelessWidget {
  const _ReasoningBlock({required this.text});

  final String text;

  /// 收起时显示的第一行（DSH `ReasoningRow.tsx:56` 的 `firstLine`）。
  static String _firstLine(String text) {
    final newline = text.indexOf('\n');
    return newline == -1 ? text : text.substring(0, newline);
  }

  @override
  Widget build(BuildContext context) {
    return _CollapsibleNote(
      icon: 'sparkle',
      label: '思考过程',
      text: text,
      markdownBody: true,
      collapsedPreview: _firstLine(text).replaceAll('**', ''),
    );
  }
}

/// 助手头像：26×26、圆角 9、**品牌渐变**（`.a-ava`）。
class _AssistantAvatar extends StatelessWidget {
  const _AssistantAvatar();

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        // `linear-gradient(135deg, #5686fe, #9e7baa)` —— 蓝到紫，
        // 与 `roleAssistant`（紫）同族。这是 DSH 的品牌识别之一，
        // 所以两个色值取自 token 而不是现编。
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [c.accentBlue, c.roleAssistant],
        ),
        borderRadius: BorderRadius.circular(9),
      ),
      child: const Center(
        child: DshIcon('sparkle', size: 14, color: Colors.white),
      ),
    );
  }
}

/// 工具调用卡片（`.tool`）。
///
/// ## 它能展开
///
/// 原型里 `.tool-r` 是按钮、`.tool-body` 是明细（默认隐藏，
/// `.tool.is-open` 时显示）。**默认折叠**是刻意的：一次长会话里工具调用很多，
/// 全展开会把对话流冲掉；而明细又必须能看（那是"它到底干了什么"）。
class ToolCard extends StatefulWidget {
  const ToolCard({
    super.key,
    required this.name,
    required this.status,
    this.argument = '',
    this.detail = '',
    this.diffStat,
    this.initiallyOpen = false,
  });

  /// 工具名（`bash` / `edit` / …）—— 等宽字体、工具色。
  final String name;

  final ToolCallStatus status;

  /// 参数摘要（`rm -rf build/ && flutter clean`）—— 可省略号截断。
  final String argument;

  /// 展开后的明细（`.tool-body`）。
  final String detail;

  /// 变更统计（`+128 −46`）；`null` = 不显示。
  final ({int added, int removed})? diffStat;

  /// 初始就是展开的（"工作步骤展示"偏好的**完全展开**档）。
  final bool initiallyOpen;

  @override
  State<ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<ToolCard> {
  bool _open = false;

  @override
  void initState() {
    super.initState();
    _open = widget.initiallyOpen;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final (icon, tone) = switch (widget.status) {
      ToolCallStatus.running => ('loading', c.roleTool),
      ToolCallStatus.completed => ('check', c.roleContext),
      ToolCallStatus.failed => ('warningTriangle', c.error),
    };
    final hasDetail = widget.detail.isNotEmpty;
    return Container(
      // `.tool { margin:12px 0; border:1px solid l1; border-radius:16 }`
      margin: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(DshRadius.lg),
        border: Border.all(color: c.layer1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Material(
            // `.tool-r { background: var(--tool-bg) }` —— 暖色底，
            // 与助手正文的冷色底区分开（一眼看出"这不是模型说的话"）。
            color: c.roleToolBg,
            child: InkWell(
              onTap: hasDetail ? () => setState(() => _open = !_open) : null,
              child: Container(
                // `.tool-r { min-height:52; padding:13px 14px; gap:10 }`
                constraints: const BoxConstraints(minHeight: 52),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 13,
                ),
                child: Row(
                  children: [
                    // `.tool-ic { 24×24; border-radius:8; 底色 rgba(tool,.16) }`
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: c.roleTool.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: DshIcon(icon, size: 13, color: tone),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      widget.name,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: c.roleTool,
                      ),
                    ),
                    const SizedBox(width: 6),
                    // `.tool-arg { flex:1; min-width:0; 等宽; 可省略 }`
                    Expanded(
                      child: Text(
                        widget.argument,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12.5,
                          color: c.labelTertiary,
                        ),
                      ),
                    ),
                    if (widget.diffStat != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        '+${widget.diffStat!.added}',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: c.fileDiffAddMarker,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '−${widget.diffStat!.removed}',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: c.fileDiffDelMarker,
                        ),
                      ),
                    ],
                    if (hasDetail) ...[
                      const SizedBox(width: 8),
                      // `.tool-cv` 展开时旋转 90°（`is-open` 那条规则）。
                      AnimatedRotation(
                        turns: _open ? 0.25 : 0,
                        duration: const Duration(milliseconds: 160),
                        child: DshIcon(
                          'chevronRight',
                          size: 16,
                          color: c.labelTertiary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (hasDetail && _open)
            Container(
              // 展开后的正文是一块**独立容器**（不是标题行那层暖色底的延续）。
              //
              // 出处：**`ui-tool/src/client/tool/components/ToolRow.module.css`
              // 的 `.ioCard` / `.ioSection` / `.ioText`（:181-247）** ——
              // 工具结果正文在 DSH 里是「输入/输出卡」，不是 `ToolDetails`
              // （后者是 todo/goal/schedule 那种**结构化字段**的卡，
              // `ToolDetails.module.css:1-9`）。我们的 `detail` 是
              // `projection.dart:691` 摊平的**结果原文**，正对 `ioCard` 的
              // 「输出」那一节。
              //
              //   .ioCard    { margin:4px 0 4px 4px; border:0.5px solid border-l1;
              //                border-radius: radius-lg;
              //                background: markdown-code-block;
              //                font: --dsw-font-markdown-code-block-small }  ← 11/16 等宽
              //   .ioSection { padding:12px 16px; max-height:150px; overflow-y:auto }
              //   .ioText    { white-space:pre-wrap; word-break:break-word;
              //                color: label-secondary }
              //
              // **2026-10-20 更正**：这里原来引的是 `ToolDetails.module.css` 的
              // `.root`（13/20 比例字体、无高度上限）—— 那是结构化字段卡，
              // 拿它套结果原文就成了"每一处看着都有出处、合起来却是另一样东西"。
              //
              // **偏离**：DSH 在正文左侧还有一列 `输出` gutter 标签
              // （`.ioLabel`，:222-227；grid 列间距 14）。手机上那一列要吃掉
              // 14+ 的横向空间，而卡片标题行已经说明了这是哪个工具的输出，
              // 所以这一版不带 gutter 标签。
              //
              // Note: 为什么不是 `ToolDetails.module.css` 的 `.root` —— 见
              // `.agents/notes/implemented/2026-10-20-render-alignment-to-dsh-spec.md`。
              margin: const EdgeInsets.fromLTRB(4, 4, 0, 4),
              width: double.infinity,
              decoration: BoxDecoration(
                color: c.codeBlock,
                borderRadius: BorderRadius.circular(DshRadius.lg),
                border: Border.all(color: c.borderL1, width: 0.5),
              ),
              // **高度上限 150 + 自己滚动**：`.ioSection` 的
              // `max-height:150px; overflow-y:auto`。没有它，一条 4000 字的
              // 命令输出会把整段对话顶到屏幕外（`toolOutputOf` 的截断上限
              // 是 4000 字符，仍是一屏多）。
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 150),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: SelectableText(
                    widget.detail,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      // `.ioCard` 的 `--dsw-font-markdown-code-block-small`
                      // = **11px/16px 等宽**（`gradient-shadow-text.css:178`）。
                      fontSize: 11,
                      height: 16 / 11,
                      color: c.labelSecondary,
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

/// 斜杠命令卡（DSH 的 `GenericCommandCard`）。
///
/// ## 它为什么之前不存在
///
/// 2026-10-19 摸到的"没有输出"之一：`command/run` / `command/done` 在投影里
/// 没有 case，落到 `OtherItem`（只计数、不渲染）。于是 `/goal`、`/compact`、
/// `/permission` 这些在 Web 上有"命令名 + 结果文本"卡片的东西，在手机上
/// **一条都没有** —— 而连接器的用法说明、权限切换、压缩全都要经命令执行。
///
/// ## 与 DSH 的对应（2026-10-20 逐项比对后重写）
///
/// `packages/client/ui-chat/src/client/chat/GenericCommandCard.tsx` +
/// `GenericCommandCard.module.css`：
///
/// | DSH | 这里 |
/// |---|---|
/// | `DisclosureRow`（`:58-72`）：24px 行、图标 14、标题 13/24 | [_DisclosureHeader]（行高 36 的触屏偏离） |
/// | `title = node.name ?? t('command.title')`（`:37`），**不是等宽字体** | 命令名走标题样式 |
/// | `summary` 跑时 `t('command.running')`、完成后 `outcome.text`（`:32-34`） | 收起/展开都显示的那行摘要 |
/// | `body = text.includes('\n') ? text : null`（`:40`） | 只有含换行才给展开 |
/// | `.body`：`max-height:260`、`margin:4px 0 4px 4px`、`padding:12px 16px`、`border:.5px l1`、`radius-lg`、`markdown-code-block` 底、**`label-primary`**、`--dsw-font-markdown-code-block-small`（11/16 等宽）（`:38-49`） | 展开区逐条照此 |
/// | 失败时摘要与正文转错误色（`:33-36`） | 同 |
/// | `IconApiOutlineRegular`（`:9`） | `api` 图标 |
///
/// **原来这里是"工具卡形状"**（`roleToolBg` 标题行 + 24×24 图标块 + 等宽橙色命令名
/// + 圆角卡片）。DSH 的命令行**不是卡片**，是流程里的一条 disclosure 行 ——
/// 与工具卡（`ToolRow`）本来就是两种东西，抄工具卡就把层级搞错了。
///
/// ## 为什么不用 [ToolCard]
///
/// 语义不同：工具是"模型调了一个能力"，命令是"用户敲了一条斜杠指令"；
/// DSH 也是两套组件（`GenericCommandCard` 与 `ToolRow`）。
///
/// Note: 为什么把原来的卡片形状换掉 —— 见
/// `.agents/notes/implemented/2026-10-20-render-alignment-to-dsh-spec.md`。
class CommandCard extends StatefulWidget {
  const CommandCard({
    super.key,
    required this.name,
    required this.status,
    this.summary = '',
    this.detail = '',
    this.initiallyOpen = false,
  });

  /// 命令名（`/goal` / `/compact`）。
  final String name;

  final ToolCallStatus status;

  /// 一行摘要（运行中 / 结果文本第一行）。
  final String summary;

  /// 展开后的明细（`command/done.text` 全文）。
  final String detail;

  /// 初始就是展开的（"工作步骤展示"偏好的**完全展开**档）。
  final bool initiallyOpen;

  @override
  State<CommandCard> createState() => _CommandCardState();
}

class _CommandCardState extends State<CommandCard> {
  bool _open = false;

  @override
  void initState() {
    super.initState();
    _open = widget.initiallyOpen;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final failed = widget.status == ToolCallStatus.failed;
    // **只有多行才给展开**（DSH `GenericCommandCard.tsx:40` 的
    // `text.includes('\n') ? text : null`）：单行文本已经在摘要里了，
    // 再给一个箭头是骗人点。
    final hasDetail = widget.detail.contains('\n');
    final open = hasDetail && _open;
    return Padding(
      // 流程行自己的上下留白（不是卡片外边距）。
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DisclosureHeader(
            icon: 'api',
            label: widget.name,
            open: open,
            expandable: hasDetail,
            // DSH 的 `keepContentWhenOpen`：摘要**展开后仍显示**。
            keepPreviewWhenOpen: true,
            preview: widget.summary,
            previewColor: failed ? c.error : null,
            onTap: hasDetail ? () => setState(() => _open = !_open) : null,
          ),
          if (open)
            Container(
              // DSH `.body`（`GenericCommandCard.module.css:38-49`）：
              // margin 4px 0 4px 4px / padding 12px 16px / 上限 260 / 自己滚 /
              // 0.5px l1 边框 / lg 圆角 / code-block 底 / **label-primary** /
              // 11px·16px 等宽。
              margin: const EdgeInsets.fromLTRB(4, 4, 0, 4),
              decoration: BoxDecoration(
                color: c.codeBlock,
                borderRadius: BorderRadius.circular(DshRadius.lg),
                border: Border.all(color: c.borderL1, width: 0.5),
              ),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: SelectableText(
                    widget.detail,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      height: 16 / 11,
                      color: failed ? c.error : c.labelPrimary,
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

/// 一轮的异常结局（DSH 的 `TurnErrorItem` / `TurnMaxTokensItem`）。
///
/// ## 它为什么之前不存在
///
/// 2026-10-19 摸到：`turn/end` 的 `reason.kind` 在投影里**完全没读**。
/// 真日志里这台电脑的历史：`error` 71 条 + `interrupted` 6 条 +
/// `max-tokens` 3 条 = **80 条"出了什么事"在手机上一片空白**，
/// 用户只看到"这一轮好像没跑完"。
///
/// ## 与 DSH 的对应
///
/// `conversation-nodes/turn-error.ts:36-51` 的 `endFailure(reason)`：
/// - `error` → `reason.error`（**DSH 的原文**，如 `Connection error.`）
/// - `interrupted` → 固定文案（进程退出）
/// - `aborted` + hook `signed-out` → 固定文案（登出）
/// - 其余（completed / blocked / max-tokens / forked / plugin-merged）→ 无失败行
///
/// `turn-max-tokens.ts:42` 的判据是 `reason.kind === 'max-tokens'`，
/// 而它在 DSH 里是**单独一条提示**（不算失败）。
///
/// ## 为什么不是卡片
///
/// 它不是"谁做的事"，是**一轮的结局标记**：DSH 也把它渲染成
/// `contextRow` 那一档（一条带图标与文案的行，没有边框卡片）。
class TurnOutcomeRow extends StatelessWidget {
  const TurnOutcomeRow({
    super.key,
    required this.kind,
    required this.message,
    required this.title,
  });

  final TurnOutcomeKind kind;

  /// 提示正文（error 用 DSH 原文，其余是固定文案）。
  final String message;

  /// 一行标题（`第 N 轮出错`）。
  final String title;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    // **颜色是语义**：error 用错误色，截断用工具色（它是"到上限了"不是"坏了"），
    // 中断/登出用告警色（那不是模型的错）。
    final (icon, tone) = switch (kind) {
      TurnOutcomeKind.error => ('warningTriangle', c.error),
      TurnOutcomeKind.interrupted => ('warning', c.roleTool),
      TurnOutcomeKind.maxTokens => ('warning', c.roleTool),
      TurnOutcomeKind.signedOut => ('closeCircleFill', c.roleTool),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DshIcon(icon, size: 14, color: tone),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: tone,
                  ),
                ),
                if (message.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    message,
                    style: TextStyle(
                      fontSize: 12,
                      height: 17 / 12,
                      color: c.labelTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 一次模型重试（DSH 的 `ModelRetryItem`）。
///
/// ## 它为什么之前不存在
///
/// 2026-10-19 摸到：`llm/retry` / `llm/retry-started` 也没接。真日志里
/// 这台电脑有 10+ 条重试链。DSH Web 渲染成 `ModelRetryItem`
/// （`MessageItem.tsx:343-346`），界面上看得到"正在重试（第 2/10 次）"，
/// 而手机上什么都没有 —— 用户只看到"卡了半天"。
///
/// ## 形状（真日志实测）
///
/// `retryId` 配对，`retry: 1..N`、`maxRetries`、`delayMs`（可能是小数）、
/// `failure: {message, code}`（如 `Request timed out.` / `TIMEOUT`）。
class RetryRow extends StatelessWidget {
  const RetryRow({
    super.key,
    required this.title,
    required this.message,
    required this.started,
  });

  /// `重试 2/10`。
  final String title;

  /// 失败原因（`failure.message`，DSH 原文）。
  final String message;

  /// 是否已经开始重试（`llm/retry-started` 到达后为真）。
  final bool started;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          // 计划中与已开跑**图标不同**：前者是钟（在等 delay），
          // 后者是转圈（在跑）。DSH 的 `ModelRetryItem` 也是
          // `retryState === 'scheduled'` 时才显示"active"态。
          DshIcon(
            started ? 'loading' : 'alarmClock',
            size: 14,
            color: started ? c.roleTool : c.labelCaption,
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: started ? c.roleTool : c.labelSecondary,
            ),
          ),
          if (message.isNotEmpty) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: c.labelTertiary),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 一次上下文压缩的标记（DSH 的 `CompactionItem`）。
///
/// ## 它为什么之前不存在
///
/// 2026-10-19 摸到的最后一个缺口：`compaction/*` 三个事件完全没接。
/// DSH Web 在压缩落定时显示一条检查点（摘要 + 替换条目数 + 压掉的 token），
/// 手机上没有 —— 于是"之前的对话被总结成一段摘要替换掉了"这件事
/// **完全不可见**，而它影响后续**所有**轮次。
///
/// ## 与 DSH 的对应
///
/// `conversation-nodes/command.ts:101-131` 的 `compactSummary`：
/// 摘要 = text 块拼接；两个计数只认形状可信的值。这里照做，
/// 显示成一行（标题 + 统计），摘要正文可展开。
class CompactionRow extends StatefulWidget {
  const CompactionRow({super.key, required this.summary, required this.stats});

  /// 压缩摘要（text 块拼接）；空串 = 没有。
  final String summary;

  /// 统计部分（`替换 142 条 · 压掉 605K tok`）；空串 = 两项都没有。
  final String stats;

  @override
  State<CompactionRow> createState() => _CompactionRowState();
}

class _CompactionRowState extends State<CompactionRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final hasSummary = widget.summary.isNotEmpty;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        // 助手色的极淡底：它是"模型看到的世界在这里换了"，
        // 不是错误、也不是工具。
        color: c.roleAssistant.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(DshRadius.md),
        border: Border.all(color: c.roleAssistant.withValues(alpha: 0.24)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: hasSummary ? () => setState(() => _open = !_open) : null,
            child: Row(
              children: [
                DshIcon('compact', size: 14, color: c.roleAssistant),
                const SizedBox(width: 8),
                Text(
                  CompactionItem.kTitle,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: c.roleAssistant,
                  ),
                ),
                if (widget.stats.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.stats,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        color: c.labelTertiary,
                      ),
                    ),
                  ),
                ],
                if (hasSummary) ...[
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: _open ? 0.25 : 0,
                    duration: const Duration(milliseconds: 160),
                    child: DshIcon(
                      'chevronRight',
                      size: 14,
                      color: c.labelTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (hasSummary && _open) ...[
            const SizedBox(height: 8),
            // 摘要正文。**不用 Markdown**：它本身就是给模型看的压缩稿，
            // 原样等宽显示更接近"这是什么"的真相。
            Text(
              widget.summary,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11.5,
                height: 17 / 11.5,
                color: c.labelSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 一轮的过程摘要（DSH 的 `TurnProcessNodeView`）。
///
/// ## 它为什么之前不存在
///
/// DSH Web 在**每一轮结束时**给一行摘要：`用时 2 分 36 秒 · 12 条消息 ·
/// 8 次工具调用 · 1 个子智能体`。手机上没有 —— 于是一轮跑完，用户看到的
/// 就是"又多了几屏内容"，没有"这一轮到底干了什么、花了多久"的收口。
///
/// ## 与 DSH 的对应
///
/// `TurnProcessNodeView.tsx:22-30`：
///
/// | DSH | 这里 |
/// |---|---|
/// | `elapsedMs = end.time - start.time`（`Math.max(1000, …)`） | `elapsedMs`，不足 1 秒按 1 秒 |
/// | `stopped`（aborted/interrupted）→ `t('message.stopped')` | `已停止` |
/// | `error` → `t('message.turnProcess.failed')` | `失败` |
/// | 其余 → `t('message.turnProcess.took')` + duration | 时长 |
/// | data 属性里的三个计数 | 统计部分 |
///
/// ## 为什么是一行而不是卡片
///
/// DSH 同处是一个 `<button>`（可折叠收起该轮内容），视觉上是**一行文字**。
/// 手机这一版不做"收起该轮"（那是组级交互，而我们没有 turn 组），
/// 所以它就是一条纯展示的行 —— 放在一轮的末尾当收口。
///
/// ## 它同时是 DSH 的 `turn-tail` 操作行（2026-10-20）
///
/// 用户原话：「dsh web 我看每个消息完毕有复制用量啥的」。DSH 的形态是
/// **独立的 `turn-tail` 行**（`turn/end` 时以 seq+0.1 物化，
/// `conversation-nodes/turn-tail.ts:107-140`，**一个 turn 只有一条**），
/// 按钮顺序 = 复制 → 点赞/点踩 → 分支 → 用量 pill → 时钟
/// （`TurnTailNodeView.tsx:57-80`）。
///
/// 手机上把**复制 + 用量 pill** 挂在这一行（本行就是那个 turn-tail）：
/// - **点赞/点踩**：要 `message-feedback` 的写面，本仓未接，不做死按钮；
/// - **分支**：要 `session/fork`，未接；
/// - **时钟**：本行左侧已有 `clock` 图标 + 用时，再加一个时刻是重复。
///
/// 用量 pill 的文案与 DSH 逐字同构：`用量 {formatTokenCount} tok`
/// （`locale.ts:178,186` + `TurnUsagePanel.tsx:18-20`）。
class TurnProcessRow extends StatefulWidget {
  const TurnProcessRow({
    super.key,
    required this.title,
    required this.stats,
    this.failed = false,
    this.usage,
    this.copyText = '',
  });

  /// 一行标题（`第 3 轮`）。
  final String title;

  /// 统计部分（`2 分 36 秒 · 12 条消息 · 8 次工具`）。
  final String stats;

  /// 这一轮是失败收尾的（换图标与颜色）。
  final bool failed;

  /// 该轮的 token 用量；`null` = 不显示用量 pill（**不摆 `0 tok`**）。
  final TurnTokenUsage? usage;

  /// 「复制」要复制的东西（该轮助手回复正文）。空串 = 不显示复制钮。
  final String copyText;

  @override
  State<TurnProcessRow> createState() => _TurnProcessRowState();
}

class _TurnProcessRowState extends State<TurnProcessRow> {
  /// 复制成功后短暂变对勾（DSH 是 1 秒，`MessageIconActions.tsx:62-76`）。
  bool _copied = false;
  Timer? _reset;

  @override
  void dispose() {
    _reset?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.copyText));
    if (!mounted) return;
    setState(() => _copied = true);
    _reset?.cancel();
    _reset = Timer(const Duration(seconds: 1), () {
      if (!mounted) return;
      setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    // 失败用工具色（那不是模型的错，也不是"这一轮的正常产出"），
    // 正常收尾用最弱的说明色 —— 它是收口，不是内容。
    final tone = widget.failed ? c.roleTool : c.labelCaption;
    final usage = widget.usage;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      // **`Wrap` 而不是 `Row`**：窄屏上"标题 + 统计 + 两枚操作"放不下一行，
      // 而 `Row` 只会把它们裁掉（或画出黄黑条纹）。`Wrap` 会自动折行。
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DshIcon(
                widget.failed ? 'warningTriangle' : 'clock',
                size: 13,
                color: tone,
              ),
              const SizedBox(width: 6),
              Text(
                widget.title,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: tone,
                ),
              ),
            ],
          ),
          Text(
            widget.stats,
            style: TextStyle(fontSize: 12, color: c.labelTertiary),
          ),
          // **用量 pill**（DSH 的 `用量 10.6M tok`）：点开是明细。
          if (usage != null)
            _Pill(
              icon: 'database',
              label: '用量 ${formatTokenCount(usage.totalTokens)} tok',
              onTap: () => showTurnUsageSheet(context, usage),
            ),
          // **复制**：没有正文就不摆（复制一个空串会让人以为成功了）。
          if (widget.copyText.isNotEmpty)
            _Pill(
              key: const Key('turn-copy'),
              icon: _copied ? 'check' : 'copy',
              label: _copied ? '已复制' : '复制',
              onTap: _copy,
            ),
        ],
      ),
    );
  }
}

/// 一枚小的操作胶囊（用量 / 复制）。
class _Pill extends StatelessWidget {
  const _Pill({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final String icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Material(
      color: c.layer2,
      borderRadius: BorderRadius.circular(11),
      child: InkWell(
        // 触摸目标 ≥ 28（`MessageIconActions` 的命中区就是 28）。
        onTap: onTap,
        borderRadius: BorderRadius.circular(11),
        child: Container(
          constraints: const BoxConstraints(minHeight: 28),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DshIcon(icon, size: 12, color: c.labelSecondary),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(fontSize: 11.5, color: c.labelSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一轮用量的明细（DSH 的「本轮用量」弹窗，`TurnUsagePanel.tsx:52-107`）。
///
/// 摆的东西与 DSH 同构：精确值（三位分组）+ 缓存命中 + 未缓存输入 +
/// 缓存读取 + 缓存写入 + 输出。**缓存命中只在这里显示，pill 上不带**
/// （DSH 同一条：`formatCacheHitPercent` 只在弹窗里用）。
Future<void> showTurnUsageSheet(BuildContext context, TurnTokenUsage usage) {
  final cacheRead = usage.cacheReadTokens;
  // **分母 = 三个互不重叠的 prompt 侧桶之和**（与 `TokenUsage.billedInput`
  // 同一条，`session_stats.dart:43-50`）—— 输出不计入"输入侧命中"。
  final promptTokens =
      usage.inputTokens + (cacheRead ?? 0) + (usage.cacheWriteTokens ?? 0);
  final hit = cacheRead == null
      ? null
      : formatCacheHitPercent(cacheRead, promptTokens);
  // 精确值按三位分组（DSH 的 `formatExactTokens`）。
  String exact(int n) => n.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  final rows = <(String, String)>[
    ('总量', '${exact(usage.totalTokens)} tok'),
    if (hit != null) ('缓存命中', '$hit%'),
    ('未缓存输入', '${exact(usage.inputTokens)} tok'),
    if (cacheRead != null) ('缓存读取', '${exact(cacheRead)} tok'),
    if (usage.cacheWriteTokens != null)
      ('缓存写入', '${exact(usage.cacheWriteTokens!)} tok'),
    ('输出', '${exact(usage.outputTokens)} tok'),
  ];
  return showDshSheet<void>(
    context: context,
    title: '本轮用量',
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      color: context.dshColors.labelSecondary,
                    ),
                  ),
                ),
                Text(
                  value,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    color: context.dshColors.labelPrimary,
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

/// 审批 / 提问的**一行提示**（原型：它们不在气泡里，而是接管输入栏；
/// 对话流里只留一行可点回来的入口）。
class TakeoverHint extends StatelessWidget {
  const TakeoverHint({
    super.key,
    required this.icon,
    required this.name,
    required this.argument,
    required this.statusText,
    this.onTap,
  });

  final String icon;
  final String name;
  final String argument;
  final String statusText;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    // 结构同 `.tool`（它本来就是 `.tool` 的一个变体），状态用告警色。
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(DshRadius.lg),
        border: Border.all(color: c.layer1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: c.roleToolBg,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: c.roleTool.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: DshIcon(icon, size: 13, color: c.roleTool),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  name,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: c.roleTool,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    argument,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      color: c.labelTertiary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  statusText,
                  style: TextStyle(fontSize: 11, color: c.roleTool),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 系统消息（`system/message` / `developer/message`）。
///
/// ## 为什么是折叠行而不是正文
///
/// 真日志里 `system/message` 是**整份系统提示词**（上万字符），
/// `developer/message` 是上下文注入（工具目录等）。2026-10-19 之前它们被
/// 渲染成 `SystemTurn(text)` —— 一条居中的弱化小字，于是对话流开头横着
/// 一面巨墙（真机复现）。DSH 对这两种事件各有一个带标题的节点：
/// `system-prompt`（`locale.ts:116` 的「系统提示词」）与 `context`
/// （生产者 kind 当标题，`event-projection.ts:60-76`），**默认折叠**。
///
/// 所以这里与「思考过程」共用同一个折叠控件（[_CollapsibleNote]）——
/// **行是同一个（DSH 也共用 `DisclosureRow`），正文不同**：
/// 思考是 compact Markdown，这两种是代码字体的 141px 滚动区
/// （`ui-chat/src/client/chat/ContextInjectionRow.module.css:50-64`）。
class SystemTurn extends StatelessWidget {
  const SystemTurn(this.text, {super.key, this.label, this.hint});

  /// 正文（展开后才看）。
  final String text;

  /// 标题行文案；`null` = 「系统提示词」。
  final String? label;

  /// 标题后那个分隔点之后的**生产者**（`runtime-context` 之类）；`null` = 不显示。
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final label = this.label;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: _CollapsibleNote(
        // **图标跟标签走**，不写死一个：DSH 的 `context` 节点（上下文注入）
        // 与 `system-prompt` 节点（系统提示词）是两行不同的东西，共用一个图标
        // 等于把区别抹掉。
        //
        // 系统提示词在 DSH 里是 **browse** 图标
        // （`ui-chat/src/client/chat/SystemPromptRow.tsx:30` 的
        // `IconBrowseOutlineRegular`，抽取进我们图标集时叫 `browse`）；
        // 上下文注入是 `contextInjection`（`ContextInjectionRow.tsx:55`）。
        // 原来系统提示词用的 `info` 是我们自己挑的，没有出处。
        icon: label == null || label == kSystemPromptLabel
            ? 'browse'
            : 'contextInjection',
        label: label ?? kSystemPromptLabel,
        text: text,
        collapsedPreview: hint ?? '',
      ),
    );
  }
}

/// 一条流程行（DSH 的 `DisclosureRow`）：图标 + 标题 + 可选摘要 + chevron。
///
/// 「思考过程」「系统提示词 / 上下文注入」「斜杠命令」三处共用它 ——
/// DSH 里这三处也共用 `DisclosureRow`（`ui-primitives/src/DisclosureRow.tsx`），
/// 各写一份必然漂。
class _DisclosureHeader extends StatelessWidget {
  const _DisclosureHeader({
    required this.icon,
    required this.label,
    required this.open,
    required this.onTap,
    this.expandable = true,
    this.preview = '',
    this.previewColor,
    this.keepPreviewWhenOpen = false,
  });

  final String icon;
  final String label;
  final bool open;

  /// 点整行切换（DSH 的 `expandOnRowClick`）；`null` = 不可展开。
  final VoidCallback? onTap;

  final bool expandable;

  /// 标题后那行摘要（思考的首行 / 命令的结果文本）；空 = 不显示。
  final String preview;

  /// 摘要色；`null` = `labelTertiary`（命令失败时传 `error`）。
  final Color? previewColor;

  /// 展开后摘要是否仍在（DSH 命令行的 `keepContentWhenOpen`）。
  final bool keepPreviewWhenOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final showPreview = preview.isNotEmpty && (keepPreviewWhenOpen || !open);
    return InkWell(
      onTap: expandable ? onTap : null,
      child: SizedBox(
        // 偏离 1：DSH 的行高是 24（`DisclosureRow.module.css:36`）；
        // 触屏要 36 才够点。
        height: 36,
        child: Row(
          children: [
            // 偏离 2 的另一半：图标固定 14（`:69-72` 的 14px 字形）。
            DshIcon(icon, size: 14, color: c.labelTertiary),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                // secondary 档 13（`:100-105` 的 `--dsh-content-font-size-secondary`）。
                fontSize: 13,
                color: c.labelTertiary,
              ),
            ),
            if (showPreview) ...[
              // DSH 的分隔点 + 摘要（`ReasoningRow.module.css:32-51`）。
              const SizedBox(width: 8),
              Container(
                width: 2,
                height: 2,
                decoration: BoxDecoration(
                  color: c.labelCaption,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    height: 20 / 13,
                    color: previewColor ?? c.labelTertiary,
                  ),
                ),
              ),
            ] else
              const Spacer(),
            if (expandable) ...[
              const SizedBox(width: 8),
              DshIcon(
                open ? 'chevronDown' : 'chevronRight',
                size: 14,
                color: c.labelTertiary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 一个可折叠的过程行：图标 + 标签 + chevron，展开后是正文。
///
/// 「思考过程」与「系统提示词」用它 —— 两者结构逐字相同（图标、标签、
/// 默认收起、展开区一条顶边），各写一份必然漂（2026-10-19 合并）。
///
/// ## 与 DSH `DisclosureRow` 的对应（2026-10-20 比对）
///
/// | DSH（`ui-primitives/src/DisclosureRow.module.css`） | 这里 |
/// |---|---|
/// | 行高 24（`:36`） | **36**（触屏命中区，见下"偏离"） |
/// | 前导图标盒 16、图标 14（`:50-72`） | 图标 14、间距 6 |
/// | 标题 13/24，色 `label-tertiary`（`:38,100-105`） | 13、`labelTertiary` |
/// | 展开时**前导图标变成 chevron-up**（`DisclosureRow.tsx:82-84`） | 右侧恒有 chevron（见下"偏离"） |
/// | **没有卡片边框/底色**，整行就是内容 | 同（2026-10-20 去掉了原来的 layer1 卡片） |
///
/// 两处**有意偏离**（触屏没有 hover，也没有 24px 的可点行）：
/// 1. 行高 36（≥ 触摸目标），DSH 是 24；
/// 2. 收起/展开都靠**右侧** chevron 表达状态 —— DSH 把状态画在**前导图标**上，
///    而那是"悬停才出现"的提示（`:84-98` 的 `chevronHover`），触屏永远看不到。
///
/// Note: 为什么两种正文（compact Markdown vs 代码滚动区）与为什么去掉卡片 —— 见
/// `.agents/notes/implemented/2026-10-20-render-alignment-to-dsh-spec.md`。
class _CollapsibleNote extends StatefulWidget {
  const _CollapsibleNote({
    required this.icon,
    required this.label,
    required this.text,
    this.markdownBody = false,
    this.collapsedPreview = '',
  });

  final String icon;
  final String label;
  final String text;

  /// 正文按 **compact Markdown** 渲染（思考过程），否则按**代码字体**渲染
  /// （系统提示词 / 上下文注入 —— 它们是给模型看的原文）。
  final bool markdownBody;

  /// 收起时跟在标题后的一行摘要（DSH 的 `collapsedContent`）；空 = 不显示。
  final String collapsedPreview;

  @override
  State<_CollapsibleNote> createState() => _CollapsibleNoteState();
}

class _CollapsibleNoteState extends State<_CollapsibleNote> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DisclosureHeader(
          icon: widget.icon,
          label: widget.label,
          open: _open,
          preview: widget.collapsedPreview,
          onTap: () => setState(() => _open = !_open),
        ),
        if (_open) _body(context.dshColors),
      ],
    );
  }

  Widget _body(DshColorTokens c) {
    if (widget.markdownBody) {
      // 思考正文：DSH `ReasoningRow.module.css:73-77` 的 `.thinkBody`
      //   `padding: 4px 0 4px calc(22px + delta)`，正文是 compact Markdown。
      return Padding(
        padding: const EdgeInsets.fromLTRB(22, 4, 0, 4),
        child: DshMarkdown(widget.text, compact: true),
      );
    }
    // 系统提示词 / 上下文注入：DSH `ContextInjectionRow.module.css:50-64` 的 `.body`
    //   width: calc(100% - 22px); max-height: 141px; overflow: auto;
    //   margin: 4px 0 0 22px; padding: 10px 16px 12px 12px;
    //   border-radius: radius-md; background: markdown-code-block;
    //   color: label-tertiary; font: 400 11px/16px <code family>
    // 141px 是 Figma 10:2482 的"代码块上限"（同文件 :1-2 的注释）：
    // 一份上万字的系统提示词展开后不该把对话顶到屏幕外。
    return Padding(
      padding: const EdgeInsets.only(left: 22, top: 4, bottom: 4),
      child: Container(
        decoration: BoxDecoration(
          color: c.codeBlock,
          borderRadius: BorderRadius.circular(DshRadius.md),
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 141),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 10, 16, 12),
            child: SelectableText(
              widget.text,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                height: 16 / 11,
                color: c.labelTertiary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
