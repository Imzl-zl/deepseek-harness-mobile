/// 输入栏接管（照 `mock/proto/interactions.js` 的 `Takeovers`）。
///
/// ## 它接管什么、为什么
///
/// DSH 的审批与提问**不在气泡里**，而是**接管输入栏**（composer takeover）：
/// 有问题待答时，输入框那个位置换成问题卡 —— 用户的下一步动作是"回答"，
/// 不是"继续打字"。答完卡片消失，输入栏回来。
///
/// 原型里对话流只留一行可点回来的入口（`TakeoverHint`），因为
/// **收起后要能重新打开**（DSH 的 `nav.close` 语义）。
///
/// ## 三条从原型抄来的语义（不是我自己定的）
///
/// 1. **"允许一次" = `allowed-once`**，不是权限变更。原型
///    `settleApproval(item, 'allowed-once')` 与 `'rejected'` 是**两个结果值**，
///    而权限档位（`perm`）是另一套东西。混起来会让"点了一次允许"变成永久放权。
/// 2. **回答在途时按钮禁用**（`item.busy`）：不只是防重复提交，
///    也是给用户"它在处理"的反馈（原型把状态点换成转圈）。
///
/// **没有"完全权限下审批不入队"这条过滤**（2026-10-24 删）：DSH 在
/// `danger-full-access` 预设下把审批策略写成 `never`
/// （`packages/bundle/base/cordis.patch.yml:274-276`），而 `never` 在 **dispatch 之前**
/// 就 `rejected`（`packages/interaction/user-approval/src/index.ts:270-275`）——
/// 那时**根本不产生 `approval/request`**。所以那层过滤过滤的是一个不会发生的场景，
/// 浏览器侧也没有同类判断。
///
/// ## 队列按**会话**分桶（2026-10-13，对齐 DSH 原生）
///
/// DSH 的待处理是 per-session 的：`PendingApproval` / `PendingQuestion` 都带
/// `sessionId`，注册进**那个会话**的 composer（`ui-session/src/client/index.ts:391`、
/// `ui-approval/src/client/contract/slots.ts:101`）。电脑上并行开着几个会话时，
/// 每个会话各有各的待处理，用户切到哪个会话就处理哪个。
///
/// 我们这边同构：**一个会话一队，一次只处理队首**（不铺成列表是因为审批要
/// 逐个看 —— 一次批准五件事等于没看）。切会话 = 换桶，另一个会话的待处理
/// 既不会插到眼前，也不会丢。跨会话的"还有几个在等"由会话行角标表达
/// （`SessionSummary.pendingCount`），否则用户不知道别的会话有东西等他。
///
/// 同一会话多个待处理的先后照 DSH 的确定性优先级，**大的赢**：
/// 计划审查 2 > 提问 1 > 审批 0（`ui-user-questions/src/client/index.ts:372`、
/// `ui-approval/src/client/index.ts:89`）。**不自己发明"审批最急"** ——
/// 那是 DSH 已经定过的次序。
///
/// ## 类型在 `model/interaction.dart`
///
/// `InteractionItem` 一族是**会话事件的投影**（契约 §6.3），所以归领域层；
/// 本文件只留状态机（`TakeoverController`）与渲染。这里 re-export 它们，
/// 免得每个调用方都要同时认识两个文件。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../model/interaction.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';

export '../model/interaction.dart'
    show
        InteractionAnswer,
        InteractionAnswerItem,
        InteractionItem,
        InteractionKind,
        InteractionOpened,
        InteractionOption,
        InteractionQuestion,
        InteractionSettled,
        InteractionSignal,
        approvalAllowLabel;

/// 阶段（决定卡片长什么样）。
enum TakeoverPhase {
  /// 无待处理 —— 输入栏正常。
  idle,

  /// 有待处理的队首。
  active,

  /// 回答在途（按钮禁用）。
  busy,

  /// 已收起（对话流里留一行提示）。
  minimized,
}

