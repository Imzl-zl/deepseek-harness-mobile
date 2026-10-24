/// 交互（审批 / 提问 / 计划审查）在**领域层**的形状（契约 §6）。
///
/// ## 为什么从 `ui/takeover.dart` 搬到这一层
///
/// 待处理项不是 UI 的发明，而是**会话事件的投影**（契约 §6.3 第一条：
/// "来源是日志，不是内存"）。投影在 `data/projection.dart`，于是它产出的东西
/// 必须在 `data/` 与 `ui/` 都不依赖对方的那一层 —— 就是这里。
///
/// 放在 UI 层的话，`data/` 为了产出待处理项就得 import `ui/`，而那是分层方向反了。
///
/// ## 一个答案批次覆盖三种交互
///
/// 这是 DSH 的原生设计，不是我们的简化：`AskUserQuestionItem` 带一个可选 `intent`
/// 标签，而 DSH 的注释明说 *"an intent changes presentation only, never the
/// protocol"*（`packages/interaction/user-questions/src/types.ts:17-22`）。
/// 所以：
///
/// - **审批**：手机表达的是"允许一次 / 拒绝"，编码成 `selected` 里有没有
///   `approvalAllowLabel`（DSH 的 outcome 词汇表，见连接器侧同名常量）；
/// - **提问**：按 DSH 给出的选项，可多选、可填自由文本；
/// - **计划审查**：同一个形状，只是其中一个选项标签是"同意"。
///   **通过与否由 DSH 的规则决定**（`types.ts:28-30` 原话
///   "every other option declines it"）—— 手机不自己判。
///
/// 空 `selected` 且无 `custom` 是**合法的「显式跳过」**
/// （`packages/interaction/tool-ask-user/src/timed.ts:172,179` 的输出 schema 原文
/// "Empty with no custom means the user explicitly skipped this question"），
/// 因此它同时是"拒绝"的编码。
library;

/// 审批答复里代表"允许一次"的那个标签。
///
/// **取值是 DSH 自己的 outcome 词汇表**（`packages/interaction/user-approval/src/types.ts:32`）：
/// outcome 集合封闭，唯一授权值是 `allowed-once`。手机端把它渲染成"允许一次"，
/// 其余任何标签一律读成拒绝 —— 与 DSH 把词汇表外的返回值静默归一成 `unavailable`
/// 同一个方向：**认不出的就是不允许**。
///
/// 这个常量是**跨端契约**：连接器侧 `connector/src/interaction-claims.ts` 有同名同值的
/// 常量，两边各有一条断言钉住它。
const String approvalAllowLabel = 'allowed-once';

/// 计划审查答复里的"同意"标记。
///
/// **它不是宿主的标签**：宿主的题 id（`plan-review`）与"同意"标签（`Approve`）
/// 只存在于那次 `ask()` 的**请求**里（`packages/plan/plan-mode/src/index.ts:73,76,329`），
/// 而手机只看得到 `exit_plan_mode` 的 `tool/call`（正文，没有选项）。
///
/// 所以手机只表达"同意 / 继续规划"：连接器拿到 claim 时记下了请求里的题 id 与标签，
/// 结算时按它们重建答案批次（`connector/src/interaction-claims.ts` 的 `planReview`，
/// 契约 §6.3.1）。**别把它换成宿主的英文标签** —— 那会成为第二份真值。
const String kPlanApproveMark = 'plan-approve';

/// 待接管的事件的种类。
enum InteractionKind {
  /// 工具越权，等审批（拒绝 / 允许一次）。
  approval,

  /// 模型提问（选项 + 自定义答案）。
  question,

  /// 计划，等同意执行 / 要求修改。
  ///
  /// **真实事件里不会出现这一类**：DSH 的 `intent` 只活在应答链的请求对象上，
  /// 不进会话事件（`user-questions/src/projection.ts:148-161` 的 `questionsOf`
  /// 不映射 `intent`），于是从事件流里看不出这是计划审查。真实计划审查因此按
  /// **提问**渲染 —— 那正是 DSH 自己的投影的行为，而答案编码完全相同。
  /// 这一类保留给原型演示（`mock/proto/interactions.js` 的 `planHtml`）。
  plan,
}

/// 一个问题里的选项。
class InteractionOption {
  const InteractionOption({
    required this.label,
    this.description,
    this.recommended = false,
  });

  final String label;

  /// 选项的补充说明（显示在标签**下面**：同行会挤掉标签）。
  final String? description;

