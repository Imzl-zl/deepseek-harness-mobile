/// 领域模型（`docs/subsystems/app-platform-boundaries.md` §1 的 `model/`）。
///
/// ## 这一层是干什么的
///
/// **UI 只认识这里的东西**，不认识帧、不认识 JSON、不认识 `itemId` 的推导规则。
/// 它是 `core/`（协议实现）与 `ui/`（逐屏）之间的**翻译层**：
///
/// ```text
/// core/  帧与事件（{type, seq, data}）        ← 协议形状
///   ↓  model/ 把事件投影成"界面上能看到的东西"
/// ui/    SessionSummary / MessageItem / …   ← 界面形状
/// ```
///
/// ## 为什么投影在 model 层，而不是在 UI 里
///
/// `core/` 只负责"这一条属于哪个 itemId"（`itemIdOf`，契约 §5.2），
/// **不认识 `type` 的语义**（那是 DSH 的事件分类，会随上游演进）。
/// 把"哪种事件渲染成什么样"放在 UI 里的话，每一屏都要各自认识一遍事件类型 ——
/// 而它们迟早会不一致（同一个 `tool/call` 在对话页与轨迹页显示成两种东西）。
///
/// 所以：**事件 → 条目的投影只在这一处**，UI 只读投影结果。
library;

import '../core/endpoint.dart';

/// 一条会话条目在界面上长什么样。
///
/// **不可变**：UI 用它做 `==` 比较来决定要不要重建（Flutter 的重建成本主要在
/// 子树 diff，而不是对象分配）。可变对象会让"内容没变但重建了"无法判断。
sealed class ChatItem {
  const ChatItem({
    required this.itemId,
    required this.seq,
    required this.updatedAt,
  });

  /// 稳定身份（契约 §5.2，不变量 I9）。**不是 `seq`** —— 用 `seq` 当主键会让
  /// 同一条消息在重放时换 id，而 UI 的 key 会跟着漂。
  final String itemId;

  /// 会话修订号（DSH 的 `seq`）。
  final int seq;

  /// 最后一次更新时刻（DSH 事件自带 `time`）。
  final int updatedAt;
}

/// 用户 / 助手 / 系统发的一条消息。
class MessageItem extends ChatItem {
  const MessageItem({
    required super.itemId,
    required super.seq,
    required super.updatedAt,
    required this.role,
    required this.text,
    this.attachmentCount = 0,
    this.steering = false,
    this.reasoning = '',
  });

  final MessageRole role;

  /// 正文。**流式期间这里是累加器的当前内容**，持久事件到达时被整体替换
  /// （`app-channel-client.md` §2.2：以持久为准，避免"流式与最终文本不一致"）。
  final String text;

  /// 附件个数（图片 + 文件块）。**只计数不渲染** —— 手机这一版不给会话消息
  /// 传附件（读附件要 `session/attachment`，本期未接），但"这条带了 2 张图"
  /// 这个事实要说出来，否则用户以为附件丢了。
  final int attachmentCount;

  /// 这是一条**插话**（轮次跑到一半从 next-step 收件箱插进去的用户消息）。
  ///
  /// 判据与 DSH Web 逐字同源（`ui-chat/src/client/model/steering-history.ts`：
  /// `agent/inbox/spliced` 进 next-step 的 id，随后作为 `user/message` 到达）。
  /// 界面上它是同一条右对齐气泡，只多一枚"插话"标 —— 没有它，
  /// "我在它跑到一半时纠正了它"这件事在对话流里看不出来。
  final bool steering;

  /// 助手消息的**思考过程**（`assistant/message` 的 content 里
  /// `{type:'reasoning', text}` 块；用户消息恒为空）。
  ///
  /// DSH 桌面端把它渲染成过程块（可折叠），手机同一条：折叠在正文上方，
  /// 默认收起 —— 它经常比正文还长，全展开会把对话冲掉。
  final String reasoning;
}

/// 消息角色（决定气泡配色与对齐）。
enum MessageRole {
  /// 用户发的。
  user,

  /// 助手（模型）发的。
  assistant,

  /// 系统注入的（上下文、goal 续跑等）。
  system,
}