/// 输入栏接管的**状态机**（`ChangeNotifier`）。
///
/// 它只管"现在轮到谁、答到哪一步"；渲染在 [TakeoverPanel]。
///
/// **一个会话一队**（见文件头"队列按会话分桶"）：`_bySid` 是桶，
/// [_currentSid] 决定当前看哪一桶。没有当前会话时（列表页）任何桶都不可见，
/// 但项**不会丢** —— 切回去还在。
class TakeoverController extends ChangeNotifier {
  /// 待处理桶：`sid → 该会话的队`（每队内部按 DSH 的优先级排序）。
  final Map<String, List<InteractionItem>> _bySid = {};

  /// 当前会话（`null` = 在列表页，看不到任何卡片）。
  String? _currentSid;

  /// 当前题号（提问可能有多个问题）。
  int _questionIndex = 0;

  /// 每题的选择（多选用 `Set`，单选只留一个）。**按问题 id 记**，不按 item 记 ——
  /// 一次提问可以有多个问题，而它们的草稿必须各自独立（原型 `qs.drafts[q.id]`）。
  final Map<String, Set<String>> _selected = {};

  /// 每题的自定义答案。
  final Map<String, String> _custom = {};

  /// 被**显式跳过**的问题（原型 `qs.skipped[q.id]`）。
  ///
  /// 为什么要单独记：空 `selected` 且无 `custom` 是**合法的「显式跳过」**
  /// （DSH `tool-ask-user/src/timed.ts:172,179` 的输出 schema 原文
  /// "Empty with no custom means the user explicitly skipped this question"），
  /// 它与"还没答"是两件事 —— 后者不该让提交可点，前者应该。
  final Set<String> _skipped = {};

  bool _busy = false;
  bool _minimized = false;

  /// 答复出口（`interaction.respond`）。**装配时注入**：控制器不认识 `AppModel`，
  /// 于是"答一次"在单测里可以只断言产出了什么批次，而不必起一个假客户端。
  ///
  /// 返回的 Future 完成 = 电脑侧已接受；抛错 = 那一项已经不在待处理集合里
  /// （`interaction/not-pending`，客户端动作是"刷新待处理列表"）。
  Future<void> Function(InteractionAnswer answer)? onAnswer;

  /// 当前看哪个会话的队。**切会话就换桶**（DSH 的待处理本来就是 per-session）。
  void setCurrentSid(String? sid) {
    if (sid == _currentSid) return;
    _currentSid = sid;
    _questionIndex = 0;
    _minimized = false;
    notifyListeners();
  }

  /// 当前会话。
  String? get currentSid => _currentSid;

  /// 当前会话的队（只读快照）。
  List<InteractionItem> get queue => List.unmodifiable(_queueOf(_currentSid));

  InteractionItem? get active =>
      _queueOf(_currentSid).isEmpty ? null : _queueOf(_currentSid).first;

  List<InteractionItem> _queueOf(String? sid) =>
      sid == null ? const [] : (_bySid[sid] ?? const []);

  /// 某个会话还有几个待处理（会话行角标用；`null` 会话回 0）。
  int pendingCountOf(String? sid) => _queueOf(sid).length;

  /// **别的**会话还有几个待处理（顶栏/空态提示用）。
  int pendingElsewhere() {
    var total = 0;
    for (final entry in _bySid.entries) {
      if (entry.key == _currentSid) continue;
      total += entry.value.length;
    }
    return total;
  }

  TakeoverPhase get phase {
    if (_minimized) return TakeoverPhase.minimized;
    if (active == null) return TakeoverPhase.idle;
    return _busy ? TakeoverPhase.busy : TakeoverPhase.active;
  }

  /// 回答在途（按钮要禁用）。
  bool get busy => _busy;

  /// 当前题号。
  int get questionIndex => _questionIndex;

  /// 当前这一题（多题时按题号走；单题时就是第一题）。
  InteractionQuestion? get currentQuestion {
    final item = active;
    if (item == null) return null;
    if (item.questions.isEmpty) return null;
    final index = _questionIndex.clamp(0, item.questions.length - 1);
    return item.questions[index];
  }

  /// 答完的事件（回执要落进对话流）。
  ///
  /// 元素是 `(key, 回执文案)`。
  final List<({String key, String text})> receipts = [];

