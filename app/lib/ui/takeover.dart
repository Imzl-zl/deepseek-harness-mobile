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
/// 2. **`danger-full-access` 下审批不入队**：原型 `enqueue()` 里
///    `if (item.kind === 'approval' && !needsApproval()) { toast(...); return false }`
///    —— 那是"已授权"的结果，不是绕过。
/// 3. **回答在途时按钮禁用**（`item.busy`）：不只是防重复提交，
///    也是给用户"它在处理"的反馈（原型把状态点换成转圈）。
///
/// ## 收成一队，一次只处理队首
///
/// 原型的注释：`const queue = [] // 待处理队列(瀑布:一次只处理队首)`。
/// 不铺成列表是因为审批要**逐个看**（一次批准五件事等于没看）。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';

/// 待接管的事件的种类。
enum TakeoverKind {
  /// 工具越权，等审批（拒绝 / 允许一次）。
  approval,

  /// 模型提问（选项 + 自定义答案）。
  question,

  /// 计划，等同意执行 / 要求修改。
  plan,
}

/// 一个问题里的选项。
class TakeoverOption {
  const TakeoverOption({
    required this.label,
    this.description,
    this.recommended = false,
  });

  final String label;

  /// 选项的补充说明（原型 `.opt-desc`：显示在标签**下面**）。
  final String? description;

  /// 是否标"推荐"（原型 `.badge-rec` 徽标）。
  ///
  /// 原型的做法值得注意：**"（推荐）"是从标签里剥出来的**，
  /// 单独渲染成徽标 —— 于是标签本身干净，而徽标位置固定。
  final bool recommended;
}

/// 一个待接管的事件。
class TakeoverItem {
  const TakeoverItem({
    required this.key,
    required this.kind,
    this.title = '',
    this.detail = '',
    this.toolName = '',
    this.header = '',
    this.options = const [],
    this.multiSelect = false,
  });

  /// 稳定 key（关掉卡片后要能重新打开同一个）。
  final String key;

  final TakeoverKind kind;

  /// 标题（审批是"工具 X 请求越权执行"或 `reason`）。
  final String title;

  /// 明细（审批是 diff / 命令预览之类）。
  final String detail;

  /// 工具名（回执里要写）。
  final String toolName;

  /// 提问的小标题（原型 `.tk-eyebrow`）。
  final String header;

  /// 选项（提问用；审批用不到）。
  final List<TakeoverOption> options;

  /// 是否多选。
  final bool multiSelect;
}

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
class TakeoverController extends ChangeNotifier {
  final List<TakeoverItem> _queue = [];

  /// 当前题号（提问可能有多个问题）。
  int _questionIndex = 0;

  /// 每题的选择（多选用 `Set`，单选只留一个）。
  final Map<String, Set<String>> _selected = {};

  /// 每题的自定义答案。
  final Map<String, String> _custom = {};

  bool _busy = false;
  bool _minimized = false;

  /// 当前权限档（决定审批是否入队）。
  bool fullAccess = false;

  List<TakeoverItem> get queue => List.unmodifiable(_queue);

  TakeoverItem? get active => _queue.isEmpty ? null : _queue.first;

  TakeoverPhase get phase {
    if (_minimized) return TakeoverPhase.minimized;
    if (active == null) return TakeoverPhase.idle;
    return _busy ? TakeoverPhase.busy : TakeoverPhase.active;
  }

  /// 回答在途（按钮要禁用）。
  bool get busy => _busy;

  /// 当前题号。
  int get questionIndex => _questionIndex;

  /// 答完的事件（回执要落进对话流）。
  ///
  /// 元素是 `(key, 回执文案)`。
  final List<({String key, String text})> receipts = [];

