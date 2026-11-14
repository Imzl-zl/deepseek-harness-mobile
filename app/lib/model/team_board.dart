/// `agentTeam` 投影（DSH Agent Teams 的**共享任务板**）解好之后的值。
///
/// ## 形状的真值来源
///
/// 不是文档，是生成 wire 的那两个 zod schema（`.strict()`，多一个字段都算非法）：
///
/// - `packages/team/agent-team/src/projection.ts:185-190` 的 `teamProjectionSchema`
///   ⇒ `{enabled: boolean, tasks: TeamTaskView[], failure?: string}`；
/// - 同文件 `:154-168` 的 `teamTaskViewSchema`
///   ⇒ `{id, revision, subject, description, status, blockedBy[], writeScopes[],
///   ownerId?, ownerName?, ready, writeScopeWarnings[]}`。
///
/// `ready` 是 **DAG 推导结果**（`task-view.ts` 按 `blockedBy` 算），`writeScopeWarnings`
/// 是宿主算好的告警（`task-view.ts:35-42`）。两样都**不要在手机侧重算** ——
/// 重算就是第二份真值，而它会在宿主动 `blockedBy` 语义那天静默分叉。
///
/// ## 一个必须记住的可见性事实
///
/// **子会话拿到的是一块空板**（`{enabled: false, tasks: []}`），不是"没有这个键"：
/// 投影对每个会话都有一格（`session-projection/src/index.ts:514-526`），
/// 而 `team/mode` / `team/task` 事件只追加在**根会话**的日志上
/// （`agent-team/src/index.ts:116`）。空板与"根会话关着"同形，从投影里分不出来 ——
/// 所以「当前会话是不是子会话」要由会话行决定，不看这个键
/// （与 `wire/rpc/projections.dart:113-114` 对 `subagentTiming` 的同一条纪律）。
///
/// 取舍见 `.agents/notes/proposed/2026-11-14-agent-team-readonly.md`。
library;

/// 一条共享任务的生命周期（字面值照 `agent-team/src/types.ts:61` 的 `TeamTaskStatus`）。
///
/// `deleted` 在线上**已被宿主滤掉**（`projection.ts:182` 的 `filter`），
/// 所以正常情况下见不到它；收下它只为"万一出现时按不可见处理"，不是为了显示。
enum TeamTaskStatus {
  pending('pending', '待处理'),
  inProgress('in_progress', '进行中'),
  completed('completed', '已完成'),
  deleted('deleted', '已删除');

  const TeamTaskStatus(this.wire, this.label);

  /// 线上字面值（**逐字**，别改成驼峰）。
  final String wire;

  /// 中文短词，逐字照 DSH 的 `ui-agent-team/src/client/locales.ts` 的
  /// `status.pending` / `status.in_progress` / `status.completed`。
  final String label;

  static TeamTaskStatus? fromWire(Object? raw) {
    for (final v in values) {
      if (v.wire == raw) return v;
    }
    return null;
  }
}

/// 任务板上的一行（`TeamTaskView`，`agent-team/src/types.ts:78-92`）。
class TeamTask {
  const TeamTask({
    required this.id,
    required this.revision,
    required this.subject,
    required this.description,
    required this.status,
    this.blockedBy = const [],
    this.writeScopes = const [],
    this.ownerId,
    this.ownerName,
    this.ready = false,
    this.writeScopeWarnings = const [],
  });

  final String id;

  /// 每次变更 +1（宿主的乐观并发用；手机只读，不参与写）。
  final int revision;

  /// 一行标题（列表主文案）。
  final String subject;

  /// 展开后的说明；可能是空串。
  final String description;

  final TeamTaskStatus status;

  /// 依赖的任务 id（DAG 边）。手机**不解析**它，只用来显示"几条前置"。
  final List<String> blockedBy;

  /// 这条任务打算写哪些路径（相对工作区）。**是告警素材，不是锁**
  /// （Team 不做文件系统隔离，见方案 §4）。
  final List<String> writeScopes;

  /// 负责人会话 id（没有负责人时缺席）。
  final String? ownerId;

  /// 负责人名字（**历史数据可能没有**：`teamProjectionDefinition` 的注释写明
  /// "Version-7 checkpoints without owner names remain usable without backfilling"，
  /// `projection.ts:203-207`）。所以回落顺序是 DSH 自己的
  /// `ownerName ?? ownerId ?? 未分配`（`ui-agent-team/src/client/TeamBoard.tsx:46`）。
  final String? ownerName;

  /// 前置是否都已完成（**宿主推的**，见文件头）。
  final bool ready;

  /// 宿主算好的写作用域冲突告警（`task-view.ts:37-42`）。
  final List<String> writeScopeWarnings;

  /// 被依赖阻塞（照 `TeamBoard.tsx:57`：`status === 'pending' && !ready`）。
  ///
  /// 注意**只有 pending 才算**：`in_progress` 的任务即使 `ready` 为假也不是
  /// "阻塞"（它已经在跑了）。
  bool get blocked => status == TeamTaskStatus.pending && !ready;

  /// 负责人显示名。回落链与 DSH 一致（见 [ownerName]）。
  ///
  /// 空串也当缺席：线上 schema 要求 `ownerName` 至少 1 个字符
  /// （`teamTaskViewSchema` 的 `z.string().min(1)`），所以空串只可能来自
  /// 我们自己解码出的畸形数据，不该被当成"有个空名字的负责人"。
  String get ownerText {
    final name = ownerName;
    if (name != null && name.isNotEmpty) return name;
    final id = ownerId;
    if (id != null && id.isNotEmpty) return id;
    return '未分配';
  }

