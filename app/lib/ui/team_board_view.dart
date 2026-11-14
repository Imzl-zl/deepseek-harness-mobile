/// 右抽屉「任务板」面板的主体（Agent Teams 的**共享任务**，只读）。
///
/// ## 照的是什么
///
/// DSH 的那块板是**子智能体菜单的下半段**：`ui-agent-team` 注册在
/// `conversation.session.header.actions.subagent.footer`（`mount.ts:66-68`），
/// 标题行「共享任务」+ 进度短语，下面一行一条任务，点一行展开说明与负责人
/// （`TeamBoard.tsx:88-110`）。
///
/// 手机把它抬成**一枚 tab**（方案 §4：与子智能体 / 任务 / 文件并列），
/// 少掉的东西只有一样：这块板在 DSH 里是滚动进子智能体菜单的一段，
/// 在手机上是整块面板 —— 所以滚动归本组件自己（`ListView`）。
///
/// ## 三处必须照抄、不许"顺手改好"的地方
///
/// 1. **`ready` 不重算**：被阻塞 = `status == pending && !ready`，`ready` 是宿主按 DAG 推的
///    （`team-view.ts` / `task-view.ts`），手机重算就是第二份真值。
/// 2. **`ownerName` 缺席不编**：回落链 `ownerName ?? ownerId ?? 未分配`
///    逐字照 `TeamBoard.tsx:46` —— 历史数据里确实可能没有名字
///    （`projection.ts:203-207` 的注释写明 v7 检查点不回填）。
/// 3. **状态点语义**：`pending→idle`、`in_progress→ongoing`、`completed→done`，
///    被阻塞时**改画琥珀 `warning`**（`TeamBoard.tsx:59-61` + `:36-40`）。
///
/// 文案（`共享任务` / `待处理` / `进行中` / `已完成` / `被依赖阻塞` / `未分配` /
/// `负责人` / `任务记录无效：` / `正在加载任务板…`）全部逐字取自
/// `ui-agent-team/src/client/locales.ts` 的 zh 字典。
///
/// Note: 为什么只读、为什么子会话不给这枚 tab —— 见
/// `.agents/notes/implemented/2026-11-14-agent-team-integration.md`。
library;

import 'package:flutter/material.dart';

import '../model/team_board.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart' show DshIcon;
import '../theme/dsh_theme.dart' show DshRadius;
import 'dsh_state_dot.dart';

/// 任务板主体。
///
/// [board] 为 `null` = 这一包投影里没有 `agentTeam`（还没读到）。
/// **"没有 Team 服务"不归这里管**：那种情况下调用方根本不会给这枚 tab
/// （能力位 `caps.team`），所以这里只会是"还没读到"。
class TeamBoardView extends StatefulWidget {
  const TeamBoardView({super.key, required this.board});

  final TeamBoard? board;

  @override
  State<TeamBoardView> createState() => _TeamBoardViewState();
}

class _TeamBoardViewState extends State<TeamBoardView> {
  /// 展开的任务 id（一次只展开一条：手机一行只有 300dp 宽，多条同展开会互相挤）。
  String? _openId;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final board = widget.board;
    if (board == null) {
      return _CenteredNote(text: '正在加载任务板…', color: c.labelTertiary);
    }
    final tasks = board.visibleTasks;
    final failure = board.failure;
    // 与 DSH 的 `TeamBoard` 同一条：**任务为空且没有失败** ⇒ 什么都不画。
    // （调用方的 tab 可见性判据与此一致，所以正常走不到这里。）
    if (tasks.isEmpty && failure == null) {
      return _CenteredNote(text: '暂无共享任务', color: c.labelTertiary);
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      children: [
        _Header(progress: board.progressText),
        if (failure != null) _FailureLine(message: failure),
        for (final task in tasks)
          _TaskRow(
            key: ValueKey(task.id),
            task: task,
            expanded: _openId == task.id,
            onToggle: () => setState(() {
              _openId = _openId == task.id ? null : task.id;
            }),
          ),
      ],
    );
  }
}

/// 标题行：`[清单图标] 共享任务  1 已完成 · 2 进行中`（DSH `TeamBoard.tsx:91-96`）。
class _Header extends StatelessWidget {
  const _Header({required this.progress});

  final String progress;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          DshIcon('checklist', size: 14, color: c.labelTertiary),
          const SizedBox(width: 7),
          Text(
            '共享任务',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: c.labelPrimary,
            ),
          ),
          if (progress.isNotEmpty) ...[
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                progress,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  // 进度里全是数字，等宽数字更稳（DSH 的 `tabular-nums`）。
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: c.labelTertiary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 投影自己报的读失败：`任务记录无效：{message}`（`locales.ts` 的 `failure`）。
///
/// **不吞也不扩写**：宿主说的是"有一条持久记录读不进来，任务保留上一版有效值"，
/// 翻译成"加载失败"会把一块其实可用的板说成坏了。
class _FailureLine extends StatelessWidget {
  const _FailureLine({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const DshStateDot(DshStateDotState.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '任务记录无效：$message',
              style: TextStyle(fontSize: 12, color: c.stateError),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一行任务：`[状态点] 标题 [箭头]`，展开后是说明 + 负责人。
class _TaskRow extends StatelessWidget {
  const _TaskRow({
    super.key,
    required this.task,
    required this.expanded,
    required this.onToggle,
  });

  final TeamTask task;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(DshRadius.sm),
          child: Padding(
            // 密度照 `ui/subagent_tree.dart` 的行（上下各 6）。
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                DshStateDot(_dotOf(task)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    task.subject,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: c.labelPrimary,
                      // 做完的任务不划掉（DSH 也不划）：状态由点表达，
                      // 行还要能点开看说明。
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                AnimatedRotation(
                  turns: expanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 120),
                  child: DshIcon(
                    'chevronDown',
                    size: 14,
                    color: c.labelTertiary,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 0, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (task.description.isNotEmpty)
                  Text(
                    task.description,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: c.labelSecondary,
                    ),
                  ),
                if (task.description.isNotEmpty) const SizedBox(height: 4),
                Text(
                  '负责人：${task.ownerText}',
                  style: TextStyle(fontSize: 11, color: c.labelTertiary),
                ),
                if (task.writeScopeWarnings.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  for (final warning in task.writeScopeWarnings)
                    Text(
                      warning,
                      style: TextStyle(fontSize: 11, color: c.stateWarn),
                    ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  /// 状态点语义照 `TeamBoard.tsx:36-40` + `:59-61`：
  /// 被依赖阻塞时**盖掉**状态色画琥珀，否则按状态。
  static DshStateDotState _dotOf(TeamTask task) {
    if (task.blocked) return DshStateDotState.warning;
    return switch (task.status) {
      TeamTaskStatus.pending => DshStateDotState.idle,
      TeamTaskStatus.inProgress => DshStateDotState.ongoing,
      TeamTaskStatus.completed => DshStateDotState.done,
      // 线上不该出现（宿主已经滤掉），留着只为穷尽 switch。
      TeamTaskStatus.deleted => DshStateDotState.idle,
    };
  }
}

/// 居中的一句话（加载中 / 空）。
class _CenteredNote extends StatelessWidget {
  const _CenteredNote({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: color),
        ),
      ),
    );
  }
}
