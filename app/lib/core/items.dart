/// 条目（itemId）推导与 upsert 排序（契约 §5.2）。
///
/// 条目是 **upsert-only** 的：同一个 itemId 再出现只覆盖内容、不新增条目。
/// 因此快照的拼接顺序取每个 itemId **最后**出现的修订号，而不是首次出现。
///
/// 移植源：`connector/src/protocol/items.ts`（行为基准）。
///
/// ## 身份字段从 `event_wire.dart` 来，不在这里猜
///
/// 2026-10-25：`tool/call` 的 `arguments` 在线上是 JSON 字符串，本文件知道、
/// `data/projection.dart` 不知道 ⇒ 计划卡静默消失。现在凡是**载荷字段的类型**都只在
/// `core/event_wire.dart` 里断言，这里只取解好的身份字段；缺身份仍然**抛**（比一行打印更响）。
library;

import 'event_wire.dart';

/// 持久事件日志里的一条：修订号 + 条目号 + 内容。
class LogEntry {
  const LogEntry({required this.seq, required this.itemId, required this.text});

  final int seq;
  final String itemId;
  final String text;
}

/// 快照 / 增量里对外暴露的条目视图。
class ItemRecord {
  const ItemRecord({
    required this.itemId,
    required this.text,
    required this.seq,
  });

  final String itemId;
  final String text;
  final int seq;
}

/// 按 itemId 最后出现的 seq 升序排列 —— 快照的拼接顺序。
///
/// [log] 是持久事件日志（含已被 trim 出内存缓冲的那些，故顺序信息取自它）；
/// [items] 是当前条目表（itemId → text）。
List<ItemRecord> orderedItems(List<LogEntry> log, Map<String, String> items) {
  final lastSeqOf = <String, int>{};
  for (final entry in log) {
    lastSeqOf[entry.itemId] = entry.seq;
  }
  final records = items.entries
      .map(
        (e) => ItemRecord(
          itemId: e.key,
          text: e.value,
          seq: lastSeqOf[e.key] ?? 0,
        ),
      )
      .toList();
  records.sort((a, b) => a.seq - b.seq);
  return records;
}

/// 事件的最小结构。itemId 推导只看类型、序号与载荷。
///
/// DSH 的 `SessionWireEvent` 结构上满足它，但本层**不 import 它的类型** ——
/// `core/` 保持零 DSH 依赖（也零平台依赖）。
class EventLike {
  const EventLike({required this.type, required this.seq, required this.data});

  final String type;
  final int seq;
  final Object? data;
}

/// 载荷里带消息本体的事件。`user/message` 的载荷**就是**消息，其余放在 `data.message`。
const Set<String> _messageEvents = <String>{
  'user/message',
  'system/message',
  'developer/message',
  'assistant/message',
};

Object? _fieldOf(Object? value, String key) => value is Map ? value[key] : null;

String? _nonEmptyString(Object? value) =>
    (value is String && value.isNotEmpty) ? value : null;