  /// 入队一个事件。**按它自己的 `sid` 进桶** —— 当前不在看的会话也照收，
  /// 切回去就看见（DSH 的待处理本来就是 per-session 的）。
  bool enqueue(InteractionItem item) {
    final bucket = _bySid.putIfAbsent(item.sid, () => <InteractionItem>[]);
    // 同一个 key 不重复入队（收起后重新打开走的是"取消最小化"而不是再入一次）。
    if (bucket.any((i) => i.itemId == item.itemId)) {
      if (item.sid == _currentSid) {
        _minimized = false;
        notifyListeners();
      }
      return true;
    }
    bucket.add(item);
    // **同桶按 DSH 的确定性优先级排**（大的赢：计划 2 > 提问 1 > 审批 0）。
    // 稳定排序：同优先级保持到达顺序（先来先处理）。
    final ordered = List<InteractionItem>.of(bucket)
      ..sort((a, b) => _precedence(b).compareTo(_precedence(a)));
    _bySid[item.sid] = ordered;
    if (item.sid == _currentSid) {
      _questionIndex = 0;
      _minimized = false;
    }
    notifyListeners();
    return true;
  }

  /// 待处理优先级（照 DSH：`ui-user-questions/.../index.ts:372` 的
  /// `plan-review ? 2 : 1`，`ui-approval/.../index.ts:89` 的 `() => 0`）。
  static int _precedence(InteractionItem item) => switch (item.kind) {
    InteractionKind.plan => 2,
    InteractionKind.question => 1,
    InteractionKind.approval => 0,
  };

  /// 收束一个待处理项（电脑侧已经决定了 / 已经答过了）。
  ///
  /// 返回是否真的撤掉了一个。**撤掉的不是队首也没关系**：一次迟到的
  /// `approval/decided` 可能排在别的待处理项后面。
  bool settle(String itemId, {String? sid}) {
    // 有 sid 就只翻那个桶；没有就全桶找（迟到事件的 sid 一定带，但调用方
    // 偷懒只给 itemId 时也该工作）。
    final keys = sid == null ? _bySid.keys.toList() : <String>[sid];
    for (final key in keys) {
      final bucket = _bySid[key];
      if (bucket == null) continue;
      final index = bucket.indexWhere((i) => i.itemId == itemId);
      if (index < 0) continue;
      bucket.removeAt(index);
      if (bucket.isEmpty) _bySid.remove(key);
      if (index == 0 && key == _currentSid) {
        _minimized = false;
        _questionIndex = 0;
      }
      notifyListeners();
      return true;
    }
    return false;
  }

  /// 收起（对话流里留一行提示，卡片消失但**没被回答**）。
  void minimize() {
    if (active == null) return;
    _minimized = true;
    notifyListeners();
  }

  /// 从提示重新打开。
  void restore() {
    if (active == null) return;
    _minimized = false;
    notifyListeners();
  }

  /// 上一题 / 下一题（多题向导，原型 `qs.index`）。
  void goToQuestion(int index) {
    final item = active;
    if (item == null || _busy) return;
    if (index < 0 || index >= item.questions.length) return;
    _questionIndex = index;
    notifyListeners();
  }

  /// 选中 / 取消一个选项。
  void toggleOption(String optionLabel) {
    final question = currentQuestion;
    if (question == null || _busy) return;
    final picked = _selected.putIfAbsent(question.id, () => <String>{});
    if (question.multiSelect) {
      if (!picked.remove(optionLabel)) picked.add(optionLabel);
    } else {
      // 单选：再点同一个是取消（否则选错了没法退回"未选"）。
      if (picked.contains(optionLabel)) {
        picked.clear();
      } else {
        picked
          ..clear()
          ..add(optionLabel);
      }
    }
    // 选了东西就不再是"跳过"—— 两个状态互斥。
    _skipped.remove(question.id);
    notifyListeners();
  }

  /// 当前选中的选项。
  Set<String> get selected =>
      _selected[currentQuestion?.id] ?? const <String>{};

  /// 当前的自定义答案。
  String get custom => _custom[currentQuestion?.id] ?? '';

