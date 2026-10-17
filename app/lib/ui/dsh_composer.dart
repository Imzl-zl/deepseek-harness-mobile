/// 输入栏与统计条（照 `mock/proto/index.html` 的 `footer.foot`）。
///
/// ## 三条硬规则（`design-and-tech-plan.md` §7.2，踩过坑写死的）
///
/// 1. **附件在卡片内部上方**，不是卡片外单独一行 ——
///    卡片外会被状态行和输入框夹住，视觉上像"被顶上去的一块"。
/// 2. **文字独占一行**，`＋` 和发送键**不进文字行** ——
///    否则占位符被迫折行、模型名被截成 `claude-...`。
/// 3. **控制行左一组（`＋` / 模型·等级 / 权限图标 / 发送模式图标），右边只有发送键**。
///    **这是有意偏离 DSH 桌面**：桌面把模型放 `.trailing`（右侧）和发送键一组；
///    手机主流是左侧集中、右侧单发送。
///    模型 chip 可压缩（上限 62%），权限与发送模式各 34px 恒宽 ——
///    保证长模型名不挤走这两个图标或发送键。
///    发送模式（排队 / 插话）是 2026-10-13 补的第四个控件：DSH 原生就有这个
///    二选一（"繁忙时的发送行为"），而它**只在会话正在跑时才有区别**，是发送
///    当下的选择 —— 放进行控区而不是以后的设置页，理由见 `model/send_mode.dart`。
///
/// ## 统计条在输入卡片**下面**
///
/// 照 DSH `InputBar.tsx:499`：统计与上下文挂在卡片下方，**不顶输入框**。
/// 点它弹 sheet（§7.4）——本版先只显示，sheet 是下一步。
library;

import 'package:flutter/material.dart';

import '../model/permission.dart';
import '../model/send_mode.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';

/// 待发送附件（`.attach-rail` 里的一项）。
class PendingAttachment {
  const PendingAttachment({required this.name, this.icon = 'deliverDoc'});

  final String name;
  final String icon;
}

/// 输入栏（含附件轨 + 文字行 + 控制行）。
class DshComposer extends StatelessWidget {
  const DshComposer({
    super.key,
    required this.controller,
    required this.attachments,
    required this.modelName,
    required this.reasoningLabel,
    required this.access,
    required this.sendMode,
    required this.sending,
    required this.onSend,
    required this.onAttach,
    required this.onPickModel,
    required this.onPickAccess,
    required this.onPickSendMode,
    required this.onRemoveAttachment,
    this.enabled = true,
    this.running = false,
    this.onStop,
  });

  final TextEditingController controller;

  /// 附件（**卡片内部上方** —— 硬规则 1）。
  final List<PendingAttachment> attachments;

  final String modelName;

  /// 推理等级（`· 高`）。
  final String reasoningLabel;

  /// 当前权限档的展示值（图标 + 文案 + 是否告警色）。
  ///
  /// **从电脑侧真值来**（`permissions` 投影的 `currentValue`，经
  /// `model/permission.dart` 的 `permissionChipOf` 归一）—— 曾经这里是
  /// 一个三档手抄枚举，点完只改本地字段，与电脑侧无关。
  final PermissionChip access;

  /// 发送模式（排队 / 插话，DSH 的"繁忙时的发送行为"）。
  final SendMode sendMode;

  final bool sending;

  /// 是否可输入（没连电脑/没会话时置灰）。
  final bool enabled;

  /// 会话是否正在跑（决定主键是"停止"还是"发送"，照 Web 的 `primaryStops`）。
  final bool running;

  /// 「停止」（打断当前轮次）。**running 且没有草稿时才用主键触发它** ——
  /// 与 Web 逐字一致（`InputBar.tsx:323` 的
  /// `primaryStops = running && (empty || blocked)`）：有草稿时主键仍然是发送，
  /// 那句话按当前发送模式排队/插进去。
  final VoidCallback? onStop;

  final VoidCallback onSend;
  final VoidCallback onAttach;
  final VoidCallback onPickModel;
  final VoidCallback onPickAccess;

  /// 打开发送模式二选一。
  final VoidCallback onPickSendMode;
  final void Function(PendingAttachment item) onRemoveAttachment;

