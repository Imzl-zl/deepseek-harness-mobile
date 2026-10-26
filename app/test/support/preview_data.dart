/// **测试专用**的会话内容（原来产品里的"看示例数据"）。
///
/// 2026-10-26：发版前把产品里的示例入口删了（未配对空态不再有「看示例数据」）。
/// 但 UI 用例仍需要一个确定的会话：长中文、代码块、工具调用三种状态、待审批、
/// 系统消息、一条带 `detail` 的工具卡、一轮收口行。
///
/// 所以数据搬到这里，注入走 `AppModel.seedForTest`（`@visibleForTesting`）。
/// **产品代码不引用本文件**；标题也不再带「（示例）」前缀。
///
/// ## 数据是照着 DSH 的真实形状写的
///
/// `updatedAt` 是**相对当前时刻的偏移（毫秒）**，由 [seedPreview] 换算成真时间戳；
/// 写死小数字会被抽屉算成 1970 年、全落进「更早」（实测踩到过）。
library;

import 'package:dsh_mobile/data/app_model.dart';
import 'package:dsh_mobile/model/chat_item.dart';

/// 一份示例会话（含它的条目）。
class PreviewSession {
  const PreviewSession({
    required this.sid,
    required this.title,
    required this.items,
    this.updatedAt = 0,
  });

  final String sid;

  /// 标题（调用方会加上 `（示例）` 前缀，见文件头）。
  final String title;

  final List<ChatItem> items;
  final int updatedAt;
}

/// 「图标为什么不用字体」那一轮的助手回复。
///
/// 提出来是因为两处要用**同一份**：消息本身，以及该轮 `turn-tail` 的
/// `copyText`（复制钮复制的就是它）。两处各写一遍迟早会漂移。
const String _iconsReplyText =
    '量完发现三样字体表达不了的东西：\n\n'
    '1. `archiveOff` 的斜杠是 `<mask>` **挖空**出来的 —— 去掉它就是另一个图标；\n'
    '2. `compact` / `folderOpen` 靠 `opacity` 同色两层叠出层次；\n'
    '3. 250 个 `<path>` 里大部分是**描边**，混着填充。\n\n'
    '所以走 SVG 渲染。代价是一个依赖，收益是 100 个图标一个都不走样。';

