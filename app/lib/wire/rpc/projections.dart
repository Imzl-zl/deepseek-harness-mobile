/// **投影面**（`session.projections`）的唯一入口。
///
/// ## 这件事的形状（一句话）
///
/// 一个方法打开全部只读面：应答是**扁平的 `values` 映射**（`connector/src/dsh/projections.ts:68-72`
/// 取 `values`、`:94` 返回）——**没有信封、永不 `null`**（`null` 归一成 `{}`）。
///
/// **这与 `session.list` 行里的 `.projections` 不是同一个形状**：那个是
/// **信封** `{kind, asOfSeq, values}`（`connector/src/dsh/sessions.ts:333-341`）。
/// 同一个名字的两种形状、读错的表现是**静默空值**，所以各自只有一处入口：
/// - 信封的读法只有 `WireFields.envelopeValues`（在 `session.dart` 的行解码里用）；
/// - 扁平的读法只有 `fields.dart` 的 `readFlatValues`（本文件调用它）。
///
/// ## 为什么产出的是一个值对象而不是裸 map
///
/// 15 个键今天散在 `app_model` 的 11 个 getter 里各读一次。那种写法有两个后果：
/// 键名没有单一归属（同一个键在两处读就必然漂），而"这个键是什么类型"只能靠读代码猜。
/// 现在**键只在这个文件里出现**，消费方拿字段（[SessionProjections.tokenUsage] 等）。
///
/// 值类型本身在 `core/session_projections.dart`（端口 `HostRpc` 的返回类型要在
/// `data/` 认的那一面）；搬出去的是**解好的字段**，键名与容忍哪些畸形仍只在这里。
///
/// 三个解析器（`permissions` / `agentPreset` / `subagentCatalog`）仍收整包 `values`
/// ——它们各自只碰一个键，且落在 `model/` 与 `core/` 里各有自己的用例；
/// 改签名只会让那些用例跟着搬，不增加任何保证。**键名仍只有一处**：它们各自那一个。
///
/// **载荷字段归值类型的解码器**（`SessionStats.fromWire` / `parseTokenUsage` /
/// `parsePermissionValue` …），本文件只读**投影键**（`values['key']`）并把值组合起来。
/// 两层判据见 `docs/subsystems/app-channel-client.md` 的规则列表。
///
/// ## 失败语义
///
/// 应答不是对象 ⇒ [WireBad]（整天读不出来，计数 1）。
/// 单个键认不出 ⇒ 那个字段 `null` / 空表，**不丢整包**、**不计数**：
/// "这台电脑没注册那个投影"与"还没读到"在界面上是同一句话（空态），不是漂移。
/// 例外是 `values` 里出现**非字符串键**（线上从不可能）：那计一次数并丢掉那个键。
///
/// Note: 布局与批次见 `.agents/notes/implemented/2026-10-25-wire-rpc-layer-layout.md`。
library;

import '../../core/job.dart' show parseSubagentCatalog;
import '../../core/session_projections.dart';
import '../../core/snapshot_digest.dart';
import '../../core/sync_client.dart';
import '../../model/agent_preset.dart' show parseAgentPresetValue;
import '../../model/goal.dart' show GoalView, parseGoalView;
import '../../model/image_limits.dart' show DshImageLimits;
import '../../model/permission.dart' show parsePermissionValue;
import '../../model/session_stats.dart'
    show ContextBreakdown, ContextPressure, SessionStats, parseTokenUsage;
import '../../model/subagent.dart' show parseSubagentTiming;
import '../../model/team_board.dart' show TeamBoard, parseTeamBoard;
import '../../model/trajectory.dart' show parseTrajectory;
import '../../model/turn_outline.dart' show TurnOutlineEntry;
import '../fields.dart';
import '../reading.dart';
import '../values.dart';
import 'snapshot.dart';

// 解出来的值类型住在 `core/`（端口 `HostRpc` 要能返回它），但**读它的入口仍是
// 本文件**：`readSessionProjections` 的调用方（`wire_shapes_replay_test` 等）
// 拿到的还是同一个名字，不必再 import 一次 core。
export '../../core/session_projections.dart' show SessionProjections;

/// 方法名只在这里出现一次（`connector/src/handlers.ts:840`）。
const String _kProjections = 'session.projections';

/// 发请求 + 解码，**`session.projections` 的唯一调用口**。
///
/// 读不出来 ⇒ `null` + 计数一次（调用方把那些只读面显示空态）。
/// 带内容摘要：键含 `sid`，所以不同会话的投影包是两个包（互不命中）。
Future<SnapshotReply<SessionProjections?>> loadSessionProjections(
  SyncClient client, {
  required String sid,
}) => loadSnapshot(client, _kProjections, {'sid': sid}, readSessionProjections);

