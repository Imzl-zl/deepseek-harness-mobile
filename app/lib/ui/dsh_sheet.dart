/// 底部 sheet 体系（照 `mock/proto` 的 `openSheet` 与 `sheet-*` action）。
///
/// ## 原型的 sheet 有哪些（`app.js` 的 action 表）
///
/// | action | 标题 | 内容 |
/// |---|---|---|
/// | `sheet-stats` | 会话统计 | 模型用时 / 工具用时 / TTFT / 输出速度 / 轮次·步数 |
/// | `sheet-usage` | Token 用量 | 缓存命中 / 未缓存输入 / 缓存读取 / 写入 / 输出 / 合计 |
/// | `sheet-context` | 上下文已用 N% | **三段用量条** + 图例 + 已用/上限 |
/// | `sheet-traj` | 轨迹条目 | 角色 / 参数 / 耗时 / 结果 + 一个动作 |
/// | 模型选择 | 选模型 | `[名称 / 其下标签组] [勾位]`（§7.9） |
/// | 权限选择 | 访问模式 | 三档 + 风险确认门（§7.10） |
/// | `＋` 菜单 | 添加 | 附件 / 工作区文件 / 新建终端 / 浏览器 / 后台任务 |
///
/// ## §7.9 的行结构是硬规则（不是审美）
///
/// `[名称 / 其下标签组] [勾位(恒占位)]`：
///
/// - **能力标签放名称下面第二行**，不做"和名称同行的第三列" ——
///   一旦同行，列宽互相牵制：勾一出现（或能力文字长短不一）就把邻列顶走。
///   那正是"选中哪个，`图片/纯文本` 那列就跟着挪"的成因。
/// - **勾位恒占位**（`flex: 0 0 16px`），不要"选中才渲染勾" ——
///   后者会让整行文字在选中瞬间横移。
///
/// 这两条在原型里有 `verify-picker.mjs` 断言（`nameRight`/`ckLeft` 切换前后不变）。
/// 这里的 [DshPickerRow] 是它们的落点。
library;

import 'package:flutter/material.dart';

import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';
import 'input_focus.dart';

/// 打开一个 DSH 风格的底部 sheet。
///
/// `showModalBottomSheet` 的包装：统一圆角、底色、拖拽把手与最大高度。
/// **不自己写动画** —— 它自带"从下往上滑入 + 遮罩渐显"，
/// 而那正是原型 `.tk` 的 `tkIn` 关键帧在做的事。
///
/// **开合两个方向都失焦**：sheet 是 `ModalRoute`，push 时它把自己设成 first focus
/// （`packages/flutter/lib/src/widgets/routes.dart:1169-1171`），pop 时框架又把焦点
/// 还给页面里上一次的焦点节点 —— 输入栏就在那儿，于是输入法自己弹出来。
/// 机制与真机证据见 `input_focus.dart`；这里只负责在开与关上各收一次。
Future<T?> showDshSheet<T>({
  required BuildContext context,
  required String title,
  required Widget body,
  List<Widget> actions = const [],
}) {
  final c = context.dshColors;
  return dismissInputFocusAround(
    () => showModalBottomSheet<T>(
      context: context,
      backgroundColor: c.layer1,
      // 顶部圆角 `--r-panel` = 28（原型 sheet 用面板圆角）。
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(DshRadius.panel),
        ),
      ),
      // 最多占 80% 高：留一截能看见背后的界面，让"这是浮层"成立。
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.8,
      ),
      builder: (context) =>
          _SheetFrame(title: title, actions: actions, child: body),
    ),
  );
}

class _SheetFrame extends StatelessWidget {
  const _SheetFrame({
    required this.title,
    required this.child,
    required this.actions,
  });