/// itemId 由事件自身推导（契约 §5.2 表）。
///
/// **不得用 `seq` 当主键**（不变量 I9）。`<type>:<seq>` 只是规格明确许可的兜底，
/// 仅用于没有更稳定身份的事件类型。
///
/// 已知类型缺了身份字段时**直接抛错**，不静默退化成 `<type>:<seq>`：那会让一条本该
/// 稳定的条目随读路径换 id，正是 I9 要防的形态。宁可让这一帧失败，也不要静默造出
/// 一个会漂移的身份。
String itemIdOf(EventLike event) {
  final type = event.type;
  final seq = event.seq;
  final data = event.data;

  if (_messageEvents.contains(type)) {
    // `user/message` 是特例：载荷本身就是消息，其余类型在 `data.message` 上。
    final holder = type == 'user/message' ? data : _fieldOf(data, 'message');
    // `MessageId` 是「跨每个表示边界保持的稳定身份」。
    final messageId = _nonEmptyString(_fieldOf(holder, 'id'));
    if (messageId == null) {
      throw StateError('$type(seq=$seq) 缺少 message.id：无法推导稳定 itemId');
    }
    return 'm:$messageId';
  }

  if (type == 'tool/call') {
    final call = valueOrNull(readToolCall(data));
    if (call == null) throw StateError('tool/call(seq=$seq) 缺少 callId');
    return 't:${call.callId}';
  }

  if (type == 'tool/result') {
    // 结果与调用共用同一个 itemId，靠 `toolCallId` 配对。
    final result = valueOrNull(readToolResult(data));
    if (result == null) {
      throw StateError(
        'tool/result(seq=$seq) 缺少 message.toolCallId：无法与 tool/call 配对',
      );
    }
    return 't:${result.callId}';
  }

  if (type == 'approval/asked' || type == 'approval/decided') {
    // ask 与 outcome 共用同一个 id，后者覆盖前者即「已决定」。
    final asked = type == 'approval/asked'
        ? valueOrNull(readApprovalAsked(data))?.approvalId
        : valueOrNull(readApprovalDecided(data))?.approvalId;
    if (asked == null) throw StateError('$type(seq=$seq) 缺少 id');
    return 'i:$asked';
  }

  if (type == 'command/run' || type == 'command/done') {
    // run 与 done 共用同一个 id，靠 `commandId` 配对 —— 与 tool/call /
    // tool/result 同一形状（DSH 的格式不变量逐字同源：
    // `session-format-v3-to-v4/README.md:244` 原话
    // "Run ids are unique; completion has a prior run"）。
    final commandId = type == 'command/run'
        ? valueOrNull(readCommandRun(data))?.commandId
        : valueOrNull(readCommandDone(data))?.commandId;
    if (commandId == null) {
      throw StateError('$type(seq=$seq) 缺少 commandId：无法与另一条配对');
    }
    return 'c:$commandId';
  }

  if (type == 'llm/retry' || type == 'llm/retry-started') {
    // 一条重试链：`llm/retry` 是"计划第 N 次重试"（`retry === 1` 时开始），
    // `llm/retry-started` 是"这次真的跑起来了"。两者靠 `retryId` 配对
    // （DSH `conversation-nodes/retry.ts:45-53`）。
    // **同一个 retryId 下会有多条 `llm/retry`**（第 1、2、3 次各一条），
    // 所以 id 必须带 `retry` 序号 —— 否则三次会互相覆盖，只剩最后一次。
    final retryId = _nonEmptyString(_fieldOf(data, 'retryId'));
    if (retryId == null) throw StateError('$type(seq=$seq) 缺少 retryId');
    final retry = _fieldOf(data, 'retry');
    if (retry is! int) {
      throw StateError('$type(seq=$seq) 缺少 retry（第几次重试）');
    }
    return 'r:$retryId:$retry';
  }

  if (type == 'turn/end') {
    // 一轮的结局与过程摘要。**同一轮只有一条 `turn/end`**（DSH 的格式不变量：
    // turn 号递增，`turn/end` 与 `turn/start` 一一对应），所以 `turn` 号
    // 就是稳定身份。`turn/start` 不占条目（它不渲染成任何东西），
    // 因此这里不需要与它配对。
    final turn = _fieldOf(data, 'turn');
    if (turn is! int) throw StateError('turn/end(seq=$seq) 缺少 turn');
    return 'e:$turn';
  }

  if (type == 'compaction/start' ||
      type == 'compaction/summary' ||
      type == 'compaction/end') {
    // 一次自动压缩的生命周期：start / summary / end 三条共用同一个 id，
    // 靠 `compactionId` 配对（DSH `conversation-nodes/compaction.ts:34-48`）。
    // **手动 `/compact` 不算**：DSH 的 `match` 对带 `sourceCommandId` 的
    // 一律返回 null（`:42`）—— 那种压缩归 `manual-compaction` 节点，
    // 由命令卡呈现（`command/run` + `command/done`）。
    final compactionId = _nonEmptyString(_fieldOf(data, 'compactionId'));
    if (compactionId == null) {
      throw StateError('$type(seq=$seq) 缺少 compactionId：无法与另两条配对');
    }
    return 'x:$compactionId';
  }

  // 规格许可的兜底：仅用于没有更稳定身份的事件类型（契约 §5.2）。
  return '$type:$seq';
}
