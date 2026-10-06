/// 事件 → 领域模型的投影（唯一一处）。
///
/// ## 为什么只有一处
///
/// DSH 的事件是 `{type, seq, time, data}`（`core/` 只认识这个形状，不认识 `type` 的语义）。
/// "哪种 `type` 渲染成什么"如果不收在一处，就会**每屏各认识一遍** ——
/// 而同一个 `tool/call` 在对话页与轨迹页显示成两种东西，是必然结果。
///
/// ## 它认识什么、不认识什么
///
/// - **认识**：DSH 会话事件的 `type` 分类（`user/message` / `assistant/message` /
///   `tool/call` / `tool/result` / `approval/asked` / `approval/decided`）。
/// - **不认识**：`itemId` 的推导规则（那是 `core/items.dart` 的事）、
///   帧与封箱（那是 `core/` 的事）。
///
/// 也就是说：**本文件只做"读事件内容"，不做"算身份"**。
library;

import '../core/items.dart';
import '../model/chat_item.dart';

/// 把一条 DSH 会话事件投影成界面条目。
///
/// [seq] 是帧头带来的会话修订号（`ev` 帧的 `seq`）；事件自带的 `seq` 以那个为准
/// （两者在正常路径上相同，帧头那个是兜底）。
///
/// **未知类型不丢**：返回 [OtherItem]，而不是 `null`。
/// 丢掉会让"事件总数与条目数对不上"这类问题无从排查，而 DSH 的事件类型会随上游增加。
ChatProjection projectEvent({
  required String type,
  required int seq,
  required Object? data,
  int time = 0,
}) {
  // `itemId` 的推导只走 `core/items.dart`（契约 §5.2）：那是**唯一**一处，
  // 而它可能在已知类型缺字段时抛错（宁可让这一帧失败，也不要造一个会漂移的身份）。
  final itemId = itemIdOf(EventLike(type: type, seq: seq, data: data));

  if (isMessageEvent(type)) {
    return ChatProjection.item(
      MessageItem(
        itemId: itemId,
        seq: seq,
        updatedAt: time,
        role: roleOfEvent(type),
        text: textOfMessageEvent(type, data),
      ),
    );
  }

  if (type == 'tool/call') {
    return ChatProjection.item(
      ToolCallItem(
        itemId: itemId,
        seq: seq,
        updatedAt: time,
        name: stringField(data, 'name') ?? '工具',
        status: ToolCallStatus.running,
        summary: summarize(data),
      ),
    );
  }

  if (type == 'tool/result') {
    // 结果与调用**共用同一个 itemId**（靠 `toolCallId` 配对，契约 §5.2），
    // 所以它到达时是"更新已有条目"，而不是新增一条。
    return ChatProjection.item(
      ToolCallItem(
        itemId: itemId,
        seq: seq,
        updatedAt: time,
        name: stringField(fieldOf(data, 'message'), 'name') ?? '工具',
        status: isToolError(data)
            ? ToolCallStatus.failed
            : ToolCallStatus.completed,
        summary: summarize(fieldOf(data, 'message')),
      ),
    );
  }

  if (type == 'approval/asked') {
    return ChatProjection.item(
      ApprovalItem(
        itemId: itemId,
        seq: seq,
        updatedAt: time,
        title: stringField(data, 'title') ?? stringField(data, 'kind') ?? '待审批',
        decided: false,
      ),
    );
  }

  if (type == 'approval/decided') {
    return ChatProjection.item(
      ApprovalItem(
        itemId: itemId,
        seq: seq,
        updatedAt: time,
        title: stringField(data, 'title') ?? '审批',
        decided: true,
        decision: stringField(data, 'decision') ?? stringField(data, 'outcome'),
      ),
    );
  }

  return ChatProjection.item(
    OtherItem(itemId: itemId, seq: seq, updatedAt: time, eventType: type),
  );
}

/// 投影结果：一条条目，或"这条事件被流式累加器接管了，别渲染"。
///
/// 用一个小类型而不是 `ChatItem?`：`null` 会被读成"投影失败"，
/// 而这里的第二种情况是**正常**的（流式 `chunk` 不进持久条目表）。
class ChatProjection {
  const ChatProjection.item(ChatItem this.item) : skipReason = null;

