/// 轨迹页（手机形态）：**一轮一行 + 用时迷你条**。
///
/// 规格与数据来源见 `docs/subsystems/trajectory-page.md`。
///
/// Note: 为什么没有甘特与「调用」明细（以及被否的三个方案）——
/// 见 `.agents/notes/implemented/2026-10-22-trajectory-turns-only-and-duration-bars.md`。
///
/// ## 它显示什么
///
/// | 这一格 | 来源 |
/// |---|---|
/// | `第 N 轮` | `turnOutline` 投影（`session.projections`，契约 §5.7） |
/// | 用时 | `turn/end.time - turn/start.time`，落在 `TurnProcessItem.elapsedMs` |
/// | 迷你条 | 该轮用时 / 已加载轮里的最长用时（真比例，不编） |
/// | 提问 / 结果 | `turnOutline` 的 `prompt` / `response` 预览（电脑侧已截断） |
/// | 计数 | `TurnProcessItem` 的消息 / 工具 / 子智能体数 |
///
/// ## 为什么没有甘特图
///
/// 时间轴要**每一步的起止**，而两处都不给：`turnOutline` 只有
/// `{turn, seq, prompt, response}`（`session-turn-outline/src/projection.ts:61-75`），
/// `sessionStats` 是会话级总量（`session-stats/src/projection.ts:72-81`）。
/// Web 的 Overview 用**客户端手里的事件时间**现算
/// （`ui-trajectory/src/client/timeline.ts:61-67`），手机的条目模型没保留每步起止 ——
/// 所以这一屏只画"每轮一条"，不画假甘特。判据与缺口见
/// `docs/subsystems/trajectory-page.md` §1。
///
/// ## 空态不造数据
///
/// `turns` 为 null / 空 = 空态。2026-10-15 之前这里有 `_sampleRows` /
/// `_sampleEntries` 兜底，而调用方从不传真数据 —— 于是轨迹页常驻假数据，
/// 用户无法分辨。假轨迹与真轨迹长得一模一样，所以"没有"必须显示成"没有"。
library;

import 'package:flutter/material.dart';

import '../model/chat_item.dart';
import '../model/turn_outline.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';

/// 轨迹页里的一轮（**显示用的形状**：该算的都算好了，widget 只画）。
class TraceTurn {
  const TraceTurn({
    required this.turn,
    required this.prompt,
    required this.response,
    this.elapsedMs,
    this.messageCount = 0,
    this.toolCallCount = 0,
    this.subagentCount = 0,
    this.failed = false,
    this.stopped = false,
    this.barFraction,
  });

  /// 第几轮。
  final int turn;

  /// 用户那句的预览（可能为空串）。
  final String prompt;

  /// 助手回复的预览（可能为空串）。
  final String response;

  /// 这一轮用了多久（毫秒）。
  ///
  /// `null` = 这一轮**没有** `TurnProcessItem`（`turn/end` 都不在手机窗口里，
  /// 比如更早的历史还没翻到）。`0` = 有它但算不出差（`turn/start` 在窗口外，
  /// 或者真的不到 1 秒）—— 两者在 [timeLabel] 里给不同的话。
  final int? elapsedMs;

  final int messageCount;
  final int toolCallCount;
  final int subagentCount;

  /// 这一轮是失败收尾的（`reason.kind == 'error'`）。
  final bool failed;

  /// 这一轮被中止/中断（`aborted` / `interrupted`）。
  final bool stopped;

  /// 迷你条占比（0.02~1）。`null` = 不画条（没有可信的用时）。
  final double? barFraction;

  /// 用时那一格的字。
  ///
  /// 失败 / 停止**替换掉用时**（DSH 的 `TurnProcessNodeView.tsx:24-30` 同一条），
  /// 因为"这一轮没跑完"比"跑了多久"重要。
  String get timeLabel {
    if (failed) return '失败';
    if (stopped) return '已停止';
    if (elapsedMs == null) return '用时未加载';
    return formatElapsedMs(elapsedMs!);
  }

  /// 计数那一行：`12 条消息 · 8 次工具 · 1 个子智能体`。
  ///
  /// **各项为 0 不列**（与 `TurnProcessItem.stats` 同一条）：一个刚起就被取消的
  /// 轮次不该摆一串 0。全为 0 时返回空串，行里就不画这一行。
  String get countsLabel {
    final parts = <String>[
      if (messageCount > 0) '$messageCount 条消息',
      if (toolCallCount > 0) '$toolCallCount 次工具',
      if (subagentCount > 0) '$subagentCount 个子智能体',
    ];
    return parts.join(' · ');
  }

