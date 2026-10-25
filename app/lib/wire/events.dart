/// 线上事件载荷的**唯一解码边界**。
///
/// ## 这个文件为什么存在
///
/// 2026-10-25 真机：计划审查卡在手机上一次都没出现。根因不是传输，而是同一个字段有两种读法 ——
/// `app/lib/core/items.dart` 知道 `tool/call` 的 `arguments` 是 **JSON 字符串**，
/// `app/lib/data/projection.dart` 却把它当**对象**取 `plan`（`fieldOf` 对非 Map 恒回 `null`）。
/// 于是事件到了、不报错、卡不开，而单测喂的正好是对象形状 —— 两边一起绿。
///
/// 同一种病还会有下一次：只要"字段叫什么、是什么类型"散在各调用点，就总有一处会猜错，
/// 而猜错的表现是**静默的空值**。
///
/// ## 三条不变量
///
/// 1. **事件载荷的字段名与类型只在这里断言**。别处拿到的是解好的值（`WireOk` 里的对象），
///    不再对裸 `Map` 取字段。门禁：`app/tools/verify-platform-boundary.mjs` 的
///    `wire-field-single-reader` 规则 —— `'arguments'` / `'toolCallId'` 两个字面量
///    只许出现在本文件。
/// 2. **读不出来必须出声**。`WireBad` 走 `reading.dart` 的 `WireDiagnostics`（计数 + 一行打印）；
///    `null` 在这套代码里已经被"这条事件与交互无关"占用了，两者混在一起就再也分不出
///    "没有"与"读不到"（教训第九条，`memory.md`）。
/// 3. **只收我们真正消费的事件**。不消费的类型不建 decoder（Skip），避免维护一份全量 schema ——
///    那会变成第二个真值来源。
///
/// ## 形状的证据
///
/// 不是照文档猜的，是照**真机落盘事件**：`app/test/fixtures/real-session-events.json`
/// 里的 `toolCall` / `planCall` / `questionCall` 都直接取自真机（手机库 `items.payload_json`
/// 与会话日志 `session.v4.jsonl.zstd`），`test/event_wire_replay_test.dart` 逐条回放它们。
library;

import 'dart:convert';

import 'reading.dart';

/// 消费方一次拿齐"三态内核 + 事件 decoder"（`items.dart` / `projection.dart` 只需要这一行 import）。
/// RPC 面同样 re-export 一次，保证全 app 只有一套失败语义。
export 'reading.dart';

// 内核（`WireReading` / `WireDiagnostics` / `valueOrReport` / `valueOrNull`）在 `reading.dart`：
// 事件面与 RPC 面共用同一套三态与同一个计数，不为每个面各造一份。

// ---------------------------------------------------------------------------
// 各事件的载荷（只断言我们消费的字段）
// ---------------------------------------------------------------------------

/// `tool/call`：`{turn, step, callId, name, arguments}`。
final class ToolCallWire {
  const ToolCallWire({
    required this.callId,
    required this.name,
    required this.argumentsRaw,
    required this.arguments,
  });

  final String callId;

  /// 工具名。**可空**：身份是 `callId`（`items.dart` 的 `itemIdOf` 只认它），
  /// 名字是**展示**用的，缺了有既有兜底（`kUnknownToolName`）——
  /// 把"没有名字"判成形状错会把一条身份完好的事件整条丢掉（2026-10-25 被一条旧用例拦下）。
  final String? name;

  /// 原始串（DSH 落盘的就是它，摘要与"改了哪个文件"都要原文）。
  final String argumentsRaw;

  /// 解开的参数。**解不开是 `null`，不是错误**：流式中断 / 被拒的调用会把原始文本留着
  /// （`toolArgumentsSummary` 的同一条：退回首行）。调用方据此决定"这张卡能不能开"。
  final Map<String, Object?>? arguments;
}

/// `tool/result`：身份在 `message.toolCallId`（与 `tool/call` 配对）。
final class ToolResultWire {
  const ToolResultWire({required this.callId});

  final String callId;
}

