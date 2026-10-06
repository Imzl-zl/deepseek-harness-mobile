/// 示例数据：**只为"没连电脑时也能看看界面长什么样"**。
///
/// ## 为什么要有它，以及为什么它必须是"显式"的
///
/// 界面在没连电脑时只能是空列表 —— 那让"这一版做出来是什么样"无法回答，
/// 也让布局问题（长文本溢出、气泡宽度、工具行对齐）要等到真连上才暴露。
///
/// 但它**绝不能是静默兜底**：真实产品里"没数据"与"演示数据"混在一起，
/// 会让人以为连上了。所以：
///
/// 1. 只有**用户点了"看示例数据"**才会装（不是自动的、不是错误路径的回退）；
/// 2. 装进来的会话标题带 **`（示例）`** 前缀，界面上任何一屏都看得出它不是真的；
/// 3. 它**不写库**（`ItemStore` 不参与）—— 所以退出重进就没了，
///    不会永远占着真实的会话列表。
///
/// ## 数据本身是照着 DSH 的真实形状编的
///
/// 会话/工具调用/审批/流式那几屏各自要能看出问题，所以样例覆盖：
/// 长中文、代码块、工具调用的三种状态、一条待审批、一条系统消息。
library;

import '../model/chat_item.dart';

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

/// 示例会话列表。三屏各自的难点都覆盖到了。
///
/// ## `updatedAt` 是**相对值**，不是绝对时间戳
///
/// 这里的 `updatedAt`（500 / 400 / 300）是**"距今多少秒"的锚点**，
/// 由 `AppModel.loadPreview()` 加上当前时刻换算成真时间戳。
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
        name: 'Read',
        status: ToolCallStatus.completed,
        summary: 'lib/core/sync_client_impl.dart（971 行）',
      ),
      ToolCallItem(
        itemId: 'p1-t2',
        seq: 4,
        updatedAt: 400,
        name: 'Bash',
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
        text: '这 98 个图标直接做成图标字体不是更省事吗？',
      ),
      MessageItem(
        itemId: 'p2-a1',
        seq: 2,
        updatedAt: 200,
        role: MessageRole.assistant,
        text:
            '量完发现三样字体表达不了的东西：\n\n'
            '1. `archiveOff` 的斜杠是 `<mask>` **挖空**出来的 —— 去掉它就是另一个图标；\n'
            '2. `compact` / `folderOpen` 靠 `opacity` 同色两层叠出层次；\n'
            '3. 250 个 `<path>` 里大部分是**描边**，混着填充。\n\n'
            '所以走 SVG 渲染。代价是一个依赖，收益是 98 个图标一个都不走样。',
      ),
      ToolCallItem(
        itemId: 'p2-t1',
        seq: 3,
        updatedAt: 300,
        name: 'Grep',
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
        name: 'Write',
        status: ToolCallStatus.completed,
        summary: 'lib/theme/dsh_icons.dart（98 个图标）',
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
