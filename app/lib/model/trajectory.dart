/// 轨迹投影（`trajectory` 键）的手机侧形状：**只解析，不计算**。
///
/// ## 为什么这个文件里没有一处减法
///
/// 每轮 / 每步的起止与用时**由电脑侧算好**随投影下发（连接器
/// `src/dsh/trajectory.ts` 的 fold）。手机只做两件事：认形状、把数字画出来。
///
/// 判据是硬的：`app/lib/` 里不许再出现 `turn/end.time - turn/start.time` 这类统计。
/// 2026-10-22 之前 `data/projection.dart` 正是拿同一批事件在**本批内**算用时，
/// 跨批（`turn/start` 落在更早一页）就退化成"不到 1 秒" ——
/// 那一处已改为读这个投影。
///
/// ## 字段语义
///
/// | 字段 | 含义 |
/// |---|---|
/// | `startTime` / `endTime` | 毫秒 epoch。**只作记录**（详情里的时钟），不参与几何 |
/// | `offsetMs`（仅步） | 相对本轮开始的偏移。x 轴位置 = `offsetMs / durationMs` |
/// | `durationMs` | 电脑侧算好的用时；`null` = 还在跑。**界面上每个时长都读它** |
/// | `outcome` | `turn/end.reason.kind` 原样（`completed` / `error` / `aborted` / `interrupted` / `forked` / `blocked` / `max-tokens`） |
/// | `label` | 来源标识：工具段 = 工具名，助手/压缩段 = 空串（词由界面给） |
/// | `isError` | 工具结果失败 / 被打断 / 压缩失败 |
///
/// ## 认不出就是空
///
/// 键不在（这台电脑没注册投影）或形状不对（`turns` 不是表、`turn` 不是整数……）
/// 一律当"没有时间轴"：**不猜、不补零**。`null`（键缺席）与空视图（键在但没有轮）
/// 在界面上是两句不同的话，所以 [TrajectoryView] 保留了"这台电脑有没有给"这一位。
///
/// 规格见 `docs/subsystems/trajectory-page.md`。
library;

/// 一段的类别。
enum TrajectoryStepKind {
  /// 一次模型请求（`step/start` → `assistant/message`）。
  assistant,

  /// 一次工具调用（`tool/call` → `tool/result`）。
  tool,

  /// 一次上下文压缩（`compaction/start` → `compaction/end`）。
  compaction,
}

/// 时间轴上的一段。
class TrajectoryStep {
  const TrajectoryStep({
    required this.kind,
    required this.seq,
    required this.startTime,
    required this.endTime,
    required this.offsetMs,
    required this.durationMs,
    required this.isError,
    required this.label,
  });

  final TrajectoryStepKind kind;

  /// 起点事件的会话修订号。
  final int seq;

  /// 起点时刻（毫秒 epoch）。**只作记录**（详情 sheet 的时钟），不参与几何。
  final int startTime;

  /// 终点时刻；`null` = 还在跑。
  final int? endTime;

  /// 这一段相对**本轮开始**的偏移（毫秒）。
  ///
  /// **电脑侧算好的**，x 轴位置就是 `offsetMs / TrajectoryTurn.durationMs` ——
  /// 手机没有一次 epoch 相减。
  final int offsetMs;

  /// **电脑侧算好的**用时；`null` = 还在跑。
  final int? durationMs;

  /// 这一段是失败 / 被打断收口的。
  final bool isError;

  /// 来源标识：工具段 = 工具名，其余空串。
  final String label;

  /// 还在跑：只画起点标记，不画长度。
  bool get running => durationMs == null;

  /// 这一段的类别词（**界面给的词**，不在数据面里编）。
  String get kindLabel => switch (kind) {
    TrajectoryStepKind.assistant => '模型',
    TrajectoryStepKind.tool => '工具',
    TrajectoryStepKind.compaction => '压缩',
  };
}

/// 时间轴上的一轮。
class TrajectoryTurn {
  const TrajectoryTurn({
    required this.turn,
    required this.startSeq,
    required this.startTime,
    required this.endTime,
    required this.durationMs,
    required this.outcome,
    required this.stepsTruncated,
    required this.steps,
  });

  final int turn;

  /// 这一轮 `turn/start` 的会话修订号。
  final int startSeq;

  final int startTime;

  /// `null` = 这一轮还在跑。
  final int? endTime;

  /// **电脑侧算好的**这一轮用时；`null` = 还在跑。
  final int? durationMs;

  /// `turn/end.reason.kind`；`null` = 还没收口。
  final String? outcome;

  /// 这一轮的步数被上限截过（界面要说出来）。
  final bool stepsTruncated;

  final List<TrajectoryStep> steps;

  /// 这一轮还在跑（没有收口）。
  bool get running => endTime == null;