/// `approval/asked`：身份是服务铸的 `id`，`callId` 只是关联字段（可能没有）。
final class ApprovalAskedWire {
  const ApprovalAskedWire({
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

/// `approval/decided`：与 ask 共用 `id`。
final class ApprovalDecidedWire {
  const ApprovalDecidedWire({required this.approvalId});

  final String approvalId;
}

/// `user/message` 里 `source.kind === 'user-question-reply'` 的那条：迟到的答复。
final class QuestionReplyWire {
  const QuestionReplyWire({required this.callId});

  final String callId;
}

/// `command/run`：`{commandId, name, args, source}`。
final class CommandRunWire {
  const CommandRunWire({
    required this.commandId,
    required this.name,
    required this.args,
  });

  final String commandId;
  final String? name;
  final String? args;
}

/// `command/done`：`{commandId, kind, text}`（**不带 name**，名字从 run 继承）。
final class CommandDoneWire {
  const CommandDoneWire({
    required this.commandId,
    required this.kind,
    required this.text,
  });

  final String commandId;
  final String? kind;
  final String? text;
}

// ---------------------------------------------------------------------------
// decoder：每个类型一个，字段名与类型只在这里断言
// ---------------------------------------------------------------------------

/// 一条 `tool/call`。`callId` 缺失是**形状错**（身份都丢了），不静默；`name` 缺失不是
/// （见 [ToolCallWire.name]）。
WireReading<ToolCallWire> readToolCall(Object? data) {
  final callId = _string(data, 'callId');
  if (callId == null) return const WireBad<ToolCallWire>('tool/call 缺 callId');
  final raw = _string(data, 'arguments') ?? '';
  return WireOk<ToolCallWire>(
    ToolCallWire(
      callId: callId,
      name: _string(data, 'name'),
      argumentsRaw: raw,
      arguments: parseArguments(raw),
    ),
  );
}

/// 把 `arguments` 解成对象。**线上是 JSON 字符串**（真机库 `payload_json.arguments`
/// 的类型就是 `str`），不是对象 —— 按对象读的那一支永远读出 `null`，这就是 2026-10-25 的病。
Map<String, Object?>? parseArguments(String raw) {
  if (raw.isEmpty) return null;
  try {
    final parsed = jsonDecode(raw);
    if (parsed is! Map) return null;
    return parsed.cast<String, Object?>();
  } catch (_) {
    return null;
  }
}

/// 一条 `tool/result`。
WireReading<ToolResultWire> readToolResult(Object? data) {
  final message = _map(data, 'message');
  final callId = message == null ? null : _string(message, 'toolCallId');
  if (callId == null) {
    return const WireBad<ToolResultWire>('tool/result 缺 message.toolCallId');
  }
  return WireOk<ToolResultWire>(ToolResultWire(callId: callId));
}

/// 一条 `approval/asked`。
WireReading<ApprovalAskedWire> readApprovalAsked(Object? data) {
  final approvalId = _string(data, 'id');
  if (approvalId == null) {
    return const WireBad<ApprovalAskedWire>('approval/asked 缺 id');
  }
  return WireOk<ApprovalAskedWire>(
    ApprovalAskedWire(
      approvalId: approvalId,
      callId: _string(data, 'callId'),
      toolName: _string(data, 'toolName'),
      reason: _string(data, 'reason'),
    ),
  );
}

/// 一条 `approval/decided`。
WireReading<ApprovalDecidedWire> readApprovalDecided(Object? data) {
  final approvalId = _string(data, 'id');
  if (approvalId == null) {
    return const WireBad<ApprovalDecidedWire>('approval/decided 缺 id');
  }
  return WireOk<ApprovalDecidedWire>(
    ApprovalDecidedWire(approvalId: approvalId),
  );
}

/// 一条迟到的提问答复（`user/message` 且 `source.kind === 'user-question-reply'`）。
///
/// 其它 `user/message` 一律 [WireSkip] —— 绝大多数用户消息与交互无关。
WireReading<QuestionReplyWire> readQuestionReply(Object? data) {
  final source = _map(data, 'source');
  if (source == null) return const WireSkip<QuestionReplyWire>();
  if (_string(source, 'kind') != 'user-question-reply') {
    return const WireSkip<QuestionReplyWire>();
  }
  final callId = _string(source, 'callId');
  if (callId == null) {
    return const WireBad<QuestionReplyWire>(
      'user-question-reply 缺 source.callId（认不出答的是哪一问）',
    );
  }
  return WireOk<QuestionReplyWire>(QuestionReplyWire(callId: callId));
}

/// 一条 `command/run`。
WireReading<CommandRunWire> readCommandRun(Object? data) {
  final commandId = _string(data, 'commandId');
  if (commandId == null) {
    return const WireBad<CommandRunWire>('command/run 缺 commandId');
  }
  return WireOk<CommandRunWire>(
    CommandRunWire(
      commandId: commandId,
      name: _string(data, 'name'),
      args: _string(data, 'args'),
    ),
  );
}

/// 一条 `command/done`。
WireReading<CommandDoneWire> readCommandDone(Object? data) {
  final commandId = _string(data, 'commandId');
  if (commandId == null) {
    return const WireBad<CommandDoneWire>('command/done 缺 commandId');
  }
  return WireOk<CommandDoneWire>(
    CommandDoneWire(
      commandId: commandId,
      kind: _string(data, 'kind'),
      text: _string(data, 'text'),
    ),
  );
}

// ---------------------------------------------------------------------------
// 取字段的底层工具：**只给本文件用**
// ---------------------------------------------------------------------------
//
// 名字带下划线不是洁癖：`fieldOf` / `stringField` 这类"对裸 Map 取字段"的公开工具
// 正是这次事故的传播途径（谁都能拿，谁都能猜错类型）。在这里私有，
// 外面就只能拿到解好的值。

Map<String, Object?>? _map(Object? value, String key) {
  if (value is! Map) return null;
  final field = value[key];
  return field is Map ? field.cast<String, Object?>() : null;
}

String? _string(Object? value, String key) {
  if (value is! Map) return null;
  final field = value[key];
  return (field is String && field.isNotEmpty) ? field : null;
}
