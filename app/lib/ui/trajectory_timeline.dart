/// 一轮的时间轴（横向 = 这一轮的起止，纵向 = 三条泳道）。
///
/// ## 几何全部来自电脑侧
///
/// 这一段唯一的算术是**除法**：位置 = `step.offsetMs / turn.durationMs`，
/// 长度 = `step.durationMs / turn.durationMs`。两个操作数都是连接器
/// （`connector/src/dsh/trajectory.ts`）算好的 —— 这里没有一次 epoch 相减，
/// 也没有一个"用时"是手机上推出来的。判据见 `model/trajectory.dart` 文件头。
///
/// ## 三条泳道照 DSH 的分法
///
/// `ui-trajectory/src/client/timeline.ts:51-55`：工具一条、消息（含压缩）
/// 一条、上下文一条。手机只落**模型 / 工具 / 压缩**三条里这一轮实际用到的
/// （没用的泳道不占高度），顺序固定，于是同一轮的两段永远不会互相压住。
///
/// ## 进行中的轮：只画起点标记
///
/// 这一轮没有 `endTime`（`durationMs` 也是 `null`）⇒ x 轴没有右端，
/// 任何"位置"都是编的。所以此时**不画比例**：按 seq 顺序等距摆**起点标记**，
/// 明确说"进行中"。等 `turn/end` 到了、投影重读之后才会变成真比例。
///
/// ## 过密的段合并（明写规则，不静默丢）
///
/// 窄屏上一轮可能有上百段，`offsetMs / durationMs` 落成像素后很多段不足
/// 1dp。规则（[layoutTimelineSegments]，可单测）：
///
/// 1. 任何一段画出来的宽度 < [kTimelineMinSegmentWidth]（3dp）算**过窄**；
/// 2. 同一条泳道上**连续**的过窄段合成一个**合并段**：左边界取第一段、
///    右边界取最后一段，宽度至少 [kTimelineMinSegmentWidth]；
/// 3. 合并段保住它全部的原始段（`TimelineSegment.steps`）—— 点它时
///    sheet 会把每一段都列出来，所以**一段都没丢**，只是画在了一格里；
/// 4. 颜色：合并段里有失败就是失败色，否则用第一段的类别色。
///
/// 规格见 `docs/subsystems/trajectory-page.md` §2。
library;

import 'package:flutter/material.dart';

import '../model/trajectory.dart';
import '../theme/dsh_colors.dart';

/// 单段最小可见宽度（逻辑像素）。比这窄的段看不出来，也点不着。
const double kTimelineMinSegmentWidth = 3;

/// 一条泳道的高度。
const double kTimelineLaneHeight = 6;

/// 泳道之间的间距。
const double kTimelineLaneGap = 3;

/// 一次点击的容差（逻辑像素）：段的左右各放宽这么多都算点中它。
const double kTimelineHitSlop = 4;

/// 时间轴上画出来的一格（可能是多个原始段合并来的）。
class TimelineSegment {
  const TimelineSegment({
    required this.left,
    required this.width,
    required this.lane,
    required this.steps,
  });

  /// 左边界（逻辑像素，相对轨道左端）。
  final double left;

  /// 宽度（逻辑像素，至少 [kTimelineMinSegmentWidth]）。
  final double width;

  /// 第几行（**紧凑后的**行号，从 0 开始且连续）。
  ///
  /// 不是 [laneOf] 的语义泳道号：这一轮没用到压缩时，工具段就在第 1 行，
  /// 而不是"第 2 行、上面留一个空行"。紧凑化由 [layoutTimelineSegments] 做，
  /// 于是"用了几条泳道"与"画多高"是同一个数（[timelineHeight]）。
  final int lane;

  /// 这一格代表的原始段：**至少一段**。多于一段 = 合并过。
  final List<TrajectoryStep> steps;

  /// 合并过（好几段挤在一格里）。
  bool get merged => steps.length > 1;

  /// 这一格的类别色：失败压过类别。
  ///
  /// 颜色读**段的类别**，不读行号 —— 行号是紧凑过的（见 [lane]），
  /// 拿它挑颜色会让工具段在没压缩的轮里变成压缩色。
  Color color(DshColorTokens c) {
    if (steps.any((step) => step.isError)) return c.error;
    return colorOf(steps.first.kind, c);
  }

  /// 这一格里有几段没结束（只有起点标记的那些）。
  bool get running => steps.any((step) => step.running);
}

