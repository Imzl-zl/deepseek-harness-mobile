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
import 'session_stats.dart' show TokenUsage, formatTokenCount;
import 'subagent.dart' show SubagentTiming;

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

/// 一次请求的 token 用量（`assistant/message` 的 `data.usage`）。
///
/// ## 形状来自真日志，不是推断
///
/// 从 `~/.dsh/sessions/**/session.v4.jsonl.zstd` 解出的一条实测样本：
///
/// ```json
/// {"inputTokens": 66352, "outputTokens": 110,
///  "totalTokens": 94408, "cacheReadTokens": 27946}
/// ```
///
/// 且它**确实挂在 `assistant/message.data.usage` 上**（真日志 8634 条），
/// 这正是 DSH 折 turn 用量的入口
/// （`packages/llm/token-meter/src/turn-usage.ts:246` 的 `event.data.usage`）。
///
/// ## `inputTokens` 是**未缓存**输入
///
/// 由上面那组数验算：`totalTokens − outputTokens = 94408 − 110 = 94298`，
/// 而 `inputTokens + cacheReadTokens = 66352 + 27946 = 94298` ✓。
/// DSH 的 `aggregateAttempts` 也把它叫 `uncachedInputTokens`
/// （`turn-usage.ts:150-151`）。
class TurnTokenUsage {
  const TurnTokenUsage({
    required this.inputTokens,
    required this.outputTokens,
    required this.totalTokens,
    this.cacheReadTokens,
    this.cacheWriteTokens,
  });

  /// 未缓存的输入 token。
  final int inputTokens;
  final int outputTokens;

  /// 这次请求的总量（含缓存读取）。
  final int totalTokens;

  final int? cacheReadTokens;
  final int? cacheWriteTokens;

  /// 从事件载荷解析。**`totalTokens` / `outputTokens` / `inputTokens` 缺一个
  /// 就整个不要** —— DSH 的 `normalizeUsage` 也是要么给全、要么 `undefined`
  /// （`turn-usage.ts:100-113`），而"缺一个就当 0"会把 `0 tok` 显示成真数据。
  static TurnTokenUsage? fromWire(Object? data) {
    if (data is! Map) return null;
    final input = data['inputTokens'];
    final output = data['outputTokens'];
    final total = data['totalTokens'];
    if (input is! int || output is! int || total is! int) return null;
    if (input < 0 || output < 0 || total < 0) return null;
    final cacheRead = data['cacheReadTokens'];
    final cacheWrite = data['cacheWriteTokens'];
    return TurnTokenUsage(
      inputTokens: input,
      outputTokens: output,
      totalTokens: total,
      cacheReadTokens: cacheRead is int && cacheRead >= 0 ? cacheRead : null,
      cacheWriteTokens: cacheWrite is int && cacheWrite >= 0
          ? cacheWrite
          : null,
    );
  }

  /// 两次请求相加（一个 turn 里有多步时用）。
  TurnTokenUsage operator +(TurnTokenUsage other) => TurnTokenUsage(
    inputTokens: inputTokens + other.inputTokens,
    outputTokens: outputTokens + other.outputTokens,
    totalTokens: totalTokens + other.totalTokens,
    // **缓存两档只在双方都有时才求和** —— 一边缺就整体不知道，
    // 摆一个偏小的数会让人以为缓存命中很差（与 DSH 的
    // `cacheRead.every(isCount) ? safeSum(...) : undefined` 同一条，
    // `turn-usage.ts:136-138`）。
    cacheReadTokens: cacheReadTokens == null || other.cacheReadTokens == null
        ? null
        : cacheReadTokens! + other.cacheReadTokens!,
    cacheWriteTokens: cacheWriteTokens == null || other.cacheWriteTokens == null
        ? null
        : cacheWriteTokens! + other.cacheWriteTokens!,
  );
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
    this.systemLabel,
    this.systemHint,
    this.usage,
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