  /// 迷你条的颜色：正常 = 助手紫、失败 = 红、停止 = 琥珀。
  Color barColor(DshColorTokens c) {
    if (failed) return c.error;
    if (stopped) return c.roleTool;
    return c.roleAssistant;
  }
}

/// 把 `turnOutline` 与本会话的条目合成轨迹页的行。
///
/// **join 键是轮次号**：`TurnProcessItem.turn` 与 `TurnOutlineEntry.turn`
/// 是同一个 DSH 的轮次号（两边都来自 `turn/start` 的 payload）。
///
/// 迷你条的分母是"已加载轮里的最长用时" —— 用会话总时长当分母的话，
/// 一个 3 秒的轮在 8 分钟的会话里会短到看不见，而"这一轮相对其他轮慢不慢"
/// 正是这条要回答的问题。
List<TraceTurn> buildTraceTurns({
  required List<TurnOutlineEntry> outline,
  required List<ChatItem> items,
}) {
  final processes = <int, TurnProcessItem>{};
  for (final item in items) {
    if (item is TurnProcessItem) processes[item.turn] = item;
  }
  var longest = 0;
  for (final process in processes.values) {
    if (process.elapsedMs > longest) longest = process.elapsedMs;
  }
  final out = <TraceTurn>[];
  for (final entry in outline) {
    final process = processes[entry.turn];
    final elapsed = process?.elapsedMs;
    out.add(
      TraceTurn(
        turn: entry.turn,
        prompt: entry.prompt,
        response: entry.response,
        elapsedMs: elapsed,
        messageCount: process?.messageCount ?? 0,
        toolCallCount: process?.toolCallCount ?? 0,
        subagentCount: process?.subagentCount ?? 0,
        failed: process?.failed ?? false,
        stopped: process?.stopped ?? false,
        // 没有可信用时就不画条：0 长度的空轨等于说"这一轮没花时间"。
        barFraction: (elapsed == null || elapsed <= 0 || longest <= 0)
            ? null
            // 最短 2%：1px 的条看不出"有数据"。
            : (elapsed / longest).clamp(0.02, 1.0),
      ),
    );
  }
  return out;
}

/// 顶部汇总：`共 12 轮 · 已知用时 8 分 12 秒（3 轮未加载）`。
///
/// 有未加载的轮时**必须带括号说明有几轮** —— 否则"已知用时"会被读成
/// 全会话总时长，而那不是这个数。
String traceSummaryLabel(List<TraceTurn> turns) {
  if (turns.isEmpty) return '';
  final loaded = turns.where((t) => t.elapsedMs != null).toList();
  final total = loaded.fold<int>(0, (sum, t) => sum + (t.elapsedMs ?? 0));
  final missing = turns.length - loaded.length;
  final head = '共 ${turns.length} 轮';
  if (loaded.isEmpty) return '$head · 用时未加载';
  if (missing == 0) return '$head · 用时 ${formatElapsedMs(total)}';
  return '$head · 已知用时 ${formatElapsedMs(total)}（$missing 轮未加载）';
}

/// 轨迹页。
///
/// ## 为什么是 `StatefulWidget`
///
/// 只有一件事要状态：**首次布局后滚到末尾**（"打开就落在最新一轮"）。
/// 用 `reverse: true` 也能锚在底部，但那一招在**行数少**时会把内容顶到屏幕
/// 下半截、上面留一大片空白（真机 2026-10-22 截图上是一屏半的空洞）。
/// 所以顺序照旧（轮次升序），只在内容溢出时滚到底 —— 与 DSH Web 的
/// "打开时定位于当前尾部"同一条。
class TrajectoryTab extends StatefulWidget {
  const TrajectoryTab({super.key, this.turns, this.onTapTurn});

  /// 轮次行；`null` / 空 = 空态（不造假的）。
  final List<TraceTurn>? turns;

  /// 点一行的回调（弹 `sheet-traj`）。
  final void Function(TraceTurn turn)? onTapTurn;

  @override
  State<TrajectoryTab> createState() => _TrajectoryTabState();
}

