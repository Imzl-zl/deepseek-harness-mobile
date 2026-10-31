/// 宿主状态同步：`host` 帧 → 按 key 重取快照（契约 §5.9 / `app-channel-client.md` §2.3）。
///
/// ## 这一层治什么
///
/// 桌面侧改了模型 / 权限档 / 设置 / 标题 / 任务表，手机还显示旧值 —— 那是**一类**
/// 症状，不是一处 bug。电脑侧因此会来一条 `host` 帧，里面**只有 key**（方法名），
/// 没有任何值：这条通道的语义是"这些快照可能过期了"。
///
/// ## 三件事，各有唯一出处
///
/// 1. **key 的拼写**只有 [HostStateKey] 一处（与连接器
///    `connector/src/protocol/host-state.ts` 的清单逐字一致）；
/// 2. **"哪个 key 该调谁、允许在哪个时机调"** 只在 [hostStateRegistry] 一处 ——
///    新增状态没配触发点会被 `app/test/host_state_test.dart` 判红；
/// 3. **合并与丢弃**在 [HostStateRefresher] 一处：同 key [window] 内合并成一次，
///    不同 key 各算各的；断连时 [HostStateRefresher.dropPending] 清空待发桶。
///
/// ## 为什么合并放在 app 侧
///
/// 一次"切模型"会同时改两个快照（`session.list` 的行与 `session.projections` 的
/// `modelSelection`），而断线重连时**只有 app 知道"这一批是不是同一屏要的"**。
/// 合并在连接器还会让"合并窗口"变成又一条连接器策略。
///
/// 取舍与被否方案（每个方法一条事件 / 客户端轮询 / 中转做状态总线）见
/// `.agents/notes/implemented/2026-10-31-host-state-sync.md`。
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

  /// `settings.describe`：设置文档。**宿主级**。
  static const String settingsDescribe = 'settings.describe';

  /// `session.projections`：投影包（权限档 / 标题 / 统计 / 轨迹 / 队列）。**会话级**。
  static const String sessionProjections = 'session.projections';

  /// `job.list`：这个会话的任务表。**会话级**。
  static const String jobList = 'job.list';

  /// 全部 key（封闭集，顺序与连接器清单一致）。
  static const List<String> all = <String>[
    sessionList,
    settingsDescribe,
    sessionProjections,
    jobList,
  ];

  /// 这个 key 要不要 `sid` 才能重取（= 那个方法要不要会话参数）。
  static bool isSessionScoped(String key) =>
      key == sessionProjections || key == jobList;
}

/// 允许重取一个 key 的时机。
enum HostStateTrigger {
  /// 收到 `host` 帧（电脑侧说"可能过期了"）。
  notification,

  /// 连上之后的那一串（`landAfterConnect`）。重连的兜底就在这里。
  connectLanding,

  /// 回到前台（用户刚在电脑上改完，抬眼看手机的那一刻应该是对的）。
  appResume,

  /// 打开 / 切会话。
  openSession,
}

