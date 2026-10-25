/// **投影面**（`session.projections`）的唯一入口。
///
/// ## 这件事的形状（一句话）
///
/// 一个方法打开全部只读面：应答是**扁平的 `values` 映射**（`connector/src/dsh/projections.ts:68-72`
/// 取 `values`、`:94` 返回）——**没有信封、永不 `null`**（`null` 归一成 `{}`）。
///
/// **这与 `session.list` 行里的 `.projections` 不是同一个形状**：那个是
/// **信封** `{kind, asOfSeq, values}`（`connector/src/dsh/sessions.ts:333-341`）。
/// 同一个名字的两种形状、读错的表现是**静默空值**，所以：
/// - 信封的读法只有 [WireFields.envelopeValues]（在 `session.dart` 的行解码里用）；
/// - 扁平的读法只有本文件（`readSessionProjections` 直接吃 `values`）。
///
/// ## 为什么产出的是一个值对象而不是裸 map
///
/// 14 个键今天散在 `app_model` 的 10 个 getter 里各读一次。那种写法有两个后果：
/// 键名没有单一归属（同一个键在两处读就必然漂），而"这个键是什么类型"只能靠读代码猜。
/// 现在**键只在这个文件里出现**，消费方拿字段（[SessionProjections.tokenUsage] 等）。
///
/// 三个解析器（`permissions` / `agentPreset` / `subagentCatalog`）仍收整包 `values`
/// ——它们各自只碰一个键，且落在 `model/` 与 `core/` 里各有自己的用例；
/// 改签名只会让那些用例跟着搬，不增加任何保证。**键名仍只有一处**：它们各自那一个。
///
/// ## 失败语义
///
/// 应答不是对象 ⇒ [WireBad]（整天读不出来，计数 1）。
/// 单个键认不出 ⇒ 那个字段 `null` / 空表，**不丢整包**、**不计数**：
/// "这台电脑没注册那个投影"与"还没读到"在界面上是同一句话（空态），不是漂移。
/// 例外是 `values` 里出现**非字符串键**（线上从不可能）：那计一次数并丢掉那个键。
///
/// Note: 布局与批次见 `.agents/notes/proposed/2026-10-25-wire-rpc-layer-layout.md`。
library;

import '../../core/job.dart' show SubagentRow, parseSubagentCatalog;
import '../../core/sync_client.dart';
import '../../model/agent_preset.dart' show parseAgentPresetValue;
import '../../model/chat_item.dart' show ModelRef;
import '../../model/image_limits.dart' show DshImageLimits;
import '../../model/permission.dart' show parsePermissionValue;
import '../../model/session_stats.dart'
    show
        ContextBreakdown,
        ContextPressure,
        SessionStats,
        TokenUsage,
        parseTokenUsage;
import '../../model/subagent.dart' show SubagentTiming, parseSubagentTiming;
import '../../model/trajectory.dart' show TrajectoryView, parseTrajectory;
import '../../model/turn_outline.dart' show TurnOutlineEntry;
import '../fields.dart';
import '../reading.dart';

/// 方法名只在这里出现一次（`connector/src/handlers.ts:840`）。
const String _kProjections = 'session.projections';

/// 一次投影读的**解码结果**：14 个被 App 消费的键各一个字段。
///
/// 字段顺序照"屏幕上从哪来"排：统计条 → 上下文 → 权限/预设 → 子智能体 → 轨迹 → 附件上限 → 队列。
final class SessionProjections {
  const SessionProjections({
    this.title,
    this.modelSelection,
    this.tokenUsage,
    this.sessionStats,
    this.contextPressure,
    this.contextBreakdown,
    this.turnOutline = const [],
    this.permissionValue,
    this.agentPreset,
    this.subagentCatalog = const [],
    this.subagentTiming,
    this.trajectory,
    this.imageLimits,
    this.inbox,
  });

  /// `title` 投影（wire view 就是 `string | null`，DSH `session-title/src/index.ts:269-281`）。
  ///
  /// 它比 `session.list` 的投影提示**更新**：会话刚生成标题时列表提示还是旧的。
  final String? title;