  /// 系统 / 上下文注入行的标题（`system/message` = 「系统提示词」；
  /// `developer/message` = 生产者 kind，见 [contextProducerLabel]）。
  ///
  /// **只有 [MessageRole.system] 有它**：用户与助手消息靠头像与名字表意，
  /// 而系统行在 DSH 里本来就是一个带标题的折叠行
  /// （`register-node-renderers.ts:45,49` 的 `context` 与 `system-prompt`）。
  /// 2026-10-19 之前这两种消息被渲染成**正文原样内联** —— 而系统提示词
  /// 在真日志里有上万字符，于是对话流开头横着一条巨墙（真机复现）。
  final String? systemLabel;

  /// 上下文行的**生产者**（`runtime-context` / `skill-catalog` / `time-context` …），
  /// 渲染在标题后面的分隔点之后；`null` = 不显示。
  ///
  /// 2026-10-20 真机发现：DSH 把运行时上下文、技能目录、时间快照都记成
  /// `user/message`，只有 `source.kind === 'user'` 才是人打的字
  /// （`ui-chat/src/client/conversation-nodes/message.ts:79`）。原来我们按事件类型
  /// 认角色 ⇒ 这些注入在手机上**冒充用户消息**（一条会话里冒出三条气泡）。
  /// 判据与标签见 `projection.dart` 的 `contextSourceKind` / `kContextInjectionLabel`。
  final String? systemHint;

  /// 这条助手消息那一次请求的 token 用量；`null` = 事件没带（老日志 / 用户消息）。
  ///
  /// 一个 turn 里可能有多步，每步一条 `assistant/message` —— 所以 turn 的
  /// 用量是**这些值相加**（`TurnProcessItem.usage`），不是取最后一条。
  final TurnTokenUsage? usage;
}

/// 一次斜杠命令（`command/run` 与 `command/done` 共用同一个 `itemId`）。
///
/// ## 它为什么之前不存在
///
/// 2026-10-19 摸到的"没有输出"之一：`command/run` / `command/done` 两个事件
/// 在投影里**完全没有 case**，一路落到 [OtherItem]（只计数、不渲染）。
/// 于是 `/goal`、`/compact`、`/permission` 这些用户在 Web 上能看见
/// "命令名 + 结果文本"的卡片，在手机上**一条都没有** —— 而连接器侧
/// `usage.summary` 的用法说明、权限切换、压缩，全都要经命令执行。
///
/// ## 与 [ToolCallItem] 的关系
///
/// 形状几乎一样（名字 + 状态 + 一行摘要 + 展开明细），但**不合并**：
/// 工具的调用/结果靠 `toolCallId` 配对，命令靠 `commandId`；而 DSH 的
/// 命令卡是独立的节点类型（`CommandNodeView` / `GenericCommandCard`，
/// 与 `ToolCard` 两套样式）。合成一类会让 itemId 的推导要同时认两套键名。
class CommandItem extends ChatItem {
  const CommandItem({
    required super.itemId,
    required super.seq,
    required super.updatedAt,
    required this.name,
    required this.status,
    this.summary = '',
    this.detail = '',
  });

  /// 命令名（如 `/goal` / `/compact` / `/permission`）。
  ///
  /// **带前导斜杠**：DSH 的 `command/run.name` 就是用户在输入框里敲的那串
  /// （真日志：`goal`、`compact`），而 Web 的卡片标题显示的是
  /// `node.name ?? t('command.title')`（`GenericCommandCard.tsx:37`）——
  /// 手机照 DSH 的原样显示，斜杠补在前面让它读起来就是"一条命令"。
  final String name;

  /// 状态。**复用 [ToolCallStatus]**：DSH 的 `stateOf`
  /// （`GenericCommandCard.tsx:12-15`）把 `outcome === null` 映成 running、
  /// `outcome.kind === 'error'` 映成 error、其余 ok —— 与工具那三档逐字对应。
  final ToolCallStatus status;

  /// 一行摘要。`command/done` 到达时是**结果文本的第一行**，
  /// 运行中是"正在执行…"（DSH 的 `t('command.running')`）。
  final String summary;

