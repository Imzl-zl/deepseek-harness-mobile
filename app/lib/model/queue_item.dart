/// 排队中的消息（DSH `inbox` 投影的 `next-turn` 段）。
///
/// ## 数据从哪来
///
/// **不是新方法** —— 队列是 `inbox` 投影的一段，随 `session.projections`
/// 到手机（契约 §5.7 已把 `inbox` 列进核实过的键）。DSH 的 wire view 是
/// `{'next-turn': [UserMessage], 'next-step': [UserMessage]}`：
///
/// - `next-turn`：排到**下一个轮次**的消息（发送时选"排队发送"进来的）；
/// - `next-step`：插进当前轮次的消息（"插话发送"）。
///
/// Web 的排队 dock 只列 `next-turn`
/// （`packages/client/ui-conversation/src/client/queue/QueueDock.tsx:113`），
/// 手机同一条：**插进当前轮次的不在队列里**，它已经生效了。
///
/// 变异走 `session.updateQueue`（编辑 / 删除 / 插话），与 Web 三个行内按钮
/// 同一个 DSH 方法。
library;

/// 排队项变异（DSH `QueueAction` 联合的三个 kind）。
///
/// 与 Web 排队 dock 的三个行内按钮一一对应（`QueueDock.tsx` 的
/// 编辑 / 删除 / 插话发送）。
enum QueueActionKind {
  /// 编辑：只发纯文本（DSH 的 `commands.ts:433-441` 同一条）。
  edit,

  /// 删除：把这一项从队列里撤掉。
  remove,

  /// 插话：立刻插进当前轮次（**仅运行中可插话发送**）。
  steer,
}

/// 一条排队消息（界面要看的那几项）。
class QueueItem {
  const QueueItem({
    required this.itemId,
    required this.previewText,
    this.attachmentCount = 0,
    this.editable = false,
  });

  /// DSH 的 `MessageId`（`session.updateQueue` 的 `itemId`）。
  final String itemId;

  /// 预览文本（非文本块折成 `[image]` 这类占位，200 字封顶）。
  final String previewText;

  /// 附件个数（图片 + 文件）。**只计数不渲染** —— 手机这一版不给排队消息
  /// 传附件（那是 `attachment` 读取面的事，本期未接），但"带了 2 个附件"
  /// 这个事实要说出来，否则用户以为排队把附件丢了。
  final int attachmentCount;

  /// 能不能编辑（**纯文本**才可编辑，见 [queueItemEditable]）。
  final bool editable;
}

/// 从 `inbox` 投影值解析排队列表。
///
/// 认不出就给空表：没有这个投影（老连接器 / 没注册）与"队列是空的"
/// 在界面上同一表现 —— 排队条不显示。**不猜**。
List<QueueItem> parseQueueItems(Object? raw) {
  if (raw is! Map) return const [];
  final rows = raw['next-turn'];
  if (rows is! List) return const [];
  final out = <QueueItem>[];
  for (final row in rows) {
    if (row is! Map) continue;
    final id = row['id'];
    if (id is! String || id.isEmpty) continue;
    out.add(
      QueueItem(
        itemId: id,
        previewText: queuePreviewOf(row['content']),
        attachmentCount: queueAttachmentCount(row['content']),
        editable: queueItemEditable(row['content']),
      ),
    );
  }
  return out;
}

/// 排队预览：滤掉图片/文件块，文本块拼接，其余折成 `[type]`，200 字封顶。
///
/// 与 Web 的 `previewOf` 逐字一致
/// （`QueueDock.tsx:20-27`：`QUEUE_PREVIEW_CHARS = 200`，块之间 `join(' ')`）。
/// **按字符数截断而不是字节**：中文一个字符顶三个字节，按字节截会把
/// 一个词砍一半（而这里只是预览，不是内容）。
String queuePreviewOf(Object? content, {int maxLength = 200}) {
  if (content is! List) return '';
  final parts = <String>[];
  for (final block in content) {
    if (block is! Map) continue;
    final type = block['type'];
    if (type == 'text') {
      final text = block['text'];
      if (text is String) parts.add(text);
      continue;
    }
    // 图片 / 文件 / 其它块：留一个占位，让"这条不全是文字"看得出来。
    if (type is String && type.isNotEmpty) parts.add('[$type]');
  }
  // **块之间一个空格**（Web 的 `join(' ')`）：没有它 `[image]` 会和正文
  // 粘成一个词，预览读起来是 "[image]带图的第二条"。
  final flat = parts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= maxLength) return flat;
  return '${flat.substring(0, maxLength)}…';
}

/// 附件块个数（`image` + `file`）。
int queueAttachmentCount(Object? content) {
  if (content is! List) return 0;
  var count = 0;
  for (final block in content) {
    if (block is! Map) continue;
    final type = block['type'];
    if (type == 'image' || type == 'file') count += 1;
  }
  return count;
}

/// 这一项能不能编辑（Web 的 `textOf`：**纯文本**才给编辑）。
///
/// 带了图片/文件的排队消息编辑不了 —— DSH 的 `updateQueue` 编辑只收
/// 纯文本（`commands.ts:433-441`），摆一个能点但必然失败的入口是骗人。
bool queueItemEditable(Object? content) {
  if (content is! List || content.isEmpty) return false;
  for (final block in content) {
    if (block is! Map) return false;
    if (block['type'] != 'text') return false;
  }
  return true;
}
