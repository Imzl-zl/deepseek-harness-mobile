/// `EventFields` 的实现：**事件载荷的字段名与类型只在这里（和 `wire/events.dart`）断言**。
///
/// 每个方法都是"调 `wire/events.dart` 的读者 → `valueOrReport` 计数一次 → 交值或 `null`"。
/// `data/` 因此不需要认识三态内核（`WireReading` / `WireBad`），也就不必 import `wire/`。
///
/// Note: 端口与分批见 `.agents/notes/implemented/2026-11-06-projection-event-fields-port.md`。
library;

import '../core/event_fields.dart';
import '../core/json_field.dart' show fieldOf, stringField;
import '../model/chat_item.dart' show TurnTokenUsage;
import '../model/tool_view.dart' show DiffHunk;
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

  @override
  MessagePayload message(String type, Object? data) {
    // **`user/message` 的载荷就是消息本身**，其余类型在 `data.message` 上。
    final holder = type == 'user/message' ? data : fieldOf(data, 'message');
    return MessagePayload(
      blocks: _blocks(fieldOf(holder, 'content')),
      // 用量在 `data` 顶层（真日志：`data` 的键是 turn / step / message / usage / stream）。
      usage: type == 'assistant/message'
          ? TurnTokenUsage.fromWire(fieldOf(data, 'usage'))
          : null,
    );
  }

  @override
  String? sourceKind(Object? data) =>
      stringField(fieldOf(data, 'source'), 'kind');

  @override
  List<DiffHunk>? diffHunks({Object? data, Object? message}) {
    // **真日志里 diffs 在 `data.meta.diffs`**（DSH 的 `presentationMeta`），不在
    // `message.metadata` 上 —— 只读后者的话 +N/−M 永远是 null（2026-10-22 真 fixture
    // 核到）。老形状留作兜底。
    final diffs =
        fieldOf(fieldOf(data, 'meta'), 'diffs') ??
        fieldOf(fieldOf(message, 'metadata'), 'diffs');
    if (diffs is! List) return null;
    return [
      for (final hunk in diffs)
        if (hunk is Map)
          DiffHunk(
            path: hunk['path'] is String ? hunk['path'] as String : '',
            oldText: hunk['oldText'] is String ? hunk['oldText'] as String : '',
            newText: hunk['newText'] is String ? hunk['newText'] as String : '',
          ),
    ];
  }

  @override
  bool isToolError(Object? data) {
    final message = fieldOf(data, 'message');
    final isError = fieldOf(message, 'isError');
    if (isError is bool) return isError;
    final status = fieldOf(message, 'status');
    return status is String && status == 'error';
  }

  /// `content` → 块表。**两种形状都收**：字符串、块数组（数组里还可能是裸字符串）。
  ///
  /// 只认一种会让另一种静默显示成空 —— 那是"消息发出去但界面是空的"这类 bug。
  /// 块的**语义**（哪块算正文、哪块算思考）不在这里判，留给投影。
  static List<ContentBlock> _blocks(Object? content) {
    if (content is String) {
      return [ContentBlock(kind: ContentBlockKind.text, text: content)];
    }
    if (content is! List) return const [];
    return [
      for (final block in content)
        if (block is Map)
          ContentBlock(
            kind: switch (block['type']) {
              'text' => ContentBlockKind.text,
              'reasoning' => ContentBlockKind.reasoning,
              'image' => ContentBlockKind.image,
              'file' => ContentBlockKind.file,
              _ => ContentBlockKind.other,
            },
            text: block['text'] is String ? block['text'] as String : null,
          )
        else if (block is String)
          ContentBlock(kind: ContentBlockKind.text, text: block),
    ];
  }
}
