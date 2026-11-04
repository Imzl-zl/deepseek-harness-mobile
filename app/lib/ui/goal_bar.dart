/// 目标条（DSH 的 `GoalBar`，`conversation.input.dock` 里 order 10 的那一格）。
///
/// ## 它是什么
///
/// 「目标」不是聊天消息，是输入框上方的一条 dock：DSH 让长任务有一个**跨轮次**
/// 的目标（`/goal <objective>` 建、`/goal pause|resume|clear|edit` 改），
/// 而这条 dock 就是那个目标的唯一可见处。
///
/// 结构与文案逐字照 `packages/client/ui-goal/src/client/GoalBar.tsx`：
/// - 36dp 高、圆角 `md`、**菜单底**（`.bar` 的 `--dsw-specific-menu`）+
///   `elevation-panel` 发丝描边（`GoalBar.module.css:19-46`）；
/// - 一行四段：图标 → 阶段标签 → 目标正文（一行省略）→ 动作（`GoalBar.tsx:132-171`）；
/// - 阶段文案照 zh 词典（`locales.ts:5-8`）：进行中的目标 / 已暂停的目标 / 受阻的目标；
/// - **`complete` 与 `null` 都不画条**（`GoalBar.tsx:86`）。
///
/// ## 动作走斜杠命令，不开新方法
///
/// DSH 有 `goals` 的 Remote（`pause` / `resume` / `clear` / `edit`），而手机这条通道
/// 没有它（`connector/src/protocol/methods.ts` 的方法面里没有 `goal.*`）。所以四个动作
/// 一律落到 `/goal …`（`command-goal/src/index.ts:16` 的用法串），
/// 走已经放行的 `command.execute`（白名单 `connector/src/handlers.ts:88` 的
/// `MOBILE_COMMANDS`）。**这条通道的结论按 `CommandOutcome` 的既有约定呈现**
/// （与 `chat_page.dart` 的 `_switchPermission` 同一个三段式），不新造文案。
///
/// 代价写在 `docs/subsystems/goal-bar.md` §4：命令会在对话流里落一张命令卡
/// （`command/run` + `command/done` 是 DSH 的生命周期事件），那是宿主的行为。
///
/// ## 与 Web 的两处形态差异（有意）
///
/// 1. **动作失败用浮层提示**（`DshToast`），不是条内那行红字（`GoalBar.tsx:99,138`）：
///    手机上 36dp 的条塞不下第二行，而"失败必须说出来"这条纪律全 App 只有一处出口。
/// 2. **受阻时整条 `title` 用 `Tooltip`**（触屏是长按）：HTML 的 `title` 在手机上不存在，
///    长按是同一件事的触屏形态。
///
/// Note: 为什么动作走斜杠命令而不是新方法、为什么没有 `GoalActivation` ——
/// 见 `.agents/notes/implemented/2026-11-04-goal-bar-on-phone.md`。
library;

import 'package:flutter/material.dart';

import '../data/app_model.dart';
import '../model/goal.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';
import 'dsh_toast.dart';

/// 阶段标签（`ui-goal/src/client/locales.ts:5-8` 的 zh 值，逐字）。
///
/// **`complete` 不在这张表里**：那一条整根不画（`GoalBar.tsx:86`）。
/// 也**没有** `phase.active.disarmed`（"已暂停的目标"）—— 那要进程内的
/// `GoalActivation`（`goal/src/types.ts:66`），手机拿不到，所以 active 一律当已激活。
const Map<GoalPhase, String> kGoalPhaseLabels = <GoalPhase, String>{
  GoalPhase.active: '进行中的目标',
  GoalPhase.paused: '已暂停的目标',
  GoalPhase.blocked: '受阻的目标',
};

/// 动作的提示语（`locales.ts:11-16` 的 zh 值，逐字）。
const String kGoalSaveLabel = '保存目标';
const String kGoalCancelLabel = '取消编辑';
const String kGoalPauseLabel = '暂停目标';
const String kGoalResumeLabel = '恢复目标';
const String kGoalEditLabel = '编辑目标';
const String kGoalClearLabel = '清除目标';

/// 条子的高度（DSH `.bar` 的 `height: 36px`）。
///
/// 在 Flutter 里落成 **`minHeight`** 而不是定高：字号放大后（`type-scale.md` §5）
/// 定高会把文字裁掉。标准字号下量到的就是 36（内容 24 + 上下各 4 + 余量）。
const double kGoalBarHeight = 36;

