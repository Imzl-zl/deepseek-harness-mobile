/// 右抽屉 —— **一个抽屉，三个面板**（文件 / 任务 / 子代理）。
///
/// 照 `mock/proto/index.html` 的 `section.page--side` 与 `styles.css`。
///
/// ## 竖屏手机上是**全屏页**，不是侧栏
///
/// 原型的 `layoutSidePane()` 写得很明确：
///
/// ```js
/// /* 什么时候给右抽屉:横屏,或宽度 ≥700(平板/折叠屏展开)。
///    竖屏手机全屏 —— 390 宽里再切一块,会话和 diff 两边都不够用。 */
/// const full = !(w >= 700 || w > h);
/// ```
///
/// 所以手机上它从右侧滑入并**铺满**（去掉圆角与左边框）。
/// 这一层不自己判断：由调用方决定 `fullscreen`，因为"屏幕多宽"是它知道的。
///
/// ## 三个面板为什么合并成一个抽屉
///
/// 原型的注释：*"diff/预览、运行中的任务、子智能体 —— 都是'右边看一眼'的东西，
/// 合并成一个抽屉，对话流里只留一行提示。"*
/// 而 tab 上的计数徽标（`.stab .n`）让"有几个在跑"一眼可见。
library;

import 'package:flutter/material.dart';

import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';

/// 侧抽屉的三个面板。
enum SidePanel {
  file('文件', 'deliverDoc'),
  jobs('任务', 'loading'),
  subs('子代理', 'users');

  const SidePanel(this.label, this.icon);

  final String label;
  final String icon;
}

/// 抽屉顶栏的信息（`.side-bar`）。
class SideHeader {
  const SideHeader({
    required this.title,
    this.subtitle = '',
    this.added,
    this.removed,
  });

  /// 标题（文件面板是文件名）。
  final String title;

  /// 副标题（文件面板是完整路径）。
  final String subtitle;

  /// 变更统计；`null` = 不显示。
  final int? added;
  final int? removed;
}

/// 任务 / 子代理行（`.jrow`）。
///
/// 两种形态（原型注释：*"进行中:两行；已结束:一行"*）：
/// - 进行中：`label` 一行 + `kind 状态` 一行，右侧时长；
/// - 已结束：一行 —— 状态点 + kind + label + 状态 + 时长。
class SideJob {
  const SideJob({
    required this.id,
    required this.label,
    required this.kind,
    required this.state,
    required this.statusText,
    this.durationText = '',
    this.output = '',
    this.gapNote,
  });

  final String id;

  /// 命令或子代理名（等宽字体）。
  final String label;

  /// `pwsh` / `bash` / …（工具色、等宽）。
  final String kind;

  /// `running` / `stopping` / `completed` / `killed` / `failed`。
  final String state;

  /// 人类可读状态（`已完成` / `已停止`）。
  final String statusText;

  /// 时长（`02:14`）。
  final String durationText;

  /// 展开后的输出。
  final String output;

  /// `gapBefore` 提示（较早输出已丢弃）——**必须显式渲染**，
  /// 不做静默拼接（`plugin-and-jobs-notes.md` §B.4）。
  final String? gapNote;

  bool get isLive => state == 'running' || state == 'stopping';
}

/// 右抽屉。
class SidePane extends StatelessWidget {
  const SidePane({
    super.key,
    required this.header,
    required this.panel,
    required this.onPanelChanged,
    required this.onClose,
    this.fileBody,
    this.jobs = const [],
    this.subs = const [],
    this.runningJobs = 0,
    this.runningSubs = 0,
    this.fileActions,
    this.jobActions,
    this.onToggleJob,
    this.openJobIds = const {},
    this.onStopJob,
    this.fullscreen = true,
  });

  final SideHeader header;
  final SidePanel panel;
  final ValueChanged<SidePanel> onPanelChanged;
  final VoidCallback onClose;

  /// 文件面板的主体（差异 / 文件内容由调用方给 —— 它知道当前在哪个 tab）。
  final Widget? fileBody;

