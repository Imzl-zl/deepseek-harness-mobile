/// `EventFields` 的实现：**事件载荷的字段名与类型只在这里（和 `wire/events.dart`）断言**。
///
/// 两类方法：
///
/// - **身份 / 必需字段**走 `wire/events.dart` 的 `readXxx`（`WireOk` / `WireBad`），
///   由 `valueOrReport` 计数一次后交值或 `null`；
/// - **宽松取值**（`message` / `source.kind` / `diffHunks` / `retry` / `turnEnd` /
///   `compaction` / 工具入参）走 `core/json_field.dart` 的 `fieldOf` —— 那些字段本来就
///   可能缺，缺不是形状错，因此不计数。
///
/// `data/` 因此不需要认识三态内核（`WireReading` / `WireBad`），也就不必 import `wire/`。
///
/// Note: 端口与三族见 `.agents/notes/implemented/2026-11-06-projection-event-fields-port.md`。
library;

import '../core/event_fields.dart';
import '../core/json_field.dart'
    show fieldOf, intField, nonEmptyString, stringField;
import '../model/chat_item.dart' show TurnTokenUsage;
import '../model/interaction.dart' show InteractionOption, InteractionQuestion;
import '../model/tool_view.dart' show DiffHunk, FileTextLine, ToolResultMeta;
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
  static const _kCommandRun = 'command/run';
  static const _kCommandDone = 'command/done';
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
  CommandRunPayload? commandRun(Object? data) =>
      valueOrReport(wire.readCommandRun(data), _kCommandRun);

  @override
  CommandDonePayload? commandDone(Object? data) =>
      valueOrReport(wire.readCommandDone(data), _kCommandDone);

  @override
  int? changesTurn(Object? data) => intField(data, 'turn');

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
      name: stringField(holder, 'name'),
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
  List<DiffHunk>? diffHunks(Object? data) {
    // **真日志里 diffs 在 `data.meta.diffs`**（DSH 的 `presentationMeta`），不在
    // `message.metadata` 上 —— 只读后者的话 +N/−M 永远是 null（2026-10-22 真 fixture
    // 核到）。老形状留作兜底，而 `message` 的持有位置（`data.message`）也归这里。
    final diffs =
        fieldOf(fieldOf(data, 'meta'), 'diffs') ??
        fieldOf(fieldOf(fieldOf(data, 'message'), 'metadata'), 'diffs');
    if (diffs is! List) return null;
    return _diffHunks(diffs);
  }

  @override
  ToolResultMeta toolMeta(Object? data) {
    // 三个工具的 meta 形状见 `model/tool_view.dart` 的文件头（逐个读过 DSH 源码）。
    final meta = fieldOf(data, 'meta');
    return ToolResultMeta(
      path: stringField(meta, 'path'),
      operation: stringField(meta, 'operation'),
      offset: _numToInt(fieldOf(meta, 'offset')),
      totalLines: _numToInt(fieldOf(meta, 'totalLines')),
      lang: stringField(meta, 'lang'),
      lines: _fileLines(fieldOf(meta, 'lines')),
      diffs: _diffHunks(fieldOf(meta, 'diffs')),
    );
  }

  @override
  bool isToolError(Object? data) {
    final message = fieldOf(data, 'message');
    final isError = fieldOf(message, 'isError');
    if (isError is bool) return isError;
    final status = fieldOf(message, 'status');
    return status is String && status == 'error';
  }

  @override
  RetryPayload retry(Object? data) {
    final failure = fieldOf(data, 'failure');
    return RetryPayload(
      retry: intField(data, 'retry'),
      maxRetries: intField(data, 'maxRetries'),
      // `delayMs` 可能是小数（真日志：`1737.516418390792`）。
      delayMs: (fieldOf(data, 'delayMs') as num?)?.toDouble(),
      failureMessage: stringField(failure, 'message'),
      failureCode: stringField(failure, 'code'),
    );
  }

  @override
  TurnEndPayload turnEnd(Object? data) {
    final reason = fieldOf(data, 'reason');
    final error = fieldOf(reason, 'error');
    // 第二层 `reason.reason`：只有 `aborted` 才带，登出判据（`hook` +
    // `deepseek-account/signed-out`）在那一层。**读出来即可，判不判归投影**。
    final inner = fieldOf(reason, 'reason');
    return TurnEndPayload(
      turn: intField(data, 'turn'),
      kind: stringField(reason, 'kind'),
      errorMessage: stringField(error, 'message'),
      errorCode: stringField(error, 'code'),
      innerKind: stringField(inner, 'kind'),
      innerReason: stringField(inner, 'reason'),
    );
  }

  @override
  CompactionPayload compaction(Object? data) => CompactionPayload(
    // 手动 `/compact`（带 `sourceCommandId`）由命令卡呈现（DSH `compaction.ts:42`）。
    isManual: stringField(data, 'sourceCommandId') != null,
    summary: _blocks(fieldOf(data, 'summary')),
    shadowedSeqs: _shadowedSeqs(fieldOf(data, 'shadowedSeqs')),
    shadowedTokenCount: _shadowedTokenCount(
      fieldOf(data, 'shadowedTokenCount'),
    ),
  );

  @override
  List<InteractionQuestion> interactionQuestions(Object? arguments) {
    // 形状照 DSH 的 `toolArgumentsSchema`（`user-questions/src/projection.ts:43-53`）：
    // 里层是 `{questions: [{id, question, header?, options?, multi_select?}]}`。
    final raw = fieldOf(arguments, 'questions');
    if (raw is! List) return const [];
    final out = <InteractionQuestion>[];
    for (final entry in raw) {
      final id = nonEmptyString(fieldOf(entry, 'id'));
      final question = nonEmptyString(fieldOf(entry, 'question'));
      // 缺 id 就没法把答案配对回去（契约 §5.7 的批次要按 id 对上），
      // 缺题干就没什么可显示的 —— 两种都跳过这个问题，而不是摆一张空卡
      // （DSH 同一处也是 `return null`，`projection.ts:142-144`）。
      if (id == null || question == null) continue;
      final rawOptions = fieldOf(entry, 'options');
      final options = <InteractionOption>[];
      if (rawOptions is List) {
        for (final option in rawOptions) {
          final label = nonEmptyString(fieldOf(option, 'label'));
          if (label == null) continue;
          options.add(
            InteractionOption.fromToolSchema(
              label: label,
              description: nonEmptyString(fieldOf(option, 'description')),
            ),
          );
        }
      }
      out.add(
        InteractionQuestion(
          id: id,
          question: question,
          detail: nonEmptyString(fieldOf(entry, 'detail')),
          header: nonEmptyString(fieldOf(entry, 'header')),
          options: options,
          // **snake_case**：模型看到的形状（应答链上才是 camelCase）。
          multiSelect: fieldOf(entry, 'multi_select') == true,
        ),
      );
    }
    return out;
  }

  @override
  String? planText(Object? arguments) =>
      nonEmptyString(fieldOf(arguments, 'plan'));

  /// `shadowedSeqs`：每一项都得是**安全非负整数**，否则整项 `null`
  /// （DSH `command.ts:113-115` 的严判据 —— 不数一个可能不准的数）。
  static List<int>? _shadowedSeqs(Object? value) {
    if (value is! List) return null;
    final out = <int>[];
    for (final seq in value) {
      if (seq is! int || seq < 0) return null;
      out.add(seq);
    }
    return out;
  }

  /// `shadowedTokenCount`：同样只认安全非负整数（DSH `command.ts:117-120`）。
  static int? _shadowedTokenCount(Object? value) =>
      (value is int && value >= 0) ? value : null;

  /// `read` 的结构化窗口：**非空数组才收**（否则 `null`，专用卡退回通用卡）。
  static List<FileTextLine>? _fileLines(Object? raw) {
    if (raw is! List || raw.isEmpty) return null;
    return [
      for (final line in raw)
        if (line is Map)
          FileTextLine(
            _numToInt(line['number']) ?? 0,
            line['text'] is String ? line['text'] as String : '',
          ),
    ];
  }

  /// hunk 表（`{path, oldText, newText}`，DSH 的 `computeHunkDiffs` 产物）。
  static List<DiffHunk> _diffHunks(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final hunk in raw)
        if (hunk is Map)
          DiffHunk(
            path: hunk['path'] is String ? hunk['path'] as String : '',
            oldText: hunk['oldText'] is String ? hunk['oldText'] as String : '',
            newText: hunk['newText'] is String ? hunk['newText'] as String : '',
          ),
    ];
  }

  /// `offset` / `totalLines` / `number`：DSH 写的是数字，`num` 一律折成 `int`
  /// （与 `model/tool_view.dart` 原来那条宽松读法一致）。
  static int? _numToInt(Object? value) => switch (value) {
    int() => value,
    num() => value.toInt(),
    _ => null,
  };

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