/// 条子在这一列里占掉的高度：条高 + 它自己的下边距（`fromLTRB(8,0,8,6)`）。
///
/// 底部预算（`chat_page.dart` 的 `_BottomBudget`）要按这个数让出空间，
/// 否则接管卡 + 候选面板 + 目标条三者相加会顶出屏幕。
const double kGoalBarBlockHeight = kGoalBarHeight + 6;

/// 目标条。**没有目标 / 已完成 / 刚清掉时整条不占位**。
class GoalBar extends StatefulWidget {
  const GoalBar({super.key, required this.app});

  /// 数据与动作都从这里来：`goal` 是当前会话那一包投影，
  /// `executeCommand` 把动作送到电脑侧（见文件头）。
  final AppModel app;

  /// 这个目标要不要画条 —— **判据只有这一处**。
  ///
  /// `build` 用它，`chat_page.dart` 的底部预算也用它（`_BottomBudget` 的
  /// `goalActive`）：两处各写一遍 `phase != complete`，预算与实际高度迟早对不上
  /// （条子 42dp 白让 / 少让，都是真机上才会看见的那种溢出）。
  ///
  /// **不含"刚清掉"那个本地闩**（那是 [State] 里的 `_clearedGoalId`）：
  /// 它最多让预算多让一次往返的空间，不会让布局错。
  static bool visibleFor(GoalView? goal) => goal != null && goal.visible;

  @override
  State<GoalBar> createState() => _GoalBarState();
}

class _GoalBarState extends State<GoalBar> {
  /// 行内编辑的输入框（DSH 的 `InlineEditor` 位置，不弹 sheet）。
  final _draft = TextEditingController();

  /// 行内输入框的焦点（**显式请求**，理由见 [_beginEdit]）。
  final _draftFocus = FocusNode();

  /// 正在编辑吗 —— 与 [_editingGoalId] 合起来才成立。
  bool _editing = false;

  /// 打开编辑时那个目标的身份。
  ///
  /// 目标换了身份（被清掉 / 被替换）就必须退出编辑：DSH 同一条
  /// （`GoalBar.tsx:50-57` 的 `useEffect([goalId])`，注释原话是
  /// "a surviving draft's Enter would write over the NEW goal"）。
  /// 这里不存"要不要重置"的标记，而是**每次都按身份比一次** ——
  /// 那是一条判据，不是一份状态。
  String? _editingGoalId;

  /// 刚清掉的那个目标。清成功到投影重读回来之间，条子还在屏幕上，
  /// 用户会以为没清掉而再点一次（DSH 的 `clearedGoalId`，`GoalBar.tsx:47,86`）。
  String? _clearedGoalId;

  /// 有动作在飞（DSH 的 `pending`：连点不许发两次同样的 CAS）。
  bool _pending = false;

