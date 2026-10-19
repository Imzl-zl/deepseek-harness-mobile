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

import 'dart:convert';

import '../core/items.dart';
import '../model/chat_item.dart';
import '../model/interaction.dart';

/// `ask_user_question` 的工具名（DSH：
/// `packages/interaction/user-questions/src/projection.ts:28` 的 `ASK_USER_QUESTION_TOOL`）。
const String askUserQuestionTool = 'ask_user_question';

/// 系统提示词那一行的标签（DSH `locale.ts:116` 的 `message.systemPrompt`）。
const String kSystemPromptLabel = '系统提示词';

/// 工具名缺失时的占位（DSH 同处是空串 `''`；空串在卡片上什么也不说，
/// 而"这是个工具但不知道是哪个"本身是信息，所以给一个明说的占位）。
const String kUnknownToolName = '工具';

/// 命令名缺失时的占位（DSH 同处是 `t('command.title')`，即"命令"）。
///
/// 出现在"历史翻页只落到 `command/done`"那种窗口外情况 —— 那时名字只在
/// 窗口外的 `command/run` 上。留一个明说的占位，不编一个 `/xxx`。
const String kUnknownCommandName = '命令';

/// 命令运行中的摘要（DSH 的 `t('command.running')`）。
const String kCommandRunningSummary = '正在执行…';

/// 上下文注入行的标签：**照 DSH 的 `contextProducer`**
/// （`conversation-nodes/event-projection.ts:60-76`）—— 有 `source.kind`
/// 就照它说（`tool-registry` / `skill-invocation` / `agent-instructions` …），
/// 没有说话才退回 `上下文`。DSH 对未知 kind 的原话是
/// "keep an unknown producer visible by its durable kind"。
String contextProducerLabel(Object? data) {
  final kind = stringField(fieldOf(data, 'source'), 'kind');
  return kind ?? '上下文';
}