  /// 写入自定义答案。
  void setCustom(String text) {
    final question = currentQuestion;
    if (question == null || _busy) return;
    _custom[question.id] = text;
    _skipped.remove(question.id);
    notifyListeners();
  }

  /// 当前这一题是否已被**显式跳过**。
  bool get skipped => _skipped.contains(currentQuestion?.id);

  /// 已回答（选了选项、写了自定义、或显式跳过）——
  /// 决定"下一题/提交"是否可点（照原型的 `answered`，但把跳过算进去）。
  bool get answered =>
      selected.isNotEmpty || custom.trim().isNotEmpty || skipped;

  /// 审批：拒绝。
  Future<void> reject() => _settleApproval('rejected', '已拒绝');

  /// 审批：**允许一次**（`allowed-once`，不是权限变更）。
  Future<void> allowOnce() => _settleApproval('allowed-once', '允许一次');

  /// 计划的两种结局。`approveLabel` 由 DSH 给（`intent.approve`），
  /// 手机不自己判"哪个标签算同意"—— 那正是契约 §6.4 的要求。
  Future<void> settlePlan({required bool approved}) async {
    final item = active;
    if (item == null || _busy) return;
    final label = item.approveLabel;
    if (approved && (label == null || label.isEmpty)) {
      // 没有同意标签就没法编码"同意"：那说明这条计划不是 DSH 的计划审查，
      // 而是别的什么。如实失败，而不是随便挑一个选项顶替。
      receipts.add((key: item.itemId, text: '计划回执 · 缺少同意标签，未能提交'));
      notifyListeners();
      return;
    }
    await _send(
      InteractionAnswer(
        sid: item.sid,
        itemId: item.itemId,
        answers: [
          InteractionAnswerItem(
            id: item.itemId,
            selected: approved ? <String>[label!] : const <String>[],
          ),
        ],
      ),
      (
        key: item.itemId,
        text: '计划回执 · ${item.title} · ${approved ? '同意执行' : '要求修改'}',
      ),
    );
  }

  Future<void> _settleApproval(String outcome, String label) async {
    final item = active;
    if (item == null || _busy) return;
    // 审批的答案是"选中的标签里有没有 `allowed-once`"：空 `selected` = 显式跳过 = 拒绝。
    await _send(
      InteractionAnswer(
        sid: item.sid,
        itemId: item.itemId,
        answers: [
          InteractionAnswerItem(
            id: item.itemId,
            selected: outcome == 'allowed-once'
                ? <String>[approvalAllowLabel]
                : const <String>[],
          ),
        ],
      ),
      (key: item.itemId, text: '审批回执 · ${item.toolName} · $label（$outcome）'),
    );
  }

  /// 显式跳过当前这一题（原型 `skipQuestion`）。
  ///
  /// **空答案是合法跳过**，不是"没答"：DSH 的输出 schema 明说
  /// "Empty with no custom means the user explicitly skipped this question"。
  /// 拦截它等于把合法答案变成失败。
  void skipQuestion() {
    final question = currentQuestion;
    if (question == null || _busy) return;
    _skipped.add(question.id);
    _selected.remove(question.id);
    _custom.remove(question.id);
    notifyListeners();
  }

  /// 提问：下一题 / 提交（原型 `continueFlow`）。
  ///
  /// 最后一题提交时把**每一题**的答案整理成一个批次；未回答的题不会被跳过 ——
  /// 调用方（`answered`）保证按钮不可点。
  Future<void> submitQuestion() async {
    final item = active;
    if (item == null || _busy || !answered) return;
    if (_questionIndex < item.questions.length - 1) {
      _questionIndex += 1;
      notifyListeners();
      return;
    }
    final all = <String>[
      for (final question in item.questions) ...?_selected[question.id],
    ];
    await _send(
      InteractionAnswer(
        sid: item.sid,
        itemId: item.itemId,
        answers: [
          for (final question in item.questions)
            InteractionAnswerItem(
              id: question.id,
              selected: <String>[...?_selected[question.id]],
              custom: _custom[question.id]?.trim().isNotEmpty == true
                  ? _custom[question.id]!.trim()
                  : null,
            ),
        ],
      ),
      (key: item.itemId, text: '已回答 · ${all.join(' / ')}'),
    );
  }

