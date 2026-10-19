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
import '../model/agent_preset.dart';
import '../model/chat_item.dart';
import '../model/interaction.dart';
import '../model/model_catalog.dart';
import '../model/permission.dart';
import '../model/preferences.dart';
import '../model/queue_item.dart';
import '../model/send_mode.dart';
import '../model/session_stats.dart';
import '../model/turn_outline.dart';
import '../model/usage_summary.dart';
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
    String? rememberedEndpointUrl,
    Set<String> hiddenEndpointIds = const {},
    Set<String> succeededEndpointIds = const {},
    Future<String?> Function()? myLanIpv4Of,
    this.onRequestEndpoint,
    this.onReconnect,
    this.onEndpointsChanged,
    this.onEndpointsMetaChanged,
    this.onConnectionTerminated,
  }) : _prefs = prefs,
       _endpoints = List<Endpoint>.of(endpoints),
       _rememberedEndpointUrl = rememberedEndpointUrl,
       _hiddenEndpointIds = Set<String>.of(hiddenEndpointIds),
       _succeededEndpointIds = Set<String>.of(succeededEndpointIds),
       _myLanIpv4Of = myLanIpv4Of;

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

  /// 端点表的**附属状态**变了之后落盘（记住的那条 / 隐藏集 / 成功过的集）。
  ///
  /// 与 [onEndpointsChanged] 分开：那几个是"表格之外的路由记忆"，
  /// 而每次拨号成功都会改"记住的那条" —— 混在一起会让每拨一次就重写整张表。
  final Future<void> Function(EndpointMeta)? onEndpointsMetaChanged;

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
  ///
  /// **顺带记住它**：拨号顺序的第一优先就是"上次拨通的那条"
  /// （见 `core/endpoint.dart` 的 `dialOrder`）。同一台电脑很少换地址，
  /// 先试它最省 —— 而"换地点之后同网段优先"是它失败之后的第二手。
  void reportActiveEndpoint(Endpoint endpoint) {
    final movedOn = _activeEndpoint?.id != endpoint.id;
    _activeEndpoint = endpoint;
    final newlySucceeded = _succeededEndpointIds.add(endpoint.id);
    final memoryMoved = _rememberedEndpointUrl != endpoint.url;
    _rememberedEndpointUrl = endpoint.url;
    if (!movedOn && !newlySucceeded && !memoryMoved) return;
    notifyListeners();
    if (newlySucceeded || memoryMoved) {
      unawaited(
        onEndpointsMetaChanged?.call(endpointMeta) ?? Future<void>.value(),
      );
    }
  }

  /// 把连接器自报的端点并进表里（`endpoint.describe` 的结果）。
  ///
  /// **合并而不是覆盖**：覆盖会抹掉用户手动排的偏好序，而连接器某次少报一个
  /// （例如直连刚好在重启）就把手机里的条目删了。规则见 `core/endpoint.dart`
  /// 的 `mergeEndpoints` —— 已知的原位更新，未知的按 kind 插。
  ///
  /// **合并后剪枝**：连接器不再自报、且本机拨过并失败的条目删掉。两个条件
  /// 同时成立才删 —— ① 这次 describe 没报它（连接器是"现在有哪些地址"的
  /// 权威）；② 本机拨过且记录是失败（没拨过的可能是刚发现、还没轮到）。
  /// 只增不删的表会无限变长：连接器的 IPv6 隐私地址每次轮换都是新的一条，
  /// 旧的永远留在表里（2026-10-17 真机实测：三个拨不通的 IPv6 地址，
  /// 冷启动每个等满超时，合计 30 秒——用户原话"退出软件怎么就连不上了"）。
  Future<void> mergeDiscoveredEndpoints(List<Endpoint> discovered) async {
    // 用户藏掉的条目**不再加回来**（否则设置页的"删除"删了白删）。
    final visible = discovered
        .where((e) => !_hiddenEndpointIds.contains(e.id))
        .toList();
    final merged = mergeEndpoints(_endpoints, visible);
    final reported = visible.map((e) => e.id).toSet();

    final kept = merged.where((e) {
      if (e.manual) return true; // 用户手填的：永不自动删
      if (reported.contains(e.id)) return true; // 连接器还在报：留
      // **成功过的永不删**：它只是"此刻不在那个网络"。家里那条在公司拨不通，
      // 但它成功过 —— 回老家要靠它自动连上，而不是再扫一次码。
      if (_succeededEndpointIds.contains(e.id)) return true;
      // 剩下的只删"从没成功过 + 这次拨过并失败"（IPv6 轮换出来的旧地址）。
      return _endpointAttempts[e.id]?.ok != false;
    }).toList();

    final bounded = _boundedByCap(kept, reported);
    if (_sameEndpointTable(bounded, _endpoints)) {
      return; // 没有变化：不落盘、不通知（否则每次重连都会写一次存储）
    }
    _endpoints = bounded;
    notifyListeners();
    await onEndpointsChanged?.call(bounded);
  }

  /// 上限保险丝：条目超 [maxEndpoints] 时，从**末尾**淘汰"从没成功过、
  /// 且不是手填"的条目。
  ///
  /// 为什么是末尾：新发现的端点追加在末尾，而用户手动排在前面的顺序
  /// 是他的意图 —— 淘汰从后往前才不动它。**手填的豁免**：那是用户明确要的。
  List<Endpoint> _boundedByCap(List<Endpoint> entries, Set<String> reported) {
    if (entries.length <= maxEndpoints) return entries;
    final out = List<Endpoint>.of(entries);
    var index = out.length - 1;
    while (out.length > maxEndpoints && index >= 0) {
      final endpoint = out[index];
      final evictable =
          !endpoint.manual && !_succeededEndpointIds.contains(endpoint.id);
      if (evictable) {
        out.removeAt(index);
      }
      index -= 1;
    }
    // 全是"成功过"或"手填"的（不常见的极端）：宁可超限也不删用户要的。
    return out;
  }

  /// 两张端点表是否**完全一样**（url + label + manual；顺序也算）。
  ///
  /// 不能用 `contains`：它只比 url，于是"label 变了""manual 标记变了"
  /// 都会被当成"没有变化"而不落盘。
  bool _sameEndpointTable(List<Endpoint> a, List<Endpoint> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i += 1) {
      if (a[i].url != b[i].url ||
          a[i].label != b[i].label ||
          a[i].manual != b[i].manual ||
          a[i].kind != b[i].kind) {
        return false;
      }
    }
    return true;
  }

  /// 上限保险丝的值。用户自己的删除总是优先于它 —— 它只防"表无限变长"。
  static const int maxEndpoints = 12;

  /// 上次拨通的端点地址（`dialOrder` 的第一优先）。
  String? get rememberedEndpointUrl => _rememberedEndpointUrl;
  String? _rememberedEndpointUrl;

  /// 用户藏掉的端点 id（连接器再报也不加回来）。
  Set<String> get hiddenEndpointIds =>
      Set<String>.unmodifiable(_hiddenEndpointIds);
  final Set<String> _hiddenEndpointIds;

  /// **曾经成功过**的端点 id（不是"上次成功"，是"曾经成功"）。
  final Set<String> _succeededEndpointIds;

  /// 本机在**当前局域网**里的 IPv4（`null` = 还不知道 / 拿不到）。
  ///
  /// 拨号排序用它判"这条直连端点是不是和我同一网段"（`core/endpoint.dart`
  /// 的 `dialOrder`）。**缓存着**：真实现要调 `dart:io`，而 `dialOrder`
  /// 在同步的 `endpointsOf()` 里跑。
  String? get myLanIpv4 => _myLanIpv4;
  String? _myLanIpv4;

  /// 读本机 LAN 地址的实现（装配层注入 `platform/lan_address.dart`；
  /// `data/` 不认识 `dart:io`）。
  final Future<String?> Function()? _myLanIpv4Of;

  /// 刷新本机 LAN 地址。
  ///
  /// **在"拨不通"之后才调**（见 [reportEndpointAttempt]）：用户的原话是
  /// "连接失败才会查下自己 IP"。平时不必付这个代价，而真正需要它的那一刻
  /// ——换了地点、记住的那条拨不通—— 正好就是失败的那一拍。
  Future<void> refreshMyLanIpv4() async {
    final read = _myLanIpv4Of;
    if (read == null) return;
    String? next;
    try {
      next = await read();
    } on Object {
      return; // 读不到就是不知道（不猜），排序退化成"用户顺序"
    }
    if (next == _myLanIpv4) return;
    _myLanIpv4 = next;
    notifyListeners();
  }

  /// 端点表的附属状态（落盘用）。
  EndpointMeta get endpointMeta => EndpointMeta(
    rememberedEndpointUrl: _rememberedEndpointUrl,
    hiddenEndpointIds: _hiddenEndpointIds,
    succeededEndpointIds: _succeededEndpointIds,
  );

  // ---------------------------------------------------------------------------
  // 点名连接（与"自动队列"是两个功能）
  // ---------------------------------------------------------------------------

  /// 用户点名的端点（`null` = 走自动队列）。界面据此显示"正在按你的选择连"。
  Endpoint? get requestedEndpoint => _requestedEndpoint;
  Endpoint? _requestedEndpoint;

  /// 点名连接的结论（成功 / 失败原因）。`null` 表示没有结论（或已恢复正常）。
  EndpointRequestResult? get endpointRequestResult => _requestResult;
  EndpointRequestResult? _requestResult;

  /// 设置"下一次拨号只用这个端点"。由装配层接到 `EndpointTransport.requestEndpoint`。
  final void Function(Endpoint? endpoint)? onRequestEndpoint;

  /// 立刻重拨。由装配层接到 `SyncClient.reconnect`。
  final Future<void> Function()? onReconnect;

  /// **用这个端点立刻连接**（点名连接）。
  ///
  /// 与"设为首选"是两件事：
  /// - 首选项 = 自动队列的**顺序**，下次自动重连时影响优先级；
  /// - 点名 = **这一次就只试它**，立刻断开当前连接重拨。
  ///
  /// **失败就回到自动**（用户原话：选了就开始连，但连不上要能自动试别的）：
  /// 结果记进 [endpointRequestResult] 让界面说清"是因为什么"，然后清掉点名 ——
  /// 下一轮由连接层自己的退避 + 自动队列接管，不需要用户再点一次。
  ///
  /// @returns 这次点名是否成功（便于界面立刻给反馈）。
  Future<bool> useEndpointNow(Endpoint endpoint) async {
    final request = onRequestEndpoint;
    final reconnect = onReconnect;
    if (request == null || reconnect == null) return false;

    _requestedEndpoint = endpoint;
    _requestResult = null;
    // 先清掉这台的旧结论：不然界面会把上一次的失败当成这一次的。
    _endpointAttempts.remove(endpoint.id);
    notifyListeners();

    request(endpoint);
    try {
      await reconnect();
    } on Object {
      // 重拨失败不在这里判：连接层会把失败经 `reportEndpointAttempt` 报回来，
      // 那才是判断"通没通"的唯一依据（这里 await 到的只是"发起完了"）。
    }

    final attempt = _endpointAttempts[endpoint.id];
    final ok = attempt?.ok == true;
    _requestResult = EndpointRequestResult(
      endpoint: endpoint,
      ok: ok,
      reason: ok ? null : attempt?.reason,
    );
    // **失败即回到自动**：点名只是一次性意图，不该把用户困在"只试这一个"。
    // 成功也清：连上之后要让自动队列（记住的 / 同网段的）重新成为常态。
    _requestedEndpoint = null;
    request(null);
    notifyListeners();
    return ok;
  }

  /// 清掉点名连接的结论（用户关掉那条提示时调）。
  void clearEndpointRequestResult() {
    if (_requestResult == null) return;
    _requestResult = null;
    notifyListeners();
  }

  /// 用户手填一条端点。
  ///
  /// **地址校验由调用方做**（设置页走 `checkedRelayUri` + `isPrivateOrLoopback`）：
  /// `data/` 只存值，不判安全边界 —— 那是 `core/endpoint.dart` 的职责，
  /// 而两处各判一遍就会漂。
  Future<void> addManualEndpoint(Endpoint endpoint) async {
    final manual = endpoint.withManual(true);
    // 之前藏过的话，这次是用户明确要它 —— 顺手解除隐藏。
    _hiddenEndpointIds.remove(manual.id);
    final next = List<Endpoint>.of(_endpoints);
    final index = next.indexWhere((e) => e.id == manual.id);
    if (index >= 0) {
      next[index] = manual; // 已经是它：只把标记刷成手填
    } else {
      next.add(manual);
    }
    _endpoints = next;
    notifyListeners();
    await onEndpointsChanged?.call(next);
    await onEndpointsMetaChanged?.call(endpointMeta);
  }

  /// 删一条端点。
  ///
  /// 连接器自报的**进隐藏集**（否则下次 `describe` 又把它加回来，删了白删）；
  /// 手填的直接从表里去掉（没有"会被报回来"的问题）。
  Future<void> removeEndpoint(Endpoint endpoint) async {
    final next = _endpoints.where((e) => e.id != endpoint.id).toList();
    if (!endpoint.manual) _hiddenEndpointIds.add(endpoint.id);
    _succeededEndpointIds.remove(endpoint.id);
    _endpoints = next;
    if (_rememberedEndpointUrl == endpoint.id) _rememberedEndpointUrl = null;
    notifyListeners();
    await onEndpointsChanged?.call(next);
    await onEndpointsMetaChanged?.call(endpointMeta);
  }

  /// 把藏掉的端点放回来（设置页的"已隐藏"区用）。
  Future<void> unhideEndpoint(String id) async {
    if (!_hiddenEndpointIds.remove(id)) return;
    notifyListeners();
    await onEndpointsMetaChanged?.call(endpointMeta);
  }

  /// 拖动换位置（队列的顺序就是自动拨号的优先级）。
  ///
  /// 参数是**表下标**，且 [newIndex] 已经是"移动后的目标下标"（调用方负责把
  /// `ReorderableListView` 的"插入位置"换算成它 —— 那是个 UI 框架概念，
  /// 不该漏到这里）。越界即忽略：拖动结束时会话可能已经变了。
  Future<void> moveEndpoint(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    if (oldIndex < 0 || oldIndex >= _endpoints.length) return;
    if (newIndex < 0 || newIndex >= _endpoints.length) return;
    final reordered = List<Endpoint>.of(_endpoints);
    final moved = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, moved);
    _endpoints = reordered;
    notifyListeners();
    await onEndpointsChanged?.call(reordered);
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
    // **拨不通才去查本机 IP**：这一拍正是"换了地点、记住的那条不通"的时刻，
    // 而下一轮重连的 `dialOrder` 需要新网段才能把同网段那条排上来。
    if (!attempt.ok) unawaited(refreshMyLanIpv4());
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
      // **标题也在这个包里**（`title` 投影，DSH `session-title/src/index.ts:269-281`
      // 的 wire view 就是 `string | null`）。它是比 `session.list` 的投影提示
      // **更新**的那个来源：会话刚生成标题时列表提示还是旧的。
      // 只在非空时落——空值表示"还没有标题"，不该把列表提示擦掉。
      final title = result['title'];
      if (title is String && title.isNotEmpty) _applySessionTitle(sid, title);
      // 收件箱播种：插话判定要从此前的 splice 历史推出来，而投影里的
      // next-turn / next-step 列表正是那个历史的当前值。
      _seedInboxTracker(sid);
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
  /// 手机就算不出 Web 上那个 `75 tok/s`；`ttftMs` / `ttftSteps`
  /// 是统计 sheet 里 TTFT 那一行的来源。
  SessionStats? get sessionStats {
    final raw = _projections?['sessionStats'];
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

  /// 轮次大纲（`turnOutline` 投影，wire view 是 `[{turn, seq, prompt, response}]`）。
  ///
  /// 形状逐字对应 DSH 的 `session-turn-outline/src/projection.ts:61-75`
  /// （`turnOutlineEntriesSchema`）。**轨迹页的账本用它**：一轮一行，
  /// `prompt` 是用户那句的预览、`response` 是助手回复的预览。
  ///
  /// 拿不到（没这个投影 / 形状不对）就是空表 —— 轨迹页显示空态，
  /// 不造一份假的（2026-10-15 删掉 `_sampleRows` 的理由）。
  List<TurnOutlineEntry> get turnOutline {
    final raw = _projections?['turnOutline'];
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

  /// 上下文三段分段（`contextBreakdown` 投影，wire view 就是三项）。
  ///
  /// **启发式估算**（DSH 的文件头原话 "Heuristic composition"）——
  /// 界面照 Web 标 `~`。三项全 0 时当没有（那与"没有这个投影"在界面上
  /// 同一表现：上下文 sheet 只画百分比条，不画分段图例）。
  ContextBreakdown? get contextBreakdown {
    final raw = _projections?['contextBreakdown'];
    if (raw is! Map) return null;
    final breakdown = ContextBreakdown(
      systemTokens: _intOf(raw['systemTokens']),
      toolsTokens: _intOf(raw['toolsTokens']),
      messageTokens: _intOf(raw['messageTokens']),
    );
    return breakdown.total == 0 ? null : breakdown;
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

  /// 打断：取消当前轮次但**保留待处理收件箱**。
  ///
  /// 走 `session.cancel`（与 Web 同一个 DSH 方法，`@Remote('cancel')`，
  /// `session-controller/src/index.ts:472`）。DSH 的注释原话是"Cancel one
  /// active Agent turn without dropping its pending inbox"—— 排队中的消息
  /// 不会被这一次取消丢掉，所以它安全地当"停止"用。
  /// **不带幂等键**（契约 §5.7 那一列是空的）：取消没有第二次副作用。
  ///
  /// @returns 成功与否；失败原因在 [lastError]。
  Future<bool> cancel(String sid) async {
    try {
      await client.call<Object?>('session.cancel', {'sid': sid});
      return true;
    } on ProtocolException catch (error) {
      _lastError = error;
      if (!_disposed) notifyListeners();
      return false;
    }
  }

  // ---- 排队消息（`inbox` 投影的 next-turn 段）----

  /// 当前会话排队中的消息（**按 sid 取**：投影包是最近一次读的那个会话的）。
  ///
  /// 队列**不是新方法** —— 它是 `inbox` 投影的一段，随 `session.projections`
  /// 到手机（契约 §5.7 已把 `inbox` 列进核实过的键）。插进当前轮次的
  /// `next-step` 段不列（Web 同一条：那已经生效了，不在队列里）。
  List<QueueItem> queueOf(String sid) {
    if (_currentSid != sid) return const [];
    return parseQueueItems(_projections?['inbox']);
  }

  /// 变异一个排队项（编辑 / 删除 / 插话）。
  ///
  /// 走 `session.updateQueue`（与 Web 排队 dock 同一个 DSH 方法）。
  /// **成功失败都重读一次投影**：队列变化不走投影推送（它乘
  /// `agent/inbox/spliced` 会话事件到手机，而投影只在打开会话时读一次），
  /// 所以不重读就要等下次开会话才变。失败时重读同样必要 ——
  /// `session/steer-unavailable` / `session/queue-item-not-found` 的语义
  /// 正是"队列已经变了，刷新"。
  ///
  /// @returns 成功与否；失败原因在 [lastError]。
  Future<bool> updateQueue(
    String sid,
    String itemId,
    QueueActionKind kind, {
    String? text,
  }) async {
    try {
      await client.call<Object?>(
        'session.updateQueue',
        {
          'sid': sid,
          'itemId': itemId,
          'action': switch (kind) {
            QueueActionKind.edit => {
              'kind': 'edit',
              'content': [
                {'type': 'text', 'text': text ?? ''},
              ],
            },
            QueueActionKind.remove => {'kind': 'remove'},
            QueueActionKind.steer => {'kind': 'steer'},
          },
        },
        requestId: 'q-${DateTime.now().microsecondsSinceEpoch}',
      );
      return true;
    } on ProtocolException catch (error) {
      _lastError = error;
      if (!_disposed) notifyListeners();
      return false;
    } finally {
      // 成功失败都重读：见方法头。`_disposed` 时 `refreshProjections` 自己早退。
      await refreshProjections(sid);
    }
  }

  // ---- 插话判定（DSH `SteeringHistory` 的忠实移植）----

  /// 每个会话的收件箱追踪器（`sid → tracker`）。
  ///
  /// **为什么需要它**：一条 `user/message` 是不是"插话"（轮次跑到一半从
  /// next-step 收件箱插进去的），只看它自己看不出来 —— 判据在它前面的
  /// `agent/inbox/spliced` 事件里。DSH Web 用的是同一个算法
  /// （`ui-chat/src/client/model/steering-history.ts`）：从 next-step 里
  /// **被 claim 掉**的 id，随后作为 `user/message` 到达时就是插话。
  final Map<String, _InboxTracker> _inboxTrackers = {};

  /// 打开会话时用投影里的当前收件箱播种追踪器（否则恢复会漏掉早先的 splice）。
  void _seedInboxTracker(String sid) {
    final inbox = _projections?['inbox'];
    if (inbox is! Map) return;
    _inboxTrackers
        .putIfAbsent(sid, () => _InboxTracker())
        .seed(Map<String, Object?>.from(inbox));
  }

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

  /// 会话列表。**标题只有电脑侧一个来源**：`session.list` 行的投影提示
  /// （`projections.values.title`），打开会话后再由 `title` 投影与会话事件流里的
  /// `session/title` 更新（见 [_applySessionTitle]）。
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

  /// 模型目录（`session/modelCatalog`，DSH `buildModelCatalog` 的真形状解析）。
  ///
  /// **拿不到就是 null** —— 手机显示"未选择"，不手抄第二份名单
  /// （2026-10-15 之前 picker 里是四个写死的模型名）。
  /// 2026-10-17 修：解析器原来认的是一个臆想形状（`List<{provider, models}>`），
  /// 而真形状是 `{default, routableProviders, groups, failures}` —— 顶层是对象，
  /// 于是目录在生产里**一次都没解析成功过**。详见 `model/model_catalog.dart` 文件头。
  ModelCatalog? get modelCatalog => _modelCatalog;
  ModelCatalog? _modelCatalog;

  /// 当前会话的模型（`modelSelection` 投影，`next ?? lastUsed`）。
  ModelRef? get currentModel {
    final sid = _currentSid;
    if (sid == null) return null;
    return sessionOf(sid)?.model;
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
  /// **与列表逐字同一条链**（[SessionSummary.displayTitle]：投影提示标题 →
  /// 「未命名」）。顶栏与列表必须是同一个字符串——2026-10-15 的真机反馈
  /// ("名字对了，但我点进去会话名字又变了"）就是两个真值源（列表读提示、
  /// 顶栏读本地从条目推导的标题）各自算出不同名字。
  ///
  /// 2026-10-16 把最后的本地推导兜底也删了：`displayTitle` 永不为空
  /// （最差也是「未命名」），所以"兜底"只在会话不在 `_sessions` 里时生效 ——
  /// 而那时它给出的是一个**列表里看不见的名字**，正是分叉的由来。
  /// 会话不在列表里（刚建还没刷新）时顶栏显示 null，由界面退到 'DSH'。
  String? get currentTitle {
    final sid = _currentSid;
    if (sid == null) return null;
    return _sessions.where((s) => s.sid == sid).firstOrNull?.displayTitle;
  }

  /// 连接状态（界面视图）。
  ConnectionStateView get connection => _connection;

  /// 最近一次错误。
  ProtocolException? get lastError => _lastError;

  /// 当前会话的变更流（UI 用它做**区块级**重建，而不是整页 setState）。
  Stream<List<ChatItem>> changesOf(String sid) => _storeOf(sid).changes;

  /// 某个会话投影失败的事件（`sid → 第一条失败的原因`）；`null` = 没失败过。
  ///
  /// **必须暴露到界面**：逐条隔离之后，一条坏事件不再炸掉整批，但它也不该
  /// 无声无息地少掉 —— 空态/对话页据此说出"有 N 类事件没能渲染"，
  /// 而不是让用户以为"会话里就没有这些"。
  String? projectionFailureOf(String sid) => _projectionFailures[sid];

  final Map<String, String> _projectionFailures = {};

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
    // 其余本地偏好（工作步骤展示 / 性能与用量）同一条路。
    await _restorePreferences();
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

  // ---- 手机本地的界面偏好（DSH 的"纯 UI 偏好"，有意偏离存本地）----

  TranscriptView _transcriptView = TranscriptView.standard;
  PerformanceUsage _performanceUsage = PerformanceUsage.detailed;

  TranscriptView get transcriptView => _transcriptView;
  PerformanceUsage get performanceUsage => _performanceUsage;

  /// 落盘的 meta 键：偏好类。**契约两端共用的字符串**，改动等于作废用户的偏好。
  static const String kTranscriptViewKey = 'transcript_view';
  static const String kPerformanceUsageKey = 'performance_usage';

  /// 切工作步骤展示密度。落盘；同一个值重复切是空操作。
  Future<void> setTranscriptView(TranscriptView view) async {
    if (_disposed || view == _transcriptView) return;
    _transcriptView = view;
    notifyListeners();
    await _prefs?.write(kTranscriptViewKey, view.wire);
  }

  /// 切性能与用量的详细程度。落盘；同一个值重复切是空操作。
  Future<void> setPerformanceUsage(PerformanceUsage usage) async {
    if (_disposed || usage == _performanceUsage) return;
    _performanceUsage = usage;
    notifyListeners();
    await _prefs?.write(kPerformanceUsageKey, usage.wire);
  }

  // ---- 跨会话用量汇总（`usage.summary`，只读）----

  /// 汇总数据；`null` = 还没拉过 / 拉失败。
  UsageSummary? get usageSummary => _usageSummary;
  UsageSummary? _usageSummary;

  /// 拉一次跨会话用量汇总。
  ///
  /// **只读、不落盘**：它是"此刻的总量"，而总量随时在变（别的客户端也在跑），
  /// 落一份本地快照只会多一个会过期的第二真值源。设置页 / 统计条每次进入时拉。
  ///
  /// 拿不到就回 `null` 并把原因留在 [lastError]：手机显示"拉不到"，
  /// 而不是摆一个 `0 tok` —— 那会把"没数据"说成"用了 0"。
  Future<void> refreshUsageSummary() async {
    try {
      final result = await client.call<Object?>('usage.summary', const {});
      _usageSummary = UsageSummary.fromWire(result);
      _lastError = null;
    } on ProtocolException catch (error) {
      _usageSummary = null;
      _lastError = error;
    }
    if (!_disposed) notifyListeners();
  }

  /// 读一个**通用字符串偏好**（`meta` 表的 k/v）。
  ///
  /// 存在的理由：主题模式这一类偏好由 `ThemeController` 持真值
  /// （`model/theme_mode.dart`），而它不该认识 `AppModel`；反过来
  /// `AppModel` 也不该认识每一种偏好。所以缝是"读一个字符串 / 写一个字符串"，
  /// 装配点（`main.dart`）把 `ThemeController` 接到这上面。
  Future<String?> readPreference(String key) =>
      _prefs?.read(key) ?? Future.value(null);

  /// 写一个**通用字符串偏好**（upsert）。
  Future<void> writePreference(String key, String value) async {
    await _prefs?.write(key, value);
  }

  /// 把落盘的偏好读回来（`start()` 里调一次）。
  ///
  /// 读不到（没存过 / 存了个不认识的值）就保持默认 —— 与发送模式同一条纪律，
  /// **不猜**。
  Future<void> _restorePreferences() async {
    final transcript = TranscriptView.fromWire(
      await _prefs?.read(kTranscriptViewKey),
    );
    if (transcript != null) _transcriptView = transcript;
    final performance = PerformanceUsage.fromWire(
      await _prefs?.read(kPerformanceUsageKey),
    );
    if (performance != null) _performanceUsage = performance;
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
    // Agent 预设目录（hero 上那枚模式 chip 的名字来源）。同样只留声：
    // 拿不到时 chip 说"拿不到目录"，而不是摆一份手抄的四个内置预设。
    await _refreshAgentPresets();
    // **落到 blank 会话上**（照 DSH 的 `reuseOrCreateBlank`，见该方法的注释）。
    await _openBlankSessionIfUnselected();
  }

  /// 没有选中会话时，落到"那个 blank 会话"上。
  ///
  /// ## 为什么要有这一步
  ///
  /// DSH Web 的首页**不是"没有会话"，是"已有会话但它是 blank"**
  /// （`ui-conversation/src/client/skeleton/ConversationMainPanel.tsx:41-43` 的
  /// `hero` 两个来源，实际走的是后者：`shellPhase === 'blank' && openState === 'open'`），
  /// 而那个 blank 会话是**工作区连上时被急切创建**的
  /// （`ui-workspace/src/client/navigation.ts:195-205` 的 `reuseOrCreateBlank()`）。
  /// 手机这边没有这一步 —— 于是"连上电脑后落到的第一屏"是**列表**，
  /// 而那个 blank 会话因为 `sessionVisible`（`ui-workspace/src/client/tree.ts:245`）
  /// 把"blank 且非当前"藏掉，用户在手机上根本看不到它、也就永远看不到 hero。
  ///
  /// 所以：**选中它**（不新建 —— 电脑侧已经有一个了，`session.create` 只会多造一个）。
  /// 挑不到 blank 时就什么都不做：那时列表是空的或全是跑过的会话，
  /// 主界面照旧显示内联列表 / 空态，与 DSH 的"冷启动没有会话"同一个形态。
  ///
  /// Note: 为什么必须有这一步（blank 会话在列表里是藏起来的）与被否方案 —— 见
  /// `.agents/notes/implemented/2026-10-17-blank-session-hero.md`。
  Future<void> _openBlankSessionIfUnselected() async {
    if (_disposed || _isPreview) return;
    if (_currentSid != null) return;
    final blank = _sessions.where((s) => s.blank && !s.subagent).firstOrNull;
    if (blank == null) return;
    await openSession(blank.sid);
  }

  Future<void> _refreshAgentPresets() async {
    try {
      final result = await client.call<Object?>('agentPresets.list', const {});
      if (_disposed) return;
      // **认不出就给 `available:false`**（`parseAgentPresetRoster` 对
      // `available != true` 与形状不对都这么回）：界面据此说"拿不到预设目录"，
      // 而不是把"电脑侧没给"显示成"这台电脑一个预设都没有"。
      _agentPresetRoster = parseAgentPresetRoster(result);
      if (!_disposed) notifyListeners();
    } catch (_) {
      // **兜住所有异常** —— 与 `_refreshPermissionCatalog` 同一条纪律：
      // 目录是附属信息，不该把"拉不到预设目录"升级成"会话列表也失败了"。
    }
  }

  /// Agent 预设目录（`agentPresets.list`）；没拉过是 `null`。
  AgentPresetRoster? get agentPresetRoster => _agentPresetRoster;
  AgentPresetRoster? _agentPresetRoster;

  /// 当前会话跑的是哪个预设（`agentPreset` 投影的 `string | null`）。
  ///
  /// **`null` 就是"这个会话没记过预设"**（老会话，或这台电脑没有预设服务）——
  /// 界面退回"按目录里的默认项显示"或显示 id，不猜一个档。
  String? get agentPresetValue {
    if (_currentSid == null) return null;
    return parseAgentPresetValue(_projections);
  }

  /// 当前会话归属的工作区；`null` = 清单里没有它（或清单还没到）。
  WorkspaceGroup? get currentWorkspace {
    final sid = _currentSid;
    if (sid == null) return null;
    return workspaceGroupOf(sid, _workspaces);
  }

  /// 当前会话是不是 blank（"从没被 agent 跑过"）。
  ///
  /// 用它决定主界面显示 hero 还是空态。**会话不在列表里时是 `false`**
  /// （刚 `session.create` 出来、`session.list` 还没刷到时）—— 那时宁可少显示一次 hero，
  /// 也不要把"不知道"当成"blank"（DSH 对不知道的字段一律不给，同一条纪律）。
  bool get currentIsBlank {
    final sid = _currentSid;
    if (sid == null) return false;
    return sessionOf(sid)?.blank ?? false;
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
      // **按 DSH 的真形状解析**（`{available, catalog:{default, routableProviders,
      // groups, failures}}`，`packages/api/session-controller/src/catalog.ts:20-72`）。
      // 认不出（含 `available: false`）就留 null —— picker 说"拿不到目录"，
      // 而不是摆一个空列表。
      final catalog = parseModelCatalog(result);
      if (catalog == _modelCatalog) return;
      _modelCatalog = catalog;
      if (!_disposed) notifyListeners();
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
  ///
  /// [workspaceId] / [agentPreset] 是 hero 上那两枚 chip 的选择：
  /// **不给就一个字段都不塞**（DSH 对缺省字段有自己的当前工作区与默认预设，
  /// 见 `connector/src/handlers.ts` 的 `session.create`）——
  /// 硬传一个猜的值比不传更糟。
  ///
  /// 选预设走这里而不是 `agentPresets.select`：后者对**跑过一轮**的会话会拒
  /// （`agent-preset/locked`，`agent-preset-registry/src/index.ts:351`），
  /// 而建会话时带上根本不会碰到那条限制。取舍见
  /// `.agents/notes/implemented/2026-10-17-blank-session-hero.md`。
  Future<void> createSession({String? workspaceId, String? agentPreset}) async {
    final result = await client.call<Object?>('session.create', {
      // 显式 `if` 而不是 null-aware element（`?key: value`）：后者的 key
      // 取的是**值的字符串形式**而不是标识符（2026-10-15 踩到，
      // 详见 `selectModel` 的注释）。`dart analyze` 会反过来建议改过去，别听。
      // ignore: use_null_aware_elements
      if (workspaceId != null) 'workspaceId': workspaceId,
      // ignore: use_null_aware_elements
      if (agentPreset != null) 'agentPreset': agentPreset,
    }, requestId: 'new-${DateTime.now().microsecondsSinceEpoch}');
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

  /// 往前翻一页历史（UI 滚到顶时调）。
  ///
  /// ## 为什么需要它
  ///
  /// 电脑侧只给**一个窗口**（DSH 的 `DEFAULT_MAX_MESSAGES = 50`，
  /// `history.ts:38`），而 `session.subscribe` 的回包一直在说
  /// "还有更早的历史"（`connector/src/session-subscriptions.ts:80-85`）。
  /// 早期手机侧把那个回包丢了、也没有 `session.page`，于是
  /// **"历史上明明有 20 轮，手机上只看到最近 3 轮"**。
  ///
  /// ## 规则照 DSH Web
  ///
  /// `client/sessions/session.ts:405` 的原话："Prepend one Turn-aligned page:
  /// at least 50 messages and two Turn starts, capped at 500 messages."
  /// 窗口参数在 `SyncClient` 的常量里（`kHistoryPage*`）。
  ///
  /// ## 翻到的条目怎么落
  ///
  /// **走与 `_onDelta` 同一条投影路径**（不是另写一份）：这样"翻页拿到的历史"
  /// 与"订阅快照拿到的历史"渲染规则完全一致，不会两套。
  ///
  /// 返回是否真的翻到了新条目（UI 用它决定要不要再翻一次）。
  Future<bool> loadOlderHistory(String sid) async {
    if (_loadingOlder.contains(sid)) return false;
    if (!client.hasOlderHistory(sid)) return false;
    final store = _storeOf(sid);
    // 切点 = 当前最早一条的 seq。**没有条目时不翻**（那说明快照还没到，
    // 此时翻只会拿到同一窗口）。
    final earliest = store.items.isEmpty ? null : store.items.first.seq;
    if (earliest == null) return false;

    _loadingOlder.add(sid);
    try {
      final page = await client.page(sid: sid, beforeSeq: earliest);
      if (page.failure != null) {
        // **失败不当成"没有更多"**：`session/window-missed` 的契约动作是
        // 「重新订阅走快照」（§3.1）。这里只留声，让用户手动重进会话。
        _historyFailure[sid] = page.failure!;
        if (!_disposed) notifyListeners();
        return false;
      }
      // **翻到的页也带 `hasMore`**：电脑侧在每一页都告诉还有没有更早的。
      // 它由连接层收着（`SyncClient.hasOlderHistory`），这里只清失败标记。
      _historyFailure.remove(sid);
      if (page.events.isEmpty) return false;

      // 与 `_onDelta` 同一条路径：逐条投影、逐条隔离、upsert 进 store。
      final items = <ChatItem>[];
      for (final event in page.events) {
        try {
          final projected = projectEvent(
            type: event.type,
            seq: event.seq,
            data: event.data,
            time: event.time,
            previous: store.byId(event.itemId),
          );
          items.addAll(projected.items);
        } on StateError catch (error) {
          _projectionFailures[sid] = '${event.type}(seq=${event.seq})：$error';
        }
      }
      store.upsertAll(items);
      if (!_disposed) notifyListeners();
      return true;
    } finally {
      _loadingOlder.remove(sid);
    }
  }

  /// 这个会话还有没有更早的历史（`sync.hello` 的应答）。
  ///
  /// **问连接层**：anchor 的来源是 `sync.hello` 的批量应答
  /// （`connector/src/handlers.ts:767` 起），那里每个 sid 都带 `hasMore`。
  bool get hasOlderHistory {
    final sid = _currentSid;
    return sid != null && client.hasOlderHistory(sid);
  }

  /// 翻页失败的原因（`session/window-missed` 等）；`null` = 没失败。
  String? get historyFailure {
    final sid = _currentSid;
    return sid == null ? null : _historyFailure[sid];
  }

  /// 正在翻页的会话集（同一会话不并发翻 —— 两次并发会拿到同一页）。
  final Set<String> _loadingOlder = <String>{};

  /// `sid → 翻页失败的原因`。
  final Map<String, String> _historyFailure = <String, String>{};

  // Note: 逐条错误隔离（一条坏事件不再炸掉整批）+ 插话判定（DSH
  // SteeringHistory 的移植）—— 见
  // .agents/notes/implemented/2026-10-17-conversation-rendering-fills-dsh-gaps.md
  void _onDelta(String sid, SessionDelta delta) {
    if (_disposed) return;
    final store = _storeOf(sid);

    // **持久事件** → 投影成界面条目 → upsert。
    // 一次恢复可能带一批：`upsertAll` 内部把通知合并成一次。
    if (delta.events.isNotEmpty) {
      final items = <ChatItem>[];
      var inboxChanged = false;
      final tracker = _inboxTrackers.putIfAbsent(sid, () => _InboxTracker());
      // **本批已投影的条目**（itemId → 条目）：`tool/call` 与 `tool/result`
      // 可能在同一个 delta 里先后到达，而 `store.upsertAll` 在循环之后才发生 ——
      // 那时结果要找的"前一个条目"还没落表。所以前一个值按
      // "本批优先、落表兜底"取（DSH 的 `update(context, match)` 同样是
      // 在同一个 Context 里滚动状态，不是回到库里查）。
      final inBatch = <String, ChatItem>{};
      // **`turn/start` 的时刻与 seq**（按轮次号记）：`turn/end` 算"这一轮
      // 用了多久"要时刻（DSH 同处 `turn.end.time - turn.start.time`），
      // 数"这一轮有多少条消息/工具"要 seq 区间。两者都只在本批内有效 ——
      // 跨批的 `turn/start`（历史翻页落在窗口外）让 `turn/end` 拿不到，
      // 那时用时说"不到 1 秒"、计数为 0，而不是猜一个数。
      final turnStarts = <int, ({int time, int seq})>{};
      for (final event in delta.events) {
        // **`session/title` 不是条目，是标题的真值**：DSH 生成/改名时落一条
        // （`session-title/src/index.ts` 的 fold 就认这个 type）。它进条目表
        // 只会渲染出一条莫名其妙的"其它事件"，所以在这里截住并落地成标题。
        if (event.type == 'session/title') {
          final title = event.data is Map ? (event.data as Map)['title'] : null;
          if (title is String && title.isNotEmpty) {
            _applySessionTitle(sid, title);
          }
          continue;
        }
        // **`agent/inbox/spliced` 是排队队列的变化**：消息进/出队列时落一条
        // （真日志里常见）。条目表里它是一条不可见的"其它事件"，而**排队条
        // 要跟着变** —— 投影不推这件事（它只在打开会话时读一次），
        // 所以在这里记一笔，循环结束后重读投影。
        if (event.type == 'agent/inbox/spliced') {
          if (event.data is Map) {
            tracker.applySplice(Map<String, Object?>.from(event.data as Map));
          }
          inboxChanged = true;
          continue;
        }
        // **`turn/start` 落一条不可见的记账条目**（`OtherItem`）。
        //
        // 它是"这一轮开始了"的边界，而界面上的那一行是 `turn/end` 时的
        // 过程摘要（DSH 的 turn-process 也正是挂在轮次末尾，
        // `TurnProcessNodeView.tsx:18` 要求 `turn.status === 'closed'`）。
        //
        // **但必须落表**：`turn/start` 与 `turn/end` 常常不在同一个 delta
        // 批次里（翻页/快照加载时前者在更早的批次），只在本批内记一张
        // `turnStarts` 表的话，过程摘要的用时与计数会**永远是 0** ——
        // 2026-10-19 真机看到的现象正是"每条收口都只说'不到 1 秒'"。
        // 落成 OtherItem 后，`_turnStatsOf` 能从 store 里翻到它。
        if (event.type == 'turn/start') {
          final turn = event.data is Map ? (event.data as Map)['turn'] : null;
          if (turn is int) {
            turnStarts[turn] = (time: event.time, seq: event.seq);
            items.add(
              OtherItem(
                itemId: event.itemId,
                seq: event.seq,
                updatedAt: event.time,
                eventType: 'turn/start',
              ),
            );
          }
          continue;
        }
        // **逐条投影，一条不再炸掉整批**：`itemIdOf` 对"已知类型缺身份字段"
        // 是抛 StateError 的（契约 §5.2 的硬规则），而这里若让它逃逸，
        // 整个 delta 的条目全部丢失 —— 症状是"会话打开了但一条消息都不渲染"，
        // 且没有任何报错（流监听里的未处理异步错误）。失败的那条记进
        // [_projectionFailures]，剩下的照常渲染。
        try {
          // **`turn/end` 专用的两个入参**：该轮 `turn/start` 的时刻（算用时）
          // 与该轮已收录条目的计数。投影层是纯函数，不认识"哪些条目属于这一轮"，
          // 所以由这一层数好给进来。
          //
          // **本批优先、落表兜底**：`turn/start` 与 `turn/end` 常常不在同一个
          // delta 批次里（翻页 / 快照加载时前者在更早的批次）。只靠本批的话，
          // 过程摘要的用时与计数会永远是 0 —— 所以本批没有就回 store 里翻
          // 那条 `OtherItem`（`turn/start` 落表用的）。
          final turnStart = event.type == 'turn/end'
              ? _turnStartOf(turnStarts, store, event.data, event.seq)
              : null;
          final projection = projectEvent(
            type: event.type,
            seq: event.seq,
            data: event.data,
            time: event.time,
            steering:
                event.type == 'user/message' &&
                tracker.claimIfSteering(event.data),
            // **upsert 的前一个值**：`tool/result` 要靠它把工具名与参数
            // 从 `tool/call` 继承过来（DSH `rootResult(match, previous)`，
            // 真日志里结果消息不带名字）。投影层自己是纯函数，所以
            // "前一个条目是什么"由这一层给。
            previous: inBatch[event.itemId] ?? store.byId(event.itemId),
            turnStartTime: turnStart?.time,
            turnStats: event.type == 'turn/end'
                ? _turnStatsOf(store, inBatch, turnStart?.seq, event.seq)
                : null,
          );
          // **`skip` 不是失败**：`turn/end` 的 completed / 用户主动 aborted
          // 这类"没有异常就不占条目"的事件走这支（DSH 同处也是无行）。
          // 早期这里写 `.item!`，于是 skip 会抛 `null check` 错误 ——
          // 而它是 `Error` 不是 `StateError`，下面的 catch 接不住，
          // 直接炸掉整个流监听（症状：会话打开后一条新消息都不进来）。
          if (projection.items.isEmpty) continue;
          // **一个事件可能产出多条**（`turn/end` 同时给过程摘要与异常结局，
          // DSH 同处也是两个独立节点）。`inBatch` 只记单条目事件的前一个值
          // —— 多条那几条的 id 由投影层自己定（`p:$turn` / `e:$turn`），
          // 不参与 upsert 配对。
          for (final projected in projection.items) {
            inBatch[projected.itemId] = projected;
            items.add(projected);
          }
        } on StateError catch (error) {
          _projectionFailures[sid] = '${event.type}(seq=${event.seq})：$error';
        }
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
      if (inboxChanged) {
        // 队列变了：重读一次投影拿新队列（`inbox` 段）。不等它 ——
        // 收帧路径上的回调不该被一个网络往返挡住。
        unawaited(refreshProjections(sid));
      }
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

  /// `turn/end` 载荷里的轮次号（取不到是 null）。
  static int? _turnOf(Object? data) =>
      data is Map && data['turn'] is int ? data['turn'] as int : null;

  /// 该轮 `turn/start` 的 `(time, seq)`；**本批优先、落表兜底**。
  ///
  /// 为什么要有兜底：`turn/start` 与 `turn/end` 常常不在同一个 delta 批次里
  /// （翻页 / 快照加载时前者在更早的批次），那时本批那张表是空的。
  /// 落表的那条是 `OtherItem(eventType: 'turn/start')`，所以这里靠
  /// **seq 小于 `turn/end` 的最后一条**认它 —— 同轮只可能有一条
  /// `turn/start`（DSH 的格式不变量：turn 号递增），所以"最后一条"就是它。
  static ({int time, int seq})? _turnStartOf(
    Map<int, ({int time, int seq})> turnStarts,
    SessionStore store,
    Object? endData,
    int endSeq,
  ) {
    final turn = _turnOf(endData);
    if (turn == null) return null;
    final inThisBatch = turnStarts[turn];
    if (inThisBatch != null) return inThisBatch;
    ({int time, int seq})? found;
    for (final item in store.items) {
      if (item is! OtherItem || item.eventType != 'turn/start') continue;
      if (item.seq >= endSeq) continue;
      if (found == null || item.seq > found.seq) {
        found = (time: item.updatedAt, seq: item.seq);
      }
    }
    return found;
  }

  /// 数一轮的过程统计（DSH 的 `TurnProcessSpec` 那三个计数）。
  ///
  /// ## 为什么在这里数，而不是投影层
  ///
  /// 投影层是**纯函数**（只认识一条事件），而"哪些条目属于这一轮"要读条目表。
  /// DSH 同处由 turn 状态机推（`contract/turn-process.ts`），手机没有那个
  /// 状态机，但有条目表 —— 数它等价。
  ///
  /// ## `turn/start` 从哪儿来
  ///
  /// **本批优先、落表兜底**（`turnStarts` → store 里的 `OtherItem`）。
  /// 只靠本批是不够的：`turn/start` 与 `turn/end` 常常不在同一个 delta
  /// 批次里（翻页 / 快照加载时前者在更早的批次），那时本批那张表是空的，
  /// 而过程摘要的用时与计数会**永远是 0**（2026-10-19 真机复现：
  /// 每条收口都只说"不到 1 秒"）。
  ///
  /// ## 数的是什么
  ///
  /// - **消息** = 带回复的助手消息（`MessageRole.assistant`）；
  /// - **工具** = `ToolCallItem`（不含子智能体委派）；
  /// - **子智能体** = 工具名是 `subagent` 或 `subagent_` 前缀的调用
  ///   （DSH `isSubagentDelegationTool`，`contract/turn-process.ts:44-46`）。
  ///
  /// ## 区间
  ///
  /// `[turn/start.seq, turn/end.seq]`。**`turn/start` 找不到时返回全 0**
  /// （连它都没有，说明这一轮的开始不在已加载的窗口里）——
  /// 区间不明就不数，与"拿不到就不显示"同一条纪律（0 项在
  /// `TurnProcessItem.stats` 里不列，不会摆出"0 条消息 · 0 次工具"）。
  static ({int messages, int tools, int subagents}) _turnStatsOf(
    SessionStore store,
    Map<String, ChatItem> inBatch,
    int? startSeq,
    int endSeq,
  ) {
    if (startSeq == null) return (messages: 0, tools: 0, subagents: 0);
    var messages = 0;
    var tools = 0;
    var subagents = 0;
    // **本批优先、落表兜底**：同一条目可能两处都有（`tool/call` 在本批、
    // 更早的 `tool/result` 在表里），按 itemId 去重后各计一次。
    final seen = <String>{};
    for (final item in [...inBatch.values, ...store.items]) {
      if (!seen.add(item.itemId)) continue;
      if (item.seq < startSeq || item.seq > endSeq) continue;
      if (item is MessageItem && item.role == MessageRole.assistant) {
        messages += 1;
      } else if (item is ToolCallItem) {
        if (_isSubagentDelegation(item.name)) {
          subagents += 1;
        } else {
          tools += 1;
        }
      }
    }
    return (messages: messages, tools: tools, subagents: subagents);
  }

  /// 这次工具调用是不是**子智能体委派**（DSH 的 `isSubagentDelegationTool`）。
  ///
  /// 判据逐字照 DSH（`contract/turn-process.ts:44-46`）：名字是 `subagent`
  /// 或以 `subagent_` 开头。控制类工具（`send_message` / `list_agents`）
  /// **不算** —— DSH 的原注释把这两类分开列。
  static bool _isSubagentDelegation(String name) =>
      name == 'subagent' || name.startsWith('subagent_');

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

  // Note: 标题只有一个真值源（电脑侧），这里只换计数不重建整行 ——
  // 见 .agents/notes/implemented/2026-10-17-session-title-single-source-of-truth.md
  void _touchSummary(String sid, SessionStore store) {
    final index = _sessions.indexWhere((s) => s.sid == sid);
    // **只换计数，不重建整行**：标题 / 模型 / running / blank / subagent / cwd
    // 全部是电脑侧给的身份字段，掉一个就是"点进会话名字变了、模型变未选择"。
    // 会话不在列表里（刚建还没刷新）时给一行空壳——它随后会被
    // `session/title` 事件或下一次 `session.list` 补上真标题。
    final base = index >= 0
        ? _sessions[index]
        : SessionSummary(sid: sid, title: '', updatedAt: 0);
    final updated = base.withCounters(
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

  /// 把电脑侧给的标题落进列表行。**同一个值不重复通知**。
  ///
  /// 两个来源都通向这里：`session.projections` 的 `title` 投影（打开会话时读）
  /// 与会话事件流里的 `session/title`（DSH 生成/改名时落一条，看着会话也能更新）。
  /// 空串不落——它会把已有标题擦成「未命名」，而投影的 `null` 只表示"还没有标题"。
  void _applySessionTitle(String sid, String title) {
    final index = _sessions.indexWhere((s) => s.sid == sid);
    if (index < 0) return;
    final current = _sessions[index];
    if (current.title == title) return;
    final next = [..._sessions];
    next[index] = current.withTitle(title);
    _sessions = next;
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
      // 这是 host 侧 `session.list` 行唯一的标题来源（`dsh-api-session-controller`
      // 的 `lib/types/types.d.ts`：行只有 `projections`，没有独立的持久标题字段），
      // Web 侧栏读的"持久标题"远程客户端拿不到——契约如此，不是将就。
      // 取不到就留空，由 [SessionSummary.displayTitle] 显示「未命名」
      // （DSH 的 Web 侧栏对无标题会话不用目录名兜底，`ui-workspace/README.zh.md:32`）。
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

/// 收件箱追踪器：从 `agent/inbox/spliced` 事件流里认出**插话**消息。
///
/// **逐字移植 DSH Web 的 `SteeringHistory`**
/// （`packages/client/ui-chat/src/client/model/steering-history.ts`）：
///
/// - 维护 next-turn / next-step 两个列表（`splice(start, removedCount, ...inserted)`）；
/// - 从 **next-step 被 claim 掉**（splice 的 removed 部分）的 id 进候选集；
/// - 插入会把 id 从候选集去掉；
/// - 随后到达的 `user/message` 带候选 id 且 `source.kind === 'user'` → 插话。
///
/// 为什么不猜"running 期间的用户消息就是插话"：排队发送的消息也是运行期间
/// 到达的，而它**不是**插话（它排下一个轮次）。判据只有这一个，猜就会把
/// 排队消息标成插话。
class _InboxTracker {
  final Map<String, List<String>> _lists = {
    'next-turn': <String>[],
    'next-step': <String>[],
  };

  final Set<String> _claimedNextStep = <String>{};

  /// 用投影里的当前收件箱播种（恢复/打开会话时调一次）。
  void seed(Map<String, Object?> inbox) {
    for (final target in const ['next-turn', 'next-step']) {
      final rows = inbox[target];
      if (rows is! List) continue;
      _lists[target] = [
        for (final row in rows)
          if (row is Map && row['id'] is String) row['id'] as String,
      ];
    }
  }

  /// 应用一条 splice 事件。
  void applySplice(Map<String, Object?> data) {
    final target = data['target'];
    final start = data['start'];
    if (target is! String || start is! int) return;
    final list = _lists[target];
    if (list == null) return;
    final removedCount = data['removedCount'];
    final count = removedCount is int ? removedCount : 0;
    final inserted = <String>[
      for (final item
          in data['inserted'] is List ? data['inserted'] as List : const [])
        if (item is Map && item['id'] is String) item['id'] as String,
    ];
    // 与 DSH 同一条算术：从 `start` 处删 `count` 个、插入 `inserted`。
    final safeStart = start.clamp(0, list.length);
    final safeEnd = (safeStart + count).clamp(safeStart, list.length);
    final removed = list.sublist(safeStart, safeEnd);
    list
      ..removeRange(safeStart, safeEnd)
      ..insertAll(safeStart, inserted);
    // 插入的 id 不再是被 claim 的候选。
    for (final id in inserted) {
      _claimedNextStep.remove(id);
    }
    // **只有从 next-step 被 claim 掉的才是插话候选**；取消的 splice 不算。
    if (target != 'next-step' || data['outcome'] == 'canceled') return;
    _claimedNextStep.addAll(removed);
  }

  /// 一条 `user/message` 是不是插话（**会消费掉那个候选**，与 DSH 的 delete 同义）。
  bool claimIfSteering(Object? data) {
    if (data is! Map) return false;
    final id = data['id'];
    if (id is! String || id.isEmpty) return false;
    if (!_claimedNextStep.remove(id)) return false;
    final source = data['source'];
    return source is Map && source['kind'] == 'user';
  }
}
