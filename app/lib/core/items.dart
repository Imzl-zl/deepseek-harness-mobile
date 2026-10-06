/// 条目（itemId）推导与 upsert 排序（契约 §5.2）。
///
/// 条目是 **upsert-only** 的：同一个 itemId 再出现只覆盖内容、不新增条目。
/// 因此快照的拼接顺序取每个 itemId **最后**出现的修订号，而不是首次出现。
///
/// 移植源：`connector/src/protocol/items.ts`（行为基准）。
library;

/// 持久事件日志里的一条：修订号 + 条目号 + 内容。
class LogEntry {
  const LogEntry({required this.seq, required this.itemId, required this.text});

  final int seq;
  final String itemId;
  final String text;
}

/// 快照 / 增量里对外暴露的条目视图。
class ItemRecord {
  const ItemRecord({required this.itemId, required this.text, required this.seq});

  final String itemId;
  final String text;
  final int seq;
}

/// 按 itemId 最后出现的 seq 升序排列 —— 快照的拼接顺序。
///
/// [log] 是持久事件日志（含已被 trim 出内存缓冲的那些，故顺序信息取自它）；
/// [items] 是当前条目表（itemId → text）。
List<ItemRecord> orderedItems(
  List<LogEntry> log,
  Map<String, String> items,
) {
  final lastSeqOf = <String, int>{};
  for (final entry in log) {
    lastSeqOf[entry.itemId] = entry.seq;
  }
  final records = items.entries
      .map((e) => ItemRecord(itemId: e.key, text: e.value, seq: lastSeqOf[e.key] ?? 0))
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

Object? _fieldOf(Object? value, String key) =>
    value is Map ? value[key] : null;

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
    final callId = _nonEmptyString(_fieldOf(data, 'callId'));
    if (callId == null) throw StateError('tool/call(seq=$seq) 缺少 callId');
    return 't:$callId';
  }

  if (type == 'tool/result') {
    // 结果与调用共用同一个 itemId，靠 `toolCallId` 配对。
    final callId = _nonEmptyString(_fieldOf(_fieldOf(data, 'message'), 'toolCallId'));
    if (callId == null) {
      throw StateError('tool/result(seq=$seq) 缺少 message.toolCallId：无法与 tool/call 配对');
    }
    return 't:$callId';
  }

  if (type == 'approval/asked' || type == 'approval/decided') {
    // ask 与 outcome 共用同一个 id，后者覆盖前者即「已决定」。
    final approvalId = _nonEmptyString(_fieldOf(data, 'id'));
    if (approvalId == null) throw StateError('$type(seq=$seq) 缺少 id');
    return 'i:$approvalId';
  }

  // 规格许可的兜底：仅用于没有更稳定身份的事件类型（契约 §5.2）。
  return '$type:$seq';
}