  /// 展开后的明细：`command/done.text` 全文。
  ///
  /// DSH 只在文本含换行时才给展开（`GenericCommandCard.tsx:40` 的
  /// `text.includes('\n') ? text : null`）—— 单行文本已经在摘要里了。
  final String detail;
}

/// 一轮结束时的**异常提示**（DSH 的 `turn-error` / `turn-max-tokens` 节点）。
///
/// ## 它为什么之前不存在
///
/// 2026-10-19 摸到的"没看到的问题"之一：`turn/end` 的 `reason.kind` 在投影里
/// **完全没有读**。真日志里这台电脑的历史有：
///
/// | `reason.kind` | 条数 | DSH Web 显示什么 |
/// |---|---|---|
/// | `completed` | 891 | 无 |
/// | `aborted` | 53 | 只有 hook `signed-out` 才显示 |
/// | `interrupted` | 6 | "DSH 进程在这一轮结束前退出了" |
/// | `error` | 71 | `reason.error.message`（原文） |
/// | `max-tokens` | 3 | "输出到达上限被截断" |
///
/// 于是 **80 条"出了什么事"在手机上一片空白** —— 用户只看到"这一轮好像没跑完"。
///
/// ## 与 DSH 的对应
///
/// `conversation-nodes/turn-error.ts:36-51` 的 `endFailure(reason)`：
/// `error` 取 `reason.error`；`aborted` **仅当** hook 是
/// `deepseek-account/signed-out` 才给一条；`interrupted` 给固定文案；
/// completed / blocked / **max-tokens** / forked / plugin-merged 一律无失败行
/// （max-tokens 由 `turn-max-tokens` 单独一条提示）。
///
/// `turn-max-tokens.ts:42` 的判据就是 `reason.kind === 'max-tokens'`。
///
/// ## 为什么不并入 [MessageItem]
///
/// 它不是谁"说"的话，是**一轮的结局标记**：没有头像、没有气泡，
/// 在 DSH 里也是一条独立的行（`contextRow` 那一档）。并入消息会让
/// "谁说的"这件事多一个假角色。
class TurnOutcomeItem extends ChatItem {
  const TurnOutcomeItem({
    required super.itemId,
    required super.seq,
    required super.updatedAt,
    required this.kind,
    this.message = '',
    this.code,
    this.turn = 0,
  });

  /// 结局种类（决定图标与颜色）。
  final TurnOutcomeKind kind;

  /// 提示正文。**error 用 DSH 的原文**（`reason.error.message`），
  /// 其余两类是固定文案（DSH 同处也是固定文案）。
  final String message;

  /// 机器可读的错误码（`TRANSPORT` / `TIMEOUT` / `ACCOUNT_SIGNED_OUT` …）。
  /// `null` = 没有（`interrupted` 就没有）。
  final String? code;

  /// 第几轮（`turn/end.data.turn`）。
  final int turn;

  /// 一行标题（`第 N 轮出错` / `第 N 轮被截断`）。
  String get title => switch (kind) {
    TurnOutcomeKind.error => '第 $turn 轮出错',
    TurnOutcomeKind.interrupted => '第 $turn 轮中断',
    TurnOutcomeKind.maxTokens => '第 $turn 轮被截断',
    TurnOutcomeKind.signedOut => '第 $turn 轮停止',
  };
}

/// 一轮的异常结局种类。
enum TurnOutcomeKind {
  /// 模型侧报错（`reason.kind === 'error'`）。
  error,

  /// DSH 进程在这一轮结束前退出（`reason.kind === 'interrupted'`）。
  interrupted,

  /// 输出到达 provider 的 token 上限（`reason.kind === 'max-tokens'`）。
  maxTokens,

  /// 用户登出 DeepSeek 账号导致停止（`aborted` + hook `signed-out`）。
  signedOut,
}

