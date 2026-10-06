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
  });

  final MessageRole role;

  /// 正文。**流式期间这里是累加器的当前内容**，持久事件到达时被整体替换
  /// （`app-channel-client.md` §2.2：以持久为准，避免"流式与最终文本不一致"）。
  final String text;
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
  });

  /// 工具名（如 `Read` / `Bash`）。
  final String name;

  final ToolCallStatus status;

  /// 一行摘要（参数或结果的短描述）。
  final String summary;
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
  });

  /// 会话别名（电脑侧分配的不透明 id，契约 §5.1）。
  final String sid;

  /// 标题。**电脑侧不返回标题**（契约 §5.7 已写明 `session.list` 不含标题），
  /// 所以标题由**本地**从首条用户消息推导 —— 这也是 DSH 桌面端的做法。
  final String title;

  final int updatedAt;
  final int itemCount;

  /// 待处理（审批 / 提问）计数，UI 用来显示角标。
  final int pendingCount;

  SessionSummary copyWith({
    String? title,
    int? updatedAt,
    int? itemCount,
    int? pendingCount,
  }) => SessionSummary(
    sid: sid,
    title: title ?? this.title,
    updatedAt: updatedAt ?? this.updatedAt,
    itemCount: itemCount ?? this.itemCount,
    pendingCount: pendingCount ?? this.pendingCount,
  );
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
};

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
}