  const ChatProjection.skip(String this.skipReason) : item = null;

  /// 要落进条目表的条目。
  final ChatItem? item;

  /// 为什么不进条目表（诊断用）。
  final String? skipReason;

  /// 是否是一条要落表的条目。
  bool get isItem => item != null;
}

/// 带消息本体的事件类型（契约 §5.2 的表）。
const Set<String> messageEventTypes = <String>{
  'user/message',
  'system/message',
  'developer/message',
  'assistant/message',
};

/// 这个事件类型是不是"带消息本体"的。
bool isMessageEvent(String type) => messageEventTypes.contains(type);

/// 事件类型 → 消息角色。
MessageRole roleOfEvent(String type) => switch (type) {
  'user/message' => MessageRole.user,
  'assistant/message' => MessageRole.assistant,
  _ => MessageRole.system,
};

/// 取消息正文。
///
/// **`user/message` 的载荷就是消息本身**，其余类型在 `data.message` 上
/// （`core/items.dart` 的 `itemIdOf` 有同一处结构知识 —— 两处都在描述 DSH 的形状，
/// 所以它们必须一起改；这一点在 `docs/` 里由契约 §5.2 那张表钉着）。
String textOfMessageEvent(String type, Object? data) {
  final holder = type == 'user/message' ? data : fieldOf(data, 'message');
  // DSH 的消息体是 `{id, role, content: [...]}` 形状；这里**只取纯文本块**，
  // 复杂块（图片、工具调用）由渲染层按需处理 —— 这一层不做富文本投影。
  return textOfContent(fieldOf(holder, 'content'));
}

/// 从 DSH 的 `content` 取纯文本。
///
/// `content` 可能是字符串，也可能是块数组（`{type: 'text', text: '…'}`）。
/// **两种都收**：DSH 的 `user/message` 历史上两种形状都出现过，
/// 而只认一种会让另一种静默显示成空 —— 那是"消息发出去但界面是空的"这类 bug。
String textOfContent(Object? content) {
  if (content is String) return content;
  if (content is List) {
    final buffer = StringBuffer();
    for (final block in content) {
      if (block is Map) {
        final text = block['text'];
        if (text is String) buffer.write(text);
      } else if (block is String) {
        buffer.write(block);
      }
    }
    return buffer.toString();
  }
  return '';
}

/// 工具结果是不是失败。
bool isToolError(Object? data) {
  final message = fieldOf(data, 'message');
  final isError = fieldOf(message, 'isError');
  if (isError is bool) return isError;
  final status = fieldOf(message, 'status');
  return status is String && status == 'error';
}

/// 一行摘要（**截断**：它是列表里的一行，不是详情）。
String summarize(Object? value, {int maxLength = 120}) {
  if (value == null) return '';
  final text = value is String ? value : _flatten(value);
  final single = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return single.length <= maxLength
      ? single
      : '${single.substring(0, maxLength)}…';
}

String _flatten(Object? value) {
  if (value is Map) {
    for (final key in const ['text', 'command', 'path', 'message', 'summary']) {
      final field = value[key];
      if (field is String && field.isNotEmpty) return field;
    }
    return value.keys.join(', ');
  }
  return '$value';
}

/// 取一个字段（非 Map 返回 `null`）。
Object? fieldOf(Object? value, String key) => value is Map ? value[key] : null;

/// 取一个字符串字段（非字符串或空串返回 `null`）。
String? stringField(Object? value, String key) {
  final field = fieldOf(value, key);
  return field is String && field.isNotEmpty ? field : null;
}

/// 从首条用户消息推导会话标题（**电脑侧不返回标题**，见 `SessionSummary.title`）。
///
/// DSH 桌面端也是这么做的：标题是本地投影，不是服务端字段。
/// 推导规则保持极简（首条用户消息的前若干字）——复杂的标题生成该由模型做，
/// 而不是由客户端猜。
String deriveTitle(List<ChatItem> items, {int maxLength = 30}) {
  for (final item in items) {
    if (item is MessageItem && item.role == MessageRole.user) {
      final text = item.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty) continue;
      return text.length <= maxLength
          ? text
          : '${text.substring(0, maxLength)}…';
    }
  }
  return '新会话';
}