/// 一次模型重试（`llm/retry` 与 `llm/retry-started` 共用同一个 `itemId`）。
///
/// ## 它为什么之前不存在
///
/// 2026-10-19 摸到：`llm/retry` / `llm/retry-started` 也没接。真日志里
/// 这台电脑有 10+ 条重试链（`retryId` 配对，`retry: 1..N`、`maxRetries`、
/// `delayMs`、`failure: {message, code}`）。DSH Web 把它渲染成
/// `ModelRetryItem`（`MessageItem.tsx:343-346`）—— 重试中用户看到的是
/// "正在重试（第 2/10 次）"，而手机上什么都没有。
///
/// ## 形状（真日志实测）
///
/// ```json
/// {"type":"llm/retry","data":{
///    "retryId":"18ac36dd-…","turn":1,"step":292,
///    "provider":"new","mode":"normal",
///    "retry":1,"maxRetries":10,"delayMs":1737.5,
///    "failure":{"message":"Request timed out.","code":"TIMEOUT"}}}
/// {"type":"llm/retry-started","data":{"retryId":"18ac36dd-…","retry":1}}
/// ```
///
/// 配对规则：`retryId`（`conversation-nodes/retry.ts:45-53`）——
/// `retry === 1` 是 start，之后是同一条的 update。
class ModelRetryItem extends ChatItem {
  const ModelRetryItem({
    required super.itemId,
    required super.seq,
    required super.updatedAt,
    required this.retry,
    required this.maxRetries,
    required this.message,
    this.code,
    this.started = false,
    this.delayMs = 0,
  });

  /// 第几次重试（从 1 开始）。
  final int retry;

  /// 上限（`maxRetries`）。
  final int maxRetries;

  /// 失败原因（`failure.message`，DSH 原文）。
  final String message;

  /// 失败码（`failure.code`，如 `TIMEOUT`）。
  final String? code;

  /// 是否已经开始重试（`llm/retry-started` 到达后为真）。
  ///
  /// 之前是"计划好还没跑"（`retryState: 'scheduled'`），之后是"在跑了"。
  final bool started;

  /// 计划延迟（毫秒）。`delayMs` 可能是小数（真日志：`1737.516…`）。
  final double delayMs;

  /// 一行标题：`重试 2/10`。
  String get title => '重试 $retry/$maxRetries';
}

/// 一轮的过程摘要（DSH 的 `turn-process` 节点）。
///
/// ## 它为什么之前不存在
///
/// 2026-10-19 摸到：DSH Web 在**每一轮结束时**给一行摘要
/// （`TurnProcessNodeView.tsx`）：`用时 2 分 36 秒 · 12 条消息 · 8 次工具调用 ·
/// 1 个子智能体`，可折叠收起该轮内容。手机上没有这一行 ——
/// 于是一轮跑完，用户看到的就是"又多了几屏内容"，没有"这一轮到底干了什么、
/// 花了多久"的收口。
///
/// ## 与 DSH 的对应
///
/// DSH 的计数由 turn 状态机推（`contract/turn-process.ts` 的
/// `TurnProcessSpec`：`messageCount` / `toolCallCount` / `subagentCount`），
/// **不在事件里**。手机没有 turn 状态机，但有三处等价来源：
///
/// - **用时** = 电脑侧算好的 `trajectory` 投影（`model/trajectory.dart`）；
///   手机**不做这个减法**（2026-10-22 之前在这里做，跨批就退化成
///   "不到 1 秒"）。DSH 同处是 `turn/end.time - turn/start.time`，
///   且 `Math.max(1000, …)` —— 不足 1 秒按 1 秒说（[formatElapsedMs] 照办）；
/// - **消息/工具/子智能体计数** = 该轮 seq 区间内的条目（子智能体委派的判据
///   照 DSH `isSubagentDelegationTool`：工具名是 `subagent` 或 `subagent_` 前缀，
///   `contract/turn-process.ts:44-46`）。
///
/// ## 为什么不放 [TurnOutlineEntry]
///
/// 那个是**轮次预览**（用户问了什么、助手答了什么，来自 `turnOutline` 投影）；
/// 这个是**过程统计**（多少条、多久）。两者都在"一轮"这个粒度上，但来源不同、
/// 用途不同，合成一类会让"轮次"同时是预览和统计两个真值源。
class TurnProcessItem extends ChatItem {
  const TurnProcessItem({
    required super.itemId,
    required super.seq,
    required super.updatedAt,
    required this.turn,
    this.messageCount = 0,
    this.toolCallCount = 0,
    this.subagentCount = 0,
    this.failed = false,
    this.stopped = false,
    this.usage,
    this.copyText = '',
  });