/// 一次工具调用（含结果）。
class ToolCallItem extends ChatItem {
  const ToolCallItem({
    required super.itemId,
    required super.seq,
    required super.updatedAt,
    required this.name,
    required this.status,
    this.summary = '',
    this.detail = '',
    this.diffStat,
  });

  /// 工具名（如 `Read` / `Bash`）。
  final String name;

  final ToolCallStatus status;

  /// 一行摘要（参数或结果的短描述）。
  final String summary;

  /// 展开后的明细（工具输出的预览，截断）。
  ///
  /// 2026-10-17 之前恒为空串 —— `ToolCard` 支持展开（`.tool-body`），
  /// 而投影从不填它，于是"这个工具到底返回了什么"在手机上看不见。
  final String detail;

  /// 变更统计（`+N −M`）；`null` = 不显示。
  ///
  /// 从 `tool/result` 的 `metadata.diffs`  hunks 折算（DSH 的
  /// `diff-card-model.ts:29-41` 认的就是 `{path, oldText, newText}` 这三项）。
  final ({int added, int removed})? diffStat;
}

/// 工具调用的状态。
enum ToolCallStatus {
  /// 已发出、还没结果。
  running,

  /// 有结果了。
  completed,

  /// 失败。
  failed,
}

/// 一次审批（`approval/asked` 与 `approval/decided` 共用同一个 `itemId`）。
///
/// **ask 与 outcome 共用一个 id 是契约的设计**（§5.2）：outcome 覆盖 ask，
/// 于是"已决定"天然表达成"同一条目的状态变了"，而不是两条并存 ——
/// 后者会让 UI 需要自己去配对，而配对规则迟早会写歪。
class ApprovalItem extends ChatItem {
  const ApprovalItem({
    required super.itemId,
    required super.seq,
    required super.updatedAt,
    required this.title,
    required this.decided,
    this.decision,
  });

  final String title;

  /// 是否已经决定（`asked` 是 false，被 `decided` 覆盖后是 true）。
  final bool decided;

  /// 决定内容（已决定时有）。
  final String? decision;
}

/// 其它事件（`usage` 更新、`step` 边界等）——**只计数、不渲染**。
///
/// 存在的理由：模型要能表达"这条我知道了，但界面上没有它的位置"，
/// 而不是把不认识的事件丢掉（丢掉会让"事件总数与条目数对不上"这类问题无从排查）。
class OtherItem extends ChatItem {
  const OtherItem({
    required super.itemId,
    required super.seq,
    required super.updatedAt,
    required this.eventType,
  });

  /// 原始事件类型（诊断用）。
  final String eventType;
}

/// 会话列表里的一行。
class SessionSummary {
  const SessionSummary({
    required this.sid,
    required this.title,
    required this.updatedAt,
    this.itemCount = 0,
    this.pendingCount = 0,
    this.running = false,
    this.blank = false,
    this.subagent = false,
    this.model,
    this.cwd,
  });

  /// 会话别名（电脑侧分配的不透明 id，契约 §5.1）。
  final String sid;

  /// 标题。**唯一来源是电脑侧**：`session.list` 行的投影提示
  /// （`projections.values.title`）或 `session.projections` 的 `title` 投影
  /// （DSH `session-title/src/index.ts:269-281`，wire view 就是 `string | null`），
  /// 以及会话事件流里的 `session/title` 事件（DSH 生成/改名时落一条）。
  ///
  /// **不从本地条目推导**：2026-10-17 前 `AppModel._touchSummary` 每次收到
  /// delta 都用"首条用户消息前 30 字"覆盖它，于是列表里叫 A、点进会话叫 B
  /// （真机反馈"选中会话名字就变"）。推导标题是**第二个真值源**，必然漂。
  final String title;

  final int updatedAt;
  final int itemCount;

  /// 待处理（审批 / 提问）计数，UI 用来显示角标。
  final int pendingCount;

