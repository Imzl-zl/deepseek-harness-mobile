/// 轨迹页（照 `mock/proto/index.html` 的第二个 `.pg` 与 `styles.css`）。
///
/// ## 它由两块组成
///
/// 1. **甘特条**（`.gantt`）：四行 —— 输入 / 模型 / 工具 / 错误，
///    每行一条 14px 高的轨道，里面按时间放彩色段。
///    宽度固定 640px 并**横滑**（原型 `.gantt-in { width:640px }`）——
///    手机上竖着看时间轴，横滑才能看清"谁占了多久"。
/// 2. **账本**（`.ledger`）：按时间排的条目 —— 上下文 / 助手 / 工具 / 错误，
///    每行左边一条 3px 的色条，右边两行（名字 + 耗时 / 摘要）。
///
/// ## 为什么这两块合在一屏
///
/// 甘特给"**形状**"（一眼看出时间花在哪），账本给"**明细**"（点进去看每条）。
/// 只有甘特会让人问"这一段到底是什么"，只有账本会让人看不出整体节奏。
///
/// ## 色条的颜色是语义（不是装饰）
///
/// | 类 | 颜色 | 含义 |
/// |---|---|---|
/// | `.lg.c` | `roleContext`（绿） | 上下文注入 |
/// | `.lg.a` | `roleAssistant`（紫） | 助手 |
/// | `.lg.t` | `roleTool`（橙） | 工具 |
/// | `.lg.e` | `error`（红） | 错误 |
///
/// 与消息流里的角色色**同一套** —— 于是"这一行是什么"不需要读文字。
library;

import 'package:flutter/material.dart';

import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';

/// 账本一行的种类（决定色条与图标）。
enum TraceKind {
  /// 上下文注入。
  context('info', DshColors.roleContext, '上下文'),

  /// 助手。
  assistant('sparkle', DshColors.roleAssistant, '助手'),

  /// 工具调用。
  tool('browse', DshColors.roleTool, '工具'),

  /// 错误。
  error('warningTriangle', DshColors.error, '错误');

  const TraceKind(this.icon, this.color, this.label);

  final String icon;
  final Color color;
  final String label;
}

/// 账本里的一条。
class TraceEntry {
  const TraceEntry({
    required this.kind,
    required this.name,
    required this.took,
    required this.summary,
    this.mono = false,
  });

  final TraceKind kind;

  /// 名字（`上下文` / `助手` / `工具 · read`）。
  final String name;

  /// 耗时（`120 ms` / `12.4 s`）。
  final String took;

  /// 摘要（一两行，多了截断）。
  final String summary;

  /// 摘要是否用等宽（工具那一类要 —— 它是路径/命令）。
  final bool mono;
}

/// 甘特里的一段。
class GanttSpan {
  const GanttSpan({
    required this.startPercent,
    required this.widthPercent,
    this.opacity = 1,
  });

  /// 起点（0~100，相对整条时间轴）。
  final double startPercent;

  /// 宽度（0~100）。
  final double widthPercent;

  /// 透明度（`<1` 表示"这一段是等待/空隙"）。
  final double opacity;
}

/// 甘特的一行。
class GanttRow {
  const GanttRow({
    required this.label,
    required this.color,
    required this.spans,
  });

  /// `输入` / `模型` / `工具` / `错误`。
  final String label;
  final Color color;
  final List<GanttSpan> spans;
}

/// 轨迹页。
///
/// **没有示例数据兜底**：`rows` / `entries` 为 null 时显示空态，不造一份假的。
/// 2026-10-15 之前这里是 `_sampleRows` / `_sampleEntries` 兜底，而调用方
/// （`chat_page.dart` 的 `_TrajectoryTab`）从不传真数据 —— 于是轨迹页
/// **常驻假数据**，用户无法分辨。真数据通路是 `turnOutline` 投影
/// （`session.projections`，契约 §5.7）。
class TrajectoryTab extends StatelessWidget {
  const TrajectoryTab({super.key, this.rows, this.entries, this.onTapEntry});

  /// 甘特的行；`null` / 空 = 空态（不造假的）。
  final List<GanttRow>? rows;

  /// 账本条目的行；`null` / 空 = 空态（不造假的）。
  final List<TraceEntry>? entries;

  final void Function(TraceEntry entry)? onTapEntry;