  /// 第几轮。
  final int turn;

  /// 该轮带回复的助手消息条数。
  final int messageCount;

  /// 该轮的工具调用次数（不含子智能体委派）。
  final int toolCallCount;

  /// 该轮的子智能体委派次数。
  final int subagentCount;

  /// 这一轮是失败收尾的（`reason.kind === 'error'`）。
  ///
  /// DSH 同处把"失败/停止"两种结局的**用时替换成一句话**
  /// （`TurnProcessNodeView.tsx:24-30`：`stopped` → "已停止"、
  /// `error` → "失败"、其余才显示用时）。
  final bool failed;

  /// 这一轮是被中止/中断的（`aborted` / `interrupted`）。
  final bool stopped;

  /// 这一轮的 token 用量（该轮内各条 `assistant/message.usage` 相加）。
  ///
  /// `null` = 该轮没有任何一条带 usage 的助手消息（或它们的字段不全）。
  /// **不摆一个 0** —— 那会把"没数据"说成"用了 0"。
  ///
  /// DSH 的同一个数在 `turn-tail` 的用量 pill 上（`TurnUsagePanel.tsx:18-20`，
  /// 文案 `用量 {formatTokens(total)} tok`），算法是
  /// `aggregateAttempts` 把该 turn 各次尝试的 `totalTokens` 相加
  /// （`packages/llm/token-meter/src/turn-usage.ts:130`）。
  final TurnTokenUsage? usage;

  /// 「复制」这一行要复制的东西：**该轮助手回复的正文**（多步时按顺序拼）。
  ///
  /// 空串 = 这一轮没有可复制的正文（纯工具轮 / 失败在中途）——
  /// 那时不显示复制钮，而不是复制一个空字符串（那会让人以为复制成功了）。
  ///
  /// DSH 的复制在 `turn-tail` 行上（`MessageIconActions.tsx:85-89`），
  /// 复制的就是收口那条助手消息的正文。
  final String copyText;

  /// 一行的标题部分：`第 3 轮`。
  String get title => '第 $turn 轮';

  /// 一行的统计部分：`2 分 36 秒 · 12 条消息 · 8 次工具 · 1 个子智能体`。
  ///
  /// ## 为什么时长要**传进来**
  ///
  /// 这一轮用了多久由电脑侧算好、随 `trajectory` 投影下发（`model/trajectory.dart`）。
  /// 手机**不做时间减法** —— 2026-10-22 之前这里是
  /// `turn/end.time - turn/start.time`，而 `turn/start` 落在更早一页时
  /// 那一轮就说"不到 1 秒"。现在时长只有一个来源，这个 getter 只负责拼串。
  ///
  /// [durationLabel] 为 `null` = 这一轮**不在**投影里（更早的轮被截掉，
  /// 或这台电脑没给时间轴）—— 那时不摆时长，也不摆 0。
  ///
  /// **各项为 0 时不列**（DSH 同处也是只列有的）：一个 0 条消息 0 次工具的
  /// 轮次（比如刚 start 就被取消）只说用时，不摆一串 0。
  String statsWith(String? durationLabel) {
    if (failed) return '失败';
    if (stopped) return '已停止';
    final parts = <String>[
      ?durationLabel,
      if (messageCount > 0) '$messageCount 条消息',
      if (toolCallCount > 0) '$toolCallCount 次工具',
      if (subagentCount > 0) '$subagentCount 个子智能体',
    ];
    return parts.join(' · ');
  }
}

