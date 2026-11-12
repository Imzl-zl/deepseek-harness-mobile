/// 宿主状态同步：`host` 帧 → 按 key 重取快照（契约 §5.9 / `app-channel-client.md` §2.3）。
///
/// ## 这一层治什么
///
/// 桌面侧改了模型 / 权限档 / 设置 / 标题 / 任务表，手机还显示旧值 —— 那是**一类**
/// 症状，不是一处 bug。电脑侧因此会来一条 `host` 帧，里面**只有 key**（方法名），
/// 没有任何值：这条通道的语义是"这些快照可能过期了"。
///
/// ## 四件事，各有唯一出处
///
/// 1. **key 的拼写**只有 [HostStateKey] 一处（与连接器
///    `connector/src/protocol/host-state.ts` 的清单逐字一致）；
/// 2. **"哪个 key 该调谁、允许在哪个时机调"** 只在 [hostStateRegistry] 一处 ——
///    它就是"拉什么、何时拉"的唯一清单。产品路径上**没有**"把全套再拉一次"的入口，
///    新增一份快照只能登记；
/// 3. **合并与丢弃**在 [HostStateRefresher] 一处：同 key [window] 内合并成一次，
///    不同 key 各算各的；断连时 [HostStateRefresher.dropPending] 清空待发桶；
/// 4. **首屏那一次是"并行批次"**（[HostStateRefresher.startBatch]）：九项同时发起，
///    调用方只等 `session.list` 那一行，其余在飞（时序判据见 `connect-landing.md` §2）。
///
/// ## 为什么合并放在 app 侧
///
/// 一次"切模型"会同时改两个快照（`session.list` 的行与 `session.projections` 的
/// `modelSelection`），而断线重连时**只有 app 知道"这一批是不是同一屏要的"**。
/// 合并在连接器还会让"合并窗口"变成又一条连接器策略。
///
/// 取舍与被否方案（每个方法一条事件 / 客户端轮询 / 中转做状态总线 / 按函数捆着拉）见
/// `.agents/notes/implemented/2026-10-31-host-state-sync.md` 与
/// `.agents/notes/implemented/2026-11-01-refetch-scope-by-trigger.md`。
library;

import 'dart:async';

import '../core/sync_client.dart' show HostStateChanged;

/// 宿主状态 key 的**唯一拼写处**（线上字符串，改动等于两端同时不认）。
///
/// 每一条都是一种**快照方法的名字**：判据是"这个名字要能直接回答'该调谁'"。
/// 状态键（`session.model`）回答不了 —— 它和 `session.permission` 都指向同一个
/// `session.projections`，按状态键走就得再合并一次。
abstract final class HostStateKey {
  /// `session.list`：会话清单行（模型 / 标题 / 更新时间 / 计数）。**宿主级**。
  static const String sessionList = 'session.list';

  /// `session.projections`：投影包（权限档 / 标题 / 统计 / 轨迹 / 队列）。**会话级**。
  static const String sessionProjections = 'session.projections';

  /// `settings.describe`：设置文档。**宿主级**。
  static const String settingsDescribe = 'settings.describe';

  /// `job.list`：这个会话的任务表。**会话级**。
  static const String jobList = 'job.list';

  /// `session.modelCatalog`：模型目录（`{default, routableProviders, groups, failures}`）。
  /// **宿主级**。电脑上加 / 换模型或改密钥后它才变。
  static const String sessionModelCatalog = 'session.modelCatalog';

  /// `permission.catalog`：权限预设目录（部署侧那张表）。**宿主级**。
  static const String permissionCatalog = 'permission.catalog';

  /// `agentPresets.list`：Agent 预设目录（hero 上模式 chip 的名字来源）。**宿主级**。
  static const String agentPresetsList = 'agentPresets.list';

  /// `workspace.list`：工作区表（列表的分组 / 归档 / 置顶都出自这一份）。**宿主级**。
  static const String workspaceList = 'workspace.list';

  /// `repo.info`：电脑侧版本与能力位（另带 `hostName`）。**宿主级**、进程级事实。
  static const String repoInfo = 'repo.info';

  /// 全部 key（封闭集，顺序与连接器清单一致）。
  static const List<String> all = <String>[
    sessionList,
    sessionProjections,
    settingsDescribe,
    jobList,
    sessionModelCatalog,
    permissionCatalog,
    agentPresetsList,
    workspaceList,
    repoInfo,
  ];

