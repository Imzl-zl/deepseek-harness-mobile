/// 事件载荷的**读法端口**：`data/` 只认"解好的值"，字段名与类型只在 `wire/` 断言。
///
/// ## 为什么需要它
///
/// `data/projection.dart` 是"事件语义的唯一归宿"（哪条事件变成界面上什么）。它**不读
/// 线上字段名**：DSH 改字段名只该动 `wire/`，我们改界面表现只该动 `data/`。所以字段名
/// 与类型只在 `wire/` 断言，投影收的是这里解好的值（`fieldOf(` 在 `app/lib/data/`
/// 一处都没有；门禁 `data-no-fieldof` 钉住它）。
///
/// ## 形状：照抄 `EventIdReaders`
///
/// - 端口在 core、实现在 wire（`wire/event_fields.dart`）；
/// - **读不出就是 `null`**（或空表），不是抛、也不是 `WireBad`：计数与出声在 `wire/`
///   那一处（`valueOrReport`），`data/` 因此不必认识三态内核 —— 这也是这一族能把
///   `data → wire` 那条 import 关掉的原因；
/// - 值类型住在这里（"解好的值"，与 `SessionProjections` 同一档）；
/// - **只放 `data/` 真正消费的方法**：`command/run` / `command/done` 的读者只有
///   `EventIdReaders` 与回放用例在用，所以不进这个端口（端口上多一个没人调的方法
///   就是一处要维护的空转面）。
///
/// ## 工具入参也在这一层
///
/// `interactionQuestions` / `planText` 读的是 `tool/call` 的**参数 schema**，不是事件
/// 载荷 —— 但它们同样是"线上形状"：`multi_select` 的 snake_case、计划正文的 `plan`
/// 都只该在 `wire/` 断言。它们在这里，`data/` 才能在"按字段名取值"上归零。
///
/// ## 三族
///
/// 第 1 族工具 / 审批 / 提问，第 2 族消息与内容块，第 3 族重试 / 轮次收口 / 压缩 /
/// 交互工具入参。**每族一批、每批门禁全绿**；第 3 族落地后 `data/` 的 `fieldOf(`
/// 归零，门禁 `data-no-fieldof` 随之加上。
///
/// Note: 取舍与被否掉的方案（在解码边界产出 typed `SessionEvent.body`）见
/// `.agents/notes/implemented/2026-11-06-projection-event-fields-port.md`。
library;

import '../model/chat_item.dart' show TurnTokenUsage;
import '../model/interaction.dart' show InteractionQuestion;
import '../model/tool_view.dart' show DiffHunk;

/// 一条 `tool/call` 的载荷（`{turn, step, callId, name, arguments}`）。
final class ToolCallPayload {
  const ToolCallPayload({
    required this.callId,
    required this.name,
    required this.argumentsRaw,
    required this.arguments,
  });

  final String callId;

  /// 工具名。**可空**：身份是 [callId]，名字是**展示**用的，缺了有既有兜底
  /// （`kUnknownToolName`）—— 把"没有名字"判成形状错会把一条身份完好的事件整条丢掉。
  final String? name;

  /// 原始串（DSH 落盘的就是它，摘要与"改了哪个文件"都要原文）。
  final String argumentsRaw;

  /// 解开的参数。**解不开是 `null`，不是错误**：流式中断 / 被拒的调用会把原始文本留着。
  final Map<String, Object?>? arguments;
}

/// 一条 `tool/result` 的载荷：身份在 `message.toolCallId`（与 `tool/call` 配对）。
final class ToolResultPayload {
  const ToolResultPayload({required this.callId});

  final String callId;
}

/// 一条 `approval/asked` 的载荷：身份是服务铸的 `id`，`callId` 只是关联字段（可能没有）。
final class ApprovalAskedPayload {
  const ApprovalAskedPayload({
    required this.approvalId,
    required this.callId,
    required this.toolName,
    required this.reason,
  });

  final String approvalId;
  final String? callId;
  final String? toolName;
  final String? reason;
}

/// 一条 `approval/decided` 的载荷（与 ask 共用 `id`）。
final class ApprovalDecidedPayload {
  const ApprovalDecidedPayload({required this.approvalId});

  final String approvalId;
}

/// `user/message` 里 `source.kind === 'user-question-reply'` 的那条：迟到的答复。
final class QuestionReplyPayload {
  const QuestionReplyPayload({required this.callId});

  final String callId;
}

