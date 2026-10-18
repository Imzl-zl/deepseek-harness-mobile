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

import 'package:flutter/material.dart';

import '../data/projection.dart';
import '../model/chat_item.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';
import 'dsh_markdown.dart';

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
                // 插话用工具色底：它是"轮次跑到一半的输入"，与开轮输入
                // 视觉上分开（DSH Web 同样把 steering 与 user 分开成两类节点）。
                color: steering ? DshColors.roleToolBg : DshColors.layer3,
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
                    const Padding(
                      padding: EdgeInsets.only(bottom: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DshIcon('queue', size: 11, color: DshColors.roleTool),
                          SizedBox(width: 4),
                          Text(
                            '插话',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: DshColors.roleTool,
                            ),
                          ),
                        ],
                      ),
                    ),
                  Text(
                    text,
                    style: const TextStyle(
                      fontSize: 14.5,
                      height: 21 / 14.5,
                      color: DshColors.labelPrimary,
                    ),
                  ),
                  if (attachmentCount > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '$attachmentCount 个附件（手机上不显示）',
                        style: const TextStyle(
                          fontSize: 11,
                          color: DshColors.labelTertiary,
                        ),
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
          // `.a-head { display:flex; align-items:center; gap:8px; margin-bottom:8px }`
          Row(
            children: [
              const _AssistantAvatar(),
              const SizedBox(width: 8),
              const Text(
                '助手',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: DshColors.labelPrimary,
                ),
              ),
              if (modelName != null && modelName!.isNotEmpty) ...[
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    '· $modelName',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: DshColors.labelCaption,
                    ),
                  ),
                ),
              ],
            ],
          ),
          // **思考过程**：折叠在正文上方。默认收起 —— 它经常比正文还长，
          // 全展开会把对话冲掉（DSH 桌面端同样把它归入"过程"分组）。
          if (reasoning.isNotEmpty) ...[
            const SizedBox(height: 8),
            _ReasoningBlock(text: reasoning),
          ],
          // `.md`：Markdown 正文（代码块、列表、加粗都渲染）。
          DshMarkdown(text),
        ],
      ),
    );
  }
}