  /// 这个 key 要不要 `sid` 才能重取（= 那个方法要不要会话参数）。
  static bool isSessionScoped(String key) =>
      key == sessionProjections || key == jobList;
}

/// 允许重取一个 key 的时机。
enum HostStateTrigger {
  /// 收到 `host` 帧（电脑侧说"可能过期了"）。
  notification,

  /// 连上之后的那一批（`landAfterConnect`）。重连的兜底就在这里。
  connectLanding,

  /// 回到前台（用户刚在电脑上改完，抬眼看手机的那一刻应该是对的）。
  appResume,

  /// 打开 / 切会话。
  openSession,

  /// **切到某一屏**（页签）：这一屏要的快照现在就对齐一次。
  ///
  /// 与 [openSession] 的差别是"会话没换，用户换了看哪一屏" —— 那正是"手里这份
  /// 包旧了"最容易暴露的一刻。轨迹页只有这一条路能换掉旧包：`turn/end` 在一轮
  /// 跑着的二十分钟里一次都不来（2026-11-04 真机：轨迹页空态，重启 App 才恢复）。
  ///
  /// Note: 取舍见 `.agents/notes/implemented/2026-11-04-trajectory-view-refetch.md`。
  viewFocus,

  /// **自己发起的写**（切模型 / 分支 / 会话页"重试"）：回执已带回值，
  /// 重取只是让电脑侧的身份字段（行里的模型 / 标题 / 计数）跟上。
  /// 立即执行，不压 `notification` 的合并窗口。
  ownWrite,
}

/// 重取函数需要的那一面（窄接口）。
///
/// 为什么不用 `AppModel`：那会让 `data/host_state.dart` 与 `app_model.dart`
/// 互相 import，而这里真正需要的只有九个方法 + 一条错误落点。
/// 顺带让登记表的机械测试可以用记账替身（断言"这个 key 调的确实是那个方法"）。
///
/// **一个 key 一个方法**：`fetch` 不许"顺手把别的也拉一遍" —— 那正是那一版
/// "一个函数捆七件事"的形态（一次通知七个往返）。
abstract interface class HostStateTarget {
  Future<void> refreshSessionRows();
  Future<void> refreshProjections(String sid);
  Future<void> refreshSettings();
  Future<void> refreshJobs(String sid);
  Future<void> refreshModelCatalog();
  Future<void> refreshPermissionCatalog();
  Future<void> refreshAgentPresets();
  Future<void> refreshWorkspaces();
  Future<void> refreshRepoInfo();

  /// 重取失败（不打断其它 key）：由实现落进 `lastError`。
  void reportHostStateFailure(String key, Object error);
}

/// 一条登记：`key → 重取函数 → 允许的触发点`。
class HostStateFetch {
  const HostStateFetch({
    required this.key,
    required this.fetch,
    required this.triggers,
  });

  /// 线上拼写（[HostStateKey] 之一）。**拼错一个字符就必须红**（机械测试）。
  final String key;

  /// 重取。`sid` 为 `null` 时只有宿主级 key 才有可能被调用。
  final Future<void> Function(HostStateTarget app, String? sid) fetch;

  /// 允许的触发点。**空集合 = 这个 key 永远不会自己刷新**，机械测试会判红。
  final Set<HostStateTrigger> triggers;

  /// 会话级 key 必须有 `sid` 才能重取。
  bool get sessionScoped => HostStateKey.isSessionScoped(key);
}

/// 会话清单行：模型 / 标题 / 更新时间 / 计数都在行里。
///
/// **只做行**，不碰任何目录 —— 目录各有各的 key 与触发点（见 [hostStateRegistry]）。
Future<void> _refetchSessionRows(HostStateTarget app, String? sid) =>
    app.refreshSessionRows();

/// 投影包（权限档 / 标题 / 统计 / 轨迹 / 队列）。**只对当前会话有意义**。
Future<void> _refetchProjections(HostStateTarget app, String? sid) async {
  if (sid == null) return;
  await app.refreshProjections(sid);
}

/// 设置文档（默认权限档 / 默认预设 / Session Log 开关）。
Future<void> _refetchSettings(HostStateTarget app, String? sid) =>
    app.refreshSettings();

/// 任务表（增删 / 终态）。
Future<void> _refetchJobs(HostStateTarget app, String? sid) async {
  if (sid == null) return;
  await app.refreshJobs(sid);
}

/// 模型目录。
Future<void> _refetchModelCatalog(HostStateTarget app, String? sid) =>
    app.refreshModelCatalog();