  @override
  void dispose() {
    _draft.dispose();
    _draftFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final goal = widget.app.goal;
    // 三种"没有"共用一条出路：读不到 / 没有目标 / 已完成（`GoalBar.tsx:86`）。
    if (!GoalBar.visibleFor(goal)) return const SizedBox.shrink();
    if (goal!.id == _clearedGoalId) return const SizedBox.shrink();
    final editing = _editing && _editingGoalId == goal.id;
    final c = context.dshColors;

    final bar = Container(
      key: const Key('goal-bar'),
      // **`minHeight` 而不是定高**：字号放大后内容会变高（`type-scale.md` §5）。
      constraints: const BoxConstraints(minHeight: kGoalBarHeight),
      padding: const EdgeInsets.fromLTRB(12, 4, 5, 4),
      decoration: BoxDecoration(
        // `.bar::before` 的 `background: var(--dsw-specific-menu)`。
        color: c.menu,
        borderRadius: BorderRadius.circular(DshRadius.md),
        // `--dsw-elevation-panel`：`0 0 0 0.5px <border-l1>` +
        // `0 3px 8px rgba(0,0,0,.03)` + `0 0 16px rgba(0,0,0,.02)`
        // （`gradient-shadow-text.css` 的 `--dsw-elevation-panel`；
        // `.bar` 自己把描边色重绑成 `border-l1`，`GoalBar.module.css:32`）。
        boxShadow: [
          BoxShadow(color: c.borderL1, spreadRadius: 0.5),
          const BoxShadow(
            color: Color(0x08000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
          const BoxShadow(color: Color(0x05000000), blurRadius: 16),
        ],
      ),
      child: editing ? _editRow(c) : _readRow(c, goal),
    );

    final blocked = goal.phase == GoalPhase.blocked;
    final reason = goal.blockedReason?.message;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      // **受阻时整条 `title` = `blockedReason.message`**（`GoalBar.tsx:129,134`）：
      // 桌面是 HTML 的 `title`，触屏上同一件事是长按。
      child: blocked && reason != null && reason.isNotEmpty
          ? Tooltip(message: reason, child: bar)
          : bar,
    );
  }

  /// 常态那一行：图标 → 阶段标签 → 正文（一行省略）→ 动作。
  Widget _readRow(DshColorTokens c, GoalView goal) {
    final label = kGoalPhaseLabels[goal.phase] ?? goal.phase.wire;
    return Row(
      children: [
        // `.goalGlyph`：`label-tertiary`，14。
        DshIcon('goal', size: 14, color: c.labelTertiary),
        const SizedBox(width: 10),
        // `.label`：13/24、500、`label-primary`。
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            height: 24 / 13,
            fontWeight: FontWeight.w500,
            color: c.labelPrimary,
          ),
        ),
        const SizedBox(width: 10),
        // `.objective`：13/20、`label-primary-dimmed`、单行省略。
        Expanded(
          child: Text(
            goal.objective,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              height: 20 / 13,
              color: c.labelPrimaryDimmed,
            ),
          ),
        ),
        const SizedBox(width: 10),
        // 动作：**暂停只在 active**、**恢复只在非 active**（`GoalBar.tsx:140-153`）。
        // 两者互斥，所以最多三个钮。`.actions` 的 `gap: 10px` 用 `spacing` 表达 ——
        // 28dp 的圆钮挨着放，触屏上很容易点到隔壁那一个。
        Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 10,
          children: [
            if (goal.phase == GoalPhase.active)
              _GoalAction(
                icon: 'pause',
                tooltip: kGoalPauseLabel,
                enabled: !_pending,
                onTap: () => _run('/goal pause'),
              ),
            if (goal.phase != GoalPhase.active)
              _GoalAction(
                icon: 'play',
                tooltip: kGoalResumeLabel,
                enabled: !_pending,
                onTap: () => _run('/goal resume'),
              ),
            _GoalAction(
              icon: 'edit',
              tooltip: kGoalEditLabel,
              enabled: !_pending,
              onTap: () => _beginEdit(goal),
            ),
            _GoalAction(
              icon: 'trash',
              tooltip: kGoalClearLabel,
              enabled: !_pending,
              onTap: () => _clear(goal),
            ),
          ],
        ),
      ],
    );
  }

  /// 编辑那一行：输入框 + 保存 / 取消（`.editBar`，`GoalBar.tsx:88-127`）。
  ///
  /// **三段对齐在同一条中线上**：DSH 的 `.editBar` 用 `align-items: flex-end`，
  /// 那是为了多行正文时把动作贴在最后一行；这一格是**单行**（理由见下面
  /// `maxLines: 1` 那条注释），用 `end` 会把图标贴到输入框底边、与文字错开
  /// （真机 2026-11-04 用户反馈"点编辑的时候字和图标不水平"）。
  Widget _editRow(DshColorTokens c) {
    final canSave = !_pending && _draft.text.trim().isNotEmpty;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        DshIcon('goal', size: 14, color: c.labelTertiary),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(
            key: const Key('goal-draft'),
            controller: _draft,
            focusNode: _draftFocus,
            // **单行**：这一格的内容要拼进一条命令行，而连接器拒收带换行的行
            // （`connector/src/handlers.ts:1242-1246`：`line 不能包含换行`）。
            // 摆一个能敲换行的框，等于让用户打出永远存不上的目标。
            minLines: 1,
            maxLines: 1,
            textInputAction: TextInputAction.done,
            // 输入法联想会破坏命令文本（`tools.md` 的配对码那条教训），
            // 目标是用户原话，不该被自动改写。
            autocorrect: false,
            enableSuggestions: false,
            style: TextStyle(
              fontSize: 13,
              height: 20 / 13,
              color: c.labelPrimary,
            ),
            cursorColor: c.accentBlue,
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 6),
              hintText: '目标内容',
              hintStyle: TextStyle(fontSize: 13, color: c.labelTertiary),
            ),
            // 空草稿**不在本地拦**是 DSH 的做法（`GoalBar.tsx:74-75` 直接 return），
            // 这里同样只是不发 —— 保存钮同时置灰，两种反馈说的是同一件事。
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _save(),
          ),
        ),
        const SizedBox(width: 10),
        _GoalAction(
          icon: 'check',
          tooltip: kGoalSaveLabel,
          enabled: canSave,
          onTap: _save,
        ),
        _GoalAction(
          icon: 'close',
          tooltip: kGoalCancelLabel,
          enabled: !_pending,
          onTap: () => setState(() => _editing = false),
        ),
      ],
    );
  }

  void _beginEdit(GoalView goal) {
    // 打开编辑时把当前正文装进去（DSH：`setDraft(goal.objective)`，
    // `GoalBar.tsx:159`）—— 编辑的是"这一句"，不是从空白重写。
    _draft.text = goal.objective;
    setState(() {
      _editing = true;
      _editingGoalId = goal.id;
    });
    // **焦点要显式请求，不能靠 `autofocus`**。
    //
    // `TextField.autofocus` 走的是 `FocusScopeNode.autofocus`，而那个请求只在
    // "所在 FocusScope 还没有焦点子节点"时才被应用（`focus_manager.dart:158-171`
    // 的 `_Autofocus.applyIfValid`：`scope.focusedChild == null` 是硬条件，
    // 不满足就**静默丢弃**）。这一条永远与输入栏同时在场，点「编辑目标」时
    // 输入栏正握着焦点 ⇒ autofocus 失效、键盘还连着输入栏。
    // 真机 2026-11-04 实测到的就是这个：点编辑后打的字全进了消息输入框。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_editing) return;
      _draftFocus.requestFocus();
    });
  }

  /// 保存：`/goal edit <objective>`（`command-goal/src/index.ts:43,154-164`）。
  Future<void> _save() async {
    // **换行折成空格**：输入框是单行，但粘贴进来的文本仍可能带换行，而连接器
    // 在拼命令行之前就拒收带换行的 `line`（`connector/src/handlers.ts:1242-1246`）。
    // 折的是"换行"，不是正文里的空格 —— 目标是一句话，句中的空格照留。
    final objective = _draft.text
        .replaceAll(RegExp(r'\s*[\r\n]+\s*'), ' ')
        .trim();
    if (objective.isEmpty) return;
    final ok = await _run('/goal edit $objective');
    if (!mounted) return;
    if (ok) setState(() => _editing = false);
  }

  /// 清除：`/goal clear`，成功后**立刻不画**（见 [_clearedGoalId]）。
  Future<void> _clear(GoalView goal) async {
    final ok = await _run('/goal clear');
    if (!mounted || !ok) return;
    setState(() => _clearedGoalId = goal.id);
  }

  /// 跑一条目标命令，按 `CommandOutcome` 的三段式报告。
  ///
  /// 与 `chat_page.dart` 的 `_switchPermission` 同一套分支：
  /// 没有结论 / 电脑上没有这条命令 / 电脑回了 error（原文照显）。
  /// **成功不弹**：条子自己会变（`goal/change` → 重读投影），
  /// 那是 `DshToast` 的第一条规则（"结果在屏幕上直接看得见的不弹"）。
  ///
  /// @returns 电脑侧真的跑成功了。
  Future<bool> _run(String line) async {
    if (_pending) return false;
    setState(() => _pending = true);
    final outcome = await widget.app.executeCommand(line);
    if (!mounted) return false;
    setState(() => _pending = false);
    if (outcome == null) {
      DshToast.show(
        context,
        '目标操作失败：${widget.app.lastError?.message ?? '电脑侧没有给结论'}',
        kind: DshToastKind.error,
      );
      return false;
    }
    if (!outcome.matched) {
      DshToast.show(
        context,
        '这台电脑上没有 /goal 命令，改不了目标',
        kind: DshToastKind.error,
      );
      return false;
    }
    if (outcome.kind == 'error') {
      // DSH 的原文（如「A goal is already paused. Use /goal edit …」）——
      // 那是电脑侧权威的措辞，自己抄一份就会静默分叉。
      DshToast.show(
        context,
        outcome.text ?? '电脑侧拒绝了这次目标操作',
        kind: DshToastKind.error,
      );
      return false;
    }
    return true;
  }
}

/// 行内动作钮（28×28，与 `.iconBtn` 同一量级）。
class _GoalAction extends StatelessWidget {
  const _GoalAction({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onTap,
  });

  final String icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    // `.iconBtn:disabled` 是整颗 `opacity: 0.4`（`GoalBar.module.css:129-132`）。
    final color = enabled
        ? c.labelTertiary
        : c.labelTertiary.withValues(alpha: 0.4);
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 28,
        height: 28,
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: enabled ? onTap : null,
            child: Center(child: DshIcon(icon, size: 14, color: color)),
          ),
        ),
      ),
    );
  }
}