  final String title;
  final Widget child;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 拖拽把手（`sheet` 的视觉惯例 —— 它告诉用户"这层能往下拖关"）。
          Center(
            child: Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 8, bottom: 4),
              decoration: BoxDecoration(
                color: c.layer3,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: c.labelPrimary,
              ),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: child,
            ),
          ),
          if (actions.isNotEmpty)
            Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.layer2)),
              ),
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: Row(
                children: [
                  for (var i = 0; i < actions.length; i += 1) ...[
                    if (i > 0) const SizedBox(width: 10),
                    Expanded(child: actions[i]),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 一行"标签 · 值"（`.kv`）—— 三种统计 sheet 共用。
///
/// ## [multiline]：长文本必须换行（2026-10-22 真机溢出的根因）
///
/// 默认形态是 `Row(children: [Expanded(label), Text(value), unit?])` ——
/// 值那个 [Text] **没有约束**，于是长英文（比如一句 120 字符的回复预览）
/// 拿到自己的固有宽度，把 `Expanded` 的标签列压到 2 字宽（「结果」竖排），
/// 整行再往右溢出（真机截图：`RIGHT OVERFLOWED BY 474 PIXELS`）。
///
/// 约束给不出来的东西就别放在一行里：[multiline] 为真时改成**纵向块**
/// （标签一行、值下一行、按词换行）。默认 `false`，统计 / 用量那几张 sheet
/// 的值都是短数字，形态不变。
class DshKeyValue extends StatelessWidget {
  const DshKeyValue({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.multiline = false,
  });

  final String label;
  final String value;

  /// 单位（`s` / `ms` / `tok/s`）—— 比数值小一号、弱一档。
  final String? unit;

  /// 值太长、必须换行时用纵向块（见类文档）。**默认保持原来的一行形态**。
  final bool multiline;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final u = unit;
    if (multiline) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(fontSize: 13, color: c.labelSecondary),
            ),
            const SizedBox(height: 3),
            Text(
              value,
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                fontWeight: FontWeight.w500,
                color: c.labelPrimary,
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: c.labelSecondary),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: c.labelPrimary,
            ),
          ),
          if (u != null) ...[
            const SizedBox(width: 3),
            Text(u, style: TextStyle(fontSize: 11, color: c.labelCaption)),
          ],
        ],
      ),
    );
  }
}

/// 上下文用量条（`.meterbar`）+ 图例（`.legend`）。
///
/// 三段颜色来自 `DshColors` 的 `ctxSystem` / `ctxTools` / `ctxMessages`
/// —— 与 `design-and-tech-plan.md` §5.4 抽出的 token 一致。
class DshContextMeter extends StatelessWidget {
  const DshContextMeter({
    super.key,
    required this.systemTokens,
    required this.toolTokens,
    required this.messageTokens,
    required this.limitTokens,
  });

  /// 系统提示词占的 token。
  final int systemTokens;

  /// 工具定义占的 token。
  final int toolTokens;

  /// 对话消息占的 token。
  final int messageTokens;

  /// 上限。
  final int limitTokens;

  /// 用了多少（三段之和）。
  int get usedTokens => systemTokens + toolTokens + messageTokens;

  /// 用了百分之几（四舍五入）。
  int get percent =>
      limitTokens == 0 ? 0 : (usedTokens * 100 / limitTokens).round();

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    // 三段各占"上限"的比例 —— **按上限算而不是按已用算**：
    // 这样空着的部分是可见的（用户要看的正是"还剩多少"）。
    double frac(int tokens) => limitTokens == 0 ? 0 : tokens / limitTokens;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // `.meterbar`：高 8、圆角 4、三段并排。
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 8,
            child: Row(
              children: [
                if (systemTokens > 0)
                  Expanded(
                    flex: (frac(systemTokens) * 1000).round(),
                    child: ColoredBox(color: c.ctxSystem),
                  ),
                if (toolTokens > 0)
                  Expanded(
                    flex: (frac(toolTokens) * 1000).round(),
                    child: ColoredBox(color: c.ctxTools),
                  ),
                if (messageTokens > 0)
                  Expanded(
                    flex: (frac(messageTokens) * 1000).round(),
                    child: ColoredBox(color: c.ctxMessages),
                  ),
                // 剩下的空格子：留一个弹性填充，把已用部分挤到左边。
                Expanded(
                  flex: ((1 - frac(usedTokens)) * 1000).round().clamp(1, 1000),
                  child: ColoredBox(color: c.layer3),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _LegendRow(color: c.ctxSystem, label: '系统提示词', tokens: systemTokens),
        _LegendRow(color: c.ctxTools, label: '工具定义', tokens: toolTokens),
        _LegendRow(color: c.ctxMessages, label: '对话消息', tokens: messageTokens),
        Divider(height: 20, color: c.layer2),
        DshKeyValue(
          label: '已用 / 上限',
          value: '${_short(usedTokens)} / ${_short(limitTokens)}',
        ),
      ],
    );
  }