/// 权限预设目录。
Future<void> _refetchPermissionCatalog(HostStateTarget app, String? sid) =>
    app.refreshPermissionCatalog();

/// Agent 预设目录。
Future<void> _refetchAgentPresets(HostStateTarget app, String? sid) =>
    app.refreshAgentPresets();

/// 工作区表。
Future<void> _refetchWorkspaces(HostStateTarget app, String? sid) =>
    app.refreshWorkspaces();

/// 电脑侧版本与能力位。
Future<void> _refetchRepoInfo(HostStateTarget app, String? sid) =>
    app.refreshRepoInfo();

/// **登记表的唯一出处**：一个新宿主状态漏配就会红。
///
/// 触发点的口径（五列，逐列的判据在 `app-channel-client.md` §2.3）：
/// - `notification` 只给**今天有生产者**的六个 key —— 它是这条通道存在的理由；
///   三个没有宿主事件的目录（预设 / 工作区 / `repo.info`）**不给**，编一个触发源
///   就是替宿主做决定；
/// - `connectLanding` 覆盖"断连期间漏收"，所以是**全部九项**：断开期间电脑上的
///   变化一条事件都收不到（目录因此**不跨重连缓存**）；
/// - `appResume` 只给宿主级 + 当前会话的投影：回前台是"对齐这一屏"，设置与目录
///   要么有通知、要么极低频；
/// - `openSession` 只给会话级（切会话就重新拉一次，宿主的写可能发生在我们不在的时候）；
/// - `ownWrite` 只给行：自己发起的写由回执带回值，重取是为了电脑侧的身份字段。
const List<HostStateFetch> hostStateRegistry = <HostStateFetch>[
  HostStateFetch(
    key: HostStateKey.sessionList,
    fetch: _refetchSessionRows,
    triggers: <HostStateTrigger>{
      HostStateTrigger.notification,
      HostStateTrigger.connectLanding,
      HostStateTrigger.appResume,
      HostStateTrigger.ownWrite,
    },
  ),
  HostStateFetch(
    key: HostStateKey.sessionProjections,
    fetch: _refetchProjections,
    triggers: <HostStateTrigger>{
      HostStateTrigger.notification,
      HostStateTrigger.openSession,
      HostStateTrigger.connectLanding,
      HostStateTrigger.appResume,
      // 切到轨迹页签：这一包只在这几个时机重读，而轨迹页**整个屏**都靠它。
      HostStateTrigger.viewFocus,
    },
  ),
  HostStateFetch(
    key: HostStateKey.settingsDescribe,
    fetch: _refetchSettings,
    triggers: <HostStateTrigger>{
      HostStateTrigger.notification,
      HostStateTrigger.connectLanding,
    },
  ),
  HostStateFetch(
    key: HostStateKey.jobList,
    fetch: _refetchJobs,
    triggers: <HostStateTrigger>{
      HostStateTrigger.notification,
      HostStateTrigger.openSession,
      HostStateTrigger.connectLanding,
    },
  ),
  HostStateFetch(
    key: HostStateKey.sessionModelCatalog,
    fetch: _refetchModelCatalog,
    // `notification` 列由五条宿主失效事件驱动（`llm/*-updated`、`settings/document-updated`、
    // `credentials/*-updated`，触发点表在 `remote-channel.md` §5.9）。
    triggers: <HostStateTrigger>{
      HostStateTrigger.notification,
      HostStateTrigger.connectLanding,
    },
  ),
  HostStateFetch(
    key: HostStateKey.permissionCatalog,
    fetch: _refetchPermissionCatalog,
    // `notification` 列由 `permission-presets/catalog-changed` 驱动（同上那张表的最后一行）。
    triggers: <HostStateTrigger>{
      HostStateTrigger.notification,
      HostStateTrigger.connectLanding,
    },
  ),
  HostStateFetch(
    key: HostStateKey.agentPresetsList,
    fetch: _refetchAgentPresets,
    // **只有连上这一列**：宿主没有"预设表变了"的事件（`agent-preset/selected`
    // 是选中、不是目录），编一个轮询就是替宿主做决定。
    triggers: <HostStateTrigger>{HostStateTrigger.connectLanding},
  ),
  HostStateFetch(
    key: HostStateKey.workspaceList,
    fetch: _refetchWorkspaces,
    // 同上：`workspace` 只 emit 会话活动 / 停止。顺序变化由手机自己的写带回全集。
    triggers: <HostStateTrigger>{HostStateTrigger.connectLanding},
  ),
  HostStateFetch(
    key: HostStateKey.repoInfo,
    fetch: _refetchRepoInfo,
    // 同上：进程级事实（版本 / 能力位）。
    triggers: <HostStateTrigger>{HostStateTrigger.connectLanding},
  ),
];

