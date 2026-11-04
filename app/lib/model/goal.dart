/// 目标（DSH 的「目标条」那一格）。
///
/// ## 数据从哪来
///
/// `session.projections` 的 `goal` 键。wire schema 逐字照
/// `packages/goal/goal/src/index.ts:61-77` 的 `goalProjectionSchema`：
///
/// ```text
/// null
/// | { goal: { id, revision, objective,
///            phase: 'active'|'paused'|'blocked'|'complete',
///            blockedReason?: {code, message}, maxGoalRounds },
///     roundsStarted, createdAt, updatedAt }
/// ```
///
/// **`null` 是"没有目标"**（还没设过 / 清掉了），与"这一包没有这个键"在界面上
/// 同一表现：**整条不画**。DSH 同一条判据（`ui-goal/src/client/GoalBar.tsx:86`：
/// `goal === undefined || goal === null` 直接 `return null`）——
/// 加载中、没有、已完成三种"没有"共用同一条出路。
///
/// ## 只解析，不计算
///
/// 手机**不折目标状态**：`roundsStarted` / `createdAt` / `updatedAt` 是电脑侧
/// 从会话日志折出来的（`goal/src/index.ts:142-155` 的 `applyGoalProjection`），
/// 这里一个减法都不做。`phase` 是宿主的四值联合（`goal/src/types.ts:47-51`），
/// 认不出就是"没有"—— 不猜一个「进行中」，因为阶段决定画哪几个动作。
///
/// ## 形状不对 = 没有（与其余 14 个键同一条纪律）
///
/// **必填**字段缺失 / 类型不对 / 阶段不在四值里 ⇒ 整个 [parseGoalView] 回 `null`。
/// 这与 `title` / `imageLimits` 那几个键同一条：**"这台电脑没注册那个投影"
/// 与"我们没看懂回复"在界面上都是"没有"**，而猜一个半懂的目标会让条子上出现
/// 一个点下去必然失败的按钮。
///
/// 判据与取舍见 `docs/subsystems/goal-bar.md` 与
/// `.agents/notes/implemented/2026-11-04-goal-bar-on-phone.md`。
library;

/// 目标的持久阶段（DSH 的 `GoalPhase`，`goal/src/types.ts:47-51`）。
///
/// **`complete` 也在里面**：它是线上合法值，只是界面不画条
/// （`GoalBar.tsx:86`）—— 把它当"认不出"会让"已完成"与"读不懂"分不开。
enum GoalPhase {
  active('active'),
  paused('paused'),
  blocked('blocked'),
  complete('complete');

  const GoalPhase(this.wire);

  /// 线上值（`zod.literal` 的四个之一，`goal/src/index.ts:68`）。
  final String wire;

  /// 认不出就是 `null`（不猜一个默认阶段）。
  static GoalPhase? fromWire(Object? raw) {
    for (final phase in GoalPhase.values) {
      if (phase.wire == raw) return phase;
    }
    return null;
  }
}

/// 受阻的原因（DSH 的 `GoalBlockReason`，`goal/src/types.ts:54-60`）。
///
/// 只有 `phase == blocked` 时才有值；`message` 是**给人看的那句**，
/// 目标条的整条 `title` 就是它（`GoalBar.tsx:129,134`）。
class GoalBlockReason {
  const GoalBlockReason({required this.code, required this.message});

  /// 稳定的 lower-kebab-case 分类（`goal/src/index.ts:225` 的校验）。
  final String code;

  /// 非空的人话解释。
  final String message;
}

/// 当前目标（DSH 的 `GoalView` 里手机读得到的那部分 —— 没有 `activation`）。
///
/// **没有 `activation`**：那是**进程内**状态（`goal/src/types.ts:66`），
/// 走 `goals.get` 的 Remote 读与 `goal/activation-changed` 事件，
/// 而手机这两条都没有。所以本类只装持久的那一份；界面按"active 就当已激活"
/// 处理（判据见 `docs/subsystems/goal-bar.md` §2）。
class GoalView {
  const GoalView({
    required this.id,
    required this.revision,
    required this.objective,
    required this.phase,
    required this.maxGoalRounds,
    required this.roundsStarted,
    required this.createdAt,
    required this.updatedAt,
    this.blockedReason,
  });

  /// 目标身份（`GoalId`，跨修订不变）。
  final String id;

  /// 修订号（每次持久变更 +1，`goal/src/types.ts:28`）。
  final int revision;