  /// 电脑侧此刻是否有轮次在跑（`session.list` 的 `running`）。
  ///
  /// 它不是装饰：**给一个正在跑的会话发消息会被 DSH 排到下一个轮次**
  /// （`sessionController.prompt` 走 `agent.followup`，`commands.ts:365`），
  /// 于是"发出去"与"电脑侧看到"之间隔着一整个轮次。要立刻看到反应的
  /// 发送方（如真机联调里那条审批探针）必须先挑一个空闲的。
  final bool running;

  /// 还没有任何轮次（`session.list` 的 `blank`，电脑侧原样过线）。
  ///
  /// 它的判据是"这个会话从没被 agent 跑过"（`connector/src/dsh/sessions.ts`：
  /// blank = 还没有任何轮次）。**挑靶子时要它**：只按 `!running` 挑会挑到
  /// "刚被别的 agent 跑完一轮"的会话，而那种会话的 agent 随时可能又被唤起
  /// （真机联调两次就这么把别人的空会话叫醒过）。
  ///
  /// 它还是**列表可见性**的一条判据：DSH Web 的 `sessionVisible`
  /// （`ui-workspace/src/client/tree.ts:245`）把 blank 且非当前的会话藏掉。
  final bool blank;

  /// 子智能体的子会话（`origin === 'subagent'`，电脑侧原样过线）。
  ///
  /// **列表里不列它**：DSH Web 的 `sessionVisible` 同样 `return false`
  /// （`tree.ts:244`）。2026-10-15 真机对比：Web 的 anatomy-test 3 条、
  /// 手机 4 条，多的那条就是子智能体会话 —— 连接器一直在发这个标志，
  /// 是手机侧没解析也没用。
  final bool subagent;

  /// 这个会话**下一次**将用的模型（`session.list` 的 `model`）。
  ///
  /// 来自 DSH 的 `modelSelection` 投影（`next ?? lastUsed`），
  /// 见 `connector/src/dsh/models.ts`。**`null` 就是"不知道"** ——
  /// 新建会话、或投影还没落时电脑侧也不说，这时界面显示"未选择"，
  /// 而不是猜一个把"看起来连着"当成"连着"。
  final ModelRef? model;

  /// 会话的工作区目录（`session.list` 的 `cwd`）。
  ///
  /// 电脑侧一直在发（`connector/src/handlers.ts` 的 `session.list`），**取不到就是
  /// `null`** —— 老连接器或落盘里没有 `cwd` 的会话都不发这个字段。界面不显示它，
  /// 它是给"挑靶子"用的：一个工作区已失效的会话，`session.prompt` 照常落
  /// `user/message`，而它的 agent 永远不起轮次（全程零痕迹），所以拿它当靶子
  /// 会等到超时也看不到任何反应。
  ///
  /// 2026-10-16 起它**不再是标题链的一级**：DSH 的 Web 侧栏对无标题会话显示
  /// 「未命名」而不用目录名兜底（`ui-workspace/README.zh.md:32`），手机对齐。
  final String? cwd;

  /// 展示用标题。链与 DSH 的**侧栏规则**一致：
  /// 投影提示里的标题 → 「未命名」。
  ///
  /// DSH 的 Web 侧栏对没有标题的会话显示本地化的「未命名 / Untitled」，
  /// **不使用目录名兜底**（`ui-workspace/README.zh.md:32`，原话
  /// "未保存标题的历史会话显示本地化名称「未命名 / Untitled」，不使用目录名兜底"；
  /// 判据在 `ui-workspace/src/client/tree.ts:296` 的 `sessionTitle`：
  /// 只取存储标题，空串交给渲染层本地化）。
  ///
  /// 2026-10-16 之前这里是 `title → 目录名 → sid`：目录名兜底让手机上出现
  /// 一串工作区目录名当会话名（Web 上同一批会话叫"未命名"），sid 兜底更糟 ——
  /// 一长串随机字符当名字。两级兜底全部删掉，与 Web 对齐。
  ///
  /// 注意：`session.list` 的行**只有投影提示**（host 侧 `SessionSummary`
  /// 没有独立的持久标题字段，见 `dsh-api-session-controller` 的
  /// `lib/types/types.d.ts`），所以远程客户端拿不到 Web 那个"持久标题"，
  /// 提示标题是列表行唯一的标题来源——这不是将就，是契约。
  String get displayTitle => title.isNotEmpty ? title : kUntitledSessionTitle;

