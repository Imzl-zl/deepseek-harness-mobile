/// 右抽屉 —— **一个抽屉，三个面板**（文件 / 任务 / 子智能体）。
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

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';

/// "确认停止"这个中间态活多久。
///
/// **照 DSH 的 `KILL_ARM_MS = 3000`**
/// （`packages/client/ui-jobs/src/client/JobListAction.tsx:64`）：
/// armed 是"我正在确认"的意图，而**意图有保质期** ——
/// 第一下点成 armed、然后去做别的事，回来随手一点就杀了一个正在跑的任务。
const Duration kStopArmWindow = Duration(seconds: 3);

/// 抽屉态下的最大内容宽。
///
/// **300 是 DSH 的 `RIGHTBAR_MIN`**（`packages/client/ui-layout/src/client/columns.ts:25`）
/// —— 低于它内容就没法读了。**不取 DSH 的 45%**：那是桌面比例，
/// 手机 390dp 的 45% = 175dp，**低于 DSH 自己的最小可用宽**
/// （推导见 `chat_page.dart` 的 `_sideDrawerWidth`）。
const double kSidePaneMaxWidth = 300;

/// 抽屉态下占屏宽的上限比例。
///
/// 沿用本项目抽屉已有的约定（`session_drawer.dart` 的 `min(86%, 360px)`）：
/// 保证右侧永远露着一条下层会话，读作抽屉而不是换页。
const double kSidePaneWidthRatio = 0.86;

/// 右抽屉该多宽。
///
/// **三个面板同一个宽度** —— 这是 2026-10-19 修掉的那条：
/// 原来文件面板 92%、任务/子智能体 78%，切换面板时整块面板横向跳一下
///（用户原话：「子智能体还变化大小多割裂啊」）。
///
/// [fullscreen] 为真时铺满（用户点头部那枚钮切的，不是宽度派生的）。
double sidePaneWidth({required double screenWidth, required bool fullscreen}) {
  if (fullscreen) return screenWidth;
  return screenWidth * kSidePaneWidthRatio < kSidePaneMaxWidth
      ? screenWidth * kSidePaneWidthRatio
      : kSidePaneMaxWidth;
}

/// 侧抽屉的三个面板。
enum SidePanel {
  file('文件', 'deliverDoc'),
  jobs('任务', 'loading'),
  subs('子智能体', 'users');

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

/// 任务 / 子智能体行（`.jrow`）。
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