/// 重取函数需要的那一面（窄接口）。
///
/// 为什么不用 `AppModel`：那会让 `data/host_state.dart` 与 `app_model.dart`
/// 互相 import，而这里真正需要的只有四个方法 + 一条错误落点。
/// 顺带让登记表的机械测试可以用记账替身（断言"这个 key 调的确实是那个方法"）。
abstract interface class HostStateTarget {
  Future<void> refreshSessions();
  Future<void> refreshSettings();
  Future<void> refreshProjections(String sid);
  Future<void> refreshJobs(String sid);

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

/// 会话清单：模型 / 标题 / 更新时间 / 计数都在行里。
Future<void> _refetchSessionList(HostStateTarget app, String? sid) =>
    app.refreshSessions();

/// 设置文档（默认权限档 / 默认预设 / Session Log 开关）。
Future<void> _refetchSettings(HostStateTarget app, String? sid) =>
    app.refreshSettings();

/// 投影包（权限档 / 标题 / 统计 / 轨迹 / 队列）。**只对当前会话有意义**。
Future<void> _refetchProjections(HostStateTarget app, String? sid) async {
  if (sid == null) return;
  await app.refreshProjections(sid);
}

/// 任务表（增删 / 终态）。
Future<void> _refetchJobs(HostStateTarget app, String? sid) async {
  if (sid == null) return;
  await app.refreshJobs(sid);
}

/// **登记表的唯一出处**：一个新宿主状态漏配就会红。
///
/// 触发点的口径：
/// - `notification` 每条都要有 —— 它才是这条通道存在的理由；
/// - `connectLanding` 覆盖"断连期间漏收"（重连一定重取一遍）；
/// - `appResume` 只给宿主级 + 当前会话的投影（任务表生在会话里，回到前台时
///   它由 `job` 帧维护，重取整份没有必要）；
/// - `openSession` 只给会话级（切会话就重新拉一次，宿主的写可能发生在我们不在的时候）。
const List<HostStateFetch> hostStateRegistry = <HostStateFetch>[
  HostStateFetch(
    key: HostStateKey.sessionList,
    fetch: _refetchSessionList,
    triggers: <HostStateTrigger>{
      HostStateTrigger.notification,
      HostStateTrigger.connectLanding,
      HostStateTrigger.appResume,
    },
  ),
  HostStateFetch(
    key: HostStateKey.settingsDescribe,
    fetch: _refetchSettings,
    // **只有通知这一列**：连上 / 回前台的设置面由 `refreshSessions()` 顺带拉
    // （它末尾就调 `refreshSettings()`，那是既有行为），在这里再挂一列等于
    // 每次重连多发一次请求 —— 而"闪断重连不发重复请求"是本轮要验的判据之一。
    triggers: <HostStateTrigger>{HostStateTrigger.notification},
  ),
  HostStateFetch(
    key: HostStateKey.sessionProjections,
    fetch: _refetchProjections,
    triggers: <HostStateTrigger>{
      HostStateTrigger.notification,
      HostStateTrigger.connectLanding,
      HostStateTrigger.appResume,
      HostStateTrigger.openSession,
    },
  ),
  HostStateFetch(
    key: HostStateKey.jobList,
    fetch: _refetchJobs,
    triggers: <HostStateTrigger>{
      HostStateTrigger.notification,
      HostStateTrigger.openSession,
    },
  ),
];

/// 登记表里这个 key 的那一条；不认识就是 `null`（老 / 新连接器的向前兼容方向）。
HostStateFetch? hostStateFetchOf(String key) {
  for (final entry in hostStateRegistry) {
    if (entry.key == key) return entry;
  }
  return null;
}

/// 按 key 合并的重取器：`host` 帧 → 一条（或几条）快照请求。
///
/// 三条规则：
/// 1. **同 key 在 [window] 内合并成一次**（默认 150 ms，落在契约给的 100–300 ms 内）；
/// 2. **不同 key 各算各的** —— 一次"切模型"同时改两个快照，它们不该互相等；
/// 3. **在飞期间再来同 key**：记一笔，等那次收尾再补一次。直接并发两次会让
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

  /// 正在飞的 key。
  final Set<String> _inFlight = <String>{};

  /// 在飞期间又被要求重取的 key（收尾时补跑一次）。
  final Set<String> _rerun = <String>{};

  int _unknownKeys = 0;

  /// 收到过多少个**登记表不认识**的 key（诊断 / 测试用）。
  ///
  /// 它必须是一个**可观察的数**：将来连接器多一个 key 时，症状要么是"界面变了"，
  /// 要么是"这个数在涨"；否则就是"通知到了但什么都没发生"，无迹可查。
  int get unknownKeys => _unknownKeys;

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

  /// 自动触发点（连上 / 回前台 / 开会话）：**立即重取**，不压 [window]。
  ///
  /// 这些时机一次只来一条（不是高频事件），压窗口只会让"连上了但列表还是空的"
  /// 多等一帧。与通知撞在一起时由 [_inFlight] 合流。
  ///
  /// 抛出的第一条错误会在这里重新抛出（调用方照旧记进 `lastError`），
  /// 但**所有**该跑的 key 都已经跑完 —— 一个 key 失败不该让别的停摆。
  Future<void> triggered(HostStateTrigger trigger, {String? sid}) async {
    final errors = <Object>[];
    final futures = <Future<void>>[];
    for (final entry in _registry) {
      if (!entry.triggers.contains(trigger)) continue;
      if (entry.sessionScoped && sid == null) continue;
      _sids[entry.key] = sid;
      // 立刻重取：把这一 key 的待发通知并进来（它们要的是同一份快照）。
      _timers.remove(entry.key)?.cancel();
      if (_inFlight.contains(entry.key)) {
        _rerun.add(entry.key);
        continue;
      }
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

  /// 断连：**不排队**。
  ///
  /// 待发桶里的请求在重连那一刻必然已经过期（而且重连会由
  /// `landAfterConnect` → [HostStateTrigger.connectLanding] 整份重取）。
  /// 排队只会让重连瞬间打出一串白跑的请求。
  void dropPending() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _sids.clear();
    _rerun.clear();
  }

  Future<void> _run(String key, {List<Object>? errors}) async {
    final entry = hostStateFetchOf(key);
    if (entry == null) return;
    final sid = _sids[key];
    _inFlight.add(key);
    try {
      await entry.fetch(_app, sid);
    } catch (error) {
      if (errors != null) {
        errors.add(error);
      } else {
        _app.reportHostStateFailure(key, error);
      }
    } finally {
      _inFlight.remove(key);
      if (_rerun.remove(key)) unawaited(_run(key));
    }
  }
}

/// 同 key 的合并窗口（契约 §5.9 给的 100–300 ms）。取中位：既压得住一串
/// 连续写（切模型会改两个快照、标题生成紧跟一轮结束），又不让人眼察觉出延迟。
const Duration kHostStateMergeWindow = Duration(milliseconds: 150);