/// 示例会话列表。三屏各自的难点都覆盖到了。
///
/// ## `updatedAt` 是**相对值**，不是绝对时间戳
///
/// 这里的 `updatedAt`（500 / 400 / 300）是**"距今多少秒"的锚点**，
/// 由 [seedPreview] 加上当前时刻换算成真时间戳。
///
/// 为什么不写死绝对时间戳：抽屉按今天 / 昨天 / 更早分组，而写死的小数字
/// 会被算成"1970 年"，于是三个会话全落进「更早」（实测踩到）。
/// 也不能在这里调 `DateTime.now()` —— 那会让这个 `const` 列表变成
/// 非 const，且同一个值每帧都不同。
const List<PreviewSession> previewSessions = <PreviewSession>[
  PreviewSession(
    sid: 'preview-1',
    title: '重构连接层',
    // **相对当前时刻的偏移（毫秒）**：`-3 分钟` 让它落在抽屉的「今天」。
    // 三个会话分属今天 / 昨天 / 更早，好让分组本身也能被看到。
    updatedAt: -3 * 60 * 1000,
    items: <ChatItem>[
      MessageItem(
        itemId: 'p1-u1',
        seq: 1,
        updatedAt: 100,
        role: MessageRole.user,
        text:
            '帮我把 sync_client_impl 里每连接的那几个字段拆出去，'
            '它们在建连和断连两处各写了一遍，我怕漏。',
      ),
      MessageItem(
        itemId: 'p1-a1',
        seq: 2,
        updatedAt: 200,
        role: MessageRole.assistant,
        text:
            '先量了一下耦合面：六个字段、33 处引用，而且 `_connect()` 与 '
            '`_enterClosed()` 里各写一遍同一个清单。\n\n'
            '拆成 `ConnectionResources`：建一份/作废一份各只有一处，不会再漏。',
      ),
      ToolCallItem(
        itemId: 'p1-t1',
        seq: 3,
        updatedAt: 300,
        name: 'read',
        status: ToolCallStatus.completed,
        summary: 'lib/core/sync_client_impl.dart（971 行）',
      ),
      ToolCallItem(
        itemId: 'p1-t2',
        seq: 4,
        updatedAt: 400,
        name: 'pwsh',
        status: ToolCallStatus.running,
        summary: 'flutter test test/sync_client_test.dart',
      ),
      ApprovalItem(
        itemId: 'p1-ap1',
        seq: 5,
        updatedAt: 450,
        title: '允许写入 lib/core/connection_resources.dart？',
        decided: false,
      ),
    ],
  ),
  PreviewSession(
    sid: 'preview-2',
    title: '图标为什么不用字体',
    // 昨天那一组。
    updatedAt: -26 * 60 * 60 * 1000,
    items: <ChatItem>[
      MessageItem(
        itemId: 'p2-u1',
        seq: 1,
        updatedAt: 100,
        role: MessageRole.user,
        text: '这 100 个图标直接做成图标字体不是更省事吗？',
      ),
      MessageItem(
        itemId: 'p2-a1',
        seq: 2,
        updatedAt: 200,
        role: MessageRole.assistant,
        text: _iconsReplyText,
      ),
      ToolCallItem(
        itemId: 'p2-t1',
        seq: 3,
        updatedAt: 300,
        name: 'grep',
        status: ToolCallStatus.failed,
        summary: 'no matches found（模式写错了）',
      ),
      MessageItem(
        itemId: 'p2-s1',
        seq: 4,
        updatedAt: 350,
        role: MessageRole.system,
        text: '上下文已压缩：早先 12 轮的工具输出折叠为摘要。',
      ),
      ToolCallItem(
        itemId: 'p2-t2',
        seq: 5,
        updatedAt: 400,
        name: 'write',
        status: ToolCallStatus.completed,
        summary: 'lib/theme/dsh_icons.dart（100 个图标）',
        // **`detail` 决定这张卡能不能展开**（`ToolCard` 的 `onTap` 是
        // `hasDetail ? … : null`）。示例数据原来一条 `detail` 都没有 ⇒
        // 示例模式下所有工具卡都点不开，"展开后会不会被新事件收起"
        // 这类行为在示例里根本看不到。补一条是为了让它可达（示例数据，
        // 会话标题带「（示例）」）。
        detail:
            '写入了 100 个图标常量：每行一对 name → path，'
            '外加 12 个语义别名的映射表。',
        changedPath: 'lib/theme/dsh_icons.dart',
        diffStat: (added: 100, removed: 0),
      ),
      // **一轮的收口行**（同时是 DSH 的 `turn-tail`：复制 + 用量 pill）。
      // 放一条是为了"没连电脑也能看到 2026-10-20 做的那一行长什么样"——
      // 否则它要等真会话才出现，用户没法在看界面时评价它。
      //
      // **数字是示例值**（与这个文件里其它样例一样，照真实形状编）。
      // `usage` 的形状取自真日志里的样本
      // （`.agents/notes/implemented/2026-10-20-turn-tail-actions.md` 文件头）。
      //
      // **这一行没有用时**（2026-10-22）：用时只从 `trajectory` 投影来，
      // 而示例模式**没有任何投影**（`loadPreview` 只装条目）—— 所以这里
      // 编一个"2 分 36 秒"会变成界面上唯一的假时长。示例里如实没有。
      TurnProcessItem(
        itemId: 'p2-turn',
        seq: 6,
        updatedAt: 500,
        turn: 2,
        messageCount: 2,
        toolCallCount: 2,
        usage: TurnTokenUsage(
          inputTokens: 66352,
          outputTokens: 110,
          totalTokens: 94408,
          cacheReadTokens: 27946,
        ),
        copyText: _iconsReplyText,
      ),
    ],
  ),
  PreviewSession(
    sid: 'preview-3',
    title: '超长文本与代码块',
    // 「更早」那一组。
    updatedAt: -5 * 24 * 60 * 60 * 1000,
    items: <ChatItem>[
      MessageItem(
        itemId: 'p3-u1',
        seq: 1,
        updatedAt: 100,
        role: MessageRole.user,
        // 故意超长且无空格：验换行与不溢出（中日韩文本没有空格可断）。
        text:
            '这一条是故意写得很长来验换行的：'
            '连接层拆分之后每连接资源束把密码器握手会话订阅计数器窗口分帧器六项收在一处'
            '于是建一份与作废一份各只有一处不会再漏掉任何一项。',
      ),
      MessageItem(
        itemId: 'p3-a1',
        seq: 2,
        updatedAt: 200,
        role: MessageRole.assistant,
        text:
            '收到。代码块也过一遍：\n\n'
            '```dart\n'
            'void _enterClosed() {\n'
            '  _res.dispose();   // 六项一次作废\n'
            '  _calls.failAll(const ProtocolException(\n'
            "    ErrorCode.relayOffline, '连接已断开',\n"
            '  ));\n'
            '}\n'
            '```\n\n'
            '**加粗**、`行内代码`、以及一个列表：\n'
            '- 第一项\n'
            '- 第二项',
      ),
      ApprovalItem(
        itemId: 'p3-ap1',
        seq: 3,
        updatedAt: 300,
        title: '允许执行 flutter build apk --debug？',
        decided: true,
        decision: 'allow',
      ),
    ],
  ),
];

/// 把三份示例会话装进 [app]（**测试专用**）。
///
/// 产品里没有这个入口了；它只调 `@visibleForTesting` 的 `seedForTest`。
void seedPreview(AppModel app) {
  final anchor = DateTime.now().millisecondsSinceEpoch;
  for (final preview in previewSessions) {
    app.seedForTest(
      sid: preview.sid,
      title: preview.title,
      updatedAt: anchor + preview.updatedAt,
      items: preview.items,
    );
  }
}