/// 纯解码：应答是**扁平 `values`**（不是信封）。
///
/// 入口只有一份：`fields.dart` 的 [readFlatValues]（与 [WireFields.envelopeValues]
/// 成对）。认不出的**键**不计数（缺席是正常的：投影没注册 / 还没读到），
/// 但"应答本身不是对象"与"非字符串键"必须留声。
WireReading<SessionProjections> readSessionProjections(Object? result) {
  final flat = readFlatValues(result, _kProjections);
  switch (flat) {
    case WireOk<Map<String, Object?>>(:final value):
      return WireOk(_buildProjections(value, WireFields(value, _kProjections)));
    case WireBad<Map<String, Object?>>(:final detail):
      return WireBad(detail);
    case WireSkip<Map<String, Object?>>():
      // 扁平映射没有"不归我"这一档；只为穷尽 switch。
      return const WireBad('应答不是扁平 values 映射（`session.projections`）');
  }
}

// ---------------------------------------------------------------------------
// 15 个键 → 值（键名只在这个文件里出现）
// ---------------------------------------------------------------------------

SessionProjections _buildProjections(
  Map<String, Object?> values,
  WireFields fields,
) {
  return SessionProjections(
    title: _nonEmptyString(values['title']),
    modelSelection: modelSelectionOf(values['modelSelection'], fields),
    tokenUsage: parseTokenUsage(values['tokenUsage']),
    sessionStats: SessionStats.fromWire(values['sessionStats']),
    contextPressure: ContextPressure.fromWire(values['contextPressure']),
    contextBreakdown: ContextBreakdown.fromWire(values['contextBreakdown']),
    turnOutline: TurnOutlineEntry.listFromWire(values['turnOutline']),
    permissionValue: parsePermissionValue(values),
    agentPreset: parseAgentPresetValue(values),
    subagentCatalog: parseSubagentCatalog(values),
    // 根会话也会带 `{settledMs: 0}` —— 所以"非 null"不代表"是子会话"
    // （判是不是子会话看 `SessionSummary.subagent`，不看这里）。
    subagentTiming: parseSubagentTiming(values['subagentTiming']),
    team: _teamOf(values, fields),
    trajectory: parseTrajectory(values['trajectory']),
    imageLimits: DshImageLimits.fromWire(values['imageLimits']),
    inbox: values['inbox'] is Map ? values['inbox']! as Map : null,
    goal: _goalOf(values, fields),
  );
}

/// `goal` 投影：**键在但解析不出来**要留声。
///
/// 其余键的漂移都由各自的解析器计数（`modelSelection` 在 `wire/values.dart`）。
/// 这一个如果不报，"形状漂了"与"没有目标"在 `WireDiagnostics` 里长得一模一样 ——
/// 而目标条消失正是最需要线索的那一屏（`docs/subsystems/goal-bar.md` §8）。
///
/// `values['goal'] == null` **不计数**：那是线上合法的"没有目标"。
GoalView? _goalOf(Map<String, Object?> values, WireFields fields) {
  final raw = values['goal'];
  final goal = parseGoalView(raw);
  if (raw != null && goal == null) {
    fields.report('goal 在但不是 {goal, roundsStarted, createdAt, updatedAt}');
  }
  return goal;
}

/// `agentTeam` 投影（Agent Teams 共享任务板）：**键在但顶层形状坏了**要留声。
///
/// 与 `goal` 同一条理由，但阈值不同：单条任务坏掉只丢那一条（解析器自己丢，
/// 见 `model/team_board.dart`），只有 `enabled` / `tasks` 这一层坏掉才计数 ——
/// 那时"Team 关着"与"投影读不动"在界面上长得一样，正是最需要线索的时候。
///
/// 键缺席（老宿主没装 team 包）**不计数**：那是如实的能力缺失，由 `caps.team` 表达。
TeamBoard? _teamOf(Map<String, Object?> values, WireFields fields) {
  final raw = values['agentTeam'];
  final board = parseTeamBoard(raw);
  if (raw != null && board == null) {
    fields.report('agentTeam 在但不是 {enabled, tasks[], failure?}');
  }
  return board;
}

String? _nonEmptyString(Object? raw) =>
    raw is String && raw.isNotEmpty ? raw : null;

/// `modelSelection` 投影 → `next ?? lastUsed`。
///
/// 解析器只有一份：`wire/values.dart` 的 [modelSelectionOf]（与 `session.list`
/// 的行共用）。这里不留副本 —— 同一份投影在两个面各写一遍，迟早只有一处会改。