  @override
  Widget build(BuildContext context) {
    final hasDraft = controller.text.trim().isNotEmpty;
    final canSend = enabled && !sending && hasDraft;
    // **主键在运行中且没有草稿时是"停止"**（Web 的 `primaryStops`）。
    final stops = running && !hasDraft && onStop != null;
    return Container(
      color: DshColors.sidebar,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Container(
        // `.composer { padding:6px 6px 6px 8px; border-radius:24px }`
        padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
        decoration: BoxDecoration(
          color: DshColors.layer1,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---- 附件轨：**卡片内部最上方**（硬规则 1）----
            if (attachments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final item in attachments)
                      _AttachmentChip(
                        item: item,
                        onRemove: () => onRemoveAttachment(item),
                      ),
                  ],
                ),
              ),

            // ---- 文字行：**独占一行**（硬规则 2）----
            TextField(
              controller: controller,
              enabled: enabled,
              minLines: 1,
              maxLines: 6,
              style: const TextStyle(
                fontSize: 15,
                color: DshColors.labelPrimary,
              ),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                // **照抄 DSH 原文**（`mock/proto/index.html` 的 `placeholder`）：
                // 半角逗号 + 空格（`任务, / 调用`），不是全角逗号。
                // 全角逗号更宽 —— 在 320px 屏上会让这段**更早折行**，
                // 而它本来就已接近放不下（实测 15px 需 345px、可用 282px）。
                // 文档 §7.2 写明"短屏由 CSS 自然折行，**不手动截断**"。
                hintText: '发消息或创建任务, / 调用指令, @ 文件或对话',
                hintStyle: TextStyle(
                  fontSize: 15,
                  color: DshColors.labelTertiary,
                ),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 8,
                ),
              ),
              onSubmitted: (_) {
                if (canSend) onSend();
              },
            ),

            // ---- 控制行：左一组 / 右只有发送（硬规则 3）----
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      // `＋`：38×38 圆钮。
                      _RoundIconButton(
                        icon: 'plus',
                        tooltip: '添加文件或调用指令',
                        onPressed: enabled ? onAttach : null,
                      ),
                      const SizedBox(width: 6),
                      // 模型 chip：可压缩，**上限 62%**（硬规则 3 的前半句）。
                      //
                      // 上限不能省：`Flexible` 只表示"可以被压"，不表示"最宽多少" ——
                      // 没有上限时它会**吃满**左组剩余宽度（长模型名尤其明显），
                      // 而原型 `#chipModel { max-width: 62% }` 是明确写了上限的。
                      // 实测：`claude-opus · 高` 在 1080px 宽的屏上被拉成一整条，
                      // 看起来像"模型是个很宽的选择器"，与胶囊形态不符。
                      Flexible(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.sizeOf(context).width * 0.62,
                          ),
                          child: _Chip(
                            onPressed: enabled ? onPickModel : null,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    modelName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: DshColors.labelPrimary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '· $reasoningLabel',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: DshColors.labelCaption,
                                  ),
                                ),
                                const SizedBox(width: 2),
                                const DshIcon(
                                  'chevronDown',
                                  size: 12,
                                  color: DshColors.labelCaption,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      // 权限图标：**34px 恒宽**（硬规则 3 的后半句）。
                      _IconChip(
                        icon: access.icon,
                        tooltip: access.label,
                        isWarn: access.warn,
                        onPressed: enabled ? onPickAccess : null,
                      ),
                      const SizedBox(width: 6),
                      // 发送模式图标：与权限并列的第二个 34px 恒宽图标。
                      //
                      // 它是 DSH 的"繁忙时的发送行为"二选一（排队 / 插话，
                      // 见 `model/send_mode.dart`），决定这句话在会话忙时
                      // 排到下一个轮次还是插进当前轮次。放进行控区而不是
                      // 设置页：它**只在会话正在跑时才有区别**，是发送当下的
                      // 选择，不是装完就不动的偏好。
                      _IconChip(
                        icon: sendMode.icon,
                        tooltip: sendMode.label,
                        onPressed: enabled ? onPickSendMode : null,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                // 右侧**只有**发送键（运行中且没草稿时它是**停止**键）。
                _SendButton(
                  key: const Key('composer-primary'),
                  // **停止键不受"空草稿"门限**：它的启用判据是"有没有停止出口"
                  // （照 Web 的 `primaryDisabled = primaryStops ? stop === undefined
                  // : empty || disabled || …`，`InputBar.tsx:325`）——
                  // 否则运行中正想停的时候，那颗键永远是灰的。
                  enabled: stops || canSend,
                  sending: sending,
                  stops: stops,
                  tooltip: stops
                      ? '停止'
                      : running
                      ? (sendMode == SendMode.steer ? '插话发送' : '排队发送')
                      : '发送',
                  onPressed: stops ? (onStop ?? onSend) : onSend,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 附件 chip（可删）。
class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({required this.item, required this.onRemove});

  final PendingAttachment item;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      decoration: BoxDecoration(
        color: DshColors.layer2,
        borderRadius: BorderRadius.circular(DshRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DshIcon(item.icon, size: 13, color: DshColors.labelSecondary),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                color: DshColors.labelSecondary,
              ),
            ),
          ),
          const SizedBox(width: 2),
          GestureDetector(
            onTap: onRemove,
            child: const Padding(
              padding: EdgeInsets.all(2),
              child: DshIcon(
                'closeFill',
                size: 12,
                color: DshColors.labelTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 38×38 圆钮（`.ctools > .ib`）。
class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
  });

  final String icon;
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
      width: 38,
      height: 38,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Center(
            child: DshIcon(
              icon,
              size: 18,
              color: onPressed == null
                  ? DshColors.labelTertiary
                  : DshColors.labelSecondary,
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// 文字 chip（`.chip`：`min-height:32`、`border-radius:16`）。
class _Chip extends StatelessWidget {
  const _Chip({required this.child, this.onPressed});

  final Widget child;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: DshColors.layer2,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Container(
          constraints: const BoxConstraints(minHeight: 32),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          child: child,
        ),
      ),
    );
  }
}

/// 图标 chip（`.chip--icon`：**34px 恒宽**）。
class _IconChip extends StatelessWidget {
  const _IconChip({
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.isWarn = false,
  });

  final String icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool isWarn;

  @override
  Widget build(BuildContext context) {
    final chip = Material(
      // 危险档用告警底（`.chip--icon.is-warn { background: var(--warn-bg) }`）。
      color: isWarn ? DshColors.roleToolBg : DshColors.layer2,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          // 恒宽：长模型名不会把它挤走（硬规则 3）。
          width: 34,
          height: 34,
          child: Center(
            child: DshIcon(
              icon,
              size: 16,
              color: isWarn ? DshColors.roleTool : DshColors.labelSecondary,
            ),
          ),
        ),
      ),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
  }
}

/// 发送键（`.send`：38×38、圆、accent 底）。
///
/// [stops] 为真时它是**停止**键（运行中且没有草稿，照 Web 的 `primaryStops`）：
/// 同一颗纽子、同一个位置，图标从纸飞机换成停止方块 —— 用户在当前上下文中
/// 唯一要做的那件事就是它，不另加一颗钮。
class _SendButton extends StatelessWidget {
  const _SendButton({
    super.key,
    required this.enabled,
    required this.sending,
    required this.onPressed,
    this.stops = false,
    this.tooltip,
  });

  final bool enabled;
  final bool sending;

  /// 这一按是"停止"而不是"发送"。
  final bool stops;

  /// 无障碍名（发送 / 排队发送 / 插话发送 / 停止）。
  final String? tooltip;

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
      width: 38,
      height: 38,
      child: Material(
        // 停止键用告警底：它是"打断一次正在跑的轮次"，与普通发送区分开。
        color: enabled
            ? (stops ? DshColors.roleTool : DshColors.accentBlue)
            : DshColors.layer2,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onPressed : null,
          child: Center(
            child: sending
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: DshColors.onAccent,
                    ),
                  )
                : DshIcon(
                    stops ? 'stopFill' : 'paperPlane',
                    size: 18,
                    color: enabled
                        ? DshColors.onAccent
                        : DshColors.labelTertiary,
                  ),
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// 统计条（`.stats`：在输入卡片**下方**）。
///
/// 三项（照 Web 的 composer dock，`ui-conversation/src/client/skeleton/InputBar.tsx:520-525`：
/// `conversation.composer.dock` 槽 = 排队条 + 统计 pill + ContextMeter）：
/// `⏱ 第 N 轮 · M 步 · X tok/s` / `🗄 302K tok · 缓存命中 96%` / `◔ 96%`。
/// 每项可点（弹 sheet）。
///
/// ## 布局为什么是 `Wrap` 不是 `Row`（2026-10-17 真机反馈）
///
/// 三项的宽度都随数字变：轮次从 1 到十几、token 从 3 位到 4 位、
/// 百分比从 1 位到 3 位。`Row` 在总宽超屏时**把末项整块裁掉**
/// （release 里没有溢出条纹，只是看不见）—— 真机上"上下文百分比不显示"
/// 正是这么来的：前两项一长，第三项被挤出屏幕。
/// `Wrap` 放不下就换行，没有"被藏起来的读数"。
class DshStatsBar extends StatelessWidget {
  const DshStatsBar({
    super.key,
    this.turnText,
    this.usageText,
    this.contextPercent,
    this.onTapTurn,
    this.onTapUsage,
    this.onTapContext,
  });

  final String? turnText;
  final String? usageText;

  /// 上下文占用百分比（0~100）；`null` = 不显示。
  final int? contextPercent;

  final VoidCallback? onTapTurn;
  final VoidCallback? onTapUsage;
  final VoidCallback? onTapContext;

  @override
  Widget build(BuildContext context) {
    if (turnText == null && usageText == null && contextPercent == null) {
      // 三项都没有时**整条不显示** —— 空条会白占一行高度。
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 2, 0),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          if (turnText != null)
            _StatChip(icon: 'gauge', text: turnText!, onTap: onTapTurn),
          if (usageText != null) ...[
            _StatChip(icon: 'database', text: usageText!, onTap: onTapUsage),
          ],
          if (contextPercent != null)
            _StatChip(
              leading: _ContextRing(percent: contextPercent!),
              text: '$contextPercent%',
              onTap: onTapContext,
            ),
        ],
      ),
    );
  }
}