/// 毫秒数的一行式中文时长（`2 分 35 秒` / `45 秒` / `不到 1 秒`）。
///
/// **与 DSH 的 `Math.max(1000, …)` 对齐**（`TurnProcessNodeView.tsx:23`）：
/// 不足 1 秒按 1 秒算，**但不显示"0 秒"** —— 那会让人以为没跑。
/// 0（拿不到 `turn/start`，历史翻页落在窗口外）与真的小于 1 秒
/// 在这里同形，都说"不到 1 秒"：两者都是"这一轮很快/不知道多久"，
/// 而编一个具体秒数是猜。
String formatElapsedMs(int ms) {
  if (ms < 1000) return '不到 1 秒';
  final minutes = ms ~/ 60000;
  final seconds = (ms % 60000) ~/ 1000;
  if (minutes > 0) return '$minutes 分 $seconds 秒';
  return '$seconds 秒';
}

/// 一次上下文压缩（DSH 的 `compaction` 节点）。
///
/// ## 它为什么之前不存在
///
/// 2026-10-19 顺着 DSH Web 节点清单摸到的第五个（也是最后一个）缺口。
/// DSH Web 在压缩落定时显示一条**检查点标记**（`CompactionItem`）：
/// 摘要 + 被替换掉的条目数 + 被压掉的 token 数。手机上没有 ——
/// 于是"这一轮之后，之前的对话被总结成一段摘要替换掉了"这件事在手机侧
/// **完全不可见**，而它影响后续**所有**轮次（模型从此只看摘要，不看原文）。
///
/// ## 真形状（`compaction/summary`，真日志实测）
///
/// ```json
/// {"type":"compaction/summary","seq":4718,"data":{
///    "compactionId":"324ce65d-…",
///    "summary":[{"type":"text","text":"## Primary Request and Intent\n…"}],
///    "shadowedSeqs":[8,9,10,…,4619,…],
///    "shadowedTokenCount":604975,
///    "provider":"…","model":"…","maxTokens":…,"usage":{…}}}
/// ```
///
/// 真例：**604975 个 token 被压掉**（本会话自己就有一条）。
///
/// ## 与 DSH 的对应
///
/// `conversation-nodes/command.ts:101-131` 的 `compactSummary(match, checkpoint)`：
/// - `summary` = `data.summary` 里 `type === 'text'` 的块**拼接**（空 = 没有）；
/// - `shadowedItemCount` = `shadowedSeqs.length`（**要求每个元素都是安全整数**，
///   否则整项作 null —— 不数一个可能不准的数）；
/// - `shadowedTokenCount` = `data.shadowedTokenCount`（同样要求安全非负整数）。
///
/// ## 为什么单独一类
///
/// 它既不是消息、不是工具、不是命令、不是轮次结局。它是**上下文面的一个
/// checkpoint**：DSH 也是独立节点（`register-node-renderers.ts:69`），
/// 而配对键是 `compactionId`（与 `tool/call` 的 `toolCallId`、命令的
/// `commandId` 同级的第三种身份）。
class CompactionItem extends ChatItem {
  const CompactionItem({
    required super.itemId,
    required super.seq,
    required super.updatedAt,
    required this.summary,
    this.shadowedItemCount,
    this.shadowedTokenCount,
  });

  /// 压缩摘要（`summary` 里的 text 块拼接）。空串 = 没有摘要。
  final String summary;

  /// 被替换掉的条目数（`shadowedSeqs.length`）；`null` = 形状不可信，不显示。
  final int? shadowedItemCount;

  /// 被压掉的 token 数；`null` = 同上。
  final int? shadowedTokenCount;

  /// 一行标题。
  static const String kTitle = '已压缩上下文';

  /// 一行的统计部分：`替换 142 条 · 压掉 605K tok`。
  ///
  /// **两项都可能没有**（形状不可信）—— 那时只说标题，
  /// 不摆"替换 0 条"。
  String get stats {
    final parts = <String>[];
    final items = shadowedItemCount;
    if (items != null) parts.add('替换 $items 条');
    final tokens = shadowedTokenCount;
    if (tokens != null) parts.add('压掉 ${formatTokenCount(tokens)} tok');
    return parts.join(' · ');
  }
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
    this.changedPath,
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

