/// 模型菜单里的「启用智能体团队协作」开关（Agent Teams）。
///
/// ## 照的是什么
///
/// DSH 把这个开关放在**根会话的模型与推理等级菜单**里
/// （`ui-agent-team/README.zh.md:28`；slot `conversation.input.model.options`），
/// 组件是 `ui-agent-team/src/client/TeamModeToggle.tsx`。四条行为逐条照抄：
///
/// 1. **子会话不渲染**（`:30-32`：`addressedChild || listedChild` ⇒ `return null`）。
///    手机上这枚整个不出现（外层还多一道 `visibleSidePanels` 的同一条判据）。
/// 2. **投影不在就不渲染**（`:44`：`mode === undefined` ⇒ `null`）——
///    "这台电脑没有 Team 服务"与"还没有这个投影"都不摆开关。
/// 3. **不做乐观更新**（`:50-52` 的 `checked={mode.enabled}`）：只认投影，
///    写完等回读。
/// 4. **停用要先确认，且只在"用过模型"时确认**（`:46-50`：
///    `if (!enabled && modelSelection !== undefined && modelSelection.lastUsed !== null)`
///    ⇒ 关菜单 + 开确认框）。理由写在确认文案里：缓存复用与后续 token。
///
/// 文案（标题 / 说明 / 确认框三段 / 失败一句）逐字取自
/// `ui-agent-team/src/client/locales.ts` 的 zh 字典。
///
/// Note: 数据面与边界见 `docs/subsystems/agent-team.md`；取舍见
/// `.agents/notes/implemented/2026-11-14-agent-team-integration.md`。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart' show DshIcon;
import '../theme/dsh_theme.dart' show DshRadius;
import 'dsh_switch.dart';

/// DSH 的文案（`locales.ts` 的 zh 字典，逐字）。
abstract final class TeamCopy {
  /// `mode.label`
  static const String label = '启用智能体团队协作';

  /// `mode.description`
  static const String description =
      '通过共享任务板协调多个智能体的分工与进度，复杂任务表现更佳，token 开销也相应更高。';

  /// `mode.infoLabel`
  static const String infoLabel = '关于智能体团队协作';

  /// `mode.failed`（`{message}` 处填宿主的原话）
  static String failed(String message) => '无法确认智能体团队协作设置已保存，请重试：$message';

  /// `disable.title`
  static const String disableTitle = '确认停用智能体团队协作？';

  /// `disable.description`
  static const String disableDescription = '对话过程中停用智能体团队协作，将停止共享任务工具和团队协调指令。';

  /// `disable.warning`
  static const String disableWarning =
      '停用后可能影响缓存复用、增加后续 token 用量与开销，并影响当前任务的协作效果。';

  /// `disable.cancel`
  static const String disableCancel = '取消';

  /// `disable.confirm`
  static const String disableConfirm = '确认停用';

  /// `disable.close`
  static const String disableClose = '关闭';
}

/// 该不该显示这行、以及建好的那一行（**判据与组件同一处**，调用方只给事实）。
///
/// 三条不显示的条件逐条照 `TeamModeToggle.tsx`：
/// 1. 没有 `caps.team`（这台电脑没有 `agentTeams` 服务）；
/// 2. 当前是**子会话**（`:30-32`）；
/// 3. 投影 `agentTeam` 还没读到（`:44` 的 `mode === undefined`）——
///    摆一个不知道自己状态的开关，用户点下去才发现在猜。
///
/// 返回 `null` 时调用方**什么都不画**（连标题都不留）。
Widget? teamModeRowFor({
  required bool teamAvailable,
  required bool childSession,
  required bool boardReady,
  required bool enabled,
  required bool modelEverUsed,
  required bool hasCurrentModel,
  required Future<String?> Function(bool enabled) onSetEnabled,
}) {
  if (!teamAvailable || childSession || !boardReady) return null;
  return TeamModeRow(
    enabled: enabled,
    modelEverUsed: modelEverUsed,
    disabled: !hasCurrentModel,
    onSetEnabled: onSetEnabled,
  );
}

/// 模型菜单里的一行开关。
///
/// [enabled] 是**投影的真值**（`agentTeam.enabled`）；[saving] 时整行不可点。
/// [onChanged] 回 `null` 表示成功，否则是给人看的一句失败原因。
class TeamModeRow extends StatefulWidget {
  const TeamModeRow({
    super.key,
    required this.enabled,
    required this.modelEverUsed,
    required this.onSetEnabled,
    this.disabled = false,
  });