  final List<SideJob> jobs;
  final List<SideJob> subs;
  final int runningJobs;
  final int runningSubs;

  /// 文件面板底部的三个动作（复制路径 / 在电脑打开 / 分享）。
  final Widget? fileActions;

  /// 任务面板底部的两个动作（停止全部 / 清空已结束）。
  final Widget? jobActions;

  final void Function(SideJob job)? onToggleJob;
  final void Function(SideJob job)? onStopJob;
  final Set<String> openJobIds;

  /// 竖屏手机上是全屏页（见文件头）。
  final bool fullscreen;

  @override
  Widget build(BuildContext context) {
    // **必须有 `Material` 祖先**：这一层里到处是 `InkWell`，而它们要求
    // 上方有 `Material` 才能画水波与接收点击。缺了它实测报
    // `No Material widget found` —— 而那个错误是**运行时**才出现的
    //（单测不点它就不会暴露），所以整块面板包一层。
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: DshColors.bgBase,
          // 竖屏全屏时**去掉圆角与左边框**（`#app.side-full .page--side`）。
          borderRadius: fullscreen
              ? null
              : const BorderRadius.only(
                  topLeft: Radius.circular(DshRadius.panel),
                  bottomLeft: Radius.circular(DshRadius.panel),
                ),
          border: fullscreen
              ? null
              : const Border(left: BorderSide(color: DshColors.layer2)),
        ),
        child: Column(
          children: [
            // ---- 顶部：标题栏 + 面板 tab ----
            Container(
              padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
              child: Column(
                children: [
                  SizedBox(
                    // `.side-bar { height: 54px }`
                    height: 54,
                    child: Row(
                      children: [
                        const SizedBox(width: 4),
                        _Ib(
                          icon: fullscreen ? 'close' : 'chevronRight',
                          tooltip: '收起',
                          onPressed: onClose,
                        ),
                        const SizedBox(width: 2),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                header.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: DshColors.labelPrimary,
                                ),
                              ),
                              if (header.subtitle.isNotEmpty)
                                Text(
                                  header.subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: DshColors.labelCaption,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (header.added != null)
                          Text(
                            '+${header.added}',
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: DshColors.fileDiffAddMarker,
                            ),
                          ),
                        if (header.removed != null) ...[
                          const SizedBox(width: 6),
                          Text(
                            '−${header.removed}',
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: DshColors.fileDiffDelMarker,
                            ),
                          ),
                        ],
                        const SizedBox(width: 8),
                      ],
                    ),
                  ),
                  // `.sidetabs { gap:4px; padding:0 10px 8px }`
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                    child: Row(
                      children: [
                        for (final p in SidePanel.values) ...[
                          _SideTab(
                            panel: p,
                            active: p == panel,
                            // 计数徽标（`.stab .n`）：**只在有在跑的才显示**。
                            count: switch (p) {
                              SidePanel.jobs => runningJobs,
                              SidePanel.subs => runningSubs,
                              _ => 0,
                            },
                            onTap: () => onPanelChanged(p),
                          ),
                          const SizedBox(width: 4),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // ---- 面板主体 ----
            Expanded(
              child: switch (panel) {
                SidePanel.file => _FilePanel(
                  body: fileBody,
                  actions: fileActions,
                ),
                SidePanel.jobs => _JobPanel(
                  jobs: jobs,
                  openIds: openJobIds,
                  onToggle: onToggleJob,
                  onStop: onStopJob,
                  actions: jobActions,
                  emptyText: '没有后台任务。',
                ),
                SidePanel.subs => _JobPanel(
                  jobs: subs,
                  openIds: openJobIds,
                  onToggle: onToggleJob,
                  emptyText: '没有子代理。',
                ),
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 文件面板：主体 + 底部三个动作。
class _FilePanel extends StatelessWidget {
  const _FilePanel({this.body, this.actions});

  final Widget? body;
  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // **不要在这里套横向滚动**：`DshDiff` / `DshCodeLines` 内部已经是
        // "固定左列 + 右侧横滑区"的结构，外面再套一层横滑会让内层的
        // `Expanded` 拿到**无限宽约束** —— 实测报
        // `BoxConstraints forces an infinite width`（渲染断言）。
        // 横滑的职责归 diff 自己，这一层只管纵向。
        Expanded(child: body ?? const SizedBox.shrink()),
        if (actions != null)
          Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: DshColors.layer1)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: actions,
          ),
      ],
    );
  }
}

/// 任务 / 子代理面板。
class _JobPanel extends StatelessWidget {
  const _JobPanel({
    required this.jobs,
    required this.openIds,
    this.onToggle,
    this.onStop,
    this.actions,
    required this.emptyText,
  });

  final List<SideJob> jobs;
  final Set<String> openIds;
  final void Function(SideJob job)? onToggle;
  final void Function(SideJob job)? onStop;
  final Widget? actions;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    if (jobs.isEmpty) {
      return Center(
        child: Text(
          emptyText,
          style: const TextStyle(fontSize: 13, color: DshColors.labelTertiary),
        ),
      );
    }
    final live = jobs.where((j) => j.isLive).toList();
    final settled = jobs.where((j) => !j.isLive).toList();
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              // 分组照原型：`进行中` / `已结束 N`。
              if (live.isNotEmpty) const _JobGroup('进行中'),
              for (final job in live)
                _JobRow(
                  job: job,
                  open: openIds.contains(job.id),
                  onToggle: onToggle,
                  onStop: onStop,
                ),
              if (settled.isNotEmpty) _JobGroup('已结束 ${settled.length}'),
              for (final job in settled)
                _JobRow(
                  job: job,
                  open: openIds.contains(job.id),
                  onToggle: onToggle,
                ),
            ],
          ),
        ),
        if (actions != null)
          Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: DshColors.layer1)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: actions,
          ),
      ],
    );
  }
}