/// 登记表里这个 key 的那一条；不认识就是 `null`（老 / 新连接器的向前兼容方向）。
HostStateFetch? hostStateFetchOf(String key) {
  for (final entry in hostStateRegistry) {
    if (entry.key == key) return entry;
  }
  return null;
}

/// 一次**并行批次**的把手：把"会话清单行"与"其余"分开，好让首屏只等行。
///
/// 为什么需要它：落点读的是行里的 `updatedAt` / `running`，而其余八份快照
/// （目录 / 设置 / 工作区 / 投影 / 任务表）不该挡住落点、也不该等落点之后才发起
/// —— 目录晚到时 blank hero 会先说"拿不到模型"。
class HostStateBatch {
  const HostStateBatch({required this.rows, required this.others});

  /// `session.list` 那一份（登记表里没有它时是已完成的 future）。
  final Future<void> rows;

  /// 其余 key（并行跑）。
  final Future<void> others;

  /// 整批收尾。
  Future<void> get all => Future.wait(<Future<void>>[rows, others]);
}

/// 按 key 合并的重取器：`host` 帧 → 一条（或几条）快照请求。
///
/// 三条规则：
/// 1. **同 key 在 [window] 内合并成一次**（默认 150 ms，落在契约给的 100–300 ms 内）；
/// 2. **不同 key 各算各的** —— 一次"切模型"同时改两个快照，它们不该互相等；
/// 3. **在飞期间再来同 key**：等那次收尾再补一次。直接并发两次会让
///    **两个应答乱序落地**（投影包没有版本号可比，后到的旧包会盖掉新包）。
class HostStateRefresher {
  HostStateRefresher({
    required HostStateTarget app,
    Duration window = kHostStateMergeWindow,
    List<HostStateFetch> registry = hostStateRegistry,
  }) : _app = app,
       _window = window,
       _registry = registry;

  final HostStateTarget _app;
  final Duration _window;
  final List<HostStateFetch> _registry;

  /// 每个 key 的待发定时器（同 key 只留一个）。
  final Map<String, Timer> _timers = <String, Timer>{};

  /// 每个 key 最近一次通知带的 `sid`（合并期间后到的那次覆盖前一次）。
  final Map<String, String?> _sids = <String, String?>{};

  /// 正在飞的 key → 那一次重取的 future（批次要能等它，而不是另发一次）。
  final Map<String, Future<void>> _inFlight = <String, Future<void>>{};

  /// 在飞期间又被要求重取的 key（收尾时补跑一次）。
  final Set<String> _rerun = <String>{};

  int _unknownKeys = 0;

  /// 收到过多少个**登记表不认识**的 key（诊断 / 测试用）。
  ///
  /// 它必须是一个**可观察的数**：将来连接器多一个 key 时，症状要么是"界面变了"，
  /// 要么是"这个数在涨"；否则就是"通知到了但什么都没发生"，无迹可查。
  int get unknownKeys => _unknownKeys;

  /// 某个 key 正在飞的那一次重取（`null` = 没在飞）。
  ///
  /// 给"必须先知道某份快照的答复、才能决定下一个调用发不发"的调用方用
  /// —— 今天只有 `job.list` 等 `repo.info`（`caps.jobs` 决定发不发，而那次读取
  /// 由首屏批次发起，`openSession` 往往抢在它前面）。**只读**：重取仍然只有
  /// [notified] / [triggered] / [startBatch] 三个入口，这里不造第四个。
  Future<void>? inFlightOf(String key) => _inFlight[key];

  /// 收到一条通知：按 key 排队，[window] 内同 key 合并。
  void notified(HostStateChanged notice) {
    for (final key in notice.keys) {
      final entry = hostStateFetchOf(key);
      if (entry == null) {
        _unknownKeys += 1;
        continue;
      }
      if (!entry.triggers.contains(HostStateTrigger.notification)) continue;
      // 会话级 key 没有 `sid` 就没法重取：**不发请求、也不计数为未知**
      // （那是连接器少带了一个路由字段，而不是"我们不认识这个 key"）。
      if (entry.sessionScoped && notice.sid == null) continue;
      _sids[key] = notice.sid;
      _timers[key]?.cancel();
      _timers[key] = Timer(_window, () {
        _timers.remove(key);
        unawaited(_run(key));
      });
    }
  }