/// 落盘条目里被合并过的那一半 `tool/call`（`{name, arguments}`）。
///
/// 只关心"还能不能把名字与参数读回来"——重启后整行不只剩「工具」靠它
/// （2026-11-04 真机：库里 200 条 result / 0 条 call）。
typedef MergedToolCall = ({String? name, String argumentsRaw});

/// `content` 块的种类：投影只区分得到这几档，其余一律 [other]（不丢块）。
enum ContentBlockKind { text, reasoning, image, file, other }

/// 一个 `content` 块（已解开）。[text] 只对 [ContentBlockKind.text] 与
/// [ContentBlockKind.reasoning] 有意义。
final class ContentBlock {
  const ContentBlock({required this.kind, this.text});

  final ContentBlockKind kind;
  final String? text;
}

/// 一条消息的载荷：`content` 已按块解好，用量在 `data` **顶层**（不在 `message` 里）。
final class MessagePayload {
  const MessagePayload({this.blocks = const [], this.usage, this.name});

  /// 按线上顺序解好的块。**缺 `content` 是空表**（历史上两种形状都出现过）。
  final List<ContentBlock> blocks;

  /// `assistant/message` 那一次请求的用量；别的类型没有。
  final TurnTokenUsage? usage;

  /// 消息自带的名字（部分适配器会写在结果的 `message.name` 上）。
  ///
  /// **只有结果自己带时才用它**：真日志里 `tool/result` 的 `message` 不带名字，
  /// 名字在 `tool/call` 上（投影的"结果继承调用"）。
  final String? name;
}

/// 一条重试事件（`llm/retry` / `llm/retry-started`）的载荷。
///
/// 真日志形状：`{retryId, turn, step, retry, maxRetries, delayMs,
/// failure: {message, code}}`。**两次重试共用同一个 itemId**
/// （`r:$retryId:$retry`，见 `core/items.dart`），所以 `retry-started` 只带次数、
/// 失败原因与间隔都要从 `llm/retry` 继承（冷启动时从合并载荷读回）。
final class RetryPayload {
  const RetryPayload({
    this.retry,
    this.maxRetries,
    this.delayMs,
    this.failureMessage,
    this.failureCode,
  });

  /// 第几次重试（DSH schema 是 `z.number().int()`，见 `core/json_field.dart` 的 `intField`）。
  final int? retry;

  /// 最多重试几次。
  final int? maxRetries;

  /// 计划的重试间隔。**可能是小数**（真日志：`1737.516418390792`）——
  /// 只用来显示"多久后重试"，取整是展示的事。
  final double? delayMs;

  /// `failure.message` —— 失败原文（模型侧报的，不编）。
  final String? failureMessage;

  /// `failure.code`（`TRANSPORT` 之类）。
  final String? failureCode;
}

/// 一条 `turn/end` 的载荷：`reason` 是**两层嵌套**。
///
/// 外层 `reason.kind` 判结局（`error` / `interrupted` / `max-tokens` / `aborted` /
/// `completed`…，DSH `turn-error.ts:36-51` 的 `endFailure`）；`reason.error` 是模型侧
/// 报错原文；`reason.reason` 只在 `aborted` 时出现，**登出**的判据在那一层
/// （`kind == 'hook'` + `reason == 'deepseek-account/signed-out'`）。
///
/// 端口只把这两层读出来，**哪一种结局算失败 / 要不要画失败行仍由 `data/` 判**。
final class TurnEndPayload {
  const TurnEndPayload({
    this.turn,
    this.kind,
    this.errorMessage,
    this.errorCode,
    this.innerKind,
    this.innerReason,
  });

  /// `data.turn`（历史翻页可能只落到 `turn/end`，轮号只能从这条事件自己读）。
  final int? turn;

  /// `reason.kind`。
  final String? kind;

  /// `reason.error.message`。
  final String? errorMessage;

  /// `reason.error.code`。
  final String? errorCode;

  /// `reason.reason.kind`（第二层）。
  final String? innerKind;

  /// `reason.reason.reason`（第二层）。
  final String? innerReason;
}

/// 一条压缩事件（`compaction/start` / `compaction/summary` / `compaction/end`）的载荷。
///
/// **只有 `compaction/summary` 带内容**（摘要与被压掉的计数）；`start` / `end`
/// 只是生命周期边界。手动 `/compact` 也是压缩事件，但带 `sourceCommandId` ——
/// 那种由命令卡呈现（DSH `compaction.ts:42` 的 `match` 对它返回 `null`）。
final class CompactionPayload {
  const CompactionPayload({
    this.isManual = false,
    this.summary = const [],
    this.shadowedSeqs,
    this.shadowedTokenCount,
  });