  /// 没有标题的会话在列表里的显示名（照 DSH 的 `session.untitled` 本地化值）。
  static const String kUntitledSessionTitle = '未命名';

  SessionSummary copyWith({
    String? title,
    int? updatedAt,
    int? itemCount,
    int? pendingCount,
    bool? running,
    bool? blank,
    bool? subagent,
    ModelRef? model,
    String? cwd,
  }) => SessionSummary(
    sid: sid,
    title: title ?? this.title,
    updatedAt: updatedAt ?? this.updatedAt,
    itemCount: itemCount ?? this.itemCount,
    pendingCount: pendingCount ?? this.pendingCount,
    running: running ?? this.running,
    blank: blank ?? this.blank,
    subagent: subagent ?? this.subagent,
    model: model ?? this.model,
    cwd: cwd ?? this.cwd,
  );

  /// 只换**易变计数**（更新时间 / 条目数 / 待处理数）。
  ///
  /// 存在的理由：`AppModel._touchSummary` 每条 delta 都会更新这三个数，
  /// 而**身份字段（标题 / 模型 / running / blank / subagent / cwd）一条都不该动** ——
  /// 2026-10-17 前那里用构造函数重建整行，身份字段全部掉成默认值，
  /// 症状是"点进会话模型变未选择、标题变成本地推导名"。
  SessionSummary withCounters({
    required int updatedAt,
    required int itemCount,
    required int pendingCount,
  }) => SessionSummary(
    sid: sid,
    title: title,
    updatedAt: updatedAt,
    itemCount: itemCount,
    pendingCount: pendingCount,
    running: running,
    blank: blank,
    subagent: subagent,
    model: model,
    cwd: cwd,
  );

  /// 只换标题（电脑侧的 `title` 投影 / `session/title` 事件落地时用）。
  SessionSummary withTitle(String title) => SessionSummary(
    sid: sid,
    title: title,
    updatedAt: updatedAt,
    itemCount: itemCount,
    pendingCount: pendingCount,
    running: running,
    blank: blank,
    subagent: subagent,
    model: model,
    cwd: cwd,
  );
}

/// 一次模型选择：provider 路由 + 该路由下的模型 id（effort 可选）。
///
/// 与 DSH 的 `ModelSelection` 逐字一致（`packages/api/session-controller/src/types.ts`）——
/// **不翻译**：手机上显示的名字要能和电脑侧对上，翻译一层就多一处会漂移的地方。
class ModelRef {
  const ModelRef({
    required this.provider,
    required this.model,
    this.reasoningEffort,
  });

  final String provider;
  final String model;

  /// 推理等级（DSH 的 `ReasoningEffortId`）；省道跟随 provider 默认。
  final String? reasoningEffort;

  /// 界面上显示的那个名字。**用 model id** 而不是 provider 名：
  /// 同一个模型可能挂在多条路由下（`deepseek-official` 与 `deepseek-account`
  /// 都有 `deepseek-flash`），用户认的是模型，不是路由。
  String get label => model;

  @override
  String toString() =>
      'ModelRef($provider/$model'
      '${reasoningEffort == null ? '' : ', effort=$reasoningEffort'})';
}

/// 连接状态在界面上的说法（把 `ConnectionState` 翻成人话）。
///
/// 放在 model 层而不是 UI：**同一个状态在多个屏上都要显示**（会话列表顶部、
/// 设置页、离线提示），文案分叉会让用户看到"两套说法"。
String connectionLabel(ConnectionStateView state) => switch (state) {
  ConnectionStateView.idle => '未连接',
  ConnectionStateView.connecting => '连接中…',
  ConnectionStateView.handshaking => '握手中…',
  ConnectionStateView.serving => '已连接',
  ConnectionStateView.backoff => '重连中…',
  ConnectionStateView.closed => '已断开',

  /// 连续失败太多次、已停止自动重连。**给结论，不给转圈**：
  /// 电脑关机 / 中转挂着时，用户该看到"连不上"，而不是一个永远在转的东西。
  ConnectionStateView.gaveUp => '连接不上',
};