  /// 自动触发点（连上 / 回前台 / 开会话 / 自己的写）：**立即重取**，不压 [window]。
  ///
  /// 这些时机一次只来一条（不是高频事件），压窗口只会让"连上了但列表还是空的"
  /// 多等一帧。与通知撞在一起时由 [_inFlight] 合流。
  ///
  /// 抛出的第一条错误会在这里重新抛出（调用方照旧记进 `lastError`），
  /// 但**所有**该跑的 key 都已经跑完 —— 一个 key 失败不该让别的停摆。
  Future<void> triggered(HostStateTrigger trigger, {String? sid}) async {
    final errors = <Object>[];
    final futures = <Future<void>>[];
    for (final entry in _select(trigger, sid)) {
      futures.add(_run(entry.key, errors: errors));
    }
    await Future.wait(futures);
    if (errors.isNotEmpty) {
      // 只往上抛 Exception / Error（`only_throw_errors`）：重取失败原本就只会是这两类，
      // 万一不是，包一层而不是把任意对象扔给上层。
      final first = errors.first;
      if (first is Error) throw first;
      if (first is Exception) throw first;
      throw StateError('刷新宿主状态失败：$first');
    }
  }

  /// **并行批次**（首屏 / 重连）：所有该跑的 key 同时发起，行与其余分开给。
  ///
  /// 与 [triggered] 的差别只有错误语义：批次不往上抛，每个 key 的失败各自
  /// 落进 `reportHostStateFailure` —— 落点不能被一份目录的失败拦住。
  HostStateBatch startBatch(HostStateTrigger trigger, {String? sid}) {
    Future<void>? rows;
    final others = <Future<void>>[];
    for (final entry in _select(trigger, sid)) {
      final future = _run(entry.key);
      if (entry.key == HostStateKey.sessionList) {
        rows = future;
      } else {
        others.add(future);
      }
    }
    return HostStateBatch(
      rows: rows ?? Future<void>.value(),
      others: Future.wait(others),
    );
  }

  /// 断连：**不排队**。
  ///
  /// 待发桶里的请求在重连那一刻必然已经过期（而且重连会由
  /// `landAfterConnect` → [HostStateTrigger.connectLanding] 整份重取）。
  /// 排队只会让重连瞬间打出一串白跑的请求。
  ///
  /// 已发出去的那些**不取消**：它们的应答是真实结果，收尾时自己落地。
  void dropPending() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _sids.clear();
    _rerun.clear();
  }

  /// 选出这次该跑的登记项，并把这一批的 `sid` 记下来（供 [_run] 读）。
  Iterable<HostStateFetch> _select(HostStateTrigger trigger, String? sid) {
    final selected = <HostStateFetch>[];
    for (final entry in _registry) {
      if (!entry.triggers.contains(trigger)) continue;
      if (entry.sessionScoped && sid == null) continue;
      _sids[entry.key] = sid;
      // 立刻重取：把这一 key 的待发通知并进来（它们要的是同一份快照）。
      _timers.remove(entry.key)?.cancel();
      selected.add(entry);
    }
    return selected;
  }

  /// 跑一个 key。在飞时不另发一次，而是**返回那一次**并把"再补一次"记下来。
  Future<void> _run(String key, {List<Object>? errors}) {
    final running = _inFlight[key];
    if (running != null) {
      _rerun.add(key);
      return running;
    }
    final future = _fetchNow(key, errors: errors);
    _inFlight[key] = future;
    return future;
  }

  Future<void> _fetchNow(String key, {List<Object>? errors}) async {
    final entry = hostStateFetchOf(key);
    try {
      // 登记表外的 key 不进这里（两个入口都先查过一次），这里只是把兜底写成
      // `finally` 里的那一格簿记，免得"在飞"标记永远挂着。
      if (entry != null) await entry.fetch(_app, _sids[key]);
    } catch (error) {
      if (errors != null) {
        errors.add(error);
      } else {
        _app.reportHostStateFailure(key, error);
      }
    } finally {
      unawaited(_inFlight.remove(key));
      if (_rerun.remove(key)) unawaited(_run(key));
    }
  }
}

/// 同 key 的合并窗口（契约 §5.9 给的 100–300 ms）。取中位：既压得住一串
/// 连续写（切模型会改两个快照、标题生成紧跟一轮结束），又不让人眼察觉出延迟。
const Duration kHostStateMergeWindow = Duration(milliseconds: 150);