  /// 用户要的那件事（宿主保证非空，`goal/src/index.ts:203-208` 的 `resolveObjective`）。
  final String objective;

  /// 持久阶段。
  final GoalPhase phase;

  /// 目标轮次上限。
  final int maxGoalRounds;

  /// 已经用掉的目标轮次。
  final int roundsStarted;

  /// 创建 / 最后变更时刻（毫秒，宿主从会话日志折出来）。
  final int createdAt;
  final int updatedAt;

  /// 受阻原因；**只有 [phase] 是 `blocked` 时才可能非空**
  /// （`goal/src/types.ts:71-72`："Present exactly while `phase` is `blocked`"）。
  final GoalBlockReason? blockedReason;

  /// 这个目标要不要画条。**`complete` 不画**（`GoalBar.tsx:86`）。
  bool get visible => phase != GoalPhase.complete;
}

/// 解 `session.projections` 的 `goal` 键。
///
/// 三态：
/// - `null`（线上真的没有目标）⇒ `null`；
/// - 合法快照 ⇒ [GoalView]；
/// - 形状不对 ⇒ `null`（见文件头，不猜）。
///
/// **`goal.phase == 'complete'` 仍然解析出 [GoalView]**：它是合法状态，
/// "不画条"是界面的判据（[GoalView.visible]），不是解析的判据 ——
/// 把两者混在解析里，"已完成"就会被说成"读不懂"。
GoalView? parseGoalView(Object? raw) {
  if (raw is! Map) return null;
  final snapshot = raw['goal'];
  if (snapshot is! Map) return null;

  final id = _nonEmptyString(snapshot['id']);
  final revision = _positiveInt(snapshot['revision']);
  final objective = _nonEmptyString(snapshot['objective']);
  final phase = GoalPhase.fromWire(snapshot['phase']);
  final maxGoalRounds = _positiveInt(snapshot['maxGoalRounds']);
  if (id == null ||
      revision == null ||
      objective == null ||
      phase == null ||
      maxGoalRounds == null) {
    return null;
  }

  final roundsStarted = _count(raw['roundsStarted']);
  final createdAt = _intOrNull(raw['createdAt']);
  final updatedAt = _intOrNull(raw['updatedAt']);
  if (roundsStarted == null || createdAt == null || updatedAt == null) {
    return null;
  }

  final blockedReason = _blockedReasonOf(snapshot['blockedReason']);
  // 声明了受阻却没有原因：DSH 的 wire schema 允许（`blockedReason` 是可选的），
  // 而折叠器保证 blocked 一定有它（`goal/src/fold.ts:101-113`：blocked 的快照
  // 恰好是六个键、含 `blockedReason`；`command-goal/src/index.ts:80-81` 也断言过）。
  // 这里**不补一句自己编的话**：缺了就当没有（条子仍然画「受阻的目标」，只是没有
  // title 可显示）。
  return GoalView(
    id: id,
    revision: revision,
    objective: objective,
    phase: phase,
    maxGoalRounds: maxGoalRounds,
    roundsStarted: roundsStarted,
    createdAt: createdAt,
    updatedAt: updatedAt,
    blockedReason: blockedReason,
  );
}

/// 受阻原因：`{code, message}` 两个非空字符串。
///
/// **不是对象 / 缺字段 ⇒ `null`**（当作"没给原因"），不让整条目标消失：
/// 阶段才是"画不画条"的判据，原因只影响 title 那一行。
GoalBlockReason? _blockedReasonOf(Object? raw) {
  if (raw is! Map) return null;
  final code = _nonEmptyString(raw['code']);
  final message = _nonEmptyString(raw['message']);
  if (code == null || message == null) return null;
  return GoalBlockReason(code: code, message: message);
}

String? _nonEmptyString(Object? raw) =>
    raw is String && raw.isNotEmpty ? raw : null;

int? _intOrNull(Object? raw) => raw is num ? raw.toInt() : null;

/// 正整数（`revision` / `maxGoalRounds` 都是 `zod.number().int().positive()`）。
int? _positiveInt(Object? raw) {
  final value = _intOrNull(raw);
  return value != null && value > 0 ? value : null;
}

/// 非负整数（`roundsStarted` 是 `zod.number().int().nonnegative()`）。
int? _count(Object? raw) {
  final value = _intOrNull(raw);
  return value != null && value >= 0 ? value : null;
}