  final bool enabled;

  /// 这个会话用过模型没有（决定停用要不要先确认，照 `TeamModeToggle.tsx:47`）。
  final bool modelEverUsed;

  /// 真正写下去的那一步（`AppModel.setTeamEnabled` 包一层）。回 `null` = 成功。
  final Future<String?> Function(bool enabled) onSetEnabled;

  /// 外部锁定（模型目录还没读到时 DSH 也是这样禁用：`modelSelection === undefined`）。
  final bool disabled;

  @override
  State<TeamModeRow> createState() => _TeamModeRowState();
}

class _TeamModeRowState extends State<TeamModeRow> {
  bool _saving = false;

  /// 失败原因。**留在行上不自动消失**：DSH 也是把它交给菜单宿主显示，
  /// 用户得知道刚才那一下没成。
  String? _failure;

  Future<void> _select(bool next) async {
    // 停用且用过模型 ⇒ 先确认（DSH 的 `requestDisableConfirmation`，
    // 确认框在菜单之外 —— 手机上菜单本来就是个 sheet，所以先关再问）。
    if (!next && widget.modelEverUsed) {
      final confirmed = await showTeamDisableConfirmation(context);
      if (confirmed != true) return;
    }
    if (!mounted) return;
    setState(() {
      _saving = true;
      _failure = null;
    });
    String? failure;
    try {
      failure = await widget.onSetEnabled(next);
    } catch (error) {
      // 宿主拒绝 / 超时 / 断线：把原话交给界面，不翻译（与其余写面同一条）。
      failure = error.toString();
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _failure = failure;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final locked = widget.disabled || _saving;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 行规格照 `TeamModeToggle.module.css` 的 `.row`：`min-height 34`、`padding 0 8`、
        // `justify-content: space-between`、`gap 16`、13px 主色。触屏把高度放到 44（热区），
        // 其余不变。**整行可点**是 DSH 的行为（`.toggle::after { inset: 0 }` 把开关的
        // 热区铺满整行），只是说明按钮自己吞掉点击。
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: InkWell(
            borderRadius: BorderRadius.circular(DshRadius.md),
            onTap: locked ? null : () => unawaited(_select(!widget.enabled)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  // `justify-content: space-between`：文字组吃掉剩余宽度，
                  // 开关被顶到行尾（不紧跟文字 —— 那读起来像"标签的下标"）。
                  Expanded(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            TeamCopy.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: c.labelPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        // 说明按钮（DSH 的 `.infoButton`：20×20、caption 色）。
                        // 它的触摸半径保留 32，但视觉上是 20 —— 触屏上再小就点不准。
                        IconButton(
                          tooltip: TeamCopy.infoLabel,
                          iconSize: 13,
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          icon: DshIcon(
                            'info',
                            size: 13,
                            color: c.labelCaption,
                          ),
                          onPressed: () => _toastInfo(context),
                        ),
                      ],
                    ),
                  ),
                  // 项目基线的开关（42×25，原型 `.settings-toggle`）。**不用 Material 的
                  // `Switch`**：它按 M3 画 52×32，放进 13px 文案的行里又大又跳。
                  DshSwitch(
                    checked: widget.enabled,
                    label: TeamCopy.label,
                    enabled: !locked,
                    onChanged: (v) => unawaited(_select(v)),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_failure != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            child: Text(
              TeamCopy.failed(_failure!),
              style: TextStyle(fontSize: 11, color: c.stateError),
            ),
          ),
      ],
    );
  }

  void _toastInfo(BuildContext context) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      const SnackBar(content: Text(TeamCopy.description)),
    );
  }
}

/// 停用确认框。**回 `true` 才真的写**（点在框外/关闭/取消都算不写）。
///
/// 照 `TeamDisableConfirmation.tsx`：warning 色调、两段文案、`取消` / `确认停用`。
Future<bool?> showTeamDisableConfirmation(BuildContext context) {
  final c = context.dshColors;
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text(TeamCopy.disableTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(TeamCopy.disableDescription),
          const SizedBox(height: 8),
          Text(
            TeamCopy.disableWarning,
            style: TextStyle(fontSize: 12, color: c.labelSecondary),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text(TeamCopy.disableCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text(TeamCopy.disableConfirm),
        ),
      ],
    ),
  );
}