/// 把一条 DSH 会话事件投影成界面条目。
///
/// [seq] 是帧头带来的会话修订号（`ev` 帧的 `seq`）；事件自带的 `seq` 以那个为准
/// （两者在正常路径上相同，帧头那个是兜底）。
///
/// [steering] 标记这是一条插话消息（判据在 `AppModel` 的收件箱追踪里，
/// 与 DSH Web 的 `SteeringHistory` 同源）—— 投影层自己是纯函数，
/// 不认识跨事件的状态。
///
/// [previous] 是**同一个 itemId 上已有的条目**（upsert 的前一个值）。
/// 它的存在是因为 DSH 的 `tool/result` **不重复携带工具名与参数**（真日志实测：
/// 结果消息只有 `{role, source, toolCallId, content, isError, id}`），
/// 而名字与参数在 `tool/call` 上。DSH Web 的同一步是
/// `conversation-nodes/tool.ts:100-118` 的 `rootResult(match, previous)`：
/// `name: previous?.name ?? ''`、`args: previous?.args`、`call: {name, argsRaw}` ——
/// **结果继承调用**。没有这一层继承，`tool/result` 一到达就把卡片上的
/// `read` 覆盖成"工具"、把参数行覆盖成 JSON 键名（2026-10-19 真机复现）。
///
/// **未知类型不丢**：返回 [OtherItem]，而不是 `null`。
/// 丢掉会让"事件总数与条目数对不上"这类问题无从排查，而 DSH 的事件类型会随上游增加。
ChatProjection projectEvent({
  required String type,
  required int seq,
  required Object? data,
  int time = 0,
  bool steering = false,
  ChatItem? previous,
}) {
  // `itemId` 的推导只走 `core/items.dart`（契约 §5.2）：那是**唯一**一处，
  // 而它可能在已知类型缺字段时抛错（宁可让这一帧失败，也不要造一个会漂移的身份）。
  final itemId = itemIdOf(EventLike(type: type, seq: seq, data: data));

  if (isMessageEvent(type)) {
    final message = messageProjectionOf(type, data);
    return ChatProjection.item(
      MessageItem(
        itemId: itemId,
        seq: seq,
        updatedAt: time,
        role: roleOfEvent(type),
        text: message.text,
        attachmentCount: message.attachmentCount,
        steering: steering,
        reasoning: message.reasoning,
        // 系统 / 上下文注入行的**标签**（DSH 的 `system-prompt` 与 `context`
        // 两个节点各有一个标题行，见 `register-node-renderers.ts:45,49`）。
        // 用户与助手消息没有它（它们有头像与名字）。
        systemLabel: type == 'system/message'
            ? kSystemPromptLabel
            : type == 'developer/message'
            ? contextProducerLabel(data)
            : null,
      ),
    );
  }

  if (type == 'tool/call') {
    return ChatProjection.item(
      ToolCallItem(
        itemId: itemId,
        seq: seq,
        updatedAt: time,
        name: stringField(data, 'name') ?? kUnknownToolName,
        status: ToolCallStatus.running,
        // **参数行按 DSH 的 `deriveSummary` 推**，不是把载荷摊平：
        // 真日志里 `tool/call` 的 data 是 `{turn, step, callId, name, arguments}`，
        // 而 `arguments` 才是参数（JSON 字符串）。摊平 data 得到的是
        // `turn, step, callId, name, arguments` 这种键名清单（2026-10-19 真机复现）。
        summary: toolArgumentsSummary(
          name: stringField(data, 'name') ?? '',
          arguments: stringField(data, 'arguments') ?? '',
        ),
      ),
    );
  }

  if (type == 'tool/result') {
    // 结果与调用**共用同一个 itemId**（靠 `toolCallId` 配对，契约 §5.2），
    // 所以它到达时是"更新已有条目"，而不是新增一条。
    final message = fieldOf(data, 'message');
    // **继承调用那一半**（DSH `conversation-nodes/tool.ts:100-118` 的
    // `rootResult(match, previous)`）：真日志里结果消息不带 `name` 与参数，
    // 它们只在 `tool/call` 上。不继承就会把卡片上已经写好的名字与参数
    // 覆盖成"工具"和 JSON 键名（2026-10-19 真机复现，见决策笔记）。
    final call = previous is ToolCallItem ? previous : null;
    // 结果自己带 name 时照它（部分适配器会写）；否则用调用的名字。
    final name = stringField(message, 'name') ?? call?.name ?? kUnknownToolName;
    return ChatProjection.item(
      ToolCallItem(
        itemId: itemId,
        seq: seq,
        updatedAt: time,
        name: name,
        status: isToolError(data)
            ? ToolCallStatus.failed
            : ToolCallStatus.completed,
        // **参数摘要只用调用的那一份**：结果里没有参数，而把结果消息
        // 摊平只会得到 `role, source, toolCallId, conten…` 这种键名清单。
        // 历史翻页可能只落到结果（调用在窗口外），那时没有参数可显示 ——
        // 留空，不编一个（DSH 同处：`call: previous == null ? null : …`）。
        summary: call?.summary ?? '',
        // **结果正文进明细**：工具到底返回了什么，展开才看得见
        // （`ToolCard` 的 `.tool-body` 一直是支持的，只是投影从不填）。
        detail: toolOutputOf(message),
        // 文件变更的 +N/−M（`metadata.diffs` hunks 折算）。
        diffStat: diffStatOf(message),
      ),
    );
  }

  if (type == 'approval/asked') {
    final toolName = stringField(data, 'toolName') ?? '工具';
    final reason = stringField(data, 'reason');
    return ChatProjection.item(
      ApprovalItem(
        itemId: itemId,
        seq: seq,
        updatedAt: time,
        // 与接管卡同一套措辞（`interactionSignalOf`）：有 reason 照它说，
        // 否则"工具 X 请求越权执行"。两处各写一份必然漂移。
        title: reason ?? '工具 $toolName 请求越权执行',
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
        title: stringField(data, 'toolName') ?? '审批',
        decided: true,
        decision: stringField(data, 'outcome'),
      ),
    );
  }

  if (type == 'command/run') {
    // 命令开始。DSH 的 `command/run` 载荷是
    // `{commandId, name, args, source}`（真日志实测：`goal` / `/compact`）。
    // **状态是 running**：结果要等 `command/done`（同一 itemId 覆盖）。
    final name = stringField(data, 'name');
    final args = stringField(data, 'args');
    return ChatProjection.item(
      CommandItem(
        itemId: itemId,
        seq: seq,
        updatedAt: time,
        name: name == null || name.isEmpty ? kUnknownCommandName : '/$name',
        status: ToolCallStatus.running,
        // 摘要带参数（DSH 的卡片标题只有命令名，参数行进摘要）——
        // 参数可能很长（`/goal <一大段>`），截断由 UI 的 ellipsis 负责。
        summary: args == null || args.trim().isEmpty
            ? kCommandRunningSummary
            : args.trim(),
      ),
    );
  }

  if (type == 'command/done') {
    // 结果。DSH 的 `command/done` 载荷是 `{commandId, kind, text}`，
    // `kind` 是 `success` / `error`（真日志实测）。
    // **与 run 共用 itemId**（`c:$commandId`，见 `core/items.dart`）——
    // 所以它到达时是"更新已有条目"，不是新增一条。
    final call = previous is CommandItem ? previous : null;
    final kind = stringField(data, 'kind');
    final text = stringField(data, 'text');
    return ChatProjection.item(
      CommandItem(
        itemId: itemId,
        seq: seq,
        updatedAt: time,
        // 名字从 run 继承：`command/done` **不带 name**（真日志实测）。
        // 历史翻页可能只落到 done（run 在窗口外）—— 那时留"命令"，
        // 不编一个（DSH 同处：`node.name ?? t('command.title')`）。
        name: call?.name ?? kUnknownCommandName,
        status: kind == 'error'
            ? ToolCallStatus.failed
            : ToolCallStatus.completed,
        // 摘要是结果文本的**第一行**（DSH 的 `GenericCommandCard` 把整段
        // text 当 summary，而那是宽屏；手机上摘要只能一行）。
        // 复用工具摘要那一个截断上限（120）—— 同一行文字，同一尺度。
        summary: text == null ? '' : _firstLine(text, 120),
        // 明细是全文 —— 多行时才看得见（DSH 只对含换行的文本给展开）。
        detail: text ?? '',
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

/// 一条消息投影出来的三样东西：正文、附件数、思考过程。
class MessageProjection {
  const MessageProjection({
    required this.text,
    this.attachmentCount = 0,
    this.reasoning = '',
  });

  final String text;
  final int attachmentCount;
  final String reasoning;
}

/// 取消息正文（以及附件数与思考过程）。
///
/// **`user/message` 的载荷就是消息本身**，其余类型在 `data.message` 上
/// （`core/items.dart` 的 `itemIdOf` 有同一处结构知识 —— 两处都在描述 DSH 的形状，
/// 所以它们必须一起改；这一点在 `docs/` 里由契约 §5.2 那张表钉着）。
MessageProjection messageProjectionOf(String type, Object? data) {
  final holder = type == 'user/message' ? data : fieldOf(data, 'message');
  // DSH 的消息体是 `{id, role, content: [...]}` 形状；正文**只取纯文本块**，
  // 复杂块（图片、工具调用）由渲染层按需处理 —— 这一层不做富文本投影。
  final content = fieldOf(holder, 'content');
  return MessageProjection(
    text: textOfContent(content),
    attachmentCount: attachmentCountOf(content),
    // 助手消息的 content 里可能有 `{type:'reasoning', text}` 块
    // （真实会话日志里就有）；用户消息没有。
    reasoning: type == 'assistant/message' ? reasoningOf(content) : '',
  );
}

/// content 里图片 / 文件块的个数。
int attachmentCountOf(Object? content) {
  if (content is! List) return 0;
  var count = 0;
  for (final block in content) {
    if (block is Map) {
      final type = block['type'];
      if (type == 'image' || type == 'file') count += 1;
    }
  }
  return count;
}

/// 助手的思考过程（content 里全部 `reasoning` 块拼接）。
String reasoningOf(Object? content) {
  if (content is! List) return '';
  final buffer = StringBuffer();
  for (final block in content) {
    if (block is! Map) continue;
    if (block['type'] != 'reasoning') continue;
    final text = block['text'];
    if (text is String) buffer.write(text);
  }
  return buffer.toString();
}

/// 从 DSH 的 `content` 取纯文本。
///
/// `content` 可能是字符串，也可能是块数组（`{type: 'text', text: '…'}`）。
/// **两种都收**：DSH 的 `user/message` 历史上两种形状都出现过，
/// 而只认一种会让另一种静默显示成空 —— 那是"消息发出去但界面是空的"这类 bug。
///
/// **只取 `type == 'text'` 的块**：`{type:'reasoning', text}` 也是 `text` 字段，
/// 不按 type 滤就会把思考过程混进正文（真机日志里两种块并存）。
String textOfContent(Object? content) {
  if (content is String) return content;
  if (content is List) {
    final buffer = StringBuffer();
    for (final block in content) {
      if (block is Map) {
        if (block['type'] != 'text') continue;
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

/// 工具结果的输出文本（`message.content` 的文本块，截断成明细）。
///
/// **截断**：一次 `ls` 可以有几十万字符，而明细是展开才看的一行区域。
String toolOutputOf(Object? message, {int maxLength = 4000}) {
  final text = textOfContent(fieldOf(message, 'content')).trim();
  if (text.isEmpty) return '';
  final single = text.replaceAll(RegExp(r'\r\n?'), '\n');
  return single.length <= maxLength
      ? single
      : '${single.substring(0, maxLength)}…';
}

/// 从 `tool/result` 的 `metadata.diffs` 折算 +N/−M。
///
/// DSH 的 `diff-card-model.ts:29-41` 认的 hunk 形状是
/// `{path, oldText, newText}`；这里只取**行数统计**（手机这一版不画 diff
/// 正文，画正文是 `ui-tool` 的 DiffBlock，属于独立一块）。
/// 按行折算：旧文本行数 = 删除，新文本行数 = 新增。
({int added, int removed})? diffStatOf(Object? message) {
  final diffs = fieldOf(fieldOf(message, 'metadata'), 'diffs');
  if (diffs is! List || diffs.isEmpty) return null;
  var added = 0;
  var removed = 0;
  for (final hunk in diffs) {
    if (hunk is! Map) continue;
    final oldText = hunk['oldText'];
    final newText = hunk['newText'];
    if (oldText is String && oldText.isNotEmpty) {
      removed += oldText.split('\n').length;
    }
    if (newText is String && newText.isNotEmpty) {
      added += newText.split('\n').length;
    }
  }
  if (added == 0 && removed == 0) return null;
  return (added: added, removed: removed);
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

// ---------------------------------------------------------------------------
// 工具参数行（照 DSH `ui-tool/.../tool-call-model.ts` 的 deriveSummary）
// ---------------------------------------------------------------------------

/// 工具名 → 行变体（DSH `TOOL_VARIANTS`，`tool-call-model.ts:45-72`）。
///
/// 只有**影响摘要取哪个键**的才列：`bash`/`pwsh` 取 `description` 再 `command`；
/// `read` 系取 `path`/`file_path`/`url`；`search` 系取 `query`/`pattern`/`url`；
/// `write`/`edit` 取 `path`/`file_path`。**未知工具走 `others`（无优先键）** ——
/// 与 DSH 的 `classifyTool(toolName) ?? 'others'` 同一条规则。
const Map<String, List<String>> _toolSummaryKeys = <String, List<String>>{
  'bash': ['description', 'command'],
  'pwsh': ['description', 'command'],
  'read': ['path', 'file_path', 'url'],
  'read_image': ['path', 'file_path', 'url'],
  'web_fetch': ['path', 'file_path', 'url'],
  'web_search': ['query', 'pattern', 'url'],
  'grep': ['query', 'pattern', 'url'],
  'glob': ['query', 'pattern', 'url'],
  'write': ['path', 'file_path'],
  'edit': ['path', 'file_path'],
};

/// 工具参数的一行摘要。
///
/// 逐条对照 DSH 的 `deriveSummary`（`tool-call-model.ts:227-241`）：
///
/// 1. `arguments` 不是合法 JSON（流式中断 / 被拒的调用原样保留）→ 取**首行**；
/// 2. 按变体取优先键（见 [_toolSummaryKeys]）的第一个非空字符串；
/// 3. 都没有 → 取参数里**第一个非空字符串值**（DSH 同款兜底）；
/// 4. 参数里一个字符串都没有 → 取原始 `arguments` 的首行。
///
/// 第 3 条是"未知工具也能说点有意义的东西"的那一条：真日志里
/// `tool_search` 的参数是 `{"query": "..."}`，而它不在变体表里 ——
/// 没有第 3 条就会退到第 4 条，显示一整行 JSON。
String toolArgumentsSummary({
  required String name,
  required String arguments,
  int maxLength = 120,
}) {
  if (arguments.isEmpty) return '';
  Object? parsed;
  try {
    parsed = jsonDecode(arguments);
  } catch (_) {
    // DSH 的同一条：解析失败就退回原始文本首行（不猜、不编）。
    return _firstLine(arguments, maxLength);
  }
  if (parsed is! Map) return _firstLine(arguments, maxLength);
  final keys = _toolSummaryKeys[name];
  if (keys != null) {
    for (final key in keys) {
      final value = parsed[key];
      if (value is String && value.isNotEmpty) {
        return _firstLine(value, maxLength);
      }
    }
  }
  for (final value in parsed.values) {
    if (value is String && value.isNotEmpty) {
      return _firstLine(value, maxLength);
    }
  }
  return _firstLine(arguments, maxLength);
}

/// 取首行并截断（DSH 的 `firstLine` + 我们的摘要上限）。
String _firstLine(String text, int maxLength) {
  final nl = text.indexOf('\n');
  final line = nl == -1 ? text : text.substring(0, nl);
  final single = line.replaceAll(RegExp(r'\s+'), ' ').trim();
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

/// 同 [stringField]，但名字更短（内部大量使用）。
String? nonEmptyString(Object? value) =>
    (value is String && value.isNotEmpty) ? value : null;

// ---------------------------------------------------------------------------
// 交互投影（契约 §6.3：待处理集合是会话事件的投影）
// ---------------------------------------------------------------------------

/// 把一条 DSH 会话事件投影成**交互信号**（开一个待处理项 / 收束一个）。
///
/// ## 为什么待处理项从事件来，而不是电脑侧另推一份
///
/// 契约 §6.3 的原话："待处理集合是**会话事件的投影**，随 `ev` 帧一起到手机"，
/// 而这不是比喻 —— 审批的 ask 在 DSH 侧就是一条 `approval/asked` 会话事件
/// （`packages/interaction/user-approval/src/index.ts:225`，`request()` 在
/// dispatch 之前 append）；提问的 ask 是 `ask_user_question` 的 `tool/call`。
/// 于是手机不需要第二种推送通道，也不会有"两份待处理集合对不上"的问题。
///
/// ## 三类事件、三种收束
///
/// | 事件 | 信号 |
/// |---|---|
/// | `approval/asked` | 开（**带 `callId` 才开**，见下） |
/// | `approval/decided` | 收束（同 `i:<id>` 覆盖） |
/// | `tool/call`（`ask_user_question`） | 开 |
/// | `tool/result` / 迟到的 `user-question-reply` | 收束 |
///
/// ## 没有 `callId` 的审批**不开卡**
///
/// 连接器的应答者要求 `request.callId !== undefined` 才 claim（没有稳定身份就
/// 交还桌面，`connector/src/dsh/interactions.ts`）。于是没有 `callId` 的审批
/// **本来就会在电脑上答** —— 在手机上摆一张答不了的卡是对用户说谎。
///
/// Note: 为什么计划审查按提问渲染（`intent` 不进会话事件）——
/// 见 `.agents/notes/implemented/2026-10-10-interaction-to-phone-chain.md`。
///
/// @returns `null` = 这条事件与交互无关（绝大多数事件都是）。
InteractionSignal? interactionSignalOf({
  required String type,
  required int seq,
  required Object? data,
}) {
  if (type == 'approval/asked') {
    // `callId` 是可选的（`user-approval/src/index.ts:228`）；没有它手机答不了。
    final callId = nonEmptyString(fieldOf(data, 'callId'));
    if (callId == null) return null;
    final approvalId = nonEmptyString(fieldOf(data, 'id'));
    if (approvalId == null) return null;
    final toolName = nonEmptyString(fieldOf(data, 'toolName')) ?? '工具';
    final reason = nonEmptyString(fieldOf(data, 'reason'));
    return InteractionOpened(
      InteractionItem(
        itemId: 'i:$approvalId',
        sid: '',
        callId: callId,
        kind: InteractionKind.approval,
        toolName: toolName,
        // 有 reason 就照它说；否则退回"工具 X 请求越权执行"（照 DSH 桌面的措辞）。
        title: reason ?? '工具 $toolName 请求越权执行',
      ),
    );
  }

  if (type == 'approval/decided') {
    final approvalId = nonEmptyString(fieldOf(data, 'id'));
    if (approvalId == null) return null;
    return InteractionSettled('i:$approvalId');
  }

  if (type == 'tool/call') {
    if (nonEmptyString(fieldOf(data, 'name')) != askUserQuestionTool) {
      return null;
    }
    final callId = nonEmptyString(fieldOf(data, 'callId'));
    if (callId == null) return null;
    final questions = _questionsOf(fieldOf(data, 'arguments'));
    if (questions.isEmpty) return null;
    final first = questions.first;
    return InteractionOpened(
      InteractionItem(
        itemId: 't:$callId',
        sid: '',
        callId: callId,
        kind: InteractionKind.question,
        title: first.question,
        header: first.header ?? '',
        detail: first.detail ?? '',
        options: first.options,
        multiSelect: first.multiSelect,
        questions: questions,
      ),
    );
  }

  if (type == 'tool/result') {
    // 结果与调用共用同一个 itemId（`core/items.dart` 的配对规则）。
    final callId = nonEmptyString(
      fieldOf(fieldOf(data, 'message'), 'toolCallId'),
    );
    if (callId == null) return null;
    return InteractionSettled('t:$callId');
  }

  if (type == 'user/message') {
    // 迟到的答复：DSH 把它 steer 成一条 `source.kind='user-question-reply'` 的
    // 用户消息，而那条消息同时是投影里"这个问题已关闭"的记录
    // （`user-questions/src/index.ts:186-191`）。
    final source = fieldOf(data, 'source');
    if (nonEmptyString(fieldOf(source, 'kind')) != 'user-question-reply') {
      return null;
    }
    final callId = nonEmptyString(fieldOf(source, 'callId'));
    if (callId == null) return null;
    return InteractionSettled('t:$callId');
  }

  return null;
}

/// 从 `ask_user_question` 的**工具参数**里读出问题清单。
///
/// 形状照 DSH 的 `toolArgumentsSchema`（`user-questions/src/projection.ts:43-53`）：
/// `arguments` 是**JSON 字符串**，里层是 `{questions: [{id, question, header?, options?, multi_select?}]}`。
/// 注意字段名是 **snake_case 的 `multi_select`**（模型看到的形状），
/// 而应答链上的 `AskUserQuestionItem` 是 camelCase 的 `multiSelect` —— 两处形状不同，
/// 照错的那个会让多选永远读成单选。
///
/// **读不懂就返回空表**：那是模型的坏参数，工具根本没被调用过，没有卡可显示
/// （DSH 同一处也是 `return null`，`projection.ts:142-144`）。
List<InteractionQuestion> _questionsOf(Object? arguments) {
  if (arguments is! String || arguments.isEmpty) return const [];
  Object? parsed;
  try {
    parsed = jsonDecode(arguments);
  } catch (_) {
    return const [];
  }
  final raw = fieldOf(parsed, 'questions');
  if (raw is! List) return const [];
  final out = <InteractionQuestion>[];
  for (final entry in raw) {
    final id = nonEmptyString(fieldOf(entry, 'id'));
    final question = nonEmptyString(fieldOf(entry, 'question'));
    // 缺 id 就没法把答案配对回去（契约 §5.7 的批次要按 id 对上），
    // 缺题干就没什么可显示的 —— 两种都跳过这个问题，而不是摆一张空卡。
    if (id == null || question == null) continue;
    final rawOptions = fieldOf(entry, 'options');
    final options = <InteractionOption>[];
    if (rawOptions is List) {
      for (final option in rawOptions) {
        final label = nonEmptyString(fieldOf(option, 'label'));
        if (label == null) continue;
        options.add(
          InteractionOption(
            label: label,
            description: nonEmptyString(fieldOf(option, 'description')),
            // **"（推荐）"从标签里剥出来**单独做徽标（照原型）：标签本身干净，
            // 徽标位置固定。DSH 的选项没有 recommended 字段，这是从文案里剥的。
            recommended: _recommendedOf(label),
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
        multiSelect: fieldOf(entry, 'multi_select') == true,
      ),
    );
  }
  return out;
}

/// 标签里带"（推荐）"就算推荐（剥掉它再显示）。
bool _recommendedOf(String label) {
  final stripped = label.replaceAll(RegExp(r'[（(]推荐[)）]'), '');
  return stripped != label;
}
