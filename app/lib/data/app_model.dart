/// 应用级状态（`ChangeNotifier`），UI 的唯一数据入口。
///
/// ## 为什么是 `ChangeNotifier` 而不是引第三方状态管理
///
/// Flutter 官方就带 `ChangeNotifier` + `ListenableBuilder`，而它满足这里的全部需求：
/// **一个 owner、若干只读投影、变更时通知**。引 Riverpod / Bloc 会多一层概念，
/// 而本项目的状态形状很简单（会话列表 + 一个当前会话 + 连接状态）。
/// 换状态管理库是"以后真需要时再换"的决定，不是开工前必须定的事。
///
/// 先例：Flutter 官方的 `provider` 包就是 `ChangeNotifier` 的薄包装，
/// 而它的 README 明说"`ChangeNotifier` 可访问性高、易于理解与实现"。
///
/// ## 它做三件事
///
/// 1. **持有 `SyncClient`**（连接、订阅、写操作全走它）；
/// 2. **把 `SessionDelta` 归并进 `SessionStore`**（UI 读 store 的不可变快照）；
/// 3. **暴露连接状态与错误**，供界面显示。
///
/// 它**不做**：不认识帧、不解析事件（那是 `data/projection.dart` 的事）、
/// 不做重连（那是 `core/` 的事）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ChangeNotifier, listEquals;

import '../core/connection.dart';
import '../core/endpoint.dart';
import '../core/errors.dart';
import '../core/job.dart';
import '../core/sync_client.dart';
import '../model/chat_item.dart';
import '../model/interaction.dart';
import '../model/permission.dart';
import '../model/send_mode.dart';
import '../model/session_stats.dart';
import '../model/workspace.dart';
import 'preview_data.dart';
import 'projection.dart';
import 'session_store.dart';
import 'store.dart';

/// 应用级状态。
///
/// ## 名字为什么是 `AppModel` 而不是 `AppState`
///
/// `core/sync_client.dart` 已经有一个 `AppState` —— 那是**前后台状态**
/// （`foreground` / `background`，决定要不要维持连接与发心跳，契约 §2.2）。
/// 两者同名会让 `import` 冲突（实测编译报 `ambiguous_import`），
/// 而更糟的是**读代码时分不清哪个是哪个**：一个是协议层的输入，一个是数据层的 owner。
///
/// 所以按职责命名：`AppState` 留给协议层（契约里已经这么叫），
/// 这里叫 `AppModel`（"界面要读的那份应用模型"）。
class AppModel extends ChangeNotifier {
  AppModel({
    required this.client,
    PreferenceStore? prefs,
    List<Endpoint> endpoints = const [],
    this.onEndpointsChanged,
    this.onConnectionTerminated,
  }) : _prefs = prefs,
       _endpoints = List<Endpoint>.of(endpoints);

  /// 通道客户端（连接 / 订阅 / 写操作的唯一 owner）。
  final SyncClient client;

  /// 偏好缝（`meta` 表的窄接口）；`null` = 不落盘（测试 / 未装配）。
  final PreferenceStore? _prefs;

  /// 端点表变了之后落盘（装配层注入：`PairingStore.saveEndpoints`）。
  ///
  /// **在这里而不是在 `AppModel` 里直接写存储**：`data/` 不认识 `platform/`
  /// （`verify-platform-boundary.mjs` 的 `core-no-platform-import` 管的是 `core/`，
  /// 但同一条纪律在 `data/` 上更要守 —— 它要能在纯 Dart 单测里跑）。
  final Future<void> Function(List<Endpoint>)? onEndpointsChanged;

  /// 连接**终态**失败时呈递一次那个协议错误（身份不被认 → 清凭据回配对页）。
  ///
  /// 装配点（`main.dart`）把它接到 `ConnectionRecovery.onTerminated` ——
  /// 那是 `ClientAction` 的**唯一执行处**。这里只负责"识别出连接层已终态停摆、
  /// 并把那个错误呈递一次"，不认识平台、不导航、也不自己判 `notPaired`。
  ///
  /// 网络类失败（`relay/offline` 等）不到这里：连接层会自行退避重连。
  final void Function(ProtocolException error)? onConnectionTerminated;

  /// 本连接周期是否已呈递过终态失败（避免重复触发重新配对）。
  bool _connectionTerminatedSurfaced = false;

  /// 有序端点表。**序即偏好**：`connect()` 按这个顺序拨，第一个通的赢。
  ///
  /// 它的所有者是这里（界面要读、设置页要改），而拨号方
  /// （`platform/transport_factory.dart` 经 `EndpointTransport`）每次
  /// `connect()` 现读它 —— 所以"发现了一条直连"立刻生效，不用重启 App。
  List<Endpoint> get endpoints => _endpoints;
  List<Endpoint> _endpoints;

  /// 当前拨通的那个端点（`null` = 还没连上）。
  ///
  /// 由装配层把 `EndpointTransport.onActivated` 接到这里。
  Endpoint? get activeEndpoint => _activeEndpoint;
  Endpoint? _activeEndpoint;

  /// 报一次"这条连接走的是哪个端点"。
  void reportActiveEndpoint(Endpoint endpoint) {
    if (_activeEndpoint?.id == endpoint.id) return;
    _activeEndpoint = endpoint;
    notifyListeners();
  }

  /// 把连接器自报的端点并进表里（`endpoint.describe` 的结果）。
  ///
  /// **合并而不是覆盖**：覆盖会抹掉用户手动排的偏好序，而连接器某次少报一个
  /// （例如直连刚好在重启）就把手机里的条目删了。规则见 `core/endpoint.dart`
  /// 的 `mergeEndpoints` —— 已知的原位更新，未知的按 kind 插。
  Future<void> mergeDiscoveredEndpoints(List<Endpoint> discovered) async {
    final merged = mergeEndpoints(_endpoints, discovered);
    if (merged.length == _endpoints.length &&
        merged.every((e) => _endpoints.contains(e))) {
      return; // 没有变化：不落盘、不通知（否则每次重连都会写一次存储）
    }
    _endpoints = merged;
    notifyListeners();
    await onEndpointsChanged?.call(merged);
  }

  /// 手动挑一个端点当首选（设置页用）。**只改顺序，不删条目**。
  Future<void> preferEndpoint(Endpoint endpoint) async {
    final index = _endpoints.indexWhere((e) => e.id == endpoint.id);
    if (index < 0) return;
    final reordered = <Endpoint>[
      _endpoints[index],
      ..._endpoints.where((e) => e.id != endpoint.id),
    ];
    if (listEquals(reordered, _endpoints)) return;
    _endpoints = reordered;
    notifyListeners();
    await onEndpointsChanged?.call(reordered);
  }

  /// 每个端点**最近一次拨号**的结果（端点 id = url → 结果）。
  ///
  /// 由传输层报事实（`EndpointTransport.onAttempt`，装配在 `main.dart`），
  /// 这里只记账。设置页的"通不通"读它：**没有记录就没有结论** ——
  /// 不猜，也不为了显示去主动探测（探测是第二条拨号路径，
  /// 会让"通不通"取决于探测时机而不是真实拨号）。
  final Map<String, EndpointAttempt> _endpointAttempts = {};

  EndpointAttempt? attemptOf(Endpoint endpoint) =>
      _endpointAttempts[endpoint.id];

