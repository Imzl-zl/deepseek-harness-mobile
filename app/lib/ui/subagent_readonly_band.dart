/// 子会话的**只读状态框**（替代输入栏）：一条横向的 54px 框。
///
/// 形状照 DSH 的 `SubagentReadOnlyComposer`
/// （`packages/client/ui-subagent/src/client/SubagentReadOnlyComposer.module.css:1-20`）：
///
/// ```css
/// .frame { display:flex; align-items:center; justify-content:center; gap:8px;
///          margin:0 24px 20px; min-height:54px; padding:10px 16px;
///          border:0.5px solid var(--dsw-alias-border-l4);
///          border-radius:var(--dsw-radius-lg); background:var(--dsw-alias-bg-layer-1);
///          color:var(--dsw-alias-label-tertiary); font-size:13px; line-height:20px }
/// .frame strong { color:var(--dsw-alias-label-primary); font-weight:510 }
/// ```
///
/// 文案逐字照 zh 词典（`ui-subagent/src/client/locales.ts:30,45-48`），
/// **不是我们发明的第二套说法**。
///
/// ## 两处有意偏离（触屏 / 槽位）
///
/// 1. **文字两行，不是一行**。Web 是 `strong` 与正文并排的 flex row ——
///    390dp 的屏上「一次性子智能体记录」+ 26 字的正文并排会**交错换行**
///    （标题和正文在同一行里各折各的，读起来是断的）。所以框还是那个框
///    （54 高、l4 发丝边、layer-1 底、13/20），但内部改成**标题一行、正文一行**。
/// 2. **左右边距 8，不是 24**：这一块**顶替输入栏卡片**，而卡片外边距就是 8
///    （`dsh_composer.dart` 的 `EdgeInsets.fromLTRB(8, 6, 8, 6)`）。
///    换 24 会让"输入栏消失"的那一瞬整块向内缩，读作布局跳动。
///
/// 因果见 `.agents/notes/implemented/2026-10-21-subagent-catalog-tree-and-state.md`。
library;

import 'package:flutter/material.dart';

import '../theme/dsh_colors.dart';
import '../theme/dsh_theme.dart';

/// 只读的原因 —— 与 DSH 的 `selectReadOnlySubagent` 一一对应
/// （`ui-subagent/src/client/index.ts:37-49`）。
///
/// **只有两档**：第三档 `parent-unavailable` 需要 `parentAvailable`
/// 这个字段，而它不在 `session.list` 里（见「仍未做的差异」）。
/// 不猜，所以这里没有第三个值。
enum SubagentReadOnlyReason {
  /// 一次性子智能体：记录可看，不能续聊。
  oneShot,

  /// 模式未知：读完子会话才知道能不能继续。
  unknown;

  /// 标题（Web 的 `strong`）。**文案只在这一处**：只读框与发送门槛
  /// （`data/composer_gate.dart` 的句子）都读它，分两处写就会漂。
  String get title => switch (this) {
    SubagentReadOnlyReason.oneShot => '一次性子智能体记录',
    SubagentReadOnlyReason.unknown => '此子智能体暂时只读',
  };

  /// 正文。
  String get body => switch (this) {
    SubagentReadOnlyReason.oneShot => '一次性任务不支持后续消息，可在这里查看完整执行记录。',
    SubagentReadOnlyReason.unknown => '读取子会话后才能确定是否可继续。',
  };
}

/// 一条只读说明。
class SubagentReadOnlyBand extends StatelessWidget {
  const SubagentReadOnlyBand({super.key, required this.reason});

  final SubagentReadOnlyReason reason;

  /// 标题（Web 的 `strong`）—— 文案在枚举上（唯一一处）。
  String get title => reason.title;

  /// 正文。
  String get body => reason.body;

  /// 框的最小高度（Web `min-height:54px`）。
  static const double minHeight = 54;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Container(
      // 与输入栏卡片同一个槽位（左右 8 / 上下 6），见文件头。
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      constraints: const BoxConstraints(minHeight: minHeight),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: c.layer1,
        borderRadius: BorderRadius.circular(DshRadius.lg),
        // 0.5px 的 l4 发丝边（`SubagentReadOnlyComposer.module.css:9`）。
        border: Border.all(color: c.borderL4, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              height: 20 / 13,
              // `strong` 是 primary + 510；Flutter 的档位只到百位，取 w500。
              fontWeight: FontWeight.w500,
              color: c.labelPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            body,
            style: TextStyle(
              fontSize: 13,
              height: 20 / 13,
              color: c.labelTertiary,
            ),
          ),
        ],
      ),
    );
  }
}
