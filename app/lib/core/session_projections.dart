/// 一次会话投影读（`session.projections`）**解好之后的值**。
///
/// ## 为什么在 `core/`
///
/// 端口（`core/host_rpc.dart` 的 `HostRpc`）要能把它交出来，而端口是 `data/` 认的那一面。
/// 值类型与"线上长什么样"是两件事：**键名、字段类型、认不出时怎么办仍然只在
/// `wire/rpc/projections.dart` 断言**（`_buildProjections` 那一处），这里只有解码之后的字段。
/// 所以消费方（`data/` / `ui/`）拿字段，不需要认识 `wire/`。
///
/// **不在这里解析**两样东西：`inbox` 的队列项解析器在 `model/queue_item.dart`
/// （它同时被别的入口用），`goal` 的三态在 `model/goal.dart` —— 这一层只负责
/// "从哪个键取"，判据留在各自那一处。
///
/// Note: 端口为什么在这里、为什么这么分批 —— 见
/// `.agents/notes/implemented/2026-11-06-p1b-batch1-session-family.md`。
library;

import '../model/chat_item.dart' show ModelRef;
import '../model/goal.dart' show GoalView;
import '../model/image_limits.dart' show DshImageLimits;
import '../model/session_stats.dart'
    show ContextBreakdown, ContextPressure, SessionStats, TokenUsage;
import '../model/subagent.dart' show SubagentTiming;
import '../model/team_board.dart' show TeamBoard;
import '../model/trajectory.dart' show TrajectoryView;
import '../model/turn_outline.dart' show TurnOutlineEntry;
import 'job.dart' show SubagentRow;

/// 一次投影读的**解码结果**：16 个被 App 消费的键各一个字段。
///
/// 字段顺序照"屏幕上从哪来"排：统计条 → 上下文 → 权限/预设 → 子智能体 → 共享任务板 →
/// 轨迹 → 附件上限 → 队列 → 目标条。
final class SessionProjections {
  const SessionProjections({
    this.title,
    this.modelSelection,
    this.modelEverUsed = false,
    this.tokenUsage,
    this.sessionStats,
    this.contextPressure,
    this.contextBreakdown,
    this.turnOutline = const [],
    this.permissionValue,
    this.agentPreset,
    this.subagentCatalog = const [],
    this.subagentTiming,
    this.team,
    this.trajectory,
    this.imageLimits,
    this.inbox,
    this.goal,
  });

  /// `title` 投影（wire view 就是 `string | null`，DSH `session-title/src/index.ts:269-281`）。
  ///
  /// 它比 `session.list` 的投影提示**更新**：会话刚生成标题时列表提示还是旧的。
  final String? title;

  /// `modelSelection` 投影的 `next ?? lastUsed`（`model-selection-projection.ts:65`）。
  final ModelRef? modelSelection;

  /// 这个会话**用过**模型没有（`modelSelection.lastUsed != null`）。
  ///
  /// 与 [modelSelection] **不是一回事**：那一格是 `next ?? lastUsed`，
  /// "选了还没用"与"用过"在它上面同形。Team 的停用确认只在**用过**时才弹
  /// （`ui-agent-team/src/client/TeamModeToggle.tsx:47`：
  /// `!enabled && modelSelection.lastUsed !== null`）—— 判据是缓存复用，
  /// 所以必须分开取，不能拿 `modelSelection != null` 顶替。
  final bool modelEverUsed;

  /// `tokenUsage` 投影（四个整数桶，DSH `token-meter/src/usage-projection.ts:45-50`）。
  final TokenUsage? tokenUsage;

  /// `sessionStats` 投影（`turns/steps/llmMs/toolMs/ttftMs/ttftSteps/decodeMs/decodeTokens`）。
  final SessionStats? sessionStats;

  /// `contextPressure` 投影（`pressureTokens/projectedTokens/contextWindow`）。
  final ContextPressure? contextPressure;

  /// `contextBreakdown` 投影（系统/工具/消息三段，DSH 自称启发式估算）。
  final ContextBreakdown? contextBreakdown;

  /// `turnOutline` 投影（一轮一行：`turn/seq/prompt/response`）。
  final List<TurnOutlineEntry> turnOutline;

  /// `permissions` 投影的 `currentValue`（`permission-presets/src/index.ts:243`）。
  final String? permissionValue;

  /// `agentPreset` 投影（`string | null`）。
  final String? agentPreset;

  /// `subagentCatalog` 投影（只含**直接子级**，`subagent/src/catalog.ts:111-131`）。
  final List<SubagentRow> subagentCatalog;

  /// `subagentTiming` 投影（`{settledMs, active?}`；**每个会话都有**，根会话是 `settledMs: 0`）。
  final SubagentTiming? subagentTiming;

  /// `agentTeam` 投影（Agent Teams 的共享任务板，wire 形状见 [TeamBoard] 的文件头）。
  ///
  /// **两件事别混**：
  /// - `null` = 这台电脑没有 Team 服务（老宿主 / 没装 `dsh-agent-team`）**或**还没读到；
  ///   两者在界面上同一条路（能力位 `caps.team` 决定 tab 出不出来，不看这里）；
  /// - 非 `null` 但 `enabled == false` = 服务在、这个会话没开 Team。
  ///
  /// **子会话也是非 `null`**（空板，见 [TeamBoard] 文件头），所以"是不是子会话"
  /// 不能从这一格推。
  final TeamBoard? team;

  /// `trajectory` 投影（本仓自带的投影，DSH 没有）。
  final TrajectoryView? trajectory;

  /// `imageLimits` 投影（宿主的上限，手机不写死这些数）。
  final DshImageLimits? imageLimits;

  /// `inbox` 投影的原文（`{next-turn: [...], next-step: [...]}`）。
  ///
  /// **不在这里解析**：队列项的解析器在 `model/queue_item.dart`（它同时被别的入口用），
  /// 这里只负责"从哪个键取"。
  final Map<Object?, Object?>? inbox;

  /// `goal` 投影（当前目标，wire view 见 `model/goal.dart` 的文件头）。
  ///
  /// **`null` 有两种意思，而界面只有一种表现**（整条不画）：线上真的是 `null`
  /// （没设过 / 清掉了），或者这一包没有这个键（老连接器 / 没装目标插件）。
  /// `phase == complete` 也是 `null` 之外的第三种"不画"—— 那条判据在
  /// [GoalView.visible]，不在这一层（见 `model/goal.dart` 的 `parseGoalView`）。
  final GoalView? goal;
}