/// 思考过程块（可折叠）。
///
/// 结构与 [_CollapsibleNote] 完全相同，差别只有图标与强调色 —— 所以直接复用它。
class _ReasoningBlock extends StatelessWidget {
  const _ReasoningBlock({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return _CollapsibleNote(icon: 'sparkle', label: '思考过程', text: text);
  }
}

/// 助手头像：26×26、圆角 9、**品牌渐变**（`.a-ava`）。
class _AssistantAvatar extends StatelessWidget {
  const _AssistantAvatar();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        // `linear-gradient(135deg, #5686fe, #9e7baa)` —— 蓝到紫，
        // 与 `roleAssistant`（紫）同族。这是 DSH 的品牌识别之一，
        // 所以两个色值取自 token 而不是现编。
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [DshColors.accentBlue, DshColors.roleAssistant],
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
    final (icon, tone) = switch (widget.status) {
      ToolCallStatus.running => ('loading', DshColors.roleTool),
      ToolCallStatus.completed => ('check', DshColors.roleContext),
      ToolCallStatus.failed => ('warningTriangle', DshColors.error),
    };
    final hasDetail = widget.detail.isNotEmpty;
    return Container(
      // `.tool { margin:12px 0; border:1px solid l1; border-radius:16 }`
      margin: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(DshRadius.lg),
        border: Border.all(color: DshColors.layer1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Material(
            // `.tool-r { background: var(--tool-bg) }` —— 暖色底，
            // 与助手正文的冷色底区分开（一眼看出"这不是模型说的话"）。
            color: DshColors.roleToolBg,
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
                        color: DshColors.roleTool.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: DshIcon(icon, size: 13, color: tone),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      widget.name,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: DshColors.roleTool,
                      ),
                    ),
                    const SizedBox(width: 6),
                    // `.tool-arg { flex:1; min-width:0; 等宽; 可省略 }`
                    Expanded(
                      child: Text(
                        widget.argument,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12.5,
                          color: DshColors.labelTertiary,
                        ),
                      ),
                    ),
                    if (widget.diffStat != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        '+${widget.diffStat!.added}',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: DshColors.fileDiffAddMarker,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '−${widget.diffStat!.removed}',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: DshColors.fileDiffDelMarker,
                        ),
                      ),
                    ],
                    if (hasDetail) ...[
                      const SizedBox(width: 8),
                      // `.tool-cv` 展开时旋转 90°（`is-open` 那条规则）。
                      AnimatedRotation(
                        turns: _open ? 0.25 : 0,
                        duration: const Duration(milliseconds: 160),
                        child: const DshIcon(
                          'chevronRight',
                          size: 16,
                          color: DshColors.labelTertiary,
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
              // `.tool-body { padding:12px 14px; background:layer1;
              //   border-top:1px solid l1; 等宽; line-height:20 }`
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: const BoxDecoration(
                color: DshColors.layer1,
                border: Border(top: BorderSide(color: DshColors.layer1)),
              ),
              child: Text(
                widget.detail,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12.5,
                  height: 20 / 12.5,
                  color: DshColors.labelSecondary,
                ),
              ),
            ),
        ],
      ),
    );
  }
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
    // 结构同 `.tool`（它本来就是 `.tool` 的一个变体），状态用告警色。
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(DshRadius.lg),
        border: Border.all(color: DshColors.layer1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: DshColors.roleToolBg,
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
                    color: DshColors.roleTool.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: DshIcon(icon, size: 13, color: DshColors.roleTool),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  name,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: DshColors.roleTool,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    argument,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      color: DshColors.labelTertiary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  statusText,
                  style: const TextStyle(
                    fontSize: 11,
                    color: DshColors.roleTool,
                  ),
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
/// 两处的差别只有图标与标签，结构完全相同。
class SystemTurn extends StatelessWidget {
  const SystemTurn(this.text, {super.key, this.label});

  /// 正文（展开后才看）。
  final String text;

  /// 标题行文案；`null` = 「系统提示词」。
  final String? label;

  @override
  Widget build(BuildContext context) {
    final label = this.label;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: _CollapsibleNote(
        // **图标跟标签走**，不写死一个：DSH 的 `context` 节点（上下文注入）
        // 与 `system-prompt` 节点（系统提示词）是两行不同的东西，共用一个图标
        // 等于把区别抹掉。`contextInjection` 是 DSH 图标集里语义最接近的那个
        // （`verify-icons.cjs` 只放行集合内的 100 个名字）。
        icon: label == null || label == kSystemPromptLabel
            ? 'info'
            : 'contextInjection',
        label: label ?? kSystemPromptLabel,
        text: text,
      ),
    );
  }
}

/// 一个可折叠的过程行：图标 + 标签 + chevron，展开后是正文。
///
/// 「思考过程」与「系统提示词」用它 —— 两者结构逐字相同（图标、标签、
/// 默认收起、展开区一条顶边），各写一份必然漂（2026-10-19 合并）。
class _CollapsibleNote extends StatefulWidget {
  const _CollapsibleNote({
    required this.icon,
    required this.label,
    required this.text,
  });

  final String icon;
  final String label;
  final String text;

  @override
  State<_CollapsibleNote> createState() => _CollapsibleNoteState();
}

class _CollapsibleNoteState extends State<_CollapsibleNote> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: DshColors.layer1,
        borderRadius: BorderRadius.circular(DshRadius.md),
        border: Border.all(color: DshColors.layer2),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  // 两处共用同一个强调色（助手色）：标签行的图标是"这是过程"
                  // 的标记，不是分类 —— 分类由标签文字说。
                  DshIcon(
                    widget.icon,
                    size: 13,
                    color: DshColors.roleAssistant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    widget.label,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: DshColors.labelSecondary,
                    ),
                  ),
                  const Spacer(),
                  DshIcon(
                    _open ? 'chevronDown' : 'chevronRight',
                    size: 13,
                    color: DshColors.labelTertiary,
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: DshColors.layer2)),
              ),
              // 按**纯文本**渲染：它不是给用户的答案，Markdown 记号在里面
              // 只会添乱（DSH 桌面端同样按文本呈现）。
              child: SelectableText(
                widget.text,
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 20 / 12.5,
                  color: DshColors.labelTertiary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