  /// `modelSelection` 投影的 `next ?? lastUsed`（`model-selection-projection.ts:65`）。
  final ModelRef? modelSelection;

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

  /// `trajectory` 投影（本仓自带的投影，DSH 没有）。
  final TrajectoryView? trajectory;

  /// `imageLimits` 投影（宿主的上限，手机不写死这些数）。
  final DshImageLimits? imageLimits;

  /// `inbox` 投影的原文（`{next-turn: [...], next-step: [...]}`）。
  ///
  /// **不在这里解析**：队列项的解析器在 `model/queue_item.dart`（它同时被别的入口用），
  /// 这里只负责"从哪个键取"。
  final Map<Object?, Object?>? inbox;
}

/// 发请求 + 解码，**`session.projections` 的唯一调用口**。
///
/// 读不出来 ⇒ `null` + 计数一次（调用方把那些只读面显示空态）。
Future<SessionProjections?> loadSessionProjections(
  SyncClient client, {
  required String sid,
}) async {
  final result = await client.call<Object?>(_kProjections, {'sid': sid});
  return valueOrReport(readSessionProjections(result), _kProjections);
}

/// 纯解码：应答是**扁平 `values`**（不是信封）。
///
/// 认不出的**键**不计数（缺席是正常的：投影没注册 / 还没读到），
/// 但**应答本身不是对象**是漂移 ⇒ [WireBad]。
WireReading<SessionProjections> readSessionProjections(Object? result) {
  if (result is! Map) {
    return const WireBad('应答不是扁平 values 映射（`session.projections`）');
  }
  // `values` 的键只在这里读一次。非字符串键线上不可能出现 —— 计一次数并丢掉。
  final values = <String, Object?>{};
  var droppedKeys = 0;
  for (final entry in result.entries) {
    if (entry.key is String) {
      values[entry.key! as String] = entry.value;
    } else {
      droppedKeys += 1;
    }
  }
  if (droppedKeys > 0) {
    WireDiagnostics.report(_kProjections, 'values 里有 $droppedKeys 个非字符串键');
  }
  return WireOk(_buildProjections(values));
}

// ---------------------------------------------------------------------------
// 14 个键 → 值（键名只在这个文件里出现）
// ---------------------------------------------------------------------------

SessionProjections _buildProjections(Map<String, Object?> values) {
  return SessionProjections(
    title: _nonEmptyString(values['title']),
    modelSelection: _modelSelectionOf(values['modelSelection']),
    tokenUsage: parseTokenUsage(values['tokenUsage']),
    sessionStats: _sessionStatsOf(values['sessionStats']),
    contextPressure: _contextPressureOf(values['contextPressure']),
    contextBreakdown: _contextBreakdownOf(values['contextBreakdown']),
    turnOutline: _turnOutlineOf(values['turnOutline']),
    permissionValue: parsePermissionValue(values),
    agentPreset: parseAgentPresetValue(values),
    subagentCatalog: parseSubagentCatalog(values),
    // 根会话也会带 `{settledMs: 0}` —— 所以"非 null"不代表"是子会话"
    // （判是不是子会话看 `SessionSummary.subagent`，不看这里）。
    subagentTiming: parseSubagentTiming(values['subagentTiming']),
    trajectory: parseTrajectory(values['trajectory']),
    imageLimits: DshImageLimits.fromWire(values['imageLimits']),
    inbox: values['inbox'] is Map ? values['inbox']! as Map : null,
  );
}

String? _nonEmptyString(Object? raw) =>
    raw is String && raw.isNotEmpty ? raw : null;

int _intOf(Object? value) => value is num ? value.toInt() : 0;