class _JobGroup extends StatelessWidget {
  const _JobGroup(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // `.jgroup { padding:8px 12px 2px; font-size:11.5px }`
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      child: Text(
        label,
        style: const TextStyle(fontSize: 11.5, color: DshColors.labelCaption),
      ),
    );
  }
}

/// 一行任务（`.jrow`）。
class _JobRow extends StatelessWidget {
  const _JobRow({
    required this.job,
    required this.open,
    this.onToggle,
    this.onStop,
  });

  final SideJob job;
  final bool open;
  final void Function(SideJob job)? onToggle;
  final void Function(SideJob job)? onStop;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        InkWell(
          onTap: onToggle == null ? null : () => onToggle!(job),
          child: Container(
            // `.jrow { min-height:44px; padding:8px 10px 8px 12px;
            //   border-top:1px solid l1 }`
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: DshColors.layer1)),
            ),
            child: Row(
              children: [
                // 状态点：在跑是绿的（一眼看出哪个还活着）。
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: switch (job.state) {
                      'running' => DshColors.roleContext,
                      'stopping' => DshColors.roleTool,
                      'failed' => DshColors.error,
                      _ => DshColors.labelTertiary,
                    },
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: job.isLive
                      // 进行中：两行（label / kind + status）。
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              job.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12.5,
                                color: DshColors.labelPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                Text(
                                  job.kind,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    color: DshColors.roleTool,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    job.statusText,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 11.5,
                                      color: DshColors.labelCaption,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        )
                      // 已结束：一行 —— label 可省略，status 不许被压没。
                      : Row(
                          children: [
                            Flexible(
                              child: Text(
                                job.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12.5,
                                  color: DshColors.labelSecondary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              job.statusText,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: DshColors.labelCaption,
                              ),
                            ),
                          ],
                        ),
                ),
                if (job.durationText.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    job.durationText,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFeatures: [FontFeature.tabularFigures()],
                      color: DshColors.labelCaption,
                    ),
                  ),
                ],
                // 停止按钮：二次点击变"确认停止"（原型 `.jstop[data-kill]`）。
                if (job.isLive && onStop != null) ...[
                  const SizedBox(width: 6),
                  _StopButton(onConfirm: () => onStop!(job)),
                ],
                if (job.output.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 160),
                    child: const DshIcon(
                      'chevronDown',
                      size: 14,
                      color: DshColors.labelTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (open && job.output.isNotEmpty)
          Container(
            // `.jrow .out { padding:10px 12px; border-radius:12;
            //   background:#171719; 等宽 12/19; max-height:200 }`
            margin: const EdgeInsets.fromLTRB(12, 6, 12, 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            constraints: const BoxConstraints(maxHeight: 200),
            decoration: BoxDecoration(
              color: const Color(0xFF171719),
              borderRadius: BorderRadius.circular(DshRadius.md),
              border: Border.all(color: DshColors.layer1),
            ),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // **`gapBefore` 必须显式渲染**（较早输出已丢弃）——
                  // 静默拼接会让用户以为输出是连续的。
                  if (job.gapNote != null) ...[
                    Text(
                      job.gapNote!,
                      style: const TextStyle(
                        fontSize: 11,
                        color: DshColors.labelCaption,
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                  Text(
                    job.output,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 19 / 12,
                      color: DshColors.labelSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// 停止按钮：第一次点变"确认停止"，第二次才真停。
///
/// 照原型（`.jstop[data-kill="armed"]`）：**两步是刻意的** ——
/// 停止一个正在跑的任务不可逆，误触的代价是丢掉半天的构建。
class _StopButton extends StatefulWidget {
  const _StopButton({required this.onConfirm});

  final VoidCallback onConfirm;

  @override
  State<_StopButton> createState() => _StopButtonState();
}

class _StopButtonState extends State<_StopButton> {
  bool _armed = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      // 有 tooltip 才有稳定的定位点（测试与无障碍都需要它 ——
      // 一个只有图标的按钮没有任何可读文本）。
      message: _armed ? '确认停止' : '停止',
      child: GestureDetector(
        onTap: () {
          if (_armed) {
            widget.onConfirm();
            setState(() => _armed = false);
          } else {
            setState(() => _armed = true);
          }
        },
        child: Container(
          constraints: const BoxConstraints(minHeight: 30),
          padding: EdgeInsets.symmetric(horizontal: _armed ? 12 : 9),
          decoration: BoxDecoration(
            color: _armed
                ? DshColors.error.withValues(alpha: 0.9)
                : DshColors.layer3,
            borderRadius: BorderRadius.circular(15),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DshIcon(
                _armed ? 'stopFill' : 'close',
                size: 14,
                color: _armed ? Colors.white : DshColors.labelSecondary,
              ),
              if (_armed) ...[
                const SizedBox(width: 5),
                const Text(
                  '确认停止',
                  style: TextStyle(fontSize: 11.5, color: Colors.white),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 面板 tab（`.stab`：`min-height:34`、`border-radius:17`）。
class _SideTab extends StatelessWidget {
  const _SideTab({
    required this.panel,
    required this.active,
    required this.count,
    required this.onTap,
  });

  final SidePanel panel;
  final bool active;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: active ? DshColors.layer3 : Colors.transparent,
      borderRadius: BorderRadius.circular(17),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 34),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                panel.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w500 : FontWeight.w400,
                  color: active
                      ? DshColors.labelPrimary
                      : DshColors.labelTertiary,
                ),
              ),
              // 计数徽标：**只在 >0 时显示**（原型 `hidden` 逻辑）。
              if (count > 0) ...[
                const SizedBox(width: 5),
                Container(
                  constraints: const BoxConstraints(minWidth: 16),
                  height: 16,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(
                    color: DshColors.roleToolBg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '$count',
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: DshColors.roleTool,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Ib extends StatelessWidget {
  const _Ib({required this.icon, required this.onPressed, this.tooltip});

  final String icon;
  final VoidCallback onPressed;
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
            child: DshIcon(icon, size: 18, color: DshColors.labelSecondary),
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
