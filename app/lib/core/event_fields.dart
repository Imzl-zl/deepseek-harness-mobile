/// 事件载荷的**读法端口**：`data/` 只认"解好的值"，字段名与类型只在 `wire/` 断言。
///
/// ## 为什么需要它
///
/// `data/projection.dart` 是"事件语义的唯一归宿"（哪条事件变成界面上什么），但它同时
/// 在**读线上字段**（`fieldOf(data, 'delayMs')` 之类，40 余处）。两件事的变更原因不同：
/// DSH 改字段名只该动 `wire/`，我们改界面表现只该动 `data/`。
///
/// ## 形状：照抄 `EventIdReaders`
///
/// - 端口在 core、实现在 wire（`wire/event_fields.dart`）；
/// - **读不出就是 `null`**，不是抛、也不是 `WireBad`：计数与出声在 `wire/` 那一处
///   （`valueOrReport`），`data/` 因此不必认识三态内核 —— 这也是这一族能把
///   `data → wire` 那条 import 关掉的原因；
/// - 值类型住在这里（"解好的值"，与 `SessionProjections` 同一档）；
/// - **只放 `data/` 真正消费的方法**：`command/run` / `command/done` 的读者只有
///   `EventIdReaders` 与回放用例在用，所以不进这个端口（端口上多一个没人调的方法
///   就是一处要维护的空转面）。
///
/// ## 分批
///
/// 第一族（工具 / 审批 / 提问）在这一版；消息与内容块、压缩 / 重试 / 轮次收口在后续两族。
/// **每族一批，每批门禁全绿**；最后一族落地时加门禁：`data/` 里不许出现 `fieldOf(`。
///
/// Note: 取舍与被否掉的方案（在解码边界产出 typed `SessionEvent.body`）见
/// `.agents/notes/implemented/2026-11-06-projection-event-fields-port.md`。
library;

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

/// 事件载荷的读法（实现在 `wire/event_fields.dart`）。
///
/// 每个方法**只读字段、不判语义**：读不出 ⇒ `null`（已经计过数）。
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
}