/// `sessionStats` 投影（`packages/session/session-stats/src/projection.ts:72-81`）。
///
/// `decodeMs` / `decodeTokens` 是输出速率的唯一来源；`ttftMs` / `ttftSteps` 是
/// 统计 sheet 里 TTFT 那一行的来源。缺字段按 0 —— 这个投影的全部字段都是计数，
/// "缺一个"与"它是 0"在界面上同一表现（与 `tokenUsage` 的四桶不同：那是**桶**，
/// 缺一个桶就必须整份作废，见 `parseTokenUsage` 的注释）。
SessionStats? _sessionStatsOf(Object? raw) {
  if (raw is! Map) return null;
  return SessionStats(
    turns: _intOf(raw['turns']),
    steps: _intOf(raw['steps']),
    llmMs: _intOf(raw['llmMs']),
    toolMs: _intOf(raw['toolMs']),
    ttftMs: _intOf(raw['ttftMs']),
    ttftSteps: _intOf(raw['ttftSteps']),
    decodeMs: _intOf(raw['decodeMs']),
    decodeTokens: _intOf(raw['decodeTokens']),
  );
}

/// `contextPressure` 投影。三个字段都没有就是 `null`（`contextWindow` 是分母，没有它无解）。
ContextPressure? _contextPressureOf(Object? raw) {
  if (raw is! Map) return null;
  final pressure = raw['pressureTokens'];
  final projected = raw['projectedTokens'];
  final window = raw['contextWindow'];
  if (pressure is! num && projected is! num && window is! num) return null;
  return ContextPressure(
    pressureTokens: pressure is num ? pressure.toInt() : null,
    projectedTokens: projected is num ? projected.toInt() : null,
    contextWindow: window is num ? window.toInt() : null,
  );
}

/// `contextBreakdown` 投影。三项全 0 时当没有（与"没有这个投影"同一表现：
/// 上下文 sheet 只画百分比条，不画分段图例）。
ContextBreakdown? _contextBreakdownOf(Object? raw) {
  if (raw is! Map) return null;
  final breakdown = ContextBreakdown(
    systemTokens: _intOf(raw['systemTokens']),
    toolsTokens: _intOf(raw['toolsTokens']),
    messageTokens: _intOf(raw['messageTokens']),
  );
  return breakdown.total == 0 ? null : breakdown;
}

/// `turnOutline` 投影（`session-turn-outline/src/projection.ts:61-75`）。
///
/// 拿不到就是空表 —— 轨迹页显示空态，不造一份假的。
List<TurnOutlineEntry> _turnOutlineOf(Object? raw) {
  if (raw is! List) return const [];
  final out = <TurnOutlineEntry>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final turn = entry['turn'];
    final seq = entry['seq'];
    if (turn is! int || seq is! int) continue;
    out.add(
      TurnOutlineEntry(
        turn: turn,
        seq: seq,
        prompt: entry['prompt'] is String ? entry['prompt'] as String : '',
        response: entry['response'] is String
            ? entry['response'] as String
            : '',
      ),
    );
  }
  return out;
}

/// `modelSelection` 投影 → `next ?? lastUsed`。
///
/// **`next ?? lastUsed` 与 DSH 的线格式逐字一致**
/// （`packages/api/session-controller/src/model-selection-projection.ts:65`：
/// `view: state => ({lastUsed, next: state.pending ?? state.lastUsed})`）。
/// `lastUsed` / `next` 都是 `null` 是**正常**（新会话、投影还没落），不计数。
ModelRef? _modelSelectionOf(Object? raw) {
  if (raw == null) return null;
  if (raw is! Map) return null;
  return _modelRefOf(raw['next'] ?? raw['lastUsed']);
}

/// `{provider, model, reasoningEffort?}` → [ModelRef]；认不出返回 `null`（不计数：
/// 新会话/投影没落时这里本来就是 `null`）。
///
/// 缺 `provider` / `model` 就当没有 —— 硬填空串会让界面显示一个空的模型名。
ModelRef? _modelRefOf(Object? raw) {
  if (raw is! Map) return null;
  final provider = raw['provider'];
  final model = raw['model'];
  if (provider is! String || provider.isEmpty) return null;
  if (model is! String || model.isEmpty) return null;
  final effort = raw['reasoningEffort'];
  return ModelRef(
    provider: provider,
    model: model,
    reasoningEffort: effort is String && effort.isNotEmpty ? effort : null,
  );
}