  /// 失败收尾（`reason.kind == 'error'`）。
  bool get failed => outcome == 'error';

  /// 被中止 / 中断（`aborted` / `interrupted`）。
  bool get stopped => outcome == 'aborted' || outcome == 'interrupted';
}

/// 整包：`session.projections` 里 `trajectory` 这个键的值。
class TrajectoryView {
  const TrajectoryView({
    required this.turns,
    required this.truncated,
    required this.droppedTurns,
    required this.droppedSteps,
  });

  /// 按轮次升序。
  final List<TrajectoryTurn> turns;

  /// 有轮或步因上限被丢。
  final bool truncated;

  /// 因上限被整轮丢掉的轮数。
  final int droppedTurns;

  /// 因上限被丢掉的步数合计。
  final int droppedSteps;

  /// 按轮次号取一轮；没有就是 `null`（更早的轮被截掉，或这一轮不在投影里）。
  TrajectoryTurn? turnOf(int turn) {
    for (final candidate in turns) {
      if (candidate.turn == turn) return candidate;
    }
    return null;
  }

  /// **还在跑的那一轮**（`durationMs == null` 的最后一轮）；没有就是 `null`。
  ///
  /// 流末尾那条运行条的秒数起点就是它的 [TrajectoryTurn.startTime] ——
  /// 手机侧唯一允许的减法只有"活时钟"这一处（见 `_RunningBar`）。
  TrajectoryTurn? get runningTurn {
    for (var i = turns.length - 1; i >= 0; i -= 1) {
      if (turns[i].durationMs == null) return turns[i];
    }
    return null;
  }
}

/// 从投影值包里解析出 [TrajectoryView]。
///
/// 返回 `null` = **这台电脑没给时间轴**（键缺席）—— 与"给了但是空的"
/// （[TrajectoryView.turns] 为空）在界面上是两句不同的话：
/// 前者说"这台电脑没给时间轴"，后者说"这一轮还没开始记"。
TrajectoryView? parseTrajectory(Object? raw) {
  if (raw is! Map) return null;
  final turnsRaw = raw['turns'];
  if (turnsRaw is! List) return null;
  final turns = <TrajectoryTurn>[];
  for (final entry in turnsRaw) {
    final turn = _parseTurn(entry);
    // 一条认不出就整包作废：时间轴上少一轮与"这一轮没有时间轴"看起来一样，
    // 而后者会让用户以为电脑侧没记 —— 所以宁可显示"没给"。
    if (turn == null) return null;
    turns.add(turn);
  }
  return TrajectoryView(
    turns: turns,
    truncated: raw['truncated'] == true,
    droppedTurns: _intOf(raw['droppedTurns']) ?? 0,
    droppedSteps: _intOf(raw['droppedSteps']) ?? 0,
  );
}

TrajectoryTurn? _parseTurn(Object? raw) {
  if (raw is! Map) return null;
  final turn = _intOf(raw['turn']);
  final startSeq = _intOf(raw['startSeq']);
  final startTime = _intOf(raw['startTime']);
  if (turn == null || startSeq == null || startTime == null) return null;
  final stepsRaw = raw['steps'];
  if (stepsRaw is! List) return null;
  final steps = <TrajectoryStep>[];
  for (final entry in stepsRaw) {
    final step = _parseStep(entry);
    if (step == null) return null;
    steps.add(step);
  }
  return TrajectoryTurn(
    turn: turn,
    startSeq: startSeq,
    startTime: startTime,
    endTime: _intOf(raw['endTime']),
    durationMs: _intOf(raw['durationMs']),
    outcome: raw['outcome'] is String ? raw['outcome'] as String : null,
    stepsTruncated: raw['stepsTruncated'] == true,
    steps: steps,
  );
}

TrajectoryStep? _parseStep(Object? raw) {
  if (raw is! Map) return null;
  final kind = switch (raw['kind']) {
    'assistant' => TrajectoryStepKind.assistant,
    'tool' => TrajectoryStepKind.tool,
    'compaction' => TrajectoryStepKind.compaction,
    _ => null,
  };
  final seq = _intOf(raw['seq']);
  final startTime = _intOf(raw['startTime']);
  final offsetMs = _intOf(raw['offsetMs']);
  if (kind == null || seq == null || startTime == null || offsetMs == null) {
    return null;
  }
  return TrajectoryStep(
    kind: kind,
    seq: seq,
    startTime: startTime,
    endTime: _intOf(raw['endTime']),
    offsetMs: offsetMs,
    durationMs: _intOf(raw['durationMs']),
    isError: raw['isError'] == true,
    label: raw['label'] is String ? raw['label'] as String : '',
  );
}

/// JSON 数字 → `int`（`null` 保持 `null`：`null` 与 0 在这份数据里意思不同）。
int? _intOf(Object? value) => value is num ? value.toInt() : null;