class _TrajectoryTabState extends State<TrajectoryTab> {
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // 数据是同步给的（来自投影），所以首帧之后就能算出该滚到哪。
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToTail());
  }

  @override
  void didUpdateWidget(covariant TrajectoryTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 行数变了（新的一轮来了）再锚一次：用户正往上翻时不打断 ——
    // 判据是"是否已经在末尾附近"。
    if ((oldWidget.turns?.length ?? 0) != (widget.turns?.length ?? 0)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToTail());
    }
  }

  void _jumpToTail() {
    if (!mounted || !_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    if (max <= 0) return;
    // 已经贴着末尾（或用户自己滚到了末尾）就不动。
    if ((_scroll.offset - max).abs() < 8) return;
    _scroll.jumpTo(max);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final rows = widget.turns ?? const [];
    final onTapTurn = widget.onTapTurn;
    if (rows.isEmpty) return const _EmptyTrajectory();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Text(
            traceSummaryLabel(rows),
            style: TextStyle(fontSize: 11, color: c.labelCaption),
          ),
        ),
        Expanded(
          // 轮次升序（`turnOutline` 给的顺序），视口由 [_jumpToTail] 锚到末尾。
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.only(bottom: 8),
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final turn = rows[index];
              return _TurnRow(
                turn: turn,
                onTap: onTapTurn == null ? null : () => onTapTurn(turn),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 一轮一行。
class _TurnRow extends StatelessWidget {
  const _TurnRow({required this.turn, this.onTap});

  final TraceTurn turn;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final counts = turn.countsLabel;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: c.layer1)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '第 ${turn.turn} 轮',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: c.labelPrimary,
                    ),
                  ),
                  const Spacer(),
                  // 用时靠右（与 DSH 的 turn-tail 同一位置感）。
                  Text(
                    turn.timeLabel,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: c.labelCaption,
                    ),
                  ),
                  const SizedBox(width: 4),
                  DshIcon('chevronRight', size: 16, color: c.labelTertiary),
                ],
              ),
              if (turn.barFraction != null)
                Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: _MiniBar(
                    fraction: turn.barFraction!,
                    color: turn.barColor(c),
                  ),
                ),
              if (turn.prompt.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: Text(
                    '提问：${turn.prompt}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: c.labelCaption),
                  ),
                ),
              if (turn.response.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '结果：${turn.response}',
                    // 与原型 `.lg .r2 { line-clamp:2 }` 同一个上限。
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 18 / 12.5,
                      color: c.labelTertiary,
                    ),
                  ),
                ),
              if (counts.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Text(
                    counts,
                    style: TextStyle(fontSize: 11, color: c.labelCaption),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 用时迷你条（4px 高）。
///
/// 用 `Row` + `Expanded(flex:)` 而不是 `LayoutBuilder`：比例是**整数 flex**，
/// 于是"这条有多长"可以直接从 widget 树读出来断言（widget 测试不需要量像素）。
class _MiniBar extends StatelessWidget {
  const _MiniBar({required this.fraction, required this.color});

  /// 0.02~1。
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final filled = (fraction.clamp(0.0, 1.0) * 1000).round();
    return SizedBox(
      height: 4,
      child: Row(
        children: [
          // `flex: 0` 的 `Expanded` 没有意义（也不该出现），所以两端都判一下。
          if (filled > 0)
            Expanded(
              flex: filled,
              child: Container(
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          if (filled < 1000)
            Expanded(
              flex: 1000 - filled,
              child: Container(
                decoration: BoxDecoration(
                  color: c.layer1,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 空态
//
// **没有示例数据兜底**（2026-10-15 删）。真数据通路是 `turnOutline` 投影
// （`session.projections`，契约 §5.7）；没接上之前说"还没接"，
// 不造一份假的 —— 假轨迹看起来和真轨迹一模一样，用户无法分辨。
// ---------------------------------------------------------------------------

/// 轨迹页的空态。
class _EmptyTrajectory extends StatelessWidget {
  const _EmptyTrajectory();

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            DshIcon('gauge', size: 40, color: c.labelTertiary),
            const SizedBox(height: 16),
            Text(
              '还没有轨迹',
              style: TextStyle(fontSize: 15, color: c.labelSecondary),
            ),
            const SizedBox(height: 8),
            Text(
              '电脑侧跑完一轮后，这里会显示每一轮的提问、结果与用时。\n'
              '数据来自会话投影 turnOutline 与这一轮的事件。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: c.labelTertiary),
            ),
          ],
        ),
      ),
    );
  }
}