  /// 这次调用**改的那个文件**（`write` / `edit` / `str_replace_editor` 才有）。
  ///
  /// 判据照 DSH 的 `mutationPath`
  /// （`ui-deliverables/src/client/turn-deliverables.ts:61-77`）—— 它是
  /// **model-free** 的：只要参数形状对，这条路径就是真的被改了。
  /// 右侧「文件」面板按它列出"这一轮/这个会话动了哪些文件"。
  ///
  /// **只存路径，不存 `arguments`**：`write` 的参数里是整个文件内容。
  final String? changedPath;
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
    this.subagentTiming,
    this.tokenUsage,
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

  /// 子会话的计时投影提示（`projections.values.subagentTiming`）。
  ///
  /// **只对子会话有意义**（DSH 的 `subagentTiming` 折的是"这个会话作为子智能体
  /// 的活跃轮次时长"），但它是**会话自己的**投影，所以挂在会话行上而不是目录行上：
  /// 目录行（`SubagentRow`）是父会话看到的"有哪些子级"，两者是不同会话的事实。
  ///
  /// `null` = 电脑侧没给（老连接器 / 该会话还没轮次）—— 界面就不摆时长，
  /// **不拿本地时钟凑一个**（那正是"一次性任务时长永远涨"的成因）。
  final SubagentTiming? subagentTiming;

  /// 子会话的 token 用量投影提示（`projections.values.tokenUsage`）。
  ///
  /// 与统计条读的是**同一个投影**（`session.projections` 的 `tokenUsage`
  /// 那次读的是当前会话，这里是列表行给每个会话的提示）——
  /// 解析器也是同一个（`parseTokenUsage`）。`null` = 没给 / 形状不认识。
  final TokenUsage? tokenUsage;

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
    SubagentTiming? subagentTiming,
    TokenUsage? tokenUsage,
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
    subagentTiming: subagentTiming ?? this.subagentTiming,
    tokenUsage: tokenUsage ?? this.tokenUsage,
  );

  /// 只换**易变计数**（更新时间 / 条目数 / 待处理数）。
  ///
  /// 存在的理由：`AppModel._touchSummary` 每条 delta 都会更新这三个数，
  /// 而**身份字段（标题 / 模型 / running / blank / subagent / cwd / 子智能体
  /// 计时与 token）一条都不该动** ——
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
    subagentTiming: subagentTiming,
    tokenUsage: tokenUsage,
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
    subagentTiming: subagentTiming,
    tokenUsage: tokenUsage,
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

/// 子智能体 chip 的**可见**文案：`{count} 个子智能体`（总数）。
///
/// 与 DSH 逐字一致：`SubagentHeaderLineage.tsx:710` 用的就是 `count.total`
/// （`{count} 个子智能体`，`ui-subagent/src/client/locales.ts:36-37`），
/// **总数后面不带"正在运行"** —— 在跑与否由前面那枚转圈点表达（`:705-708`）。
/// `{count} 个子智能体，正在运行`（`:38-39`）是 **aria-label** 那一份（`:679-680`），
/// 见 [subagentChipAria]。
///
/// 放 model 层而不是某一屏里：顶栏 chip 的可见文案与 aria 是**同一个真值源**，
/// 两处各写一份必然漂（2026-10-16 就漂过一次）。
String subagentChipLabel(int total) => '$total 个子智能体';

/// 子智能体 chip 的无障碍名：在跑时报**在跑的个数**，否则报总数（`:679-680`）。
String subagentChipAria({required int total, required int running}) =>
    running > 0 ? '$running 个子智能体，正在运行' : subagentChipLabel(total);

/// 后台任务 chip 的文案：**在跑报在跑的个数**，没有在跑的才报总数。
///
/// 与 DSH 逐字一致（`JobListAction.tsx:450-453`）：
/// `liveRows.length > 0` → `count.live`（`{count} 个后台任务运行中`），count 取**在跑数**；
/// 否则 → `count.idle`（`{count} 个后台任务`），count 取可见总数。
/// 模板见 `ui-jobs/src/client/locales.ts:8-11`。
String jobChipLabel({required int live, required int total}) =>
    live > 0 ? '$live 个后台任务运行中' : '$total 个后台任务';

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
