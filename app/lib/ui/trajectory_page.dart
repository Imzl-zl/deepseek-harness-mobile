/// 轨迹页（手机形态）：**一轮一行 + 真时间轴**。
///
/// 规格与数据来源见 `docs/subsystems/trajectory-page.md`。
///
/// Note: 上一版只有"每轮一条迷你条"（无甘特），以及被否的三个方案 ——
/// 见 `.agents/notes/implemented/2026-10-22-trajectory-turns-only-and-duration-bars.md`；
/// 这一版把时间轴做真的那份取舍见
/// `.agents/notes/implemented/2026-10-22-trajectory-timeline-from-host-projection.md`。
///
/// ## 它显示什么
///
/// | 这一格 | 来源 |
/// |---|---|
/// | `第 N 轮` | `turnOutline` 投影（`session.projections`，契约 §5.7） |
/// | 用时 | `trajectory` 投影的 `turn.durationMs`（**电脑侧算好**） |
/// | 时间轴 | `trajectory` 投影的 `steps`（`offsetMs` / `durationMs` 都是电脑侧给的） |
/// | 提问 / 结果 | `turnOutline` 的 `prompt` / `response` 预览（电脑侧已截断） |
/// | 计数 | `TurnProcessItem` 的消息 / 工具 / 子智能体数 |
///
/// ## 为什么这一版才画得出时间轴
///
/// 时间轴要**每一步的起止**。`turnOutline` 只有 `{turn, seq, prompt, response}`
/// （`session-turn-outline/src/projection.ts:61-75`），`sessionStats` 是会话级
/// 总量（`session-stats/src/projection.ts:72-81`）—— 两处都没有。
/// Web 用客户端手里的事件时间现算（`ui-trajectory/src/client/timeline.ts:61-67`），
/// 而手机的条目表是**分页**来的：`turn/start` 落在更早一页时那一轮连起点都没有。
/// 所以这一版把折叠搬到电脑侧的**完整日志**上（`connector/src/dsh/trajectory.ts`），
/// 手机只解析与画 —— 窗口外的轮也有时间轴，且**手机一个时间减法都不做**。
///
/// ## 空态不造数据
///
/// `turns` 为 null / 空 = 空态。2026-10-15 之前这里有 `_sampleRows` /
/// `_sampleEntries` 兜底，而调用方从不传真数据 —— 于是轨迹页常驻假数据，
/// 用户无法分辨。假轨迹与真轨迹长得一模一样，所以"没有"必须显示成"没有"。
library;

import 'package:flutter/material.dart';

import '../model/chat_item.dart';
import '../model/trajectory.dart';
import '../model/turn_outline.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import 'trajectory_timeline.dart';

/// 轨迹页里的一轮（**显示用的形状**：该算的都算好了，widget 只画）。
class TraceTurn {
  const TraceTurn({
    required this.turn,
    required this.prompt,
    required this.response,
    this.trajectory,
    this.messageCount = 0,
    this.toolCallCount = 0,
    this.subagentCount = 0,
    this.failed = false,
    this.stopped = false,
  });

  /// 第几轮。
  final int turn;

  /// 用户那句的预览（可能为空串）。
  final String prompt;

  /// 助手回复的预览（可能为空串）。
  final String response;

  /// 这一轮的时间轴（`trajectory` 投影里的一轮）。
  ///
  /// `null` = **电脑侧没给这一轮**（没注册投影 / 这一轮被上限截掉）。
  /// 界面上那时说"用时未知"且不画轴 —— 不补零、不估。
  final TrajectoryTurn? trajectory;

  /// 这一轮用了多久（毫秒）。**电脑侧算好的**，手机不做减法。
  int? get durationMs => trajectory?.durationMs;

  /// 这一轮还在跑（投影里没有 `endTime`）。
  bool get running => trajectory?.running ?? false;

  /// 这一轮的步数被上限截过（界面要说出来）。
  bool get stepsTruncated => trajectory?.stepsTruncated ?? false;

  final int messageCount;
  final int toolCallCount;
  final int subagentCount;

  /// 这一轮是失败收尾的（`reason.kind == 'error'`）。
  final bool failed;

  /// 这一轮被中止/中断（`aborted` / `interrupted`）。
  final bool stopped;

