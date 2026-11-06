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

import '../core/event_fields.dart';
import '../core/items.dart' show EventIdReaders;
import 'reading.dart';

/// 消费方一次拿齐"三态内核 + 事件 decoder"（`items.dart` / `projection.dart` 只需要这一行 import）。
/// RPC 面同样 re-export 一次，保证全 app 只有一套失败语义。
export 'reading.dart';

// 内核（`WireReading` / `WireDiagnostics` / `valueOrReport` / `valueOrNull`）在 `reading.dart`：
// 事件面与 RPC 面共用同一套三态与同一个计数，不为每个面各造一份。

// ---------------------------------------------------------------------------
// 各事件的载荷（只断言我们消费的字段）
// ---------------------------------------------------------------------------
//
// 所有事件的载荷**类型**都住在 `core/event_fields.dart`：它们要穿过 `EventFields`
// 端口交给 `data/`，类型跟着端口走才不用在这里再抄一份同样的字段表
// （抄一份就是两处真值）。这里只留"读线上形状 → 交 core 的值"。

// ---------------------------------------------------------------------------
// decoder：每个类型一个，字段名与类型只在这里断言
// ---------------------------------------------------------------------------

/// 一条 `tool/call`。`callId` 缺失是**形状错**（身份都丢了），不静默；`name` 缺失不是
/// （见 [ToolCallPayload.name]）。
WireReading<ToolCallPayload> readToolCall(Object? data) {
  final callId = _string(data, 'callId');
  if (callId == null) {
    return const WireBad<ToolCallPayload>('tool/call 缺 callId');
  }
  final raw = _string(data, 'arguments') ?? '';
  return WireOk<ToolCallPayload>(
    ToolCallPayload(
      callId: callId,
      name: _string(data, 'name'),
      argumentsRaw: raw,
      arguments: parseArguments(raw),
    ),
  );
}

/// **合并载荷**里的调用那一半（`name` / `arguments`）；两个都没有就是 `null`。
///
/// 为什么单独一个：`readToolCall` 要求 `callId`（那是 `tool/call` 的身份字段），
/// 而这里读的是**结果行的合并载荷** —— `StoreItemPersister` 把同一个 itemId 上
/// 前一条 `tool/call` 的字段留在同一行里（`tool/result` 自己不带名字与参数）。
/// 缺字段是**正常的**：修复之前写下的老载荷就没有它们。
///
/// Note: 为什么盘上要合并写 —— 见 `.agents/notes/implemented/2026-11-04-merged-payload-on-write.md`。
({String? name, String argumentsRaw})? mergedToolCallOf(Object? data) {
  final name = _string(data, 'name');
  final raw = _string(data, 'arguments');
  if (name == null && raw == null) return null;
  return (name: name, argumentsRaw: raw ?? '');
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
WireReading<ToolResultPayload> readToolResult(Object? data) {
  final message = _map(data, 'message');
  final callId = message == null ? null : _string(message, 'toolCallId');
  if (callId == null) {
    return const WireBad<ToolResultPayload>('tool/result 缺 message.toolCallId');
  }
  return WireOk<ToolResultPayload>(ToolResultPayload(callId: callId));
}

/// 一条 `approval/asked`。
WireReading<ApprovalAskedPayload> readApprovalAsked(Object? data) {
  final approvalId = _string(data, 'id');
  if (approvalId == null) {
    return const WireBad<ApprovalAskedPayload>('approval/asked 缺 id');
  }
  return WireOk<ApprovalAskedPayload>(
    ApprovalAskedPayload(
      approvalId: approvalId,
      callId: _string(data, 'callId'),
      toolName: _string(data, 'toolName'),
      reason: _string(data, 'reason'),
    ),
  );
}

/// 一条 `approval/decided`（DSH 只写 `{id, outcome}`，`user-approval/src/types.ts:55-58`）。
WireReading<ApprovalDecidedPayload> readApprovalDecided(Object? data) {
  final approvalId = _string(data, 'id');
  if (approvalId == null) {
    return const WireBad<ApprovalDecidedPayload>('approval/decided 缺 id');
  }
  return WireOk<ApprovalDecidedPayload>(
    ApprovalDecidedPayload(
      approvalId: approvalId,
      outcome: _string(data, 'outcome'),
    ),
  );
}

/// 一条迟到的提问答复（`user/message` 且 `source.kind === 'user-question-reply'`）。
///
/// 其它 `user/message` 一律 [WireSkip] —— 绝大多数用户消息与交互无关。
WireReading<QuestionReplyPayload> readQuestionReply(Object? data) {
  final source = _map(data, 'source');
  if (source == null) return const WireSkip<QuestionReplyPayload>();
  if (_string(source, 'kind') != 'user-question-reply') {
    return const WireSkip<QuestionReplyPayload>();
  }
  final callId = _string(source, 'callId');
  if (callId == null) {
    return const WireBad<QuestionReplyPayload>(
      'user-question-reply 缺 source.callId（认不出答的是哪一问）',
    );
  }
  return WireOk<QuestionReplyPayload>(QuestionReplyPayload(callId: callId));
}

/// 一条 `command/run`（DSH `commands/src/types.ts:105`）。
WireReading<CommandRunPayload> readCommandRun(Object? data) {
  final commandId = _string(data, 'commandId');
  if (commandId == null) {
    return const WireBad<CommandRunPayload>('command/run 缺 commandId');
  }
  return WireOk<CommandRunPayload>(
    CommandRunPayload(
      commandId: commandId,
      name: _string(data, 'name'),
      args: _string(data, 'args'),
    ),
  );
}

/// 一条 `command/done`（DSH `commands/src/types.ts:112-117`）。
WireReading<CommandDonePayload> readCommandDone(Object? data) {
  final commandId = _string(data, 'commandId');
  if (commandId == null) {
    return const WireBad<CommandDonePayload>('command/done 缺 commandId');
  }
  return WireOk<CommandDonePayload>(
    CommandDonePayload(
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

/// [EventIdReaders] 的**实现**：把四个身份字段的读取转给本文件的 decoder。
///
/// 为什么实现在这里：字段名叫什么、在哪一层（`data.callId` 与
/// `data.message.toolCallId` 不是同一处）只有本文件有权断言；而"哪个事件用哪个字段
/// 当身份、缺了就抛"留在 `core/items.dart`。装配点把这个常量交给
/// `SyncClientDeps.eventIds`（解码边界）与 `wire/rpc/session_page.dart`。
const EventIdReaders kWireEventIdReaders = _WireEventIdReaders();

final class _WireEventIdReaders implements EventIdReaders {
  const _WireEventIdReaders();

  @override
  String? toolCallId(Object? data) => valueOrNull(readToolCall(data))?.callId;

  @override
  String? toolResultId(Object? data) =>
      valueOrNull(readToolResult(data))?.callId;

  @override
  String? approvalId(Object? data, {required bool decided}) => decided
      ? valueOrNull(readApprovalDecided(data))?.approvalId
      : valueOrNull(readApprovalAsked(data))?.approvalId;

  @override
  String? commandId(Object? data, {required bool done}) => done
      ? valueOrNull(readCommandDone(data))?.commandId
      : valueOrNull(readCommandRun(data))?.commandId;
}