  /// 发一次答复：**只有真的发出去了**才写回执、撤卡。
  ///
  /// 失败（传输 / 超时 / 这一项已经没了）**不写回执、不撤卡** —— 卡片的去留由调用方
  /// （`chat_page` 的 `_onTakeoverAnswer`）按错误码决定：`interaction/not-pending` 撤，
  /// 其余留卡可重试。这里只保证 `_busy` 一定复位（没有 `finally` 会让卡片永远禁用）。
  ///
  /// 因果见 `.agents/notes/implemented/2026-10-23-in-flight-interaction-is-host-held.md`。
  Future<void> _send(
    InteractionAnswer answer,
    ({String key, String text}) receipt,
  ) async {
    _busy = true;
    notifyListeners();
    var sent = false;
    try {
      await _submit(answer);
      sent = true;
    } on Exception {
      // 提示与撤卡由调用方处理；这里只吞掉异常让 busy 复位（错误已经报给用户了）。
      sent = false;
    } finally {
      _busy = false;
      notifyListeners();
    }
    if (!sent) return;
    receipts.add(receipt);
    settle(answer.itemId, sid: answer.sid);
  }

  /// 把答复交给注入的出口。**没有出口时只记回执**（演示模式）。
  ///
  /// 失败**不吞**：`interaction/not-pending` 要让调用方看见，否则用户以为答成功了。
  Future<void> _submit(InteractionAnswer answer) async {
    final send = onAnswer;
    if (send == null) return;
    await send(answer);
  }
}

/// 接管卡（原型 `.tk`）。
///
/// ## 高度上限按**可用高度**算，不是屏幕高度
///
/// 2026-10-20 真机：审批卡 + 输入栏 + 键盘同时在场时底部报
/// `BOTTOM OVERFLOWED BY 79 PIXELS`。原因是上限用了
/// `MediaQuery.size.height * 0.45` —— 那是**整窗高度**，而键盘弹起后
/// 留给"接管卡 + 输入栏"的高度只剩一小半。扣掉 `viewInsets.bottom` 才是
/// 真正可用的高度（`Scaffold` 会按它压缩 body）。
///
/// [fraction] 是占可用高度的比例：整张卡 0.5、卡内正文 0.45
/// （正文那一层外面还有卡片自身的 margin / 边框，取小一点才不会把外框顶满）。
double takeoverMaxHeightFor(BuildContext context, {double fraction = 0.5}) {
  final media = MediaQuery.of(context);
  return (media.size.height - media.viewInsets.bottom) * fraction;
}

class TakeoverPanel extends StatefulWidget {
  const TakeoverPanel({super.key, required this.controller});

  final TakeoverController controller;

  @override
  State<TakeoverPanel> createState() => _TakeoverPanelState();
}