  /// 命令或子智能体名（等宽字体）。
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
    this.subsBody,
    this.runningJobs = 0,
    this.runningSubs = 0,
    this.fileActions,
    this.jobActions,
    this.onToggleJob,
    this.openJobIds = const {},
    this.onStopJob,
    this.fullscreen = true,
    this.onToggleFullscreen,
  });

  final SideHeader header;
  final SidePanel panel;
  final ValueChanged<SidePanel> onPanelChanged;
  final VoidCallback onClose;

  /// 文件面板的主体（差异 / 文件内容由调用方给 —— 它知道当前在哪个 tab）。
  final Widget? fileBody;

  final List<SideJob> jobs;

  /// 子智能体面板的主体（**目录树**，由调用方给）。
  ///
  /// 树要自己持两个状态 —— 展开集合与"在跑就走秒"的时钟 ——
  /// 而且点一行是"进入那个子会话"、点 disclosure 才"展开"，
  /// 与任务行的"展开输出"不是一个语义。所以它不塞进 [_JobPanel]，
  /// 由 `ui/subagent_tree.dart` 自成一块。
  final Widget? subsBody;

  final int runningJobs;
  final int runningSubs;

  /// 文件面板底部的三个动作（复制路径 / 在电脑打开 / 分享）。
  final Widget? fileActions;

  /// 任务面板底部的两个动作（停止全部 / 清空已结束）。
  final Widget? jobActions;

  final void Function(SideJob job)? onToggleJob;
  final void Function(SideJob job)? onStopJob;

  final Set<String> openJobIds;

  /// 铺满整屏（由调用方给 —— 它知道屏幕多宽，见文件头）。
  ///
  /// **它是用户切的，不是宽度派生的**：DSH 有同一枚钮
  /// （`ui-sidebar-right/src/client/shell/SidebarRight.tsx:263-296` 的
  /// `FullscreenGlyph` / `ExitFullscreenGlyph`），
  /// 手机侧默认抽屉态、点它铺满。
  final bool fullscreen;

  /// 点全屏 / 退出全屏那枚钮。`null` = 不显示那枚钮
  ///（没有切换能力时摆一个按不动的图标是骗人）。
  final VoidCallback? onToggleFullscreen;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    // **必须有 `Material` 祖先**：这一层里到处是 `InkWell`，而它们要求
    // 上方有 `Material` 才能画水波与接收点击。缺了它实测报
    // `No Material widget found` —— 而那个错误是**运行时**才出现的
    //（单测不点它就不会暴露），所以整块面板包一层。
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: c.bgBase,
          // 竖屏全屏时**去掉圆角与左边框**（`#app.side-full .page--side`）。
          borderRadius: fullscreen
              ? null
              : const BorderRadius.only(
                  topLeft: Radius.circular(DshRadius.panel),
                  bottomLeft: Radius.circular(DshRadius.panel),
                ),
          border: fullscreen ? null : Border(left: BorderSide(color: c.layer2)),
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
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: c.labelPrimary,
                                ),
                              ),
                              if (header.subtitle.isNotEmpty)
                                Text(
                                  header.subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: c.labelCaption,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (header.added != null)
                          Text(
                            '+${header.added}',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: c.fileDiffAddMarker,
                            ),
                          ),
                        if (header.removed != null) ...[
                          const SizedBox(width: 6),
                          Text(
                            '−${header.removed}',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                              color: c.fileDiffDelMarker,
                            ),
                          ),
                        ],
                        // **全屏 / 退出全屏**（2026-10-19 用户原话：
                        // "有一个全面的图标，点击全屏，点击缩回"）。
                        //
                        // DSH 把它放在 tab 条**末端**
                        //（`SidebarRight.tsx:263-296` 的 `PanelChrome`）。
                        //
                        // **两态用同一枚字形**（`fullscreen`），靠 tooltip 说动作。
                        // 为什么不做两枚：DSH 的"退出全屏"那个 glyph 是
                        // **组件内联 SVG**（`SidebarRight.tsx:253-260`），
                        // **不在它的图标包里**（图标包只有 `IconFullscreenOutline`，
                        // `ui-primitives/src/icons/index.tsx:796`）——
                        // 手写一枚就破了"图标集机生成"这条不变量
                        //（`extract-dsh-icons.mjs` 只读图标包，不该去抓某个组件的内联 SVG）。
                        // 而且这一枚是**尺寸控制**：面板铺满与否本身就一眼可见。
                        if (onToggleFullscreen != null) ...[
                          const SizedBox(width: 4),
                          _Ib(
                            icon: 'fullscreen',
                            tooltip: fullscreen ? '退出全屏' : '全屏',
                            onPressed: onToggleFullscreen!,
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
                // 子智能体：**目录树**（`ui/subagent_tree.dart`）。
                //
                // 点行 = 进入那个子会话，与 DSH 的 `openChild` → `openSession`
                // 同一条（`ui-subagent/src/client/index.ts:61-63`）；
                // 行左侧的 disclosure 才是"展开下级"（Web 的 `toggleBranch`）。
                // DSH 另有一个行尾按钮走 `openChildAside` → 右侧栏内嵌渲染
                //（`:64-69`），手机不做（右下角抽屉里再嵌一个会话，
                // 300dp 宽里会窄到不能读）——「仍未做的差异」记在
                // `.agents/notes/implemented/2026-10-21-subagent-catalog-tree-and-state.md`。
                SidePanel.subs => subsBody ?? const SizedBox.shrink(),
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
    final c = context.dshColors;
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
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.layer1)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: actions,
          ),
      ],
    );
  }
}