/// 泳道号：模型 0 / 压缩 1 / 工具 2。
///
/// 固定顺序（不按出现先后重排）：同一轮里模型段永远在最上面，
/// 用户不需要每次重新认哪条是哪条。
int laneOf(TrajectoryStepKind kind) => switch (kind) {
  TrajectoryStepKind.assistant => 0,
  TrajectoryStepKind.compaction => 1,
  TrajectoryStepKind.tool => 2,
};

/// 一段的类别色（失败另算，见 [TimelineSegment.color]）。
Color colorOf(TrajectoryStepKind kind, DshColorTokens c) => switch (kind) {
  TrajectoryStepKind.tool => c.roleTool,
  TrajectoryStepKind.compaction => c.roleContext,
  TrajectoryStepKind.assistant => c.roleAssistant,
};

/// 时间轴要几像素高（这一轮实际用到几条泳道）。
double timelineHeight(Iterable<TrajectoryStep> steps) {
  final lanes = <int>{for (final step in steps) laneOf(step.kind)};
  if (lanes.isEmpty) return kTimelineLaneHeight;
  return lanes.length * kTimelineLaneHeight +
      (lanes.length - 1) * kTimelineLaneGap;
}

/// 把这一段按 `offsetMs` / `durationMs` 摊到 [width] 像素上。
///
/// 返回空表的情形（都不是错误，是"画不出来"）：
/// - `width <= 0`（还没布局）；
/// - 这一轮**没有可信的跨度**（`durationMs` 为 `null` 或 0）——
///   进行中的轮与"零长度的轮"同形，都由调用方改画起点标记；
/// - 这一轮一步都没有。
///
/// 合并规则见文件头第 2 节；**同一泳道、按时间升序**输出。
List<TimelineSegment> layoutTimelineSegments({
  required List<TrajectoryStep> steps,
  required int? turnDurationMs,
  required double width,
}) {
  final span = turnDurationMs;
  if (width <= 0 || span == null || span <= 0 || steps.isEmpty) {
    return const [];
  }
  // 三条泳道各自成行（`laneOf` 的固定顺序），泳道内按时间升序。
  //
  // 这一轮先按**原始宽度**摆（不钳），合并要拿原始宽度判"过窄"；
  // 钳位放在最后一步 —— 先钳再判会让每段都 ≥3dp，合并规则永远不触发。
  final byLane = <int, List<TimelineSegment>>{};
  for (final step in steps) {
    final segment = TimelineSegment(
      // 夹在轨道里：DSH 的日志理论上不会越界，越了也不该画到外面去。
      left: (width * step.offsetMs / span).clamp(0.0, width),
      // 还在跑的段只知道起点：宽度 0（"有个开头"），不编长度。
      width: step.durationMs == null ? 0.0 : width * step.durationMs! / span,
      lane: laneOf(step.kind),
      steps: <TrajectoryStep>[step],
    );
    byLane.putIfAbsent(segment.lane, () => <TimelineSegment>[]).add(segment);
  }
  final out = <TimelineSegment>[];
  // **紧凑化**：只给这一轮实际用到的泳道排行号（0,1,2…）。
  // 否则没用压缩的轮里工具段会被摆到第 2 行，而高度只有 1~2 行 —— 画到框外。
  for (final (row, lane) in (byLane.keys.toList()..sort()).indexed) {
    for (final segment in _mergeNarrow(byLane[lane]!, width)) {
      out.add(
        TimelineSegment(
          left: segment.left,
          // 最后一步才钳宽度：过窄的段至少看得见/点得着。
          width: segment.width.clamp(kTimelineMinSegmentWidth, width),
          lane: row,
          steps: segment.steps,
        ),
      );
    }
  }
  return out;
}

/// 一条泳道内：把**连续**的过窄段并成一格（规则见文件头）。
///
/// 入参的 `width` 是**原始宽度**（未钳位），返回值也可能是未钳位的
/// —— 钳位统一由调用方在最后一步做。
List<TimelineSegment> _mergeNarrow(List<TimelineSegment> lane, double width) {
  lane.sort((a, b) => a.left.compareTo(b.left));
  final out = <TimelineSegment>[];
  var run = <TimelineSegment>[];
  void flush() {
    if (run.isEmpty) return;
    if (run.length == 1) {
      // 单独一段过窄：不叫"合并"，照样交给调用方去钳位。
      out.add(run.single);
      run = <TimelineSegment>[];
      return;
    }
    final first = run.first;
    final last = run.last;
    final right = last.left + last.width;
    out.add(
      TimelineSegment(
        left: first.left,
        width: right - first.left,
        lane: first.lane,
        // 合并段保住全部的原始段：点它时每一段都能被列出来。
        steps: <TrajectoryStep>[for (final s in run) ...s.steps],
      ),
    );
    run = <TimelineSegment>[];
  }

  for (final segment in lane) {
    if (segment.width < kTimelineMinSegmentWidth) {
      run.add(segment);
      continue;
    }
    flush();
    out.add(segment);
  }
  flush();
  return out;
}