class _TakeoverPanelState extends State<TakeoverPanel> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final item = widget.controller.active;
        // **别的会话还有待处理**：本会话空着也要说一声，否则用户不知道
        // 电脑那边还有事在等他（切过去才看得见，而他没有理由知道要切）。
        if (item == null) {
          final elsewhere = widget.controller.pendingElsewhere();
          if (elsewhere == 0) return const SizedBox.shrink();
          return const _ElsewhereHint();
        }
        // **收起时要真的收掉**：`minimize()` 只改 phase，卡片本身仍会被
        // 构建 —— 不看 phase 的话"收起"按钮点了没反应
        //（队列没减、卡片还在）。收起的语义是"对话流里留一行可点回来的提示"，
        // 那行提示由 `TakeoverHint` 渲染，不是这一层。
        if (widget.controller.phase == TakeoverPhase.minimized) {
          return const SizedBox.shrink();
        }
        // **整张卡有高度上限**：它和输入栏、统计条同在一个 `Column` 里，
        // 而消息列表是 `Expanded` —— 卡片不设上限就会把那个 `Column` 撑爆
        //（实测在 800×544 上报 `RenderFlex overflowed by 9.0 pixels`）。
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: takeoverMaxHeightFor(context)),
          child: Container(
            // 接管卡从下往上浮入 —— 用 `AnimatedSize` 而不是硬切。
            margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            decoration: BoxDecoration(
              color: c.layer1,
              borderRadius: BorderRadius.circular(DshRadius.lg),
              border: Border.all(
                color: switch (item.kind) {
                  // 审批是"要你拿主意"的事 —— 告警色边框。
                  InteractionKind.approval => c.roleTool,
                  InteractionKind.plan => c.businessBlue,
                  InteractionKind.question => c.layer2,
                },
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              // 三个部分（顶条 / 主体 / 动作）在高度受限时，**主体先让位**
              //（它内部已经可滚），顶条与动作行必须完整可见 ——
              // 用户最需要的恰恰是那两个按钮。
              mainAxisSize: MainAxisSize.min,
              children: [
                _Strip(controller: widget.controller, item: item),
                Flexible(
                  child: _Body(
                    controller: widget.controller,
                    item: item,
                    input: _input,
                  ),
                ),
                _Actions(
                  controller: widget.controller,
                  item: item,
                  input: _input,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// "别的会话还有待处理"的一行提示（本会话的输入栏空着时显示）。
///
/// 它**不抢输入栏**：只是一行可点的提示，点了也切不过去（切会话要走列表）——
/// 所以它只负责"告诉你还有事"，不假装能处理。
class _ElsewhereHint extends StatelessWidget {
  const _ElsewhereHint();

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: c.layer2,
        borderRadius: BorderRadius.circular(DshRadius.md),
      ),
      child: Row(
        children: [
          DshIcon('queue', size: 14, color: c.labelSecondary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '其他会话还有待处理，去会话列表切换',
              style: TextStyle(fontSize: 12, color: c.labelSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶条（`.tk-strip`：状态点 + 一句话 + 权限档）。
class _Strip extends StatelessWidget {
  const _Strip({required this.controller, required this.item});

  final TakeoverController controller;
  final InteractionItem item;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final label = switch (item.kind) {
      InteractionKind.approval => '等待审批',
      InteractionKind.question => '等待回答',
      InteractionKind.plan => '等待确认计划',
    };
    // 审批与计划用告警/业务色，提问是中性的。
    final tone = switch (item.kind) {
      InteractionKind.approval => c.roleTool,
      InteractionKind.plan => c.businessBlue,
      InteractionKind.question => c.labelSecondary,
    };
    return Container(
      color: c.layer2,
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      child: Row(
        children: [
          if (controller.busy)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
            ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: tone,
            ),
          ),
          const Spacer(),
          // 收起（对话流里留一行可点回来的提示）。
          IconButton(
            tooltip: '收起',
            visualDensity: VisualDensity.compact,
            onPressed: controller.minimize,
            icon: DshIcon('chevronDown', size: 16, color: c.labelTertiary),
          ),
        ],
      ),
    );
  }
}

/// 主体（`.tk-body`）。
class _Body extends StatelessWidget {
  const _Body({
    required this.controller,
    required this.item,
    required this.input,
  });

  final TakeoverController controller;
  final InteractionItem item;
  final TextEditingController input;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    // **多题时按当前题渲染**（原型 `qs.index`）：一次提问可以有 1..N 个问题，
    // 铺成一屏长表单会让用户漏答，而逐个走正是 DSH 桌面端 `QuestionComposer` 的形状。
    final question = controller.currentQuestion;
    final multi = item.questions.length > 1;
    return ConstrainedBox(
      // **明细可以很长（审批的 diff、多题的选项），但整张卡必须有上限**。
      //
      // 它和输入栏、统计条同在一个 `Column` 里，而消息列表是 `Expanded` ——
      // 卡片不设上限时会把那个 `Column` 撑爆：实测在 800×544 上报
      // `RenderFlex overflowed by 9.0 pixels on the bottom`（黄黑条）。
      // 上限取**可用高度**（扣掉键盘）的 45%：既能看清明细，也保证输入栏永远在视口内。
      constraints: BoxConstraints(
        maxHeight: takeoverMaxHeightFor(context, fraction: 0.45),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (question != null && question.header != null) ...[
              Text(
                question.header!,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: c.labelCaption,
                ),
              ),
              const SizedBox(height: 4),
            ],
            Text(
              question?.question ?? item.title,
              style: TextStyle(
                fontSize: 14,
                height: 21 / 14,
                fontWeight: FontWeight.w500,
                color: c.labelPrimary,
              ),
            ),
            if (question?.detail != null || item.detail.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: c.bgBase,
                  borderRadius: BorderRadius.circular(DshRadius.sm),
                  border: Border.all(color: c.layer2),
                ),
                child: Text(
                  question?.detail ?? item.detail,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 19 / 12,
                    color: c.labelSecondary,
                  ),
                ),
              ),
            ],
            if (multi) ...[
              const SizedBox(height: 8),
              Text(
                '第 ${controller.questionIndex + 1} / ${item.questions.length} 题',
                style: TextStyle(fontSize: 11, color: c.labelTertiary),
              ),
            ],
            // **计划不渲染选项行**：它的两个动作（要求修改 / 同意执行）就是决策面，
            // 再把 DSH 给的两个标签铺成选项等于让用户在同一次决定上点两处
            // （原型 `planHtml` 也只有正文 + 两个按钮）。
            if (question != null &&
                item.kind != InteractionKind.plan &&
                question.options.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (var i = 0; i < question.options.length; i += 1)
                _OptionRow(
                  index: i,
                  option: question.options[i],
                  multiSelect: question.multiSelect,
                  selected: controller.selected.contains(
                    question.options[i].label,
                  ),
                  disabled: controller.busy,
                  onTap: () =>
                      controller.toggleOption(question.options[i].label),
                ),
            ],
            if (question != null) ...[
              const SizedBox(height: 10),
              _CustomAnswer(controller: controller, input: input),
            ],
          ],
        ),
      ),
    );
  }
}