/// 任务面板。
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
    final c = context.dshColors;
    if (jobs.isEmpty) {
      // **必须 `textAlign: center`**（2026-10-20 用户反馈："子智能体空态文字
      // 不居中看着好难受"）：`Center` 只把**这个 Text 盒子**放中间，
      // 盒子里的多行文本仍按 `start` 对齐。子智能体那句较长会折成两行，
      // 折行后第二行就左对齐了 —— 看起来像"没居中"。
      // 加左右留白则是为了长句不贴着卡片边缘折行。
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            emptyText,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              height: 20 / 13,
              color: c.labelTertiary,
            ),
          ),
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
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.layer1)),
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
    final c = context.dshColors;
    return Padding(
      // `.jgroup { padding:8px 12px 2px; font-size:11.5px }`
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
      child: Text(
        label,
        style: TextStyle(fontSize: 11.5, color: c.labelCaption),
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
    final c = context.dshColors;
    return Column(
      children: [
        InkWell(
          onTap: onToggle == null ? null : () => onToggle!(job),
          child: Container(
            // `.jrow { min-height:44px; padding:8px 10px 8px 12px;
            //   border-top:1px solid l1 }`
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.layer1)),
            ),
            child: Row(
              children: [
                // 状态点：在跑是绿的（一眼看出哪个还活着）。
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: switch (job.state) {
                      'running' => c.roleContext,
                      'stopping' => c.roleTool,
                      'failed' => c.error,
                      _ => c.labelTertiary,
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
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12.5,
                                color: c.labelPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                Text(
                                  job.kind,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 11,
                                    color: c.roleTool,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    job.statusText,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: c.labelCaption,
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
                                style: TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 12.5,
                                  color: c.labelSecondary,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              job.statusText,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: c.labelCaption,
                              ),
                            ),
                          ],
                        ),
                ),
                if (job.durationText.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(
                    job.durationText,
                    style: TextStyle(
                      fontSize: 11,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: c.labelCaption,
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
                    child: DshIcon(
                      'chevronDown',
                      size: 14,
                      color: c.labelTertiary,
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
              border: Border.all(color: c.layer1),
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
                      style: TextStyle(fontSize: 11, color: c.labelCaption),
                    ),
                    const SizedBox(height: 4),
                  ],
                  Text(
                    job.output,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 19 / 12,
                      color: c.labelSecondary,
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

  /// armed 之后的自动解除定时器。
  ///
  /// **DSH 有这一步**（`ui-jobs/src/client/JobListAction.tsx:64` 的
  /// `KILL_ARM_MS = 3000`）：armed 态 **3 秒后自己解除**。
  ///
  /// 少了它会有一个真危险：第一下点成 armed，然后去做别的事 ——
  /// 回来随手一点（以为在点别的）就把任务杀了。armed 是"我正在确认"，
  /// 而这个意图有保质期。
  Timer? _disarm;

  @override
  void dispose() {
    _disarm?.cancel();
    super.dispose();
  }

  void _arm() {
    setState(() => _armed = true);
    _disarm?.cancel();
    _disarm = Timer(kStopArmWindow, () {
      if (!mounted) return;
      setState(() => _armed = false);
    });
  }

  void _disarmNow() {
    _disarm?.cancel();
    setState(() => _armed = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Tooltip(
      // 有 tooltip 才有稳定的定位点（测试与无障碍都需要它 ——
      // 一个只有图标的按钮没有任何可读文本）。
      message: _armed ? '确认停止' : '停止',
      child: GestureDetector(
        onTap: () {
          if (_armed) {
            widget.onConfirm();
            _disarmNow();
          } else {
            _arm();
          }
        },
        child: Container(
          constraints: const BoxConstraints(minHeight: 30),
          padding: EdgeInsets.symmetric(horizontal: _armed ? 12 : 9),
          decoration: BoxDecoration(
            color: _armed ? c.error.withValues(alpha: 0.9) : c.layer3,
            borderRadius: BorderRadius.circular(15),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              DshIcon(
                _armed ? 'stopFill' : 'close',
                size: 14,
                color: _armed ? Colors.white : c.labelSecondary,
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
    final c = context.dshColors;
    return Material(
      color: active ? c.layer3 : Colors.transparent,
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
                  color: active ? c.labelPrimary : c.labelTertiary,
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
                    color: c.roleToolBg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: c.roleTool,
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
            child: DshIcon(icon, size: 18, color: c.labelSecondary),
          ),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