/// 上下文占用小环（照 Web `ContextMeter.tsx:119-129`：14px 环 + 百分比）。
///
/// 底色是轨道，前景弧长按百分比走 —— 它是"还有多少余量"的一眼线索，
/// 纯文字百分比给不出这个。
class _ContextRing extends StatelessWidget {
  const _ContextRing({required this.percent});

  final int percent;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 13,
      height: 13,
      child: CustomPaint(
        painter: _RingPainter(
          fraction: (percent.clamp(0, 100)) / 100,
          track: DshColors.layer3,
          fill: DshColors.roleContext,
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.fraction,
    required this.track,
    required this.fill,
  });

  final double fraction;
  final Color track;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.16;
    final rect = Rect.fromLTWH(
      stroke / 2,
      stroke / 2,
      size.width - stroke,
      size.height - stroke,
    );
    final trackPaint = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawArc(rect, 0, 3.141592653589793 * 2, false, trackPaint);
    if (fraction <= 0) return;
    final fillPaint = Paint()
      ..color = fill
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    // 从 12 点方向开始顺时针（照 Web 的 `rotate(-90 7 7)`）。
    canvas.drawArc(
      rect,
      -3.141592653589793 / 2,
      3.141592653589793 * 2 * fraction,
      false,
      fillPaint,
    );
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.fraction != fraction ||
      oldDelegate.track != track ||
      oldDelegate.fill != fill;
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.text, this.icon, this.leading, this.onTap});

  final String text;

  /// 图标名（走 `DshIcon`）；与 [leading] 二选一。
  final String? icon;

  /// 自绘前导（上下文环）；与 [icon] 二选一。
  final Widget? leading;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final iconName = icon;
    return Material(
      color: DshColors.layer1,
      borderRadius: BorderRadius.circular(999),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (iconName != null) ...[
                DshIcon(iconName, size: 12, color: DshColors.labelCaption),
                const SizedBox(width: 4),
              ],
              if (leading != null) ...[leading!, const SizedBox(width: 4)],
              // **可压缩是最后防线**：`Wrap` 已经保证"放不下就换行"，
              // 而系统大字缩放 / 超长文本仍可能让单项超过屏宽 ——
              // 那时省略号比溢出裁切好（溢出在 release 里是静默看不见）。
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  // **11px**：这三项的数字都会变宽（四位数 token、三位数
                  // 百分比、十几轮），字号大一点就把同行挤爆。
                  style: const TextStyle(
                    fontSize: 11,
                    color: DshColors.labelCaption,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
