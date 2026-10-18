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

/// 普通会话的输入框占位符。
///
/// **照抄 DSH 原文**（`packages/client/ui-conversation/src/client/locales.ts:20`
/// 的 `placeholder.default`）：半角逗号 + 空格（`任务, / 调用`），不是全角逗号。
/// 全角逗号更宽 —— 在 320px 屏上会让这段**更早折行**，
/// 而它本来就已接近放不下（实测 15px 需 345px、可用 282px）。
/// 文档 §7.2 写明"短屏由 CSS 自然折行，**不手动截断**"。
const String kComposerHintDefault = '发消息或创建任务, / 调用指令, @ 文件或对话';

/// **新会话页（hero）的占位符**，与普通会话只差前半句
/// （`locales.ts:23` 的 `placeholder.hero`）。
///
/// 两套文案都是半角逗号；DSH 在 hero 变体上把它换成"描述你想要构建的内容"，
/// 因为那一屏的动作是"开一个新任务"而不是"接着说"。
const String kComposerHintHero = '描述你想要构建的内容, / 调用指令, @ 文件或对话';

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
    required this.onRemoveAttachment,
    this.enabled = true,
    this.running = false,
    this.onStop,
    this.hintText = kComposerHintDefault,
  });

  /// 占位符。默认是普通会话那句；hero（blank 会话）传 [kComposerHintHero]。
  final String hintText;

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
  ///
  /// **只用于 tooltip 文字**（"排队发送 / 插话发送"）：改它的入口在设置页
  /// 「通用」，行控区那颗图标 2026-10-19 按用户要求移除（"设置中有，
  /// 这个也不经常更换设置，占位置"）。
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

  final void Function(PendingAttachment item) onRemoveAttachment;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final hasDraft = controller.text.trim().isNotEmpty;
    final canSend = enabled && !sending && hasDraft;
    // **主键在运行中且没有草稿时是"停止"**（Web 的 `primaryStops`）。
    final stops = running && !hasDraft && onStop != null;
    return Container(
      color: c.sidebar,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Container(
        // `.composer { padding:6px 6px 6px 8px; border-radius:24px }`
        padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
        decoration: BoxDecoration(
          color: c.layer1,
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
              style: TextStyle(fontSize: 15, color: c.labelPrimary),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: hintText,
                hintStyle: TextStyle(fontSize: 15, color: c.labelTertiary),
                contentPadding: const EdgeInsets.symmetric(
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
                      // 模型 chip：**图标 + 模型名**，可压缩、上限 62%。
                      //
                      // 上限不能省：`Flexible` 只表示"可以被压"，不表示"最宽多少" ——
                      // 没有上限时它会**吃满**左组剩余宽度（长模型名尤其明显），
                      // 而原型 `#chipModel { max-width: 62% }` 是明确写了上限的。
                      // 实测：`claude-opus · 高` 在 1080px 宽的屏上被拉成一整条，
                      // 看起来像"模型是个很宽的选择器"，与胶囊形态不符。
                      //
                      // **图标 + 名字而不是裸名字**（照 rikkahub 的
                      // `ModelSelectorButton(onlyIcon = true)`，`ChatInput.kt:309-313`）：
                      // 真机上模型名是 `step-5-preview · max` 这种 20+ 字符的 id，
                      // 光靠文字就把左组吃掉一半；加一枚图标让"这是模型选择器"
                      // 在名字被省略号截掉之后仍然认得出。推理等级跟在名字后面
                      // （`· max`），它是同一个选择的第二半。
                      //
                      // 图标取 `database`：DSH Web 的模型触发器用的就是它
                      // （`ui-model-selection/src/client/ModelSelect.tsx:484` 的
                      // `IconDataOutlineRegular`，抽取进我们图标集时叫 `database`）。
                      // **不新造字形**：`verify-icons.cjs` 只放行集合内的 100 个。
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
                                DshIcon(
                                  'database',
                                  size: 13,
                                  color: c.labelSecondary,
                                ),
                                const SizedBox(width: 5),
                                Flexible(
                                  child: Text(
                                    modelName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: c.labelPrimary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '· $reasoningLabel',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: c.labelCaption,
                                  ),
                                ),
                                const SizedBox(width: 2),
                                DshIcon(
                                  'chevronDown',
                                  size: 12,
                                  color: c.labelCaption,
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
                      // **「忙时发送」图标已移除**（2026-10-19，用户原话
                      // "输入框下的忙时发送行为没必要吧，设置中有，这个也不经常
                      // 更换设置，占位置"）：它是**装完就不动的偏好**，而设置页
                      // 「通用」里一直有同一选择（`settings_page.dart` 的发送模式行）。
                      // 运行时要改也有出路：发送键在 running 且没草稿时是**停止**键，
                      // 有草稿时 tooltip 直接说"排队发送 / 插话发送"——
                      // 当前模式看得见，不必再占一颗 34px 的图标位。
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
                  // tooltip 里带当前发送模式（排队 / 插话）：**模式只在设置页改**，
                  // 而行控区那颗图标已移除（2026-10-19，用户原话"设置中有，
                  // 不经常更换，占位置"）。长按/无障碍时用户仍要知道这句话会怎样，
                  // 而 tooltip 是它唯一的出口。
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
    final c = context.dshColors;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      decoration: BoxDecoration(
        color: c.layer2,
        borderRadius: BorderRadius.circular(DshRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DshIcon(item.icon, size: 13, color: c.labelSecondary),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: c.labelSecondary),
            ),
          ),
          const SizedBox(width: 2),
          GestureDetector(
            onTap: onRemove,
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: DshIcon('closeFill', size: 12, color: c.labelTertiary),
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
    final c = context.dshColors;
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
              color: onPressed == null ? c.labelTertiary : c.labelSecondary,
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
    final c = context.dshColors;
    return Material(
      color: c.layer2,
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
    final c = context.dshColors;
    final chip = Material(
      // 危险档用告警底（`.chip--icon.is-warn { background: var(--warn-bg) }`）。
      color: isWarn ? c.roleToolBg : c.layer2,
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
              color: isWarn ? c.roleTool : c.labelSecondary,
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
    final c = context.dshColors;
    final button = SizedBox(
      width: 38,
      height: 38,
      child: Material(
        // 停止键用告警底：它是"打断一次正在跑的轮次"，与普通发送区分开。
        color: enabled ? (stops ? c.roleTool : c.accentBlue) : c.layer2,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? onPressed : null,
          child: Center(
            child: sending
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: c.onAccent,
                    ),
                  )
                : DshIcon(
                    stops ? 'stopFill' : 'paperPlane',
                    size: 18,
                    color: enabled ? c.onAccent : c.labelTertiary,
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
/// `⏱ N 轮 M 步 · X tok/s` / `🗄 302K tok · 缓存命中 96%` / `◔ 96%`。
/// 每项可点（弹 sheet）。
///
/// ## 布局：**单行 + 横向滚动**（2026-10-17 用户定案）
///
/// 三项的宽度都随数字变：轮次从 1 到十几、token 从 3 位到 4 位、
/// 百分比从 1 位到 3 位。真机（1080×2400 @420dpi = **411.4dp**）实测三项合计
/// **632.6dp**，而可用宽度只有 **391.4dp** —— 差 237dp。
///
/// 走过的两条路都不对：
/// - `Row`（无滚动）：超屏时把末项**整块裁掉**（release 里没有溢出条纹，
///   只是看不见）—— 真机"上下文百分比不显示"就是这么来的；
/// - `Wrap`：放不下就换行，但**哪一项掉到第二行随数字漂**，同一条统计条
///   时高时低，看着像布局坏了。
///
/// 横滚与前者不同：读数**滑得到**，不是被裁掉。代价是"没滑之前看不全"，
/// 这是用户明确接受的取舍。取舍见
/// `.agents/notes/implemented/2026-10-17-topbar-single-row-and-stats-scroll.md`。
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

  /// 相邻两枚 chip 之间的距离。
  static const double _gap = 6;

  @override
  Widget build(BuildContext context) {
    if (turnText == null && usageText == null && contextPercent == null) {
      // 三项都没有时**整条不显示** —— 空条会白占一行高度。
      return const SizedBox.shrink();
    }
    final chips = <Widget>[
      if (turnText != null)
        _StatChip(icon: 'gauge', text: turnText!, onTap: onTapTurn),
      if (usageText != null)
        _StatChip(icon: 'database', text: usageText!, onTap: onTapUsage),
      if (contextPercent != null)
        _StatChip(
          leading: _ContextRing(percent: contextPercent!),
          text: '$contextPercent%',
          onTap: onTapContext,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 2, 0),
      // `SingleChildScrollView` 的 viewport 撑满可用宽度，于是整条**从左边起**排
      // （`Wrap` 会收缩到内容宽、再被外层 `Column` 居中，一枚 chip 时看着悬在中间）。
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        // **点击不受影响**：横滑由滚动的拖动识别器接管，原地按一下仍归 chip 的
        // `InkWell`（手势竞技场按"有没有移动"分派）。`stats_bar_layout_test.dart`
        // 用例真点一次钉住这条。
        child: Row(
          children: [
            for (var i = 0; i < chips.length; i += 1) ...[
              if (i > 0) const SizedBox(width: _gap),
              chips[i],
            ],
          ],
        ),
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
    final c = context.dshColors;
    return SizedBox(
      width: 13,
      height: 13,
      child: CustomPaint(
        painter: _RingPainter(
          fraction: (percent.clamp(0, 100)) / 100,
          track: c.layer3,
          fill: c.roleContext,
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
    final c = context.dshColors;
    final iconName = icon;
    return Material(
      color: c.layer1,
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
                DshIcon(iconName, size: 12, color: c.labelCaption),
                const SizedBox(width: 4),
              ],
              if (leading != null) ...[leading!, const SizedBox(width: 4)],
              // **不压缩**：横滚容器给的是**无界宽度**，`Flexible` 在这里会直接
              // 抛 `RenderFlex children have non-zero flex but incoming width
              // constraints are unbounded`；而"放不下"这件事已经归滚动管了 ——
              // 单项再长也只是多滑一点，不会被裁掉。
              Text(
                text,
                maxLines: 1,
                // **11px**：这三项的数字都会变宽（四位数 token、三位数
                // 百分比、十几轮），字号大一点就得多滑一下。
                style: TextStyle(fontSize: 11, color: c.labelCaption),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