  /// 用时那一格的字。
  ///
  /// 失败 / 停止**替换掉用时**（DSH 的 `TurnProcessNodeView.tsx:24-30` 同一条），
  /// 因为"这一轮没跑完"比"跑了多久"重要。
  ///
  /// `用时未知` 与 `进行中` 是两句不同的话：前者是"电脑侧没给这一轮"，
  /// 后者是"给了，但它还没收口"（时间轴上只有起点标记）。
  String get timeLabel {
    if (failed) return '失败';
    if (stopped) return '已停止';
    if (running) return '进行中';
    final duration = durationMs;
    if (duration == null) return '用时未知';
    return formatElapsedMs(duration);
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
}

/// 把 `turnOutline`、`trajectory` 与本会话的条目合成轨迹页的行。
///
/// **join 键是轮次号**：`TurnProcessItem.turn`、`TrajectoryTurn.turn` 与
/// `TurnOutlineEntry.turn` 是同一个 DSH 的轮次号（三边都来自 `turn/start`）。
///
/// ## 行的来源是 `turnOutline`，不是 `trajectory`
///
/// `trajectory` 只保留最近 [MAX_TURNS] 轮（连接器 `MAX_TURNS = 200`），
/// 而 `turnOutline` 是 DSH 自己的轮次账本。用前者当行源会让"被上限截掉的
/// 老轮"整行消失，看起来像那一轮不存在；用后者当行源、前者只补时间轴，
/// 老轮就仍然是"用时未知"，这是两句不同的话。
///
List<TraceTurn> buildTraceTurns({
  required List<TurnOutlineEntry> outline,
  required List<ChatItem> items,
  TrajectoryView? trajectory,
}) {
  final processes = <int, TurnProcessItem>{};
  for (final item in items) {
    // 轮号可能缺席（老连接器 / 这一屏没读到 `turn/start`）：那种收口行
    // join 不上任何一行账本，**跳过它**，而不是拿 0 号去撞。
    if (item is TurnProcessItem && item.turn != null) {
      processes[item.turn!] = item;
    }
  }
  final out = <TraceTurn>[];
  for (final entry in outline) {
    final process = processes[entry.turn];
    final projected = trajectory?.turnOf(entry.turn);
    // 结局以投影为准（它是电脑侧折的完整日志），拿不到才退回条目上的那一位。
    final failed = projected == null
        ? (process?.failed ?? false)
        : projected.failed;
    final stopped = projected == null
        ? (process?.stopped ?? false)
        : projected.stopped;
    out.add(
      TraceTurn(
        turn: entry.turn,
        prompt: entry.prompt,
        response: entry.response,
        trajectory: projected,
        messageCount: process?.messageCount ?? 0,
        toolCallCount: process?.toolCallCount ?? 0,
        subagentCount: process?.subagentCount ?? 0,
        failed: failed,
        stopped: stopped,
      ),
    );
  }
  return out;
}

/// 时间轴被上限截过时的说明；没截过 = `null`。
///
/// 数字**只来自投影自报的字段**（`truncated` / `droppedTurns` / `droppedSteps`，
/// 连接器 `src/dsh/trajectory.ts`），这里不做任何推算。
String? trajectoryTruncationLabel(TrajectoryView? view) {
  if (view == null || !view.truncated) return null;
  final parts = <String>[];
  if (view.droppedTurns > 0) parts.add('${view.droppedTurns} 轮');
  if (view.droppedSteps > 0) parts.add('${view.droppedSteps} 步');
  final detail = parts.isEmpty ? '' : '（更早的 ${parts.join(' · ')} 没保留）';
  return '时间轴不全$detail：电脑侧只保留最近的若干轮与步。';
}

/// 顶部汇总：`共 12 轮 · 已知用时 8 分 12 秒（3 轮用时未知）`。
///
/// 有拿不到的轮时**必须带括号说明有几轮** —— 否则"已知用时"会被读成
/// 全会话总时长，而那不是这个数。
///
/// **进行中的轮不计入总数**（它的时长还没算出来），单独说"1 轮进行中"：
/// 把它算进"已知用时"就是把一个未完成的数当成了总数。
String traceSummaryLabel(List<TraceTurn> turns) {
  if (turns.isEmpty) return '';
  final known = turns.where((t) => !t.running && t.durationMs != null).toList();
  final total = known.fold<int>(0, (sum, t) => sum + (t.durationMs ?? 0));
  final running = turns.where((t) => t.running).length;
  final missing = turns.length - known.length - running;
  final head = '共 ${turns.length} 轮';
  final parts = <String>[];
  if (known.isNotEmpty) {
    parts.add(
      missing == 0
          ? '用时 ${formatElapsedMs(total)}'
          : '已知用时 ${formatElapsedMs(total)}',
    );
  }
  if (running > 0) parts.add('$running 轮进行中');
  if (missing > 0) parts.add('$missing 轮用时未知');
  if (parts.isEmpty) return '$head · 用时未知';
  return '$head · ${parts.join(' · ')}';
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
  const TrajectoryTab({
    super.key,
    this.turns,
    this.onTapTurn,
    this.onTapSegment,
    this.truncationLabel,
    this.timelineMissing = false,
  });

  /// 轮次行；`null` / 空 = 空态（不造假的）。
  final List<TraceTurn>? turns;

  /// 点一行的回调（弹 `sheet-traj`）。
  final void Function(TraceTurn turn)? onTapTurn;

  /// 点一格时间轴的回调（弹段的详情；参数是这一格里的段，可能多于一段）。
  final void Function(TraceTurn turn, List<TrajectoryStep> steps)? onTapSegment;

  /// 时间轴被上限截过的说明（`null` = 没截过）。
  ///
  /// **必须显示出来**：被截掉的轮与"这一轮本来就没有时间轴"在界面上长得
  /// 一模一样，不说就分不清（连接器 `MAX_TURNS` / `MAX_STEPS_TOTAL`）。
  final String? truncationLabel;

  /// 这台电脑**根本没给时间轴**（`trajectory` 这个键不在）。
  ///
  /// 与"给了但是空的"是两句不同的话：前者要用户去电脑侧找原因，
  /// 后者只是还没跑完一轮。
  final bool timelineMissing;

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
    final onTapSegment = widget.onTapSegment;
    if (rows.isEmpty) {
      return _EmptyTrajectory(timelineMissing: widget.timelineMissing);
    }
    final truncation = widget.truncationLabel;
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
        // 截断要明说：被截掉的轮与"本来就没有"在界面上同形。
        if (truncation != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Text(
              truncation,
              style: TextStyle(fontSize: 11, color: c.labelTertiary),
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
                onTapSegment: onTapSegment == null
                    ? null
                    : (steps) => onTapSegment(turn, steps),
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
  const _TurnRow({required this.turn, this.onTap, this.onTapSegment});

  final TraceTurn turn;
  final VoidCallback? onTap;
  final void Function(List<TrajectoryStep> steps)? onTapSegment;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final counts = turn.countsLabel;
    final trajectory = turn.trajectory;
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
              // **时间轴**：每轮一条，横向 = 这一轮的起止。
              // 电脑侧没给这一轮就整条不画 —— 空轨会被读成"这一轮没花时间"。
              if (trajectory != null && trajectory.steps.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: TrajectoryTimeline(
                    turn: trajectory,
                    onTapSegment: onTapSegment,
                  ),
                ),
              // 这一轮的步数被上限截过：说在行里，而不是让用户以为时间轴就是全部。
              if (turn.stepsTruncated)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '只画了最近的若干步（这一轮步数超过上限）',
                    style: TextStyle(fontSize: 11, color: c.labelCaption),
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
                      fontSize: 12,
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
// ---------------------------------------------------------------------------
// 空态
//
// **没有示例数据兜底**（2026-10-15 删）。真数据通路是 `turnOutline` + `trajectory`
// 两个投影（`session.projections`，契约 §5.7）；没接上之前说"还没接"，
// 不造一份假的 —— 假轨迹看起来和真轨迹一模一样，用户无法分辨。
// ---------------------------------------------------------------------------

/// 轨迹页的空态。
class _EmptyTrajectory extends StatelessWidget {
  const _EmptyTrajectory({this.timelineMissing = false});

  /// 这台电脑没给 `trajectory` 投影 —— 空态要说清是哪一种"没有"。
  final bool timelineMissing;

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
              timelineMissing
                  // 键缺席 = 这台电脑的连接器没注册 trajectory 投影。
                  // 与"跑完一轮就有了"是两句不同的话（一句要查电脑，一句只要等）。
                  ? '这台电脑没给时间轴：连接器没有注册 trajectory 投影，'
                        '升级电脑侧的连接器后才有每一步的起止。'
                  : '电脑侧跑完一轮后，这里会显示每一轮的提问、结果与时间轴。\n'
                        '用时与每一段的起止都由电脑侧算好随投影下发。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: c.labelTertiary),
            ),
          ],
        ),
      ),
    );
  }
}