/// 一个选项（`.opt`）。
///
/// ## 行结构（照原型，与 §7.9 同源）
///
/// `[标记(编号/勾)] [标签 + 其下说明] [推荐徽标]`
///
/// - 单选用**编号**（`1` / `2`…，原型 `.opt-num`），多选用**勾**（`.opt-chk`）
///   —— 编号让"直接说选第 2 个"成为可能；
/// - 说明放标签**下面**（同行会挤掉标签）；
/// - "推荐"是**徽标**，且原型把它从标签里**剥出来**
///   （`label.replace(/（推荐）/g, '')`）—— 于是标签本身干净、徽标位置固定。
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.index,
    required this.option,
    required this.multiSelect,
    required this.selected,
    required this.disabled,
    required this.onTap,
  });

  final int index;
  final InteractionOption option;
  final bool multiSelect;
  final bool selected;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final desc = option.description;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? c.layer2 : c.layer1,
        borderRadius: BorderRadius.circular(DshRadius.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: disabled ? null : onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(DshRadius.md),
              border: Border.all(color: selected ? c.accentBlue : c.layer2),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标记：多选勾、单选编号。
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: selected ? c.accentBlue : c.layer3,
                    borderRadius: BorderRadius.circular(
                      multiSelect ? DshRadius.xs : 10,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: multiSelect
                      ? (selected
                            ? DshIcon('check', size: 12, color: c.onAccent)
                            : const SizedBox.shrink())
                      : Text(
                          '${index + 1}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: selected ? c.onAccent : c.labelSecondary,
                          ),
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              option.label,
                              style: TextStyle(
                                fontSize: 13,
                                color: c.labelPrimary,
                              ),
                            ),
                          ),
                          if (option.recommended) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: c.roleToolBg,
                                borderRadius: BorderRadius.circular(
                                  DshRadius.xs,
                                ),
                              ),
                              child: Text(
                                '推荐',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: c.roleTool,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (desc != null && desc.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          desc,
                          style: TextStyle(fontSize: 12, color: c.labelCaption),
                        ),
                      ],
                    ],
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