  @override
  Widget build(BuildContext context) {
    final ganttRows = rows ?? const [];
    final traceEntries = entries ?? const [];
    if (ganttRows.isEmpty && traceEntries.isEmpty) {
      return const _EmptyTrajectory();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 顶部工具行：三个 chip + 搜索（原型 `.tj-tools`）。
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
          child: Row(
            children: [
              const _Chip(label: '时长', on: true),
              const SizedBox(width: 6),
              const _Chip(label: '轮次'),
              const SizedBox(width: 6),
              const _Chip(label: '调用'),
              const Spacer(),
              IconButton(
                tooltip: '搜索轨迹',
                visualDensity: VisualDensity.compact,
                onPressed: () {},
                icon: const DshIcon(
                  'search',
                  size: 18,
                  color: DshColors.labelSecondary,
                ),
              ),
            ],
          ),
        ),
        // ---- 甘特条（固定 640px 宽，横滑）----
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
          child: SizedBox(
            // `.gantt-in { width:640px }` —— 固定宽度是刻意的：
            // 时间轴要有稳定刻度，跟着屏宽变会让两张截图没法对比。
            width: 640,
            child: Column(
              children: [
                for (final row in ganttRows) _GanttRowView(row: row),
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '← 横滑查看完整时间轴 →',
                      style: TextStyle(
                        fontSize: 11,
                        color: DshColors.labelCaption,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // ---- 账本 ----
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 8),
            itemCount: traceEntries.length,
            itemBuilder: (context, index) => _LedgerRow(
              entry: traceEntries[index],
              onTap: onTapEntry == null
                  ? null
                  : () => onTapEntry!(traceEntries[index]),
            ),
          ),
        ),
      ],
    );
  }
}

/// 甘特的一行（`.grow`）。
class _GanttRowView extends StatelessWidget {
  const _GanttRowView({required this.row});

  final GanttRow row;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // `.grow { gap:10px; margin:7px 0 }`
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          // `.grow .lb { width:34px; font-size:11px }`
          SizedBox(
            width: 34,
            child: Text(
              row.label,
              style: const TextStyle(
                fontSize: 11,
                color: DshColors.labelCaption,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final track = constraints.maxWidth;
                return SizedBox(
                  // `.gtrack { height:14px; border-radius:7px }`
                  height: 14,
                  child: Stack(
                    children: [
                      // 轨道底。
                      Container(
                        decoration: BoxDecoration(
                          color: DshColors.layer1,
                          borderRadius: BorderRadius.circular(7),
                        ),
                      ),
                      for (final span in row.spans)
                        Positioned(
                          left: track * span.startPercent / 100,
                          width: track * span.widthPercent / 100,
                          top: 0,
                          height: 14,
                          child: Opacity(
                            opacity: span.opacity,
                            child: Container(
                              decoration: BoxDecoration(
                                color: row.color,
                                borderRadius: BorderRadius.circular(7),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 账本的一行（`.lg`）。
class _LedgerRow extends StatelessWidget {
  const _LedgerRow({required this.entry, this.onTap});

  final TraceEntry entry;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          // `.lg { gap:10px; padding:10px 4px; border-bottom:1px solid l1 }`
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: DshColors.layer1)),
          ),
          child: IntrinsicHeight(
            // **`IntrinsicHeight` 是必需的**：色条要"和这一行一样高"，
            // 而 `CrossAxisAlignment.stretch` 在 `ListView` 里拿到的是
            // **无限高**约束 —— 实测报 `BoxConstraints forces an infinite
            // height`（渲染断言，整页不显示）。
            // `IntrinsicHeight` 先量出这一行的自然高度，再让色条撑满它。
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 色条：**这一行是什么**不需要读文字就能看出来。
                Container(
                  width: 3,
                  decoration: BoxDecoration(
                    color: entry.kind.color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          DshIcon(
                            entry.kind.icon,
                            size: 13,
                            color: entry.kind.color,
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              entry.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: DshColors.labelPrimary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // 耗时靠右（`.lg .tt { margin-left:auto }`）。
                          Text(
                            entry.took,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: DshColors.labelCaption,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        entry.summary,
                        // `.lg .r2 { -webkit-line-clamp:2 }` —— 最多两行。
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 18 / 12.5,
                          fontFamily: entry.mono ? 'monospace' : null,
                          color: DshColors.labelTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Align(
                  alignment: Alignment.center,
                  child: DshIcon(
                    'chevronRight',
                    size: 16,
                    color: DshColors.labelTertiary,
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

/// 顶部的小 chip（`.chip`：`min-height:32` / `border-radius:16`）。
class _Chip extends StatelessWidget {
  const _Chip({required this.label, this.on = false});

  final String label;
  final bool on;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 32),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: on ? DshColors.layer3 : Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        border: on ? null : Border.all(color: DshColors.layer2),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: on ? FontWeight.w600 : FontWeight.w400,
          color: on ? DshColors.labelPrimary : DshColors.labelSecondary,
        ),
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
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            DshIcon('gauge', size: 40, color: DshColors.labelTertiary),
            SizedBox(height: 16),
            Text(
              '还没有轨迹',
              style: TextStyle(fontSize: 15, color: DshColors.labelSecondary),
            ),
            SizedBox(height: 8),
            Text(
              '电脑侧跑完一轮后，这里会显示这一轮的时间轴与每一步的耗时。\n'
              '数据来自会话投影 turnOutline。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: DshColors.labelTertiary),
            ),
          ],
        ),
      ),
    );
  }
}