  /// 入队一个事件。
  ///
  /// **`fullAccess` 下的审批不入队**（原型 `enqueue` 的同一条逻辑）——
  /// 返回 `false` 表示"没入队"，调用方据此提示。
  bool enqueue(TakeoverItem item) {
    if (item.kind == TakeoverKind.approval && fullAccess) return false;
    // 同一个 key 不重复入队（收起后重新打开走的是"取消最小化"而不是再入一次）。
    if (_queue.any((i) => i.key == item.key)) {
      _minimized = false;
      notifyListeners();
      return true;
    }
    _queue.add(item);
    if (item.kind == TakeoverKind.question) {
      _questionIndex = 0;
    }
    _minimized = false;
    notifyListeners();
    return true;
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

  /// 选中 / 取消一个选项。
  void toggleOption(String optionLabel) {
    final item = active;
    if (item == null || _busy) return;
    final picked = _selected.putIfAbsent(item.key, () => <String>{});
    if (item.multiSelect) {
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
    notifyListeners();
  }

  /// 当前选中的选项。
  Set<String> get selected => _selected[active?.key] ?? const <String>{};

  /// 当前的自定义答案。
  String get custom => _custom[active?.key] ?? '';

  /// 写入自定义答案。
  void setCustom(String text) {
    final item = active;
    if (item == null || _busy) return;
    _custom[item.key] = text;
    notifyListeners();
  }

  /// 已回答（选了选项或写了自定义）——
  /// 决定"下一题/提交"是否可点（照原型的 `answered`）。
  bool get answered => selected.isNotEmpty || custom.trim().isNotEmpty;

  /// 审批：拒绝。
  Future<void> reject() => _settleApproval('rejected', '已拒绝');

  /// 审批：**允许一次**（`allowed-once`，不是权限变更）。
  Future<void> allowOnce() => _settleApproval('allowed-once', '允许一次');

  Future<void> _settleApproval(String outcome, String label) async {
    final item = active;
    if (item == null || _busy) return;
    _busy = true;
    notifyListeners();
    // 原型是 `setTimeout(..., 420)` 的拟真延迟。这里不假装有网络：
    // 真实现里这一步是 `interaction.respond` 的 await。
    await Future<void>.delayed(const Duration(milliseconds: 120));
    receipts.add((
      key: item.key,
      text: '审批回执 · ${item.toolName} · $label（$outcome）',
    ));
    _busy = false;
    _dequeue();
  }

  /// 计划：同意执行 / 要求修改。
  Future<void> settlePlan({required bool approved}) async {
    final item = active;
    if (item == null || _busy) return;
    _busy = true;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    receipts.add((
      key: item.key,
      text: '计划回执 · ${item.title} · ${approved ? '同意执行' : '要求修改'}',
    ));
    _busy = false;
    _dequeue();
  }

  /// 提问：下一题 / 提交。
  ///
  /// 最后一题提交时把答案整理成回执；**未回答的题不会被跳过** ——
  /// 调用方（`answered`）保证按钮不可点。
  Future<void> submitQuestion() async {
    final item = active;
    if (item == null || _busy || !answered) return;
    if (_questionIndex < 0) return;
    // 有多题时逐题走（原型 `qs.index`）。这里只有一题的模型，
    // 多题的推进留给真正接上 `ask_user_question` 时做 ——
    // 如实记录，而不是假装支持。
    _busy = true;
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final all = {...selected};
    if (custom.trim().isNotEmpty) all.add(custom.trim());
    receipts.add((key: item.key, text: '已回答 · ${all.join(' / ')}'));
    _busy = false;
    _dequeue();
  }

  void _dequeue() {
    _queue.removeAt(0);
    _minimized = false;
    _questionIndex = 0;
    notifyListeners();
  }
}

/// 接管卡（原型 `.tk`）。
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
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final item = widget.controller.active;
        if (item == null) return const SizedBox.shrink();
        // **收起时要真的收掉**：`minimize()` 只改 phase，卡片本身仍会被
        // 构建 —— 不看 phase 的话"收起"按钮点了没反应
        //（队列没减、卡片还在）。收起的语义是"对话流里留一行可点回来的提示"，
        // 那行提示由 `TakeoverHint` 渲染，不是这一层。
        if (widget.controller.phase == TakeoverPhase.minimized) {
          return const SizedBox.shrink();
        }
        return Container(
          // 接管卡从下往上浮入 —— 用 `AnimatedSize` 而不是硬切。
          margin: const EdgeInsets.fromLTRB(8, 0, 8, 6),
          decoration: BoxDecoration(
            color: DshColors.layer1,
            borderRadius: BorderRadius.circular(DshRadius.lg),
            border: Border.all(
              color: switch (item.kind) {
                // 审批是"要你拿主意"的事 —— 告警色边框。
                TakeoverKind.approval => DshColors.roleTool,
                TakeoverKind.plan => DshColors.businessBlue,
                TakeoverKind.question => DshColors.layer2,
              },
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Strip(controller: widget.controller, item: item),
              _Body(controller: widget.controller, item: item, input: _input),
              _Actions(
                controller: widget.controller,
                item: item,
                input: _input,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 顶条（`.tk-strip`：状态点 + 一句话 + 权限档）。
class _Strip extends StatelessWidget {
  const _Strip({required this.controller, required this.item});

  final TakeoverController controller;
  final TakeoverItem item;

  @override
  Widget build(BuildContext context) {
    final label = switch (item.kind) {
      TakeoverKind.approval => '等待审批',
      TakeoverKind.question => '等待回答',
      TakeoverKind.plan => '等待确认计划',
    };
    // 审批与计划用告警/业务色，提问是中性的。
    final tone = switch (item.kind) {
      TakeoverKind.approval => DshColors.roleTool,
      TakeoverKind.plan => DshColors.businessBlue,
      TakeoverKind.question => DshColors.labelSecondary,
    };
    return Container(
      color: DshColors.layer2,
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
            icon: const DshIcon(
              'chevronDown',
              size: 16,
              color: DshColors.labelTertiary,
            ),
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
  final TakeoverItem item;
  final TextEditingController input;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      // 明细可以很长（审批的 diff），给个上限并让它自己滚。
      constraints: const BoxConstraints(maxHeight: 240),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (item.header.isNotEmpty) ...[
              Text(
                item.header,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: DshColors.labelCaption,
                ),
              ),
              const SizedBox(height: 4),
            ],
            Text(
              item.title,
              style: const TextStyle(
                fontSize: 14,
                height: 21 / 14,
                fontWeight: FontWeight.w500,
                color: DshColors.labelPrimary,
              ),
            ),
            if (item.detail.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: DshColors.bgBase,
                  borderRadius: BorderRadius.circular(DshRadius.sm),
                  border: Border.all(color: DshColors.layer2),
                ),
                child: Text(
                  item.detail,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 19 / 12,
                    color: DshColors.labelSecondary,
                  ),
                ),
              ),
            ],
            if (item.options.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (var i = 0; i < item.options.length; i += 1)
                _OptionRow(
                  index: i,
                  option: item.options[i],
                  multiSelect: item.multiSelect,
                  selected: controller.selected.contains(item.options[i].label),
                  disabled: controller.busy,
                  onTap: () => controller.toggleOption(item.options[i].label),
                ),
            ],
            if (item.kind == TakeoverKind.question) ...[
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
  final TakeoverOption option;
  final bool multiSelect;
  final bool selected;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final desc = option.description;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? DshColors.layer2 : DshColors.layer1,
        borderRadius: BorderRadius.circular(DshRadius.md),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: disabled ? null : onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(DshRadius.md),
              border: Border.all(
                color: selected ? DshColors.accentBlue : DshColors.layer2,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 标记：多选勾、单选编号。
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    color: selected ? DshColors.accentBlue : DshColors.layer3,
                    borderRadius: BorderRadius.circular(
                      multiSelect ? DshRadius.xs : 10,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: multiSelect
                      ? (selected
                            ? const DshIcon(
                                'check',
                                size: 12,
                                color: DshColors.onAccent,
                              )
                            : const SizedBox.shrink())
                      : Text(
                          '${index + 1}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: selected
                                ? DshColors.onAccent
                                : DshColors.labelSecondary,
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
                              style: const TextStyle(
                                fontSize: 13.5,
                                color: DshColors.labelPrimary,
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
                                color: DshColors.roleToolBg,
                                borderRadius: BorderRadius.circular(
                                  DshRadius.xs,
                                ),
                              ),
                              child: const Text(
                                '推荐',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: DshColors.roleTool,
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
                          style: const TextStyle(
                            fontSize: 12,
                            color: DshColors.labelCaption,
                          ),
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
class _CustomAnswer extends StatelessWidget {
  const _CustomAnswer({required this.controller, required this.input});

  final TakeoverController controller;
  final TextEditingController input;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(DshRadius.md),
        border: Border.all(color: DshColors.layer2),
      ),
      child: Row(
        children: [
          const DshIcon('edit', size: 14, color: DshColors.labelCaption),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: input,
              enabled: !controller.busy,
              onChanged: controller.setCustom,
              style: const TextStyle(
                fontSize: 13.5,
                color: DshColors.labelPrimary,
              ),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: '其他答案…',
                hintStyle: TextStyle(
                  fontSize: 13.5,
                  color: DshColors.labelTertiary,
                ),
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
  final TakeoverItem item;
  final TextEditingController input;

  @override
  Widget build(BuildContext context) {
    final busy = controller.busy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      child: switch (item.kind) {
        // 审批：拒绝 / **允许一次**（不是"允许" —— 一次就是一次）。
        TakeoverKind.approval => Row(
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
        TakeoverKind.plan => Row(
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
        // 提问：**未回答时提交不可点**（原型 `answered` 那个判据）。
        TakeoverKind.question => _Button(
          label: '提交',
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
    final enabled = onPressed != null;
    return Material(
      color: filled
          ? (enabled ? DshColors.accentBlue : DshColors.layer2)
          : Colors.transparent,
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
                  border: Border.all(color: DshColors.layer3),
                ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: filled
                  ? (enabled ? DshColors.onAccent : DshColors.labelTertiary)
                  : (enabled
                        ? DshColors.labelPrimary
                        : DshColors.labelTertiary),
            ),
          ),
        ),
      ),
    );
  }
}