  /// `12345` → `12.3K`（照原型的 `19.9K / 1M` 写法）。
  static String _short(int tokens) {
    if (tokens >= 1000000) {
      final m = tokens / 1000000;
      return m == m.roundToDouble()
          ? '${m.round()}M'
          : '${m.toStringAsFixed(1)}M';
    }
    if (tokens >= 1000) return '${(tokens / 1000).toStringAsFixed(1)}K';
    return '$tokens';
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.color,
    required this.label,
    required this.tokens,
  });

  final Color color;
  final String label;
  final int tokens;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: c.labelSecondary),
            ),
          ),
          Text(
            DshContextMeter._short(tokens),
            style: TextStyle(fontSize: 12, color: c.labelCaption),
          ),
        ],
      ),
    );
  }
}

/// 选择类列表的一行 —— **§7.9 的硬规则落点**。
///
/// 结构：`[名称 / 其下标签组] [勾位(恒占位)]`。
///
/// ## 两条"别自己发明第三列"的具体做法
///
/// 1. **能力标签在名称下面**（`Column` 的第二行），不做同行第三列 ——
///    同行时列宽互相牵制：勾一出现、或某行的标签文字长一点，
///    就把名称列顶窄，于是**选中哪个，所有行都跟着挪**。
/// 2. **勾位恒占位**：不管选中与否都占那 16px。用 `Visibility` 而不是
///    `if (selected)` —— 后者会让名称的可用宽度在选中瞬间变化。
class DshPickerRow extends StatelessWidget {
  const DshPickerRow({
    super.key,
    required this.name,
    required this.selected,
    required this.onTap,
    this.tags = const [],
    this.icon,
    this.trailing,
    this.enabled = true,
  });

  /// 名称（占满剩余宽度）。
  final String name;

  /// 能力标签（**排一行**在名称下面；空则不留第二行）。
  final List<String> tags;

  final bool selected;
  final VoidCallback onTap;

  /// 可选的前置图标。
  final String? icon;

  /// 右侧勾位**之后**的额外内容（比如"需在电脑上编辑"的注记）。
  final Widget? trailing;

  /// 这一行能不能选。`false` 时置灰且点不动 —— 用于"这个选项此刻不成立"
  /// （如插话只在会话正在跑时可选），而不是靠 onTap 里再报错。
  final bool enabled;

  /// 禁用行的空动作（[InkWell] 的 onTap 非空；置灰由 opacity 表达）。
  static void _noop() {}

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final iconName = icon;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: InkWell(
        onTap: enabled ? onTap : _noop,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 11),
          child: Row(
            children: [
              if (iconName != null) ...[
                DshIcon(iconName, size: 18, color: c.labelSecondary),
                const SizedBox(width: 10),
              ],
              // 名称 + 其下标签组（**第二行**，不是第三列）。
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, color: c.labelPrimary),
                    ),
                    if (tags.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [for (final tag in tags) _Tag(tag)],
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
              const SizedBox(width: 10),
              // 勾位**恒占位**（`flex: 0 0 16px`）——
              // 用 `Visibility(maintainSize:)` 而不是 `if (selected)`。
              SizedBox(
                width: 16,
                child: Visibility(
                  visible: selected,
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: DshIcon('check', size: 16, color: c.accentBlue),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 能力标签（`ModelTypeTag` 那一类的小胶囊）。
class _Tag extends StatelessWidget {
  const _Tag(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: c.layer2,
        borderRadius: BorderRadius.circular(DshRadius.xs),
      ),
      child: Text(text, style: TextStyle(fontSize: 11, color: c.labelCaption)),
    );
  }
}

/// sheet 上的一个动作按钮（`.btn--out` / `.btn--fill`）。
class DshSheetAction extends StatelessWidget {
  const DshSheetAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.filled = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Material(
      color: filled ? c.accentBlue : Colors.transparent,
      borderRadius: BorderRadius.circular(DshRadius.md),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Container(
          height: 44,
          alignment: Alignment.center,
          decoration: filled
              ? null
              : BoxDecoration(
                  borderRadius: BorderRadius.circular(DshRadius.md),
                  border: Border.all(color: c.layer3),
                ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: filled ? c.onAccent : c.labelPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