/// 端点种类在界面上的说法（连接 sheet、设置页共用，**只有这一套**）。
String endpointKindLabel(EndpointKind kind) =>
    kind == EndpointKind.direct ? '直连' : '中转';

/// 一个端点的一行式描述：`直连 · ws://192.168.2.43:8790`。
String endpointLine(Endpoint endpoint) =>
    '${endpointKindLabel(endpoint.kind)} · ${endpoint.url}';

/// 当前连接的**两行式描述**（连接 sheet 与设置页共用）。
///
/// - [ConnectionSummary.line]：没连上时是状态（[connectionLabel]），连上了是
///   `当前连接：<端点>`；
/// - [ConnectionSummary.note]：非空时解释"为什么没走首选"—— 那是"换 WiFi /
///   电脑换 IP 后直连失效、自动回落中转"的唯一提示，否则它只会安静重连，
///   用户看着"已连接"不知道自己在走保底通道（议题：连接方式选择器第 3 步）。
typedef ConnectionSummary = ({String line, String? note});

ConnectionSummary connectionSummary({
  required ConnectionStateView state,
  required Endpoint? active,
  required List<Endpoint> endpoints,
  required EndpointAttempt? Function(Endpoint) attemptOf,
}) {
  if (state != ConnectionStateView.serving || active == null) {
    // 没连上：给状态名；**端点表里每一条都拨不通时补一句诊断** ——
    // 那是"电脑不在线 / 换了网络地址"与"正在重连"的唯一区分，而空态与
    // 连接 sheet 都靠它说人话（议题：连接方式选择器第 3 步）。
    return (
      line: connectionLabel(state),
      note: _allFailedNote(endpoints, attemptOf),
    );
  }
  final line = '当前连接：${endpointLine(active)}';
  // 当前就走第一位：没有"为什么没走首选"可解释。
  if (endpoints.isEmpty || endpoints.first.id == active.id) {
    return (line: line, note: null);
  }
  final preferred = endpoints.first;
  final attempt = attemptOf(preferred);
  // 首选没拨过、或上次是通的：说不出原因，就不编一个。
  if (attempt == null || attempt.ok) return (line: line, note: null);
  final reason = attempt.reason?.isNotEmpty == true
      ? '（${attempt.reason}）'
      : '';
  return (
    line: line,
    note: '${endpointKindLabel(preferred.kind)} ${preferred.url} 拨不通$reason',
  );
}

/// 端点表里**每一条**都有失败记录时的一句诊断；否则 `null`（不猜）。
///
/// 有"从没拨过"的端点时不说"都拨不通"—— 那可能是刚启动、第一轮还没跑完。
String? _allFailedNote(
  List<Endpoint> endpoints,
  EndpointAttempt? Function(Endpoint) attemptOf,
) {
  if (endpoints.isEmpty) return null;
  for (final endpoint in endpoints) {
    if (attemptOf(endpoint)?.ok != false) return null;
  }
  return '${endpoints.length} 个端点都拨不通（电脑可能不在线，或换了网络地址）';
}

/// 连接状态的**界面视图**。
///
/// 与 `core/connection.dart` 的 `ConnectionState` 分开是刻意的：
/// core 的那个是**协议状态机**（含 `closed` 这种中间态），而界面只需要"能给用户看"的几档。
/// 直接让 UI import core 的枚举，会让"加一个协议状态"变成"改一堆 UI 文案"。
enum ConnectionStateView {
  /// 未连接（初始态）。
  idle,

  /// 建连中。
  connecting,

  /// 握手中。
  handshaking,

  /// 已连接、可收发。
  serving,

  /// 退避重连中。
  backoff,

  /// 已断开（等待重连或用户操作）。
  closed,

  /// 连续失败太多次，**已停止自动重连**（界面给结论 + 手动重试）。
  ///
  /// 它不是一个协议状态：core 的状态机停在 `backoff`，这一档是界面根据
  /// "连接层是否已放弃"推出来的。所以映射写在 `AppModel._viewOf` 里，
  /// 而这里只负责文案。
  gaveUp,
}
