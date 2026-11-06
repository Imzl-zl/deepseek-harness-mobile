/// `EventFields` 的实现：**事件载荷的字段名与类型只在这里（和 `wire/events.dart`）断言**。
///
/// 每个方法都是"调 `wire/events.dart` 的读者 → `valueOrReport` 计数一次 → 交值或 `null`"。
/// `data/` 因此不需要认识三态内核（`WireReading` / `WireBad`），也就不必 import `wire/`。
///
/// Note: 端口与分批见 `.agents/notes/implemented/2026-11-06-projection-event-fields-port.md`。
library;

import '../core/event_fields.dart';
import 'events.dart' as wire;
import 'reading.dart' show valueOrReport;

/// 端口 `EventFields` 的唯一实现。**无状态**，可以 `const`。
final class WireEventFields implements EventFields {
  const WireEventFields();

  /// 计数时点名用的"方法名"：形状坏掉时那一行要能指出是哪条事件读的。
  ///
  /// 与 `wire/rpc/*.dart` 传 `_kXxx` 同一做法 —— 缺陷出声的那一处，
  /// 必须知道形状的那一处（这里）。
  static const _kToolCall = 'tool/call';
  static const _kToolResult = 'tool/result';
  static const _kApprovalAsked = 'approval/asked';
  static const _kApprovalDecided = 'approval/decided';
  static const _kQuestionReply = 'user/message(user-question-reply)';

  @override
  ToolCallPayload? toolCall(Object? data) =>
      valueOrReport(wire.readToolCall(data), _kToolCall);

  @override
  ToolResultPayload? toolResult(Object? data) =>
      valueOrReport(wire.readToolResult(data), _kToolResult);

  @override
  ApprovalAskedPayload? approvalAsked(Object? data) =>
      valueOrReport(wire.readApprovalAsked(data), _kApprovalAsked);

  @override
  ApprovalDecidedPayload? approvalDecided(Object? data) =>
      valueOrReport(wire.readApprovalDecided(data), _kApprovalDecided);

  @override
  QuestionReplyPayload? questionReply(Object? data) =>
      valueOrReport(wire.readQuestionReply(data), _kQuestionReply);

  @override
  MergedToolCall? mergedToolCall(Object? data) => wire.mergedToolCallOf(data);
}