/// 一次点击落在哪一格上；`null` = 点在空白处（不硬塞一个最近的）。
///
/// 容差 [kTimelineHitSlop]：3dp 宽的段靠手指点是点不中的，左右各放宽一点
/// 才可能选中。重叠时取**后画的那一格**（`Stack` 的命中顺序），
/// 于是合并段（后面生成）不会被它盖住的单个段抢走。
TimelineSegment? segmentAt(List<TimelineSegment> segments, double dx) {
  for (final segment in segments.reversed) {
    final left = segment.left - kTimelineHitSlop;
    final right = segment.left + segment.width + kTimelineHitSlop;
    if (dx >= left && dx <= right) return segment;
  }
  return null;
}

/// 一轮的时间轴。
///
/// 高度只有十几像素（3 条泳道），所以它**不进滚动容器**：宽度就是父级给的
/// 可用宽度，窄屏上靠"过窄段合并"解决，而不是横向滚动条。
class TrajectoryTimeline extends StatelessWidget {
  const TrajectoryTimeline({super.key, required this.turn, this.onTapSegment});

  final TrajectoryTurn turn;

  /// 点中一格的回调（参数是这一格里的原始段，可能多于一段）。
  final void Function(List<TrajectoryStep> steps)? onTapSegment;

  @override
  Widget build(BuildContext context) {
    final steps = turn.steps;
    if (steps.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (turn.running || (turn.durationMs ?? 0) <= 0) {
          return _RunningTrack(steps: steps, width: width);
        }
        final segments = layoutTimelineSegments(
          steps: steps,
          turnDurationMs: turn.durationMs,
          width: width,
        );
        if (segments.isEmpty) return const SizedBox.shrink();
        return _Track(
          segments: segments,
          height: timelineHeight(steps),
          onTapSegment: onTapSegment,
        );
      },
    );
  }
}

/// 有跨度的那些轮：按比例画真正的条。
class _Track extends StatelessWidget {
  const _Track({
    required this.segments,
    required this.height,
    this.onTapSegment,
  });

  final List<TimelineSegment> segments;
  final double height;
  final void Function(List<TrajectoryStep> steps)? onTapSegment;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return SizedBox(
      height: height,
      child: GestureDetector(
        // 整条轨道一个手势，命中靠 [segmentAt] —— 3dp 的段自己收不到点击。
        behavior: HitTestBehavior.opaque,
        onTapUp: onTapSegment == null
            ? null
            : (details) {
                final hit = segmentAt(segments, details.localPosition.dx);
                if (hit != null) onTapSegment!(hit.steps);
              },
        child: Stack(
          children: [
            // 底轨：让"这一轮总共多长"看得见（没有段的部分也是时间）。
            Positioned.fill(
              top: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: c.layer1,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            for (final segment in segments)
              Positioned(
                left: segment.left,
                top: segment.lane * (kTimelineLaneHeight + kTimelineLaneGap),
                width: segment.width,
                height: kTimelineLaneHeight,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: segment.color(c),
                    borderRadius: BorderRadius.circular(1.5),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 进行中的轮：没有右端 ⇒ 不画比例，只按顺序摆起点标记。
class _RunningTrack extends StatelessWidget {
  const _RunningTrack({required this.steps, required this.width});

  final List<TrajectoryStep> steps;
  final double width;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    // 等距摆放：这是**顺序**，不是时间比例（时间比例要有右端才算得出来）。
    final gap = steps.isEmpty ? 0.0 : width / steps.length;
    return SizedBox(
      height: kTimelineLaneHeight,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: c.layer1,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          for (var index = 0; index < steps.length; index += 1)
            Positioned(
              left: (index * gap).clamp(0.0, width - kTimelineMinSegmentWidth),
              width: kTimelineMinSegmentWidth,
              top: 0,
              height: kTimelineLaneHeight,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: steps[index].isError
                      ? c.error
                      : colorOf(steps[index].kind, c),
                  borderRadius: BorderRadius.circular(1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