  /// DSH 的 aria 标签判据：被阻塞 ⇒「被依赖阻塞」，否则就是状态词
  /// （`TeamBoard.tsx:59-61` 的 `aria-label`）。
  String get stateLabel => blocked ? '被依赖阻塞' : status.label;
}

/// 一块共享任务板（`TeamProjection`，`agent-team/src/types.ts:98-102`）。
class TeamBoard {
  const TeamBoard({required this.enabled, this.tasks = const [], this.failure});

  /// Team 模式开着没有（根会话上的显式选择；**从没选过 ⇒ false**）。
  ///
  /// 不要把它当"能力位"：能力位是"这台电脑有没有 Team 服务"（`caps.team`），
  /// 而这个是"这个会话开没开"。两件事混起来会出现"服务在、开关关着却被当成没能力"。
  final bool enabled;

  /// 全部任务（含 `deleted`；线上一般已经滤掉了）。
  final List<TeamTask> tasks;

  /// 投影自己报的读失败（**记录无效**时才出现）。
  ///
  /// 宿主的行为是"保留上一版有效任务"（`projection.ts:190-196`），所以
  /// `failure` 非空**不代表** `tasks` 不可信 —— 它说的是"有一条持久记录读不进来"。
  final String? failure;

  /// 要画出来的任务（照 DSH 再滤一次 `deleted`，`TeamBoard.tsx:86-87`）。
  List<TeamTask> get visibleTasks =>
      tasks.where((t) => t.status != TeamTaskStatus.deleted).toList();

  int countOf(TeamTaskStatus status) =>
      visibleTasks.where((t) => t.status == status).length;

  /// `{n} 已完成 · {n} 进行中 · {n} 待处理`（**零的那段不出现**，全零是空串）。
  ///
  /// 分隔符逐字照 DSH：`\u2002·\u2002`（en space + 中点 + en space，
  /// `TeamBoard.tsx:41-47`）。
  String get progressText {
    final parts = <String>[
      if (countOf(TeamTaskStatus.completed) > 0)
        '${countOf(TeamTaskStatus.completed)} 已完成',
      if (countOf(TeamTaskStatus.inProgress) > 0)
        '${countOf(TeamTaskStatus.inProgress)} 进行中',
      if (countOf(TeamTaskStatus.pending) > 0)
        '${countOf(TeamTaskStatus.pending)} 待处理',
    ];
    return parts.join('\u2002·\u2002');
  }

  /// 有在跑的任务（tab 徽标用）。
  int get activeCount => countOf(TeamTaskStatus.inProgress);
}

/// 解析 `agentTeam` 投影。
///
/// **只在顶层形状坏掉时返回 `null`**（不是 Map / 没有布尔 `enabled` /
/// `tasks` 不是数组）—— 那是"这个键有但我们读不动"，由
/// `wire/rpc/projections.dart` 计一次数。
///
/// 单条任务坏掉**只丢那一条**：一块板里一条脏记录不该让整块消失
/// （宿主自己对 `failure` 的处理也是"保留最后一份有效任务"，
/// `projection.ts:190-195`）。
TeamBoard? parseTeamBoard(Object? raw) {
  if (raw is! Map) return null;
  final enabled = raw['enabled'];
  if (enabled is! bool) return null;
  final rawTasks = raw['tasks'];
  if (rawTasks is! List) return null;
  final tasks = <TeamTask>[];
  for (final item in rawTasks) {
    final task = _parseTask(item);
    if (task != null) tasks.add(task);
  }
  final rawFailure = raw['failure'];
  final failure = rawFailure is String && rawFailure.isNotEmpty
      ? rawFailure
      : null;
  return TeamBoard(enabled: enabled, tasks: tasks, failure: failure);
}

/// 解析一条任务。**认不出就 `null`**（丢掉那一条，不降级成"待处理"——
/// 把一条状态不明的任务画成待处理是在编事实）。
TeamTask? _parseTask(Object? raw) {
  if (raw is! Map) return null;
  final id = raw['id'];
  if (id is! String || id.isEmpty) return null;
  final subject = raw['subject'];
  if (subject is! String) return null;
  final status = TeamTaskStatus.fromWire(raw['status']);
  if (status == null) return null;
  final revision = raw['revision'];
  // `revision` 在 schema 里是正整数（`positiveSafeInteger`）。缺了它手机也读得懂，
  // 但那是"形状不对"的证据 —— 按认不出处理，免得把畸形数据当成正常任务显示。
  if (revision is! num || revision < 1) return null;
  final description = raw['description'];
  final ready = raw['ready'];
  return TeamTask(
    id: id,
    revision: revision.toInt(),
    subject: subject,
    description: description is String ? description : '',
    status: status,
    blockedBy: _stringList(raw['blockedBy']),
    writeScopes: _stringList(raw['writeScopes']),
    ownerId: _nonEmpty(raw['ownerId']),
    ownerName: _nonEmpty(raw['ownerName']),
    // `ready` 缺失 ⇒ false（保守：pending 且不知道前置满足没有，别声称"没被阻塞"）。
    ready: ready is bool && ready,
    writeScopeWarnings: _stringList(raw['writeScopeWarnings']),
  );
}

List<String> _stringList(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if (item is String && item.isNotEmpty) item,
  ];
}

String? _nonEmpty(Object? raw) => raw is String && raw.isNotEmpty ? raw : null;