/// 自定义答案那一行（`.opt` + 内联输入框）。
///
/// **有状态**：多题时每题一个草稿，而输入框是共用的一个 `TextEditingController`。
/// 换题必须把框里的文字换成那一题的草稿 —— 否则用户会在第二题的输入框里看到
/// 第一题写过的东西，而提交出去的是第二题的（空）草稿。
class _CustomAnswer extends StatefulWidget {
  const _CustomAnswer({required this.controller, required this.input});

  final TakeoverController controller;
  final TextEditingController input;

  @override
  State<_CustomAnswer> createState() => _CustomAnswerState();
}

class _CustomAnswerState extends State<_CustomAnswer> {
  String? _questionId;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final questionId = widget.controller.currentQuestion?.id;
    if (questionId != _questionId) {
      _questionId = questionId;
      // 直接改 `text` 而不是重建 controller：重建会让输入框在每次击键后失焦。
      widget.input.text = widget.controller.custom;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(DshRadius.md),
        border: Border.all(color: c.layer2),
      ),
      child: Row(
        children: [
          DshIcon('edit', size: 14, color: c.labelCaption),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: widget.input,
              enabled: !widget.controller.busy,
              onChanged: widget.controller.setCustom,
              style: TextStyle(fontSize: 13, color: c.labelPrimary),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: '其他答案…',
                hintStyle: TextStyle(fontSize: 13, color: c.labelTertiary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 动作行（`.tk-actions`）。
class _Actions extends StatelessWidget {
  const _Actions({
    required this.controller,
    required this.item,
    required this.input,
  });

  final TakeoverController controller;
  final InteractionItem item;
  final TextEditingController input;

  @override
  Widget build(BuildContext context) {
    final busy = controller.busy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      child: switch (item.kind) {
        // 审批：拒绝 / **允许一次**（不是"允许" —— 一次就是一次）。
        InteractionKind.approval => Row(
          children: [
            Expanded(
              child: _Button(
                label: '拒绝',
                onPressed: busy ? null : () => controller.reject(),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Button(
                label: '允许一次',
                filled: true,
                onPressed: busy ? null : () => controller.allowOnce(),
              ),
            ),
          ],
        ),
        InteractionKind.plan => Row(
          children: [
            Expanded(
              child: _Button(
                label: '要求修改',
                onPressed: busy
                    ? null
                    : () => controller.settlePlan(approved: false),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Button(
                label: '同意执行',
                filled: true,
                onPressed: busy
                    ? null
                    : () => controller.settlePlan(approved: true),
              ),
            ),
          ],
        ),
        // 提问：跳过 + **未回答时提交不可点**（原型 `answered` 那个判据）。
        // 最后一题的按钮写"提交"，中间题写"下一题"（原型 `last ? '提交' : '下一题'`）。
        InteractionKind.question => Row(
          children: [
            SizedBox(
              width: 76,
              child: _Button(
                label: '跳过',
                onPressed: busy || controller.skipped
                    ? null
                    : controller.skipQuestion,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _Button(
                label: controller.questionIndex == item.questions.length - 1
                    ? '提交'
                    : '下一题',
                filled: true,
                onPressed: (busy || !controller.answered)
                    ? null
                    : () {
                        input.clear();
                        // 不等它：提交是"发出去"就完事，卡片会在
                        // `submitQuestion` 内部 `notifyListeners` 后自己消失。
                        unawaited(controller.submitQuestion());
                      },
              ),
            ),
          ],
        ),
      },
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({
    required this.label,
    required this.onPressed,
    this.filled = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final enabled = onPressed != null;
    return Material(
      color: filled ? (enabled ? c.accentBlue : c.layer2) : Colors.transparent,
      borderRadius: BorderRadius.circular(DshRadius.md),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Container(
          height: 42,
          alignment: Alignment.center,
          decoration: filled
              ? null
              : BoxDecoration(
                  borderRadius: BorderRadius.circular(DshRadius.md),
                  border: Border.all(color: c.layer3),
                ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: filled
                  ? (enabled ? c.onAccent : c.labelTertiary)
                  : (enabled ? c.labelPrimary : c.labelTertiary),
            ),
          ),
        ),
      ),
    );
  }
}