  /// 是否标"推荐"（独立徽标，且从标签里剥出来）。
  final bool recommended;
}

/// 一个问题。一次 `ask_user_question` 可以有 1..N 个。
class InteractionQuestion {
  const InteractionQuestion({
    required this.id,
    required this.question,
    this.detail,
    this.header,
    this.options = const [],
    this.multiSelect = false,
  });

  /// 问题 id —— 答案批次用它配对（契约 §5.7）。
  final String id;

  final String question;

  /// 补充说明（计划审查把计划正文放在这里）。
  final String? detail;

  /// 小标题。
  final String? header;

  final List<InteractionOption> options;

  final bool multiSelect;
}

/// 一个待处理的交互（来自会话事件的投影）。
class InteractionItem {
  const InteractionItem({
    required this.itemId,
    this.sid = '',
    this.callId,
    required this.kind,
    this.title = '',
    this.detail = '',
    this.toolName = '',
    this.header = '',
    this.options = const [],
    this.multiSelect = false,
    this.questions = const [],
    this.approveLabel,
  });

  /// 稳定身份：审批是 `i:<approvalId>`，提问是 `t:<callId>`（契约 §5.2）。
  ///
  /// **它是答复的键**（`interaction.respond` 的 `itemId`）：连接器的在途 claim 也以它为键。
  final String itemId;

  /// 会话别名（答复要带回它）。
  final String sid;

  /// "这条交互针对哪一次工具调用"。**只为呈现与关联**，不再是答复的键 ——
  /// 审批的 `callId` 在 DSH 是可选的（`user-approval/src/types.ts:68-69`），
  /// 拿它当键会把"没有 tool call 的审批"整类挡在门外。
  final String? callId;

  final InteractionKind kind;

  /// 标题（审批是 `reason`，或"工具 X 请求越权执行"；提问是题干）。
  final String title;

  /// 明细（审批的 diff / 命令预览，提问的补充说明）。
  final String detail;

  /// 工具名（回执里要写）。
  final String toolName;

  /// 提问的小标题。
  final String header;

  /// 选项（**第一个问题**的；多题走 [questions]）。
  final List<InteractionOption> options;

  /// 是否多选（**第一个问题**的）。
  final bool multiSelect;

  /// 全部问题（一次提问可以有多个；审批与计划用不到）。
  final List<InteractionQuestion> questions;

  /// 计划审查的"同意"标签：`selected` 含它即同意，其余一律拒绝（契约 §6.4）。
  final String? approveLabel;
}

/// 一次答复里的一项（与 DSH 的 `AskUserQuestionAnswerItem` 逐字一致）。
class InteractionAnswerItem {
  const InteractionAnswerItem({
    required this.id,
    this.selected = const [],
    this.custom,
  });

  final String id;

  /// 选中的选项标签。**空且无 [custom] 是合法的「显式跳过」**。
  final List<String> selected;

  final String? custom;
}

/// 一次答复（手机 → 电脑）。
class InteractionAnswer {
  const InteractionAnswer({
    required this.sid,
    required this.itemId,
    required this.answers,
  });

  /// 会话别名（电脑侧据此反解回 DSH 会话 id）。
  final String sid;

  /// 这一项的身份 = 卡自己的 `itemId`（`i:<approvalId>` / `t:<callId>`，契约 §5.7）。
  final String itemId;

  /// 答案批次：每个问题恰好一项（契约 §5.7）。
  final List<InteractionAnswerItem> answers;
}

/// 一条交互信号：开一个待处理项，或收束一个。
///
/// 用**两个类型**而不是一个带可空字段的类型：`open` 那种写法让"这一项是什么"
/// 永远有可能为 `null`，于是每个消费点都要判一次空；而两种信号的字段本来就不同
/// （一个带整项，一个只带身份）。 sealed + 穷尽 `switch` 让"漏了一种"在编译期就红。
sealed class InteractionSignal {
  const InteractionSignal();
}

/// 开一个待处理项。
final class InteractionOpened extends InteractionSignal {
  const InteractionOpened(this.item);

  final InteractionItem item;
}

/// 收束一个待处理项（电脑侧已经决定了 / 已经答过了）。
final class InteractionSettled extends InteractionSignal {
  const InteractionSettled(this.itemId);

  /// 待处理项的稳定身份（`i:<approvalId>` 或 `t:<callId>`）。
  final String itemId;
}