  /// 手动 `/compact`（`sourceCommandId` 非空）：投影跳过它（由命令卡呈现）。
  final bool isManual;

  /// `data.summary` 的块表（与消息 `content` 同一个解码，见 [ContentBlock]）。
  final List<ContentBlock> summary;

  /// 被这次压缩替换掉的条目 seq。
  ///
  /// **DSH 的判据更严**（`command.ts:113-115`）：每一项都必须是安全非负整数，
  /// 否则整项 `null` —— 不数一个可能不准的数。
  final List<int>? shadowedSeqs;

  /// 被压掉的 token 数（同样只认安全非负整数，DSH `command.ts:117-120`）。
  final int? shadowedTokenCount;
}

/// 事件载荷的读法（实现在 `wire/event_fields.dart`）。
///
/// 每个方法**只读字段、不判语义**：缺字段就是 `null` / 空表，哪一种算失败、要不要出提示
/// 仍由 `data/` 判。
abstract interface class EventFields {
  /// 一条 `tool/call`。`callId` 缺失是形状错（身份丢了）⇒ `null` 并计一次数。
  ToolCallPayload? toolCall(Object? data);

  /// 一条 `tool/result`。
  ToolResultPayload? toolResult(Object? data);

  /// 一条 `approval/asked`。
  ApprovalAskedPayload? approvalAsked(Object? data);

  /// 一条 `approval/decided`。
  ApprovalDecidedPayload? approvalDecided(Object? data);

  /// 一条迟到的提问答复（`user/message` + `source.kind == 'user-question-reply'`）。
  QuestionReplyPayload? questionReply(Object? data);

  /// 从落盘条目里被合并过的载荷读回 `{name, argumentsRaw}`。
  MergedToolCall? mergedToolCall(Object? data);

  /// 一条消息的 `content`（按块解好）与用量。
  ///
  /// **`user/message` 的载荷就是消息本身**，其余消息类型在 `data.message` 上 ——
  /// 这处结构知识只在这里（`core/items.dart` 的 `itemIdOf` 有同一处，两处都在描述
  /// DSH 的形状，必须一起改）。
  MessagePayload message(String type, Object? data);

  /// `source.kind`（上下文注人行的判据与标签来源）。没有 `source` ⇒ `null`。
  String? sourceKind(Object? data);

  /// 工具结果的 diff hunks：先看 `data.meta.diffs`（DSH 的 `presentationMeta`），
  /// **再退回老的 `message.metadata.diffs`**（消息的持有位置由端口自己从 `data` 取）。
  /// 不是列表 ⇒ `null`。
  List<DiffHunk>? diffHunks(Object? data);

  /// 工具结果是不是失败：`message.isError` 为布尔就用它，否则看 `status == 'error'`。
  bool isToolError(Object? data);

  /// 一条重试事件（`llm/retry` 与 `llm/retry-started` 同形；缺的字段是 `null`）。
  RetryPayload retry(Object? data);

  /// 一条 `turn/end` 的结局（`reason` 两层 + 轮号；缺的字段是 `null`）。
  TurnEndPayload turnEnd(Object? data);

  /// 一条压缩事件（`compaction/start|summary|end` 同形；非 summary 只有
  /// [CompactionPayload.isManual] 有值）。
  CompactionPayload compaction(Object? data);

  /// `ask_user_question` 的**工具入参**（不是事件载荷）：`questions[]` 解成问题表。
  ///
  /// 它进端口不是因为有事件字段要读，而是为了让 `data/` 的"按线上字段名取值"归零
  /// （门禁 `data-no-fieldof`）。入参是 **snake_case 的 `multi_select`**（模型看到的
  /// 形状），应答链上的是 camelCase —— 读错的那个会让多选永远读成单选
  /// （DSH `user-questions/src/projection.ts:43-53` 的 `toolArgumentsSchema`）。
  ///
  /// **读不懂 / 参数不是问题表 ⇒ 空表**（不是 `null`）：那是模型的坏参数，
  /// 工具根本没被调用过，没有卡可显示 —— 与"这条事件与交互无关"同一个去处。
  List<InteractionQuestion> interactionQuestions(Object? arguments);

  /// `exit_plan_mode` 的**工具入参**（不是事件载荷）：`arguments.plan` 的正文。
  ///
  /// 缺它 / 空串 ⇒ `null` —— 那次调用没有卡可显示。
  String? planText(Object? arguments);
}