  /// 记一次拨号结果。**同一个结果不重复通知**：退避重连时每一轮都会把
  /// 所有端点重报一遍，不判重会让界面每隔几秒重建一次。
  void reportEndpointAttempt(Endpoint endpoint, EndpointAttempt attempt) {
    if (_endpointAttempts[endpoint.id] == attempt) return;
    _endpointAttempts[endpoint.id] = attempt;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 会话投影（`session.projections`，契约 §5.7）—— 一个方法打开全部只读面
  // ---------------------------------------------------------------------------

  /// 最近一次读到的投影值包（`null` = 还没读过 / 读不到）。
  ///
  /// **原样存，不挑字段**：投影的 `viewSchema` 是 zod `.strict()`，
  /// 连接器那侧"挑着发"就要预先知道全部键 —— 而那正是会漂移的清单。
  /// 各面按需从这里取，认不出就不给。
  Map<String, Object?>? _projections;

  Map<String, Object?>? get projections => _projections;

  /// 读一次投影。**点开会话时调**（与 `refreshJobs` 同一步）。
  ///
  /// 失败只留声：投影读不到时那些只读面显示空态，而"整个会话打不开"更糟。
  Future<void> refreshProjections(String sid) async {
    try {
      final result = await client.call<Object?>('session.projections', {
        'sid': sid,
      });
      if (_disposed || result is! Map) return;
      // JSON 解出来是 `Map<dynamic, dynamic>`，逐字段转型成我们要的形状 ——
      // **不整体 cast**：那会把"键不是字符串"这种畸形数据一起带进来，
      // 而后者的症状是取字段时抛 `noSuchMethod`，很难定位。
      _projections = {
        for (final entry in result.entries)
          if (entry.key is String) entry.key as String: entry.value,
      };
      // 子智能体从同一个投影包里取（`subagentCatalog` 键）。
      _subagents[sid] = parseSubagentCatalog(result);
      notifyListeners();
    } catch (error) {
      // **兜住所有异常，不只 `ProtocolException`**（与 `refreshSessions` 同一条纪律）：
      // 解析出错 / 类型不对 / 超时都只该让"这一批只读面显示空态"，
      // 逃逸成未处理的异步错误会让 `openSession` 半途而废 ——
      // 症状是"会话打开了但统计条/权限档永远空着且不报错"。
      _recordError('读取会话投影失败', error);
    }
  }

  // ---- 统计条（`tokenUsage` / `contextPressure` / `sessionStats` 三个投影）----

  /// token 用量。**认不出就是 null**，不猜 —— 猜一个就是把
  /// "看起来连着"当成"连着"。
  TokenUsage? get tokenUsage {
    final raw = _projections?['tokenUsage'];
    if (raw is! Map) return null;
    return TokenUsage(
      uncachedInputTokens: _intOf(raw['uncachedInputTokens']),
      outputTokens: _intOf(raw['outputTokens']),
      cacheReadTokens: _intOf(raw['cacheReadTokens']),
      cacheWriteTokens: _intOf(raw['cacheWriteTokens']),
    );
  }

  /// 会话统计（`sessionStats` 投影）。
  ///
  /// 字段与投影的 wire view 逐字对应
  /// （`packages/session/session-stats/src/projection.ts:72-81`）——
  /// `decodeMs` / `decodeTokens` 是输出速率的唯一来源，缺了它
  /// 手机就算不出 Web 上那个 `75 tok/s`。
  SessionStats? get sessionStats {
    final raw = _projections?['sessionStats'];
    if (raw is! Map) return null;
    return SessionStats(
      turns: _intOf(raw['turns']),
      steps: _intOf(raw['steps']),
      llmMs: _intOf(raw['llmMs']),
      toolMs: _intOf(raw['toolMs']),
      decodeMs: _intOf(raw['decodeMs']),
      decodeTokens: _intOf(raw['decodeTokens']),
    );
  }

  /// 上下文占用压力（`contextPressure` 投影）。三个字段都没有就是 `null`。
  ///
  /// `contextWindow` 是**分母**：没有它"占了多少"无解，而 Web 的
  /// `ContextMeter` 同样在只有分子时不渲染。
  ContextPressure? get contextPressure {
    final raw = _projections?['contextPressure'];
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

  static int _intOf(Object? value) => value is num ? value.toInt() : 0;

  /// 从 `session.list` 行的**投影提示**里取标题。
  ///
  /// 形状：`{kind, asOfSeq, values: {title: '...', ...}}`
  /// （DSH `SessionProjectionHints`，`list.ts:291-312` 产出）。
  /// 认不出就给空串 —— 由 [SessionSummary.displayTitle] 按 DSH 的链继续退。
  static String _titleHintOf(Object? raw) {
    if (raw is! Map) return '';
    final values = raw['values'];
    if (values is! Map) return '';
    final title = values['title'];
    return title is String && title.isNotEmpty ? title : '';
  }

  // ---- 权限档（`permission.catalog` 目录 + `permissions` 投影的当前值）----

  /// 权限预设目录（`permission.catalog`，原样过线）。
  ///
  /// **拿不到就是 null** —— 手机显示"拿不到目录"，不摆三档手抄的名字
  /// （2026-10-15 之前输入栏的权限档正是三个写死的枚举值）。
  /// 预设表是**部署可配**的（DSH `bundle/base/cordis.patch.yml:262-271`），
  /// 手抄一份就是第二份真值。
  PermissionCatalog? get permissionCatalog => _permissionCatalog;

  PermissionCatalog? _permissionCatalog;

  /// 当前会话的权限档（`permissions` 投影的 `currentValue`）。
  ///
  /// **认不出就是 null**：投影没注册（这台电脑没装权限插件）与
  /// "这一帧没有这个键"是同一件事，而正确表现都是"不知道"——
  /// 界面显示空态，不猜一个档位。
  String? get permissionValue {
    final sid = _currentSid;
    if (sid == null) return null;
    return parsePermissionValue(_projections);
  }

  /// 存一份预设目录（连接器 `permission.catalog` 的应答）。
  void setPermissionCatalog(PermissionCatalog? catalog) {
    _permissionCatalog = catalog;
    notifyListeners();
  }

  /// 切这个会话的权限预设。**与 Web 同一条写路径**：
  /// DSH 的 `/permission <档位>` 斜杠命令
  /// （`packages/interaction/permission-presets/src/index.ts:255-276`，
  /// DSH 注释原话 "the one write path a web client uses"），Web 侧经
  /// `remote.commands.execute` 调它
  /// （`packages/client/ui-permission-presets/src/client/index.ts:126`）。
  ///
  /// 切完立刻重读一次投影：当前值在 `permissions` 投影里，
  /// 而投影只在打开会话时拉过一次 —— 不重读就要等下次开会话才变。
  ///
  /// @returns 电脑侧的结论；`null` = 这次调用没成功（原因在 [lastError]）。
  Future<PermissionSwitch?> switchPermission(String preset) async {
    final sid = _currentSid;
    if (sid == null) return null;
    try {
      final result = await client.call<Object?>(
        'permission.switch',
        {'sid': sid, 'preset': preset},
        requestId: 'perm-${DateTime.now().microsecondsSinceEpoch}',
      );
      final switched = parsePermissionSwitch(result);
      if (switched == null || _disposed) return null;
      if (switched.succeeded) await refreshProjections(sid);
      return switched;
    } catch (error) {
      // **兜住所有异常，不只 `ProtocolException`**（与 `refreshSessions`
      // 同一条纪律）：解析出错 / 形状不对 / 超时都不该逃逸成未处理的异步错误。
      _recordError('切换权限档失败', error);
      return null;
    }
  }

  // ---- 子智能体（`subagentCatalog` 投影）----

  final Map<String, List<SubagentRow>> _subagents = {};

  /// 子智能体列表。**空表就是没有**，不造假的 —— 2026-10-15 之前这里是
  /// 两条写死的示例（`Extract DSH icon paths` 等）。
  List<SubagentRow> subagentsOf(String sid) =>
      List.unmodifiable(_subagents[sid] ?? const []);

  // ---------------------------------------------------------------------------
  // 后台任务（契约 §7 的 job.* / §5.3 的 job 帧）
  // ---------------------------------------------------------------------------

  /// 当前会话的后台任务（按 sid 分桶：切会话看的是那一会话的任务）。
  final Map<String, List<JobRow>> _jobs = {};

  /// 正在订阅的任务（`sid` → `jobId` 集合）。展开时 follow、收起时 unfollow。
  final Map<String, Set<String>> _followedJobs = {};

  /// 每个任务已收到的输出（`jobId` → 文本）。**只追加，不重排** ——
  /// 输出是日志，重排会让"读到这里"失去意义。
  final Map<String, StringBuffer> _jobOutput = {};

  /// 任务帧流出问题（订阅中断 / 帧解不开）时给界面的一句话。
  final Map<String, String> _jobErrors = {};

  List<JobRow> jobsOf(String sid) => List.unmodifiable(_jobs[sid] ?? const []);

  /// 某个任务已收到的输出文本（没有订阅过就是空串）。
  String jobOutput(String jobId) => _jobOutput[jobId]?.toString() ?? '';

  /// 某个任务的订阅问题；`null` = 没问题。
  String? jobError(String jobId) => _jobErrors[jobId];

  bool isJobFollowed(String sid, String jobId) =>
      _followedJobs[sid]?.contains(jobId) ?? false;

  /// 拉一次任务清单。**只在进服务态与切会话时调** —— 它是一次性快照，
  /// 后续变化走 `job` 帧的 `status`。
  Future<void> refreshJobs(String sid) async {
    // **先建桶再早退**：`job` 帧不带 sid，只能靠"这个会话有桶"归位。
    // 桶不存在时帧会被丢 —— 而表现是"任务在跑但没有输出"，最难查的那类。
    _jobs.putIfAbsent(sid, () => <JobRow>[]);
    final result = await client.call<Object?>('job.list', {'sid': sid});
    if (_disposed || result is! Map) return;
    final raw = result['jobs'];
    if (raw is! List) return;
    _jobs[sid] = [
      for (final entry in raw)
        if (entry is Map) _jobRowFromJson(entry),
    ];
    notifyListeners();
  }

  /// 展开一个任务：订阅它的输出流。
  ///
  /// **幂等**：同一个 `(sid, jobId)` 重复 follow 由电脑侧合流，但本地也要挡一次，
  /// 否则 UI 上会出现"点了两下、输出翻倍"。
  Future<void> followJob(String sid, String jobId) async {
    final followed = _followedJobs.putIfAbsent(sid, () => <String>{});
    if (!followed.add(jobId)) return;
    _jobOutput.putIfAbsent(jobId, StringBuffer.new);
    _jobErrors.remove(jobId);
    try {
      await client.call<Object?>('job.follow', {'sid': sid, 'jobId': jobId});
    } on ProtocolException catch (error) {
      // 订阅没开成：把本地标记撤掉，否则 UI 会显示"已订阅"却永远没有输出。
      followed.remove(jobId);
      _jobErrors[jobId] = error.message;
      notifyListeners();
    }
  }

  /// 收起一个任务：退订。
  Future<void> unfollowJob(String sid, String jobId) async {
    _followedJobs[sid]?.remove(jobId);
    try {
      await client.call<Object?>('job.unfollow', {'sid': sid, 'jobId': jobId});
    } on ProtocolException catch (error) {
      _jobErrors[jobId] = error.message;
    }
    notifyListeners();
  }

  /// 停一个任务。**走宿主的人类发起门面**，返回电脑侧的结论。
  Future<String?> killJob(String sid, String jobId) async {
    try {
      final result = await client.call<Object?>('job.kill', {
        'sid': sid,
        'jobId': jobId,
      });
      return result is Map && result['outcome'] is String
          ? result['outcome'] as String
          : null;
    } on ProtocolException catch (error) {
      _jobErrors[jobId] = error.message;
      notifyListeners();
      return null;
    }
  }

  /// 把一条 `job` 帧应用到状态。**只认四种 kind**（`core/job.dart` 的 sealed 类），
  /// 漏一种编译期就红。
  void _applyJobFrame(JobFrame frame) {
    switch (frame) {
      case JobOpened(:final row):
        _applyJobRow(row);
        _jobOutput.putIfAbsent(row.id, StringBuffer.new);
        _jobErrors.remove(row.id);
      case JobOutput(:final jobId, :final chunks, :final lossy):
        final buffer = _jobOutput.putIfAbsent(jobId, StringBuffer.new);
        for (final chunk in chunks) {
          if (chunk.gapBefore) {
            buffer.write('…（较早的输出已被淘汰）\n');
          }
          buffer.write(chunk.text);
        }
        if (lossy) {
          _jobErrors[jobId] = '部分输出已丢失（保留窗口之外）';
        }
      case JobStatus(:final row):
        _applyJobRow(row);
      case JobError(:final jobId, :final message):
        _jobErrors[jobId] = message;
    }
    notifyListeners();
  }

  void _applyJobRow(JobRow row) {
    // **帧上带了 sid 就按它归桶**（连接器盖的）：这是唯一可靠的归属信息，
    // 猜的代价是"正在看的会话不显示 chip、别的会话凭空多一个"。
    //
    // 2026-10-15 之前的做法是 `_jobs.keys.last`（地图插入序）——用户先开 A 再开 B，
    // B 里新起的任务被归到 A，于是**正在看的 B 看不到后台任务**。
    // 只有老连接器（帧不带 sid）才退回"当前会话"，且只在它的桶已存在时归。
    final targetSid = row.sid ?? _currentSid;
    if (targetSid != null && _jobs.containsKey(targetSid)) {
      final bucket = _jobs[targetSid]!;
      final index = bucket.indexWhere((j) => j.id == row.id);
      _jobs[targetSid] = index >= 0
          ? [...bucket..[index] = row]
          : [...bucket, row];
      notifyListeners();
      return;
    }
    // 全局更新：任务在**任何**已建桶的会话里都同步（同 id 覆盖）。
    // 这是为了"用户在 A 看任务、B 也开过"时状态不分裂 —— 但不新建桶
    // （硬塞进一个错误的会话比丢一帧更糟）。
    for (final entry in _jobs.entries) {
      final index = entry.value.indexWhere((j) => j.id == row.id);
      if (index >= 0) {
        _jobs[entry.key] = [...entry.value..[index] = row];
        notifyListeners();
        return;
      }
    }
  }

  static JobRow _jobRowFromJson(Map entry) => JobRow(
    id: entry['id'] is String ? entry['id'] as String : '',
    kind: entry['kind'] is String ? entry['kind'] as String : '',
    label: entry['label'] is String ? entry['label'] as String : '',
    status: entry['status'] is String ? entry['status'] as String : 'running',
    startedAt: (entry['startedAt'] as num?)?.toInt() ?? 0,
    outputTotal: (entry['outputTotal'] as num?)?.toInt() ?? 0,
    progress: entry['progress'] is String ? entry['progress'] as String : null,
    detail: entry['detail'] is String ? entry['detail'] as String : null,
    finishedAt: (entry['finishedAt'] as num?)?.toInt(),
    // 帧路径上连接器盖的 sid（`job` 帧不带会话，归桶靠它）。
    // `job.list` 的行不带 —— 那次本来就知道是哪个会话。
    sid: entry['sid'] is String ? entry['sid'] as String : null,
  );

  final Map<String, SessionStore> _stores = {};

  /// 会话列表（**电脑侧不返回标题**，标题由本地从条目推导 —— 见 `SessionSummary.title`）。
  List<SessionSummary> _sessions = const [];

  /// 当前打开的会话（`null` = 在列表页）。
  String? _currentSid;

  ConnectionStateView _connection = ConnectionStateView.idle;

  /// 最近一次错误（界面显示用；`null` = 没有）。
  ProtocolException? _lastError;

  /// **这条连接为什么被关掉**（来自客户端的诊断面；`null` = 没关过）。
  ///
  /// 必须暴露到界面：真机上出现过"列表恒空 + 反复重连"，而**两端日志都看不出原因** ——
  /// 因为原因一直存在 `SyncClientProbe.lastProtocolError` 里，而那是"只给测试用"的字段。
  /// 一个只给测试看的诊断面，在真机上等于没有诊断面。
  String? get connectionDiagnosis {
    // `SyncClientProbe` 与 `SyncClient` 是**两个独立接口**（前者是诊断面，
    // 故意不并进产品接口 —— 免得界面层顺手去解析帧）。所以这里不能靠
    // `is SyncClientProbe` 收窄（`client` 的静态类型是 `SyncClient`，两者无子型关系），
    // 得显式转一次。
    final probe = client is SyncClientProbe ? client as SyncClientProbe : null;
    if (probe == null) return null;
    final error = probe.lastProtocolError;
    if (error != null) return '${error.code.wire}：${error.message}';
    // **握手失败排在"对端关闭"之前**：它是更具体的原因 ——
    // 握手失败也会导致连接被关，先看更具体的那一个（真机上"每 10 秒重连"就是它）。
    final handshake = probe.lastHandshakeFailure;
    if (handshake != null) return '握手失败（$handshake）';
    final silent = probe.lastHalfOpenSilentMs;
    if (silent != null) return '判为半开（沉默 ${silent}ms）';
    // **断开但没有任何协议错误** —— 真机上"每 10 秒重连"就是这种。
    // 关闭码与理由是唯一的线索，必须显示出来。
    final code = probe.lastCloseCode;
    final reason = probe.lastCloseReason;
    if (code != null || reason != null) {
      return '连接被关闭（code=${code ?? '无'}${reason == null ? '' : '，$reason'}）';
    }
    return null;
  }

  StreamSubscription<ConnectionState>? _stateSub;
  StreamSubscription<JobFrame>? _jobSub;
  final Map<String, StreamSubscription<SessionDelta>> _deltaSubs = {};

  /// 交互信号流（契约 §6.3：待处理集合是会话事件的投影）。
  ///
  /// **广播**流：UI 的接管队列要听，会话列表的角标也要听。
  final StreamController<InteractionSignal> _interactions =
      StreamController<InteractionSignal>.broadcast();

  bool _disposed = false;

  /// 交互信号（开一个待处理项 / 收束一个）。
  Stream<InteractionSignal> get interactions => _interactions.stream;

  /// 会话列表（只读快照）。
  List<SessionSummary> get sessions => _sessions;

  /// 按别名取一个会话；没有就 `null`。
  ///
  /// 输入栏的模型名走它（`chat_page.dart` 的 `_modelLabel`）——
  /// 直接从 `sessions` 里 `firstWhereOrNull` 会让"当前会话不在列表里"变成一个异常，
  /// 而那是正常情况（刚 `openSession` 一个还没被 `session.list` 刷到的会话）。
  SessionSummary? sessionOf(String sid) {
    for (final s in _sessions) {
      if (s.sid == sid) return s;
    }
    return null;
  }

  /// 当前会话的条目（只读快照；没打开会话时是空表）。
  List<ChatItem> get items =>
      _currentSid == null ? const [] : _storeOf(_currentSid!).items;

  // ---- 模型（`session/modelCatalog` + `modelSelection` 投影）----

  /// 模型目录（`session/modelCatalog`，原样过线）。
  ///
  /// **拿不到就是 null** —— 手机显示"未选择"，不手抄第二份名单
  /// （2026-10-15 之前 picker 里是四个写死的模型名）。
  List<ModelRef>? get modelCatalog => _modelCatalog;
  List<ModelRef>? _modelCatalog;

  /// 当前会话的模型（`modelSelection` 投影，`next ?? lastUsed`）。
  ModelRef? get currentModel {
    final sid = _currentSid;
    if (sid == null) return null;
    return sessionOf(sid)?.model;
  }

  /// 存一份模型目录（连接器 `session/modelCatalog` 的应答）。
  void setModelCatalog(List<ModelRef> catalog) {
    _modelCatalog = List.unmodifiable(catalog);
    notifyListeners();
  }

  /// 切这个会话的模型。**与 Web 用同一个 DSH 方法**（`session/select-model`），
  /// 没有第二套接口 —— 已核实 Web 侧调的就是它
  /// （`packages/client/ui-model-selection/src/client/directory.ts:98`）。
  ///
  /// 语义（`packages/core/agent-default-model/src/index.ts:82-94` + README）：
  /// ① **当前会话**立即生效（README: "Session-specific selection takes
  ///    precedence in the consumer"）；
  /// ② **以后新建的** agent 默认用它；没有 configEditor 时这步是 no-op；
  /// ③ **不改别的会话**。
  /// 所以"新会话默认跟随"是 Web 一直有的行为，不是副作用。
  ///
  /// @returns 电脑侧归一后的选择（可能与请求略有出入，如补上默认 effort）
  Future<ModelRef?> selectModel({
    required String provider,
    required String model,
    String? reasoningEffort,
  }) async {
    final sid = _currentSid;
    if (sid == null) return null;
    try {
      final result = await client.call<Object?>(
        'session.select-model',
        {
          'sid': sid,
          'provider': provider,
          'model': model,
          // 显式 `if` 而不是 null-aware element（`?key: value`）：后者的 key
          // 取的是**值的字符串形式**而不是标识符 —— 实测展开成 `high: high`
          // 而不是 `reasoningEffort: high`（2026-10-15 踩到）。`dart analyze`
          // 会反过来建议改用那个语法（`use_null_aware_elements`），别听它的。
          // ignore: use_null_aware_elements
          if (reasoningEffort != null) 'reasoningEffort': reasoningEffort,
        },
        requestId: 'sel-${DateTime.now().microsecondsSinceEpoch}',
      );
      if (_disposed || result is! Map) return null;
      final selected = result['selected'];
      if (selected is! Map) return null;
      // 切完立刻重拉一次清单：`session.list` 的行带 `model` 字段，
      // 而输入栏的模型名走的是它。不拉就要等下一次自然刷新才变。
      await refreshSessions();
      return ModelRef(
        provider: selected['provider'] is String
            ? selected['provider'] as String
            : provider,
        model: selected['model'] is String
            ? selected['model'] as String
            : model,
      );
    } on ProtocolException catch (error) {
      _lastError = error;
      if (!_disposed) notifyListeners();
      return null;
    }
  }

  /// 当前会话 id。
  String? get currentSid => _currentSid;

  /// 当前会话的标题（顶栏用）。
  ///
  /// **与列表用同一条链**（[SessionSummary.displayTitle]，DSH 的
  /// `displayTitleOf`：持久标题 → 项目目录名 → 会话 id）。
  ///
  /// 2026-10-15 之前这里只读**本地从条目推导**的标题（`deriveTitle`）——
  /// 于是同一个人会话在列表里叫 A、点进顶栏叫 B（真机反馈："名字对了,
  /// 但我点进去会话名字又变了"）。两个真值源必然漂，所以现在只认一条：
  /// 投影提示里的持久标题优先，本地推导只在前两者都拿不到时兜底。
  String? get currentTitle {
    final sid = _currentSid;
    if (sid == null) return null;
    final summary = _sessions.where((s) => s.sid == sid).firstOrNull;
    final fromSummary = summary?.displayTitle;
    if (fromSummary != null && fromSummary.isNotEmpty) return fromSummary;
    final local = _storeOf(sid).title;
    return local.isEmpty ? null : local;
  }

  /// 连接状态（界面视图）。
  ConnectionStateView get connection => _connection;

  /// 最近一次错误。
  ProtocolException? get lastError => _lastError;

  /// 当前会话的变更流（UI 用它做**区块级**重建，而不是整页 setState）。
  Stream<List<ChatItem>> changesOf(String sid) => _storeOf(sid).changes;

  /// 是否是示例数据（界面上要能看出来，见 `preview_data.dart` 的文件头）。
  bool get isPreview => _isPreview;
  bool _isPreview = false;

  /// 装上示例数据，让"没连电脑也能看看界面长什么样"。
  ///
  /// **只在用户点了那个入口时调**：它不是错误路径的回退，
  /// 也不是"没数据就自动填" —— 那会让人以为连上了。
  ///
  /// 它**不写库**（不经 `ItemStore`）：退出重进就没了，不会永远占着真实列表。
  void loadPreview() {
    if (_disposed) return;
    _isPreview = true;
    // 把示例数据里的**相对锚点**换算成真时间戳（见 `preview_data.dart` 的说明）：
    // 不换算的话它们会被算成 1970 年，全落进抽屉的「更早」那一组。
    final anchor = DateTime.now().millisecondsSinceEpoch;
    final sessions = <SessionSummary>[];
    for (final preview in previewSessions) {
      final store = _storeOf(preview.sid);
      store.replaceAll(preview.items);
      // 标题带 `（示例）` 前缀：**任何一屏都看得出它不是真的**。
      sessions.add(
        SessionSummary(
          sid: preview.sid,
          title: '（示例）${preview.title}',
          updatedAt: anchor + preview.updatedAt,
          itemCount: preview.items.length,
          pendingCount: preview.items
              .whereType<ApprovalItem>()
              .where((a) => !a.decided)
              .length,
        ),
      );
    }
    _sessions = sessions;
    _lastError = null;
    notifyListeners();
  }

  /// 清掉示例数据（真的连上时要清，免得混在真实列表里）。
  void clearPreview() {
    if (!_isPreview) return;
    _isPreview = false;
    for (final preview in previewSessions) {
      // 不等它：`dispose` 只是关一个广播控制器（见 `SessionStore.dispose`）。
      unawaited(_stores.remove(preview.sid)?.dispose());
    }
    _sessions = const [];
    if (!_disposed) notifyListeners();
  }

  /// 启动：连通道。
  Future<void> start() async {
    _stateSub = client.connection.listen(_onConnectionChanged);
    // 任务输出帧：任务面板与角标都听它。**广播流**，所以这里只订一份。
    _jobSub = client.jobUpdates.listen(_applyJobFrame);
    _connection = _viewOf(client.state, client);
    // **先把落盘的发送模式读回来**：它决定发 prompt 时带哪个 `mode`，
    // 重启后要还是用户选的那个。读不到（没存过 / 存了个不认识的值）
    // 就保持默认的排队 —— 与 DSH 的默认一致，也不猜。
    final stored = await _prefs?.read(kSendModeKey);
    final restored = SendMode.fromWire(stored);
    if (restored != null) _sendMode = restored;
    notifyListeners();
    await client.start();
  }

  /// 落盘的 meta 键：发送模式。**契约两端共用的字符串**，改动等于作废用户的偏好。
  static const String kSendModeKey = 'send_mode';

  SendMode _sendMode = SendMode.queue;

  /// 当前的发送模式（排队 / 插话）。
  SendMode get sendMode => _sendMode;

  /// 切发送模式。**落盘**（见 [kSendModeKey]）；同一个值重复切是空操作。
  Future<void> setSendMode(SendMode mode) async {
    if (_disposed || mode == _sendMode) return;
    _sendMode = mode;
    notifyListeners();
    await _prefs?.write(kSendModeKey, mode.wire);
  }

  void _onConnectionChanged(ConnectionState state) {
    if (_disposed) return;
    _connection = _viewOf(state, client);
    // **连上了就清掉上一次的失败**（它可能是好几轮之前那次断开留下的）。
    //
    // 少了这一行，界面会一边显示"拉取会话失败"一边正常收发 ——
    // 而那句话会把排查引向一个**已经不存在**的故障（真机实测：
    // 屏幕写着 `handshake-timeout`，中转侧却显示 hello / confirm / req 三步都正常）。
    if (state == ConnectionState.serving) {
      _lastError = null;
      // 连上了：重置"已呈递终态"标记（下一次真掉线再按需呈递）。
      _connectionTerminatedSurfaced = false;
    }
    // **身份不被认是终态**：连接层确认"不再退避重连"后，把那个终态协议错误
    // 呈递给上层**一次**（`onConnectionTerminated` → `ConnectionRecovery`）。
    // 这里只读连接层的 `lastConnectWasTerminal` 事实，不自己判 `notPaired` ——
    // 真正的"错误码 → 客户端动作 → 副作用"只在装配层那一处。
    if (state == ConnectionState.closed && !_connectionTerminatedSurfaced) {
      final probe = client is SyncClientProbe
          ? client as SyncClientProbe
          : null;
      if (probe != null && probe.lastConnectWasTerminal) {
        final error = probe.lastProtocolError;
        if (error != null) {
          _connectionTerminatedSurfaced = true;
          onConnectionTerminated?.call(error);
        }
      }
    }
    notifyListeners();
    // **一进服务态就拉会话列表**。
    //
    // 少了这一步，界面永远停在「还没有会话」—— 而那不是"电脑上真没有会话"，
    // 是**根本没人去问过**。连上的那一刻是唯一正确的时机：
    // 之前发请求会撞上"还没握手"，之后没有别的事件会再来一次。
    //
    // 拉完的结果由 `refreshSessions` 自己 `notifyListeners`，这里不等它：
    // 收帧路径上的回调不该被一个网络往返挡住（§2.2 的状态迁移通知是同步派发的）。
    if (state == ConnectionState.serving) {
      unawaited(refreshSessions());
      // **一进服务态就问一次"你还在哪些地址"**。
      //
      // 这是"局域网直连"能自愈的唯一时机：连接器只在**连上之后**才说得出自己
      // 绑在哪个 IP 上（`endpoint.describe`），而手机此前可能存着一个过期地址
      // （DHCP 换 IP、切 WiFi）。经中转连上→问到新地址→下次直连就用新的。
      //
      // 失败只留声，不打断主链：拿不到端点表不影响已经建立的这条连接，
      // 而下一次重连会再问一次。
      unawaited(_discoverEndpoints());
    }
  }

  /// 拉一次 `endpoint.describe` 并并进端点表。
  ///
  /// **没有这个方法时静默返回**（老连接器没有它）—— 那时端点表就是配对时那一条，
  /// 行为与这个功能之前完全一致。这不是"猜一个默认值"，而是能力不存在。
  Future<void> _discoverEndpoints() async {
    if (_discovering) return;
    _discovering = true;
    try {
      final result = await client.call<Object?>('endpoint.describe', const {});
      final discovered = parseEndpointList(result);
      if (discovered.isEmpty) return;
      await mergeDiscoveredEndpoints(discovered);
    } on ProtocolException catch (error) {
      // 方法不存在 / 能力没开：老连接器的正常形态，不当故障。
      if (error.code != ErrorCode.connectorUnsupported) {
        _lastError = error;
        notifyListeners();
      }
    } finally {
      _discovering = false;
    }
  }

  bool _discovering = false;

  /// 把 `ConnectionState`（协议状态机）翻成界面视图。
  /// 协议状态 → 界面视图。
  ///
  /// **多一个输入：客户端本身**。因为「连接不上」这一档不是协议状态 ——
  /// core 的状态机停在 `backoff`，是界面根据"连接层是否已放弃自动重连"
  /// （`SyncClientProbe.lastConnectGaveUp`）推出来的。事实仍然只有一个来源
  /// （连接层），这里只做映射。
  static ConnectionStateView _viewOf(ConnectionState state, SyncClient client) {
    if (state == ConnectionState.backoff) {
      final probe = client is SyncClientProbe
          ? client as SyncClientProbe
          : null;
      if (probe?.lastConnectGaveUp ?? false) return ConnectionStateView.gaveUp;
    }
    return switch (state) {
      ConnectionState.idle => ConnectionStateView.idle,
      ConnectionState.connecting => ConnectionStateView.connecting,
      ConnectionState.handshake => ConnectionStateView.handshaking,
      ConnectionState.serving => ConnectionStateView.serving,
      ConnectionState.backoff => ConnectionStateView.backoff,
      ConnectionState.closed => ConnectionStateView.closed,
    };
  }

  /// 拉会话列表（`session.list`）。
  ///
  /// **失败不吞**：把错误记进 [lastError] 并让界面能显示。
  /// 吞掉的话界面只会显示"空列表"，而用户无从知道是"真没有会话"还是"请求失败了"。
  Future<void> refreshSessions() async {
    try {
      final result = await client.call<Object?>('session.list', const {});
      final list = _parseSessionList(result);
      // **待处理数本地算**：从每个会话已落地的条目里数未决审批/提问。
      // 不指望 `session.list` 带它 —— 那是跨请求的汇总，而投影就在手里。
      // 多会话并行时，用户靠这个数知道该切去哪个会话（DSH 的待处理是
      // per-session 的，切过去才看得见）。
      _sessions = [
        for (final s in list) s.copyWith(pendingCount: _pendingCountOf(s.sid)),
      ];
      _lastError = null;
      if (!_disposed) notifyListeners();
    } catch (error) {
      // **兜住所有异常，不只 `ProtocolException`**（契约 §9：失败要留声）。
      // 只接 `ProtocolException` 的话，任何别的错（解析、类型、超时…）
      // 都会逃逸成未处理的异步错误 —— 界面**停在空列表且不报错**，
      // 而那正是"连上了却永远没有会话"最容易被误判成"电脑上真没有"的形态。
      _recordError('拉取会话列表失败', error);
    }

    // 模型目录：**与会话清单同源但不同周期** —— 它很少变，所以跟清单一起拉。
    // 失败只留声：拿不到目录时 picker 说"拿不到"，而不是弹四个假名字。
    await _refreshModelCatalog();
    // 权限预设目录同理（进程级，与会话无关）。失败只留声：
    // 拿不到时权限 sheet 说"拿不到目录"，而不是摆三档手抄的名字。
    await _refreshPermissionCatalog();
    // 工作区清单：会话列表**按它分组**（Web 的侧栏就是 工作区 → 会话）。
    // 失败只留声：拿不到时列表退回不分组，而不是按 `cwd` 猜一个分组。
    await refreshWorkspaces();
  }

  Future<void> _refreshPermissionCatalog() async {
    try {
      final result = await client.call<Object?>('permission.catalog', const {});
      if (_disposed) return;
      // **认不出就给 null**（`parsePermissionCatalog` 对 `available != true`
      // 与形状不对都返回 null）：界面据此说"拿不到目录"，
      // 而不是把"电脑侧没给"显示成"这台电脑没有预设"。
      setPermissionCatalog(parsePermissionCatalog(result));
    } catch (_) {
      // **兜住所有异常** —— 与 `_refreshModelCatalog` 同一条纪律。
      // 目录是附属信息，不该把"拉不到权限目录"升级成"会话列表也失败了"。
    }
  }

  /// 拉一次工作区清单（会话列表按它分组）。
  ///
  /// **拿不到就留空**（`_workspaces` 空列表）：界面退回不分组。按 `cwd` 猜分组
  /// 是第二份真值 —— `cwd` 与工作区不是一对一，猜错比不分组更难查。
  /// 方法不存在（老连接器 / 没装 `workspaceController`）与读取失败都走这条：
  /// 分组是增强，不是正确性前提。
  Future<void> refreshWorkspaces() async {
    try {
      final result = await client.call<Object?>('workspace.list', const {});
      if (_disposed) return;
      _workspaces = _parseWorkspaces(result);
      // 归档集与工作区分组**同一份应答**（`workspace.list` 带 `archivedSessionIds`）——
      // 分两次解析会让"列表看过一眼、归档集还是旧的"。
      final archived = _parseArchivedIds(result);
      if (archived != null) _archivedSids = archived;
      if (!_disposed) notifyListeners();
    } catch (_) {
      // 附属信息：不把"拉不到工作区"升级成"会话列表也失败了"。
    }
  }

  /// 工作区分组（**空列表 = 不分组**）。
  List<WorkspaceGroup> get workspaces => _workspaces;
  List<WorkspaceGroup> _workspaces = const [];

  /// 已归档的会话 sid 集合（`workspace.list` 的 `archivedSessionIds`）。
  ///
  /// 它是**列表可见性的第三个判据**（`sessionVisible`，照 DSH Web 的默认过滤档
  /// `ui-workspace/src/client/tree.ts:247-248`）。归档不是删除：手机在「归档」
  /// 列表里列它们，取消归档就回原位。
  Set<String> get archivedSids => _archivedSids;
  Set<String> _archivedSids = const {};

  /// 已归档的会话行（顺序照会话列表，不另排）。
  List<SessionSummary> get archivedSessions => [
    for (final s in sessions)
      if (_archivedSids.contains(s.sid)) s,
  ];

  /// 归档一个会话。
  ///
  /// - **不带 `stopActivity`**：有活动在跑的会话会被宿主拒（`workspace/session-active`）——
  ///   那是**信息**不是故障。调用方据此弹「停止并归档」（DSH 的 Web 就是这样：
  ///   `ui-workspace/src/client/index.ts:190-208`），带 `stopActivity: true` 重发。
  /// - 成功时把应答里的**归档全集**落进 [archivedSids]（宿主的应答就是权威值，
  ///   不本地猜）。
  ///
  /// @returns 成功与否；失败原因在 [lastError]（`code` 是 `workspace/session-active`
  /// 时该走"停止并归档"）。
  Future<bool> archiveSession(String sid, {bool stopActivity = false}) async {
    try {
      final result = await client.call<Object?>(
        'workspace.archive',
        {
          'sid': sid,
          // 只在真的要停时才带这个键：DSH 判的是 `=== true`，
          // 塞一个 false 进去是另一种语义（见 `dsh/workspaces.ts` 的注释）。
          if (stopActivity) 'stopActivity': true,
        },
        requestId: 'arc-${DateTime.now().microsecondsSinceEpoch}',
      );
      _applyArchiveSet(result);
      return true;
    } catch (error) {
      _recordError('归档失败', error);
      return false;
    }
  }

  /// 取消归档（**宿主侧幂等**：没归档过的 id 也成功）。
  Future<bool> unarchiveSession(String sid) async {
    try {
      final result = await client.call<Object?>(
        'workspace.unarchive',
        {'sid': sid},
        requestId: 'unarc-${DateTime.now().microsecondsSinceEpoch}',
      );
      _applyArchiveSet(result);
      return true;
    } catch (error) {
      _recordError('取消归档失败', error);
      return false;
    }
  }

  /// 落归档全集。**认不出就不动**：一个有损的解析会让"哪条是归档的"错位，
  /// 而错位的表现只是"列表里少了一条"，最难查的那类。
  void _applyArchiveSet(Object? result) {
    final ids = _parseArchivedIds(result);
    if (ids == null || _disposed) return;
    _archivedSids = ids;
    notifyListeners();
  }

  /// 记一次失败（与 `switchPermission` 同一条纪律：**兜住所有异常**，
  /// 不只 `ProtocolException`，别让形状不对 / 超时逃逸成未处理的异步错误）。
  void _recordError(String what, Object error) {
    _lastError = error is ProtocolException
        ? error
        : ProtocolException(ErrorCode.internal, '$what：$error');
    if (!_disposed) notifyListeners();
  }

  /// 解析归档全集（`{archivedSessionIds: [...]}`）；**形状不认识给 `null`**。
  static Set<String>? _parseArchivedIds(Object? result) {
    if (result is! Map) return null;
    final ids = result['archivedSessionIds'];
    if (ids is! List) return null;
    return ids.whereType<String>().where((s) => s.isNotEmpty).toSet();
  }

  /// 解析 `workspace.list`。认不出就给空列表（不分组）。
  static List<WorkspaceGroup> _parseWorkspaces(Object? result) {
    if (result is! Map) return const [];
    final rows = result['workspaces'];
    if (rows is! List) return const [];
    final out = <WorkspaceGroup>[];
    for (final row in rows) {
      if (row is! Map) continue;
      final id = row['workspaceId'];
      final title = row['title'];
      final ids = row['sessionIds'];
      if (id is! String || id.isEmpty) continue;
      if (title is! String || title.isEmpty) continue;
      if (ids is! List) continue;
      out.add(
        WorkspaceGroup(
          workspaceId: id,
          title: title,
          path: row['path'] is String ? row['path'] as String : '',
          // 只收非空串：一个空 sid 会让"这个会话属于谁"对不上。
          sessionIds: ids
              .whereType<String>()
              .where((s) => s.isNotEmpty)
              .toList(),
        ),
      );
    }
    return out;
  }

  Future<void> _refreshModelCatalog() async {
    try {
      final result = await client.call<Object?>(
        'session.modelCatalog',
        const {},
      );
      if (_disposed || result is! Map) return;
      if (result['available'] != true) return;
      final catalog = result['catalog'];
      if (catalog is! List) return;
      final out = <ModelRef>[];
      for (final group in catalog) {
        if (group is! Map) continue;
        final provider = group['provider'];
        if (provider is! String) continue;
        final models = group['models'];
        if (models is! List) continue;
        for (final m in models) {
          if (m is! Map) continue;
          final id = m['id'] ?? m['model'];
          if (id is! String || id.isEmpty) continue;
          out.add(ModelRef(provider: provider, model: id));
        }
      }
      setModelCatalog(out);
    } catch (_) {
      // **兜住所有异常，不只 `ProtocolException`** —— 与 `refreshSessions`
      // 同一条纪律。目录是附属信息：解析出错 / 类型不对 / 超时都不该逃逸成
      // 未处理的异步错误，更不该把"拉不到模型目录"升级成"会话列表也失败了"。
      // picker 自己会说"拿不到"。
    }
  }

  /// 某个会话此刻有几个**未决**待处理（审批/提问，从本地投影数）。
  ///
  /// 与 UI 层 `TakeoverController` 的桶同源而未连通：那里管"输入栏显示哪个"，
  /// 这里管"列表里告诉用户有几个"。**故意不合成一个** —— 数据层不认识 UI 状态机。
  int _pendingCountOf(String sid) {
    var count = 0;
    for (final item in _storeOf(sid).items) {
      if (item is ApprovalItem && !item.decided) count += 1;
    }
    return count;
  }

  /// 新建会话。
  ///
  /// **会话由电脑侧建**（它才是会话的 owner），所以这里走 `session.create`，
  /// 然后把新 sid 加进列表并打开它。
  ///
  /// 它走 `outbox`（带幂等键的写操作）：点了两次不会建出两个会话 ——
  /// 重发复用同一个 `requestId`，电脑侧去重。
  Future<void> createSession() async {
    final result = await client.call<Object?>(
      'session.create',
      const {},
      requestId: 'new-${DateTime.now().microsecondsSinceEpoch}',
    );
    final sid = result is Map ? result['sid'] : null;
    if (sid is! String || sid.isEmpty) {
      throw const ProtocolException(
        ErrorCode.internal,
        '新建会话没有返回 sid（电脑侧实现不对？）',
      );
    }
    _sessions = [
      SessionSummary(sid: sid, title: '', updatedAt: 0),
      ..._sessions.where((s) => s.sid != sid),
    ];
    if (!_disposed) notifyListeners();
    await openSession(sid);
  }

  /// 打开一个会话：订阅它，并把条目喂给 store。
  ///
  /// [since] 是本地已有的水位（本地库还没做，先给 0 = 从零开始，电脑侧会给快照）。
  Future<void> openSession(String sid, {int since = 0}) async {
    _currentSid = sid;
    if (!_disposed) notifyListeners();

    // 订阅前先把这一路的事件流接上（顺序反了会丢掉开启帧 —— 那是第一帧）。
    _deltaSubs[sid] ??= client.sessionUpdates(sid).listen((delta) {
      _onDelta(sid, delta);
    });

    try {
      await client.subscribe(sid, since: since);
      _lastError = null;
    } on ProtocolException catch (error) {
      _lastError = error;
      if (!_disposed) notifyListeners();
    }

    // 点开会话就拉一次任务清单：任务面板在这一屏里，而清单是**一次性快照**，
    // 后续变化走 `job` 帧的 `status`。失败只留声 —— 任务面板空着比
    // 整个会话打不开更可接受，而那正是"拉清单失败就抛"的后果。
    try {
      await refreshJobs(sid);
    } on ProtocolException catch (error) {
      _lastError = error;
      if (!_disposed) notifyListeners();
    }

    // 同一批只读面（统计条 / 轨迹 / 子智能体 / 交付物 / 权限档）走同一个投影读。
    await refreshProjections(sid);
  }

  /// 关闭当前会话（退订）。
  Future<void> closeSession() async {
    final sid = _currentSid;
    _currentSid = null;
    if (!_disposed) notifyListeners();
    if (sid == null) return;
    await _deltaSubs.remove(sid)?.cancel();
    try {
      await client.unsubscribe(sid);
    } on ProtocolException {
      // 退订失败不值得打扰用户：本地已经不再显示它了。
    }
  }

  void _onDelta(String sid, SessionDelta delta) {
    if (_disposed) return;
    final store = _storeOf(sid);

    // **持久事件** → 投影成界面条目 → upsert。
    // 一次恢复可能带一批：`upsertAll` 内部把通知合并成一次。
    if (delta.events.isNotEmpty) {
      final items = <ChatItem>[];
      for (final event in delta.events) {
        items.add(
          projectEvent(
            type: event.type,
            seq: event.seq,
            data: event.data,
            time: event.time,
          ).item!,
        );
        // **交互信号与条目投影同源**：两者读同一个事件，于是"对话流里有一条审批"
        // 与"输入栏上有一张审批卡"不可能对不上。
        final signal = interactionSignalOf(
          type: event.type,
          seq: event.seq,
          data: event.data,
        );
        if (signal is InteractionOpened) {
          // 信号要带上 `sid`（投影层不认识会话别名，那是这一层的事）。
          _interactions.add(InteractionOpened(_withSid(signal.item, sid)));
        } else if (signal is InteractionSettled) {
          _interactions.add(signal);
        }
      }
      store.upsertAll(items);
    }

    // **流式文本** → 单独的槽位（UI 从它读"正在生成的这段"）。
    // 它**不进 store**：没有稳定 itemId，且会被随后的持久 `assistant/message`
    // 整体替换（`app-channel-client.md` §2.2：以持久为准）。
    if (delta.liveText != null) {
      _liveText = delta.liveText;
    }

    // 会话列表里的更新时间与计数跟着动。
    _touchSummary(sid, store);
  }

  /// 当前会话的流式文本（`null` = 没有正在生成的流）。
  ///
  /// 它在持久 `assistant/message` 到达后**不清空**（那是 `core/` 的累加器负责的）——
  /// 界面按"最后一条持久消息"渲染，流式槽位只在没有持久消息时显示。
  String? get liveText => _liveText;

  String? _liveText;

  SessionStore _storeOf(String sid) =>
      _stores.putIfAbsent(sid, () => SessionStore(sid));

  /// 把投影出来的待处理项补上 `sid`（投影层不认识会话别名，那是这一层的事）。
  static InteractionItem _withSid(InteractionItem item, String sid) =>
      InteractionItem(
        itemId: item.itemId,
        sid: sid,
        callId: item.callId,
        kind: item.kind,
        title: item.title,
        detail: item.detail,
        toolName: item.toolName,
        header: item.header,
        options: item.options,
        multiSelect: item.multiSelect,
        questions: item.questions,
        approveLabel: item.approveLabel,
      );

  /// 把一次答复发给电脑（契约 §5.7 的 `interaction.respond`）。
  ///
  /// **答案批次原样转发**，一个字段都不翻译：翻译层就是漂移层（契约 §6.3.1）。
  /// 幂等键是 `i:<callId>`（§5.7 的表），所以重复点两次不会变成两次授权。
  ///
  /// 失败**照原样抛**：调用方（接管卡）要据此把那一项标成"已过期"，
  /// 而吞掉它会让用户以为答成功了 —— 答案从未进入会话。
  Future<void> respondInteraction(InteractionAnswer answer) async {
    await client.call<Object?>('interaction.respond', <String, Object?>{
      'sid': answer.sid,
      'callId': answer.callId,
      'answers': <Object?>[
        for (final item in answer.answers)
          <String, Object?>{
            'id': item.id,
            'selected': item.selected,
            if (item.custom != null) 'custom': item.custom,
          },
      ],
    }, requestId: 'i:${answer.callId}');
  }

  void _touchSummary(String sid, SessionStore store) {
    final index = _sessions.indexWhere((s) => s.sid == sid);
    final updated = SessionSummary(
      sid: sid,
      title: store.title,
      updatedAt: store.updatedAt,
      itemCount: store.length,
      pendingCount: store.pendingCount,
    );
    if (index < 0) {
      _sessions = [..._sessions, updated];
    } else {
      final next = [..._sessions];
      next[index] = updated;
      _sessions = next;
    }
    if (!_disposed) notifyListeners();
  }

  /// 解析 `session.list` 的返回。
  ///
  /// **形状是 `{ sessions: [...] }`，不是一个裸数组** —— 这是真机上"连上了却永远
  /// 没有会话"的真因：这里原先只认 `List`，而电脑侧回的是对象，
  /// 于是**每一条都被静默跳过**、列表恒为空、且不报错（用户无从分辨
  /// "电脑上真没有会话"与"我们没看懂回复"）。
  ///
  /// 判据取电脑侧：`connector/src/handlers.ts` 的 `session.list` 返回
  /// `{ sessions: [...] }`，且 `connector/tests/connection-methods.test.ts` 有多处
  /// 按 `result.sessions[…]` 断言。**两侧只有一个真值，不能各认各的形状。**
  ///
  /// Note: 这条与另外两处"线上形状不一致"一起记在
  /// `.agents/notes/implemented/2026-10-07-three-wire-shape-mismatches.md`
  static List<SessionSummary> _parseSessionList(Object? result) {
    // 对象形状是权威；裸数组也认（早期的假客户端与将来的简写都可能这么给），
    // 但**认不出就必须留声** —— 静默返回空列表正是这个 bug 藏了这么久的原因。
    final Object? raw = switch (result) {
      List() => result,
      Map() => result['sessions'],
      _ => null,
    };
    if (raw is! List) return const [];
    final out = <SessionSummary>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final sid = entry['sid'];
      if (sid is! String || sid.isEmpty) continue;
      // **标题从行的投影提示来**：`projections.values.title`。
      // 这是 DSH 自己的列表标题来源（`list.ts:291-312` 的 hints，Web 读同一个），
      // 冷行（从没打开过的会话）也有值。取不到才留空，由 [SessionSummary.displayTitle]
      // 按 DSH 的链退到项目目录名、再退到 sid。
      out.add(
        SessionSummary(
          sid: sid,
          title: _titleHintOf(entry['projections']),
          updatedAt: (entry['updatedAt'] as num?)?.toInt() ?? 0,
          // 电脑侧一直在发（`connector/src/handlers.ts` 的 `session.list`），
          // 只是手机侧此前丢掉了它 —— 而"这个会话正在跑"决定了新消息会不会被排队。
          running: entry['running'] == true,
          // 从没被 agent 跑过（`connector/src/handlers.ts` 的 `session.list` 一直在发）。
          // **挑靶子时要它**：只按 `!running` 挑会挑到"刚被别的 agent 跑完一轮"的
          // 会话，而那种会话随时可能又被唤起（真机联调两次叫醒别人的会话）。
          blank: entry['blank'] == true,
          // 子智能体的子会话：**列表可见性的一条判据**（DSH Web 同样不列它，
          // `ui-workspace/src/client/tree.ts:244`）。连接器一直在发这个标志，
          // 手机此前没解析 —— 真机上于是多列一行（Web 3 条 / 手机 4 条）。
          subagent: entry['subagent'] == true,
          // 当前模型：来自 DSH 的 `modelSelection` 投影（`connector/src/dsh/models.ts`）。
          // **认不出就不给**（`null`），界面显示"未选择"—— 猜一个就是把
          // "看起来连着"当成"连着"。
          model: _parseModelRef(entry['model']),
          // 工作区目录：电脑侧一直在发（`connector/src/handlers.ts` 的 `session.list`）。
          // **认不出就不给**（`null`）—— 空串会让"按工作区挑靶子"静默匹配失败。
          cwd: entry['cwd'] is String && (entry['cwd'] as String).isNotEmpty
              ? entry['cwd'] as String
              : null,
        ),
      );
    }
    return out;
  }

  /// 解析 `session.list` 行里的 `model` 字段。
  ///
  /// 形状与 DSH 的 `ModelSelection` 逐字一致（`{provider, model, reasoningEffort?}`）。
  /// 字段不齐就当没有 —— 一个缺 `model` 的 `ModelRef` 显示不出来，
  /// 而硬填一个空串会让界面显示一个空的模型名。
  static ModelRef? _parseModelRef(Object? raw) {
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

  /// 释放（**幂等**）。
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_stateSub?.cancel());
    unawaited(_jobSub?.cancel());
    for (final sub in _deltaSubs.values) {
      unawaited(sub.cancel());
    }
    _deltaSubs.clear();
    unawaited(_interactions.close());
    for (final store in _stores.values) {
      unawaited(store.dispose());
    }
    _stores.clear();
    super.dispose();
  }
}
