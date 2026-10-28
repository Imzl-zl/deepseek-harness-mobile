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

import 'package:flutter/foundation.dart' show ChangeNotifier, visibleForTesting;

import '../core/connection.dart';
import '../core/endpoint.dart';
import '../core/errors.dart';
import '../core/job.dart';
import '../core/notify.dart';
import '../core/sync_client.dart';
import '../model/agent_preset.dart';
import '../model/changes.dart';
import '../model/chat_item.dart';
import '../model/command.dart';
import '../model/file_diff.dart';
import '../model/file_open.dart';
import '../model/image_limits.dart';
import '../model/interaction.dart';
import '../model/mention.dart';
import '../model/model_catalog.dart';
import '../model/permission.dart';
import '../model/plugins.dart';
import '../model/preferences.dart';
import '../model/queue_item.dart';
import '../model/send_mode.dart';
import '../model/session_stats.dart';
import '../model/subagent.dart';
import '../model/trajectory.dart';
import '../model/turn_outline.dart';
import '../model/usage_summary.dart';
import '../model/workspace.dart';
import '../model/workspace_files.dart';
import '../wire/rpc/changes.dart' as wire;
import '../wire/rpc/command.dart' as wire;
import '../wire/rpc/endpoint.dart' as wire;
import '../wire/rpc/file.dart' as wire;
import '../wire/rpc/interaction.dart' as wire;
import '../wire/rpc/job.dart' as wire;
import '../wire/rpc/permission.dart' as wire;
import '../wire/rpc/plugin.dart' as wire;
import '../wire/rpc/projections.dart' as wire;
import '../wire/rpc/refs.dart' as wire;
import '../wire/rpc/repo.dart' as wire;
import '../wire/rpc/session.dart' as wire;
import '../wire/rpc/settings.dart' as wire;
import '../wire/rpc/usage.dart' as wire;
import '../wire/rpc/workspace.dart' as wire;
import 'endpoint_book.dart';
import 'file_preview.dart';
import 'host_catalogs.dart';
import 'ids.dart';
import 'item_derivations.dart';
import 'projection.dart';
import 'session_rows.dart';
import 'session_store.dart';
import 'store.dart';
import 'ui_state.dart';

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
    NotifyPort? notify,
  }) : _prefs = prefs,
       _notify = notify,
       _initialEndpoints = List<Endpoint>.of(endpoints),
       _initialRememberedEndpointUrl = rememberedEndpointUrl,
       _initialHiddenEndpointIds = Set<String>.of(hiddenEndpointIds),
       _initialSucceededEndpointIds = Set<String>.of(succeededEndpointIds),
       _myLanIpv4Of = myLanIpv4Of;

  /// 通道客户端（连接 / 订阅 / 写操作的唯一 owner）。
  final SyncClient client;

  /// 偏好缝（`meta` 表的窄接口）；`null` = 不落盘（测试 / 未装配）。
  final PreferenceStore? _prefs;

  /// 宿主侧只读目录面（模型 / 权限 / Agent 预设）。
  ///
  /// 三类目录同形（一次只读请求 → 解析 → 缓存 → getter），收窄计划的**第一簇**
  /// （`.agents/notes/proposed/2026-10-27-appmodel-narrowing.md`）。
  /// 这里只建一次；`onChange` 走守卫过的 `notifyListeners`。
  /// 条目列表的派生表（改动清单 / 每轮产出 / 收口助手 / 提及表）。
  ///
  /// 只依赖条目列表，所以能纯 Dart 构造；收窄计划第二簇
  /// （`.agents/notes/proposed/2026-10-27-appmodel-narrowing.md`）。
  late final ItemDerivations _derivations = ItemDerivations(() => items);

  late final HostCatalogs _catalogs = HostCatalogs(
    client: client,
    onChange: () {
      if (!_disposed) notifyListeners();
    },
  );

  /// 设备本地 UI 状态的唯一缝（`data/ui_state.dart`）。
  ///
  /// `null` = 这个宿主没装配（单测里常见）。**所有 `device.*` / `host.*` 的读写都经它**，
  /// 页面不许自己拼键名；未装配时各 getter 退到"无持久化"的默认值。
  UiStateStore? get uiState => _uiState;
  UiStateStore? _uiState;

  /// 每会话页签（内存缓存，`sid → viewId`）。落盘由 [UiStateStore] 负责。
  final Map<String, String?> _views = <String, String?>{};

  /// 通知与后台保活的端口（`core/notify.dart` 的接口，实现在 `platform/`）。
  ///
  /// `null` = 这个宿主没有通知能力（测试 / 未装配）—— 所有通知路径直接跳过，
  /// **不做假成功**。
  final NotifyPort? _notify;

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

  /// 端点簿（表 + 附属路由记忆）。**唯一所有者**，本类只转发。
  ///
  /// 搬出去的理由与判据集中在 `data/endpoint_book.dart` 的文件头；
  /// 行为钉子见 `app/test/endpoint_book_test.dart`。
  final List<Endpoint> _initialEndpoints;
  final String? _initialRememberedEndpointUrl;
  final Set<String> _initialHiddenEndpointIds;
  final Set<String> _initialSucceededEndpointIds;

  /// 读本机 LAN 地址的实现（装配层注入 `platform/lan_address.dart`；
  /// `data/` 不认识 `dart:io`）。
  final Future<String?> Function()? _myLanIpv4Of;

  late final EndpointBook _endpointsBook = EndpointBook(
    endpoints: _initialEndpoints,
    rememberedEndpointUrl: _initialRememberedEndpointUrl,
    hiddenEndpointIds: _initialHiddenEndpointIds,
    succeededEndpointIds: _initialSucceededEndpointIds,
    myLanIpv4Of: _myLanIpv4Of,
    onTableChanged: onEndpointsChanged,
    onMetaChanged: onEndpointsMetaChanged,
    onChange: () {
      if (!_disposed) notifyListeners();
    },
  );

  /// 有序端点表。**序即偏好**：`connect()` 按这个顺序拨，第一个通的赢。
  ///
  /// 它的所有者是 [EndpointBook]（界面要读、设置页要改），而拨号方
  /// （`platform/transport_factory.dart` 经 `EndpointTransport`）每次
  /// `connect()` 现读它 —— 所以"发现了一条直连"立刻生效，不用重启 App。
  List<Endpoint> get endpoints => _endpointsBook.endpoints;

  /// 当前拨通的那个端点（`null` = 还没连上）。
  ///
  /// 由装配层把 `EndpointTransport.onActivated` 接到这里。
  Endpoint? get activeEndpoint => _endpointsBook.activeEndpoint;

  /// 报一次"这条连接走的是哪个端点"。
  ///
  /// **顺带记住它**：拨号顺序的第一优先就是"上次拨通的那条"
  /// （见 `core/endpoint.dart` 的 `dialOrder`）。同一台电脑很少换地址，
  /// 先试它最省 —— 而"换地点之后同网段优先"是它失败之后的第二手。
  void reportActiveEndpoint(Endpoint endpoint) =>
      _endpointsBook.reportActiveEndpoint(endpoint);

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
  Future<void> mergeDiscoveredEndpoints(List<Endpoint> discovered) =>
      _endpointsBook.mergeDiscoveredEndpoints(discovered);

  /// 上限保险丝的值。用户自己的删除总是优先于它 —— 它只防"表无限变长"。
  static const int maxEndpoints = EndpointBook.maxEndpoints;

  /// 上次拨通的端点地址（`dialOrder` 的第一优先）。
  String? get rememberedEndpointUrl => _endpointsBook.rememberedEndpointUrl;

  /// 用户藏掉的端点 id（连接器再报也不加回来）。
  Set<String> get hiddenEndpointIds => _endpointsBook.hiddenEndpointIds;

  /// 本机在**当前局域网**里的 IPv4（`null` = 还不知道 / 拿不到）。
  ///
  /// 拨号排序用它判"这条直连端点是不是和我同一网段"（`core/endpoint.dart`
  /// 的 `dialOrder`）。**缓存着**：真实现要调 `dart:io`，而 `dialOrder`
  /// 在同步的 `endpointsOf()` 里跑。
  String? get myLanIpv4 => _endpointsBook.myLanIpv4;

  /// 刷新本机 LAN 地址（**在"拨不通"之后才调**，见 `EndpointBook`）。
  Future<void> refreshMyLanIpv4() => _endpointsBook.refreshMyLanIpv4();

  /// 端点表的附属状态（落盘用）。
  EndpointMeta get endpointMeta => _endpointsBook.endpointMeta;

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
    _endpointsBook.clearAttempt(endpoint.id);
    notifyListeners();

    request(endpoint);
    try {
      await reconnect();
    } on Object {
      // 重拨失败不在这里判：连接层会把失败经 `reportEndpointAttempt` 报回来，
      // 那才是判断"通没通"的唯一依据（这里 await 到的只是"发起完了"）。
    }

    final attempt = _endpointsBook.attemptOf(endpoint);
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

  /// 用户手填一条端点（地址校验由调用方做，见 `EndpointBook`）。
  Future<void> addManualEndpoint(Endpoint endpoint) =>
      _endpointsBook.addManualEndpoint(endpoint);

  /// 删一条端点（自报的进隐藏集，手填的直接去掉）。
  Future<void> removeEndpoint(Endpoint endpoint) =>
      _endpointsBook.removeEndpoint(endpoint);

  /// 把藏掉的端点放回来（设置页的"已隐藏"区用）。
  Future<void> unhideEndpoint(String id) => _endpointsBook.unhideEndpoint(id);

  /// 拖动换位置（队列的顺序就是自动拨号的优先级）。
  ///
  /// 参数是**表下标**，且 [newIndex] 已经是"移动后的目标下标"（调用方负责把
  /// `ReorderableListView` 的"插入位置"换算成它 —— 那是个 UI 框架概念，
  /// 不该漏到这里）。
  Future<void> moveEndpoint(int oldIndex, int newIndex) =>
      _endpointsBook.moveEndpoint(oldIndex, newIndex);

  /// 手动挑一个端点当首选（设置页用）。**只改顺序，不删条目**。
  Future<void> preferEndpoint(Endpoint endpoint) =>
      _endpointsBook.preferEndpoint(endpoint);

  /// 某个端点**最近一次拨号**的结果（没有记录就没有结论 —— 不猜、不探测）。
  EndpointAttempt? attemptOf(Endpoint endpoint) =>
      _endpointsBook.attemptOf(endpoint);

  /// 记一次拨号结果（由传输层报事实，见 `EndpointBook`）。
  void reportEndpointAttempt(Endpoint endpoint, EndpointAttempt attempt) =>
      _endpointsBook.reportEndpointAttempt(endpoint, attempt);

  // ---------------------------------------------------------------------------
  // 会话投影（`session.projections`，契约 §5.7）—— 一个方法打开全部只读面
  // ---------------------------------------------------------------------------

  /// 最近一次读到的投影包（`null` = 还没读过 / 读不到）。
  ///
  /// **类型是解码结果，不是裸 map**：14 个键的键名与类型只在
  /// `wire/rpc/projections.dart` 里出现一次（`SessionProjections`），
  /// 各面拿字段而不是 `values['x']`。连接器原样透传整包（不挑键）这一点没变，
  /// 挑键发生在解码层（那一层正好是"知道线上形状"的那一层）。
  wire.SessionProjections? _projections;

  /// 这一包是**哪个会话**的。
  ///
  /// 投影包没有版本号也没有会话字段（`session.projections` 的应答就是 `values`），
  /// 所以"它属于谁"只能在这里记。**换会话的那一刻**（新包还没落地）以及
  /// 新会话**读失败**时，都不许再把上一包当成当前的 —— 那会让统计条 / token /
  /// 权限档显示上一个会话的数字（真机上就是"进了子会话，数字还是父会话的"）。
  String? _projectionsSid;

  /// 当前会话的投影包；**不匹配就当作没有**（见 [_projectionsSid]）。
  wire.SessionProjections? get projections =>
      _projectionsSid == _currentSid ? _projections : null;

  /// 读一次投影。**点开会话时调**（与 `refreshJobs` 同一步）。
  ///
  /// 失败只留声：投影读不到时那些只读面显示空态，而"整个会话打不开"更糟。
  Future<void> refreshProjections(String sid) async {
    final values = await _readProjections(sid, what: '读取会话投影失败');
    if (values == null) return;
    _applyProjectionValues(sid, values);
  }

  /// 重读投影，但**同一会话不并发**（在飞那次跑完后补一次）。
  ///
  /// 为什么要有这一层：`turn/end` 与"队列变了"经常挤在同一批事件里，
  /// 两条信号直接各发一次 `session.projections` 会**两个应答乱序落地** ——
  /// 后到的旧包会把先到的新包盖掉（投影包没有版本号可比，手机上分不出
  /// 谁更新）。合并成"在飞 + 攒一次"就只有一个应答会落地。
  void _refreshProjectionsOnce(String sid) {
    if (_disposed) return;
    if (!_projectionRefresh.add(sid)) {
      // 在飞：只记一笔，由那次收尾时兑现（连来十次也只补一次）。
      _projectionRefreshQueued.add(sid);
      return;
    }
    unawaited(
      refreshProjections(sid).whenComplete(() {
        _projectionRefresh.remove(sid);
        if (_projectionRefreshQueued.remove(sid)) _refreshProjectionsOnce(sid);
      }),
    );
  }

  /// 正在飞投影重读的会话。
  final Set<String> _projectionRefresh = <String>{};

  /// 在飞期间又要求重读一次的会话。
  final Set<String> _projectionRefreshQueued = <String>{};

  /// 只重读一个会话的**子智能体目录**（展开子级时的懒加载）。
  ///
  /// DSH 的 catalog 投影**只含直接子级**
  /// （`packages/subagent/subagent/src/catalog.ts:111-131`：
  /// "current direct-child rows in parent catalog event order"），
  /// 所以树是"直接子级 + 按需展开"，展开哪一级才读哪一级 ——
  /// 与 Web 的 `toggleBranch(childSessionId)` → `refreshProjection(child)`
  /// 同一条（`SubagentHeaderLineage.tsx:570-577`）。
  /// **不新增方法面**：读的还是 `session.projections`。
  ///
  /// 与 [refreshProjections] 的差别只有一处：当前会话之外，这里**不写**
  /// `_projections`（那一包是当前会话的统计条 / 标题 / 权限档的来源，
  /// 被某个子会话的投影覆盖会让统计条显示别人的数字）。
  Future<void> refreshSubagentCatalog(String sid) async {
    final values = await _readProjections(sid, what: '读取子智能体目录失败');
    if (values == null) return;
    _applyProjectionValues(sid, values);
  }

  /// 读一个会话的投影值包，**顺带把 `subagentCatalog` 落进目录三态**。
  ///
  /// 返回 `null` = 这次没读到（失败已记进 [lastError]，目录进 `error` 态）。
  ///
  /// ## 为什么读之前先置 `loading`
  ///
  /// "还没读到"与"读到空"在界面上必须是两句话：前者要等，后者要换地方找。
  /// Web 的判据在同一处（`SubagentHeaderLineage.tsx:465-467` 把 `idle` 当
  /// `loading`；`:212` 只在 `loading` **且 entries 空**时显示"正在加载"）。
  /// 置 `loading` 时**保留上一次的 entries** —— 刷新不闪空（同 Web `:244-245`）。
  Future<wire.SessionProjections?> _readProjections(
    String sid, {
    required String what,
  }) async {
    if (_disposed) return null;
    _subagentCatalogs[sid] = SubagentCatalog.loading(
      entries: _subagentCatalogs[sid]?.entries ?? const [],
    );
    if (!_disposed) notifyListeners();
    try {
      final values = await wire.loadSessionProjections(client, sid: sid);
      if (_disposed) return null;
      if (values == null) {
        // **形状不对也是失败**，不是"没有子智能体" —— 静默当空会让
        // "这台电脑没装 subagent 插件"与"我们没看懂回复"分不开。
        // （形状错已经在 `wire/rpc/projections.dart` 计过数了，这里只落错误态。）
        _subagentCatalogs[sid] = const SubagentCatalog.failed();
        _recordError(
          what,
          const FormatException('session.projections 的应答不是对象'),
        );
        return null;
      }
      _subagentCatalogs[sid] = SubagentCatalog.ready(values.subagentCatalog);
      return values;
    } catch (error) {
      // **兜住所有异常，不只 `ProtocolException`**（与 `refreshSessions` 同一条纪律）：
      // 解析出错 / 类型不对 / 超时都只该让"这一批只读面显示空态"，
      // 逃逸成未处理的异步错误会让 `openSession` 半途而废 ——
      // 症状是"会话打开了但统计条/权限档永远空着且不报错"。
      _subagentCatalogs[sid] = const SubagentCatalog.failed();
      _recordError(what, error);
      return null;
    }
  }

  /// 把一次成功的投影读落进各面。
  ///
  /// **`_projections` 只写当前会话**：它是"当前会话那一包"（统计条 / 标题 /
  /// 权限档 / 队列的来源）。别名会话（子智能体）的投影覆盖它会让统计条
  /// 显示别人的数字 —— 2026-10-21 之前正是无条件覆盖的
  /// （笔记 §2.1 的既有缺陷）。
  void _applyProjectionValues(String sid, wire.SessionProjections values) {
    if (sid == _currentSid) {
      _projections = values;
      _projectionsSid = sid;
      // 收件箱播种：插话判定要从此前的 splice 历史推出来，而投影里的
      // next-turn / next-step 列表正是那个历史的当前值。
      _seedInboxTracker(sid);
    }
    // **标题也在这个包里**（`title` 投影）。它是比 `session.list` 的投影提示
    // **更新**的那个来源：会话刚生成标题时列表提示还是旧的。
    // 只在非空时落——空值表示"还没有标题"，不该把列表提示擦掉。
    final title = values.title;
    if (title != null && title.isNotEmpty) _applySessionTitle(sid, title);
    if (!_disposed) notifyListeners();
  }

  // ---- 统计条（`tokenUsage` / `contextPressure` / `sessionStats` 三个投影）----

  /// token 用量。**认不出就是 null**，不猜 —— 猜一个就是把
  /// "看起来连着"当成"连着"。
  TokenUsage? get tokenUsage => projections?.tokenUsage;

  /// 会话统计（`sessionStats` 投影）。
  ///
  /// 字段与投影的 wire view 逐字对应
  /// （`packages/session/session-stats/src/projection.ts:72-81`）——
  /// `decodeMs` / `decodeTokens` 是输出速率的唯一来源，缺了它
  /// 手机就算不出 Web 上那个 `75 tok/s`；`ttftMs` / `ttftSteps`
  /// 是统计 sheet 里 TTFT 那一行的来源。
  SessionStats? get sessionStats => projections?.sessionStats;

  /// 轮次大纲（`turnOutline` 投影，wire view 是 `[{turn, seq, prompt, response}]`）。
  ///
  /// 形状逐字对应 DSH 的 `session-turn-outline/src/projection.ts:61-75`
  /// （`turnOutlineEntriesSchema`）。**轨迹页的账本用它**：一轮一行，
  /// `prompt` 是用户那句的预览、`response` 是助手回复的预览。
  ///
  /// 拿不到（没这个投影 / 形状不对）就是空表 —— 轨迹页显示空态，
  /// 不造一份假的（2026-10-15 删掉 `_sampleRows` 的理由）。
  List<TurnOutlineEntry> get turnOutline =>
      projections?.turnOutline ?? const [];

  /// 轨迹时间轴（`trajectory` 投影）。
  ///
  /// **手机一个时间减法都不做**：每轮 / 每步的 `durationMs` 由电脑侧折好
  /// （连接器 `src/dsh/trajectory.ts`），这一层只认形状（`model/trajectory.dart`）。
  /// 2026-10-22 之前 `data/projection.dart` 拿同一批事件在本批内做减法，
  /// 跨批（`turn/start` 在更早一页）就退化成"不到 1 秒" —— 那一处已删除。
  ///
  /// 返回 `null` = **这台电脑没给时间轴**（键缺席 / 形状不对）；空视图 =
  /// 给了但还没有轮。界面上这是两句不同的话。
  ///
  /// 解析已在 `wire/rpc/projections.dart` 做过（随那一包一起解），
  /// **按包缓存为了"换包才重算"**：`identical` 判断的是"这一包换没换"。
  TrajectoryView? get trajectory {
    final source = projections;
    if (identical(source, _trajectorySource)) return _trajectory;
    _trajectorySource = source;
    _trajectory = source?.trajectory;
    return _trajectory;
  }

  wire.SessionProjections? _trajectorySource;
  TrajectoryView? _trajectory;

  /// 某一轮的时间轴（对话流的过程摘要读它取用时）。
  ///
  /// 取不到就是 `null` —— 界面照"用时未知"渲染，不补零、不估。
  TrajectoryTurn? trajectoryTurnOf(int turn) => trajectory?.turnOf(turn);

  /// 上下文三段分段（`contextBreakdown` 投影，wire view 就是三项）。
  /// **启发式估算**（DSH 的文件头原话 "Heuristic composition"）——
  /// 界面照 Web 标 `~`。三项全 0 时当没有（那与"没有这个投影"在界面上
  /// 同一表现：上下文 sheet 只画百分比条，不画分段图例）。
  ContextBreakdown? get contextBreakdown => projections?.contextBreakdown;

  /// 上下文占用压力（`contextPressure` 投影）。三个字段都没有就是 `null`。
  ///
  /// `contextWindow` 是**分母**：没有它"占了多少"无解，而 Web 的
  /// `ContextMeter` 同样在只有分子时不渲染。
  ContextPressure? get contextPressure => projections?.contextPressure;

  // ---- 权限档（`permission.catalog` 目录 + `permissions` 投影的当前值）----

  /// 权限预设目录（`permission.catalog`，原样过线）。
  ///
  /// **拿不到就是 null** —— 手机显示"拿不到目录"，不摆三档手抄的名字
  /// （2026-10-15 之前输入栏的权限档正是三个写死的枚举值）。
  /// 预设表是**部署可配**的（DSH `bundle/base/cordis.patch.yml:262-271`），
  /// 手抄一份就是第二份真值。
  PermissionCatalog? get permissionCatalog => _catalogs.permissionCatalog;

  /// 当前会话的权限档（`permissions` 投影的 `currentValue`）。
  ///
  /// **认不出就是 null**：投影没注册（这台电脑没装权限插件）与
  /// "这一帧没有这个键"是同一件事，而正确表现都是"不知道"——
  /// 界面显示空态，不猜一个档位。
  ///
  /// 不另判 `_currentSid == null`：`projections` getter 判的就是**这一包属于谁**，
  /// 没选中会话时它必然给 null（`_projections` 与 `_projectionsSid` 同批写）。
  String? get permissionValue => projections?.permissionValue;

  /// 图片附件的**宿主上限**（`imageLimits` 投影）。
  ///
  /// `null` = 这一包没有这个键（老连接器没注册投影 / 还没读到）⇒
  /// **不前置拦**，靠 DSH 自己的拒绝码（`IMAGES_TOO_LARGE` / `TOO_MANY_IMAGES`）。
  /// 由来与"为什么手机不写死这些数"见 `model/image_limits.dart` 的文件头。
  DshImageLimits? get imageLimits => projections?.imageLimits;

  /// 存一份预设目录（连接器 `permission.catalog` 的应答）。转发给 [HostCatalogs]。
  void setPermissionCatalog(PermissionCatalog? catalog) =>
      _catalogs.setPermissionCatalog(catalog);

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
  Future<CommandOutcome?> switchPermission(String preset) async {
    final sid = _currentSid;
    if (sid == null) return null;
    try {
      // 方法名、参数形状与`{matched, execution?}` 的回执都在 `wire/rpc/permission.dart`。
      final switched = await wire.switchPermissionPreset(
        client,
        sid: sid,
        preset: preset,
        requestId: newRequestId('perm'),
      );
      if (switched == null) {
        // 回执认不出：**如实报错**，别让界面读上一条错误（`_commandOutcomeOf` 的旧账）。
        _recordError('切换权限档失败', StateError('电脑侧的命令应答形状认不出'));
        return null;
      }
      if (_disposed) return null;
      if (switched.succeeded) await refreshProjections(sid);
      return switched;
    } catch (error) {
      // **兜住所有异常，不只 `ProtocolException`**（与 `refreshSessions`
      // 同一条纪律）：解析出错 / 形状不对 / 超时都不该逃逸成未处理的异步错误。
      _recordError('切换权限档失败', error);
      return null;
    }
  }

  /// 跑一条斜杠命令（`command.execute`）。
  ///
  /// **与 Web 同一个 DSH 方法**：`commands.execute`
  /// （`packages/interaction/commands/src/index.ts:360` 的 `@Remote`），Web 侧
  /// `SessionFace.command(line)` 落到 `remote.commands.execute(sessionId, line, [])`
  /// （`session-controller/src/client/sessions/session.ts:388`）。
  ///
  /// 参数是 `{sid, line}`：**`agentId` 由连接器从 `sid` 解析**（Typert 的线上键是
  /// `agentId`，见 `tools.md` 铁律①），手机不传 agent id。附件恒为空数组 ——
  /// 这一版命令不随附件发送（契约 §5.7）。
  ///
  /// @returns 电脑侧的结论；`null` = 这次没跑成（原因在 [lastError]）。
  /// `matched == false` **不是失败**：那是"电脑上没这条命令"（DSH 的 `execute`
  /// 回 `undefined`），调用方按 Web 的同一条推导退成普通消息（`model/command.dart`）。
  Future<CommandOutcome?> executeCommand(String line) async {
    final sid = _currentSid;
    if (sid == null) return null;
    try {
      // 方法名 / 参数形状 / 回执形状都在 `wire/rpc/command.dart`。
      final outcome = await wire.executeCommand(
        client,
        sid: sid,
        line: line,
        requestId: newRequestId('cmd'),
      );
      if (outcome == null) {
        // 形状认不出也要留声：只回 null 的话，调用方读到的 lastError 会是上一条错误。
        _recordError('执行命令失败', StateError('电脑侧的命令应答形状认不出'));
        return null;
      }
      return outcome;
    } catch (error) {
      _recordError('执行命令失败', error);
      return null;
    }
  }

  // ---- 子智能体（`subagentCatalog` 投影）----

  /// 每个会话读到的目录结论（sid → 三态 + 内容）。
  final Map<String, SubagentCatalog> _subagentCatalogs = {};

  /// 一个会话的子智能体目录（**直接子级**，带加载 / 就绪 / 失败三态）。
  ///
  /// 没读到过 ⇒ `loading`：Web 把 `idle` 与 `loading` 视为同一个可见状态
  /// （`SubagentHeaderLineage.tsx:465-467`）。**空表不等于"没有子智能体"** ——
  /// 要判空得看 `state == ready`（`SubagentCatalog.isKnownLeaf`），
  /// 否则"没读到"会被说成"没有"。
  SubagentCatalog subagentCatalogOf(String sid) =>
      _subagentCatalogs[sid] ?? const SubagentCatalog.loading();

  /// 在**已读到的目录**里找 [sid] 这一行，返回它所在的父级 sid（找不到 = `null`）。
  ///
  /// **只服务 `chat_page.dart` 的 `_subagentParentSid` 第 2 档**：进入子会话时父级
  /// 由画出那一行的那一层交出（DSH 的 `openChild(address)`，见
  /// `SubagentHeaderLineage.tsx:279-287`），只有"恢复出来的子会话 + 老连接器"
  /// （行里没有 `parentSessionId`）才需要回头扫目录。DSH 同一条：拿不到
  /// `address.parentSessionId` 时才扫所有已加载的 catalog
  /// （`SubagentHeaderLineage.tsx:790-797` 的 `projectionsBySession` 那一圈）。
  ///
  /// **只扫已读到的**：`subagentCatalogOf` 对没读过的会话返回 `loading` 占位，
  /// 拿它扫是白扫。扫不到就如实返回 `null`，由调用方退到下一档 —— 不猜、
  /// 也不为找父级发起一轮网络请求。
  String? subagentParentOfCatalogEntry(String sid) {
    for (final entry in _subagentCatalogs.entries) {
      // 自引用：畸形投影里"自己是自己的子级"会让 `←` 原地重进自己。
      if (entry.key == sid) continue;
      if (entry.value.state != SubagentCatalogState.ready) {
        // 失败/加载中的目录不算证据：它们的 `entries` 是上一次的内容
        // （刷新不闪空，见 [_readProjections]），拿它认父级会认到旧关系上。
        continue;
      }
      if (entry.value.entries.any((row) => row.id == sid)) return entry.key;
    }
    return null;
  }

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
      await wire.cancelSession(client, sid: sid);
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
    // **两个条件不是同一件事**：这里判"调用方问的是谁"，`projections` getter 判
    // "这一包属于谁"（`_projectionsSid == _currentSid`）。少了这一行，问别的会话
    // 会拿到当前会话的队列（`queue_dock_test.dart` 的"队列按 sid 取"盯着它）。
    if (_currentSid != sid) return const [];
    return parseQueueItems(projections?.inbox);
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
      await wire.updateQueueAction(
        client,
        sid: sid,
        itemId: itemId,
        action: switch (kind) {
          QueueActionKind.edit => {
            'kind': 'edit',
            'content': [
              {'type': 'text', 'text': text ?? ''},
            ],
          },
          QueueActionKind.remove => {'kind': 'remove'},
          QueueActionKind.steer => {'kind': 'steer'},
        },
        requestId: newRequestId('q'),
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
    final inbox = projections?.inbox;
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
    // 形状（`{jobs: [...]}` 与一行任务）在 `wire/rpc/job.dart`。
    final rows = await wire.loadJobList(client, sid: sid);
    if (_disposed || rows == null) return;
    _mergeJobSnapshot(sid, rows);
    notifyListeners();
  }

  /// 把一次 `job.list` 快照并进桶里。
  ///
  /// 判据（**终态单向**）只有一份：`core/job.dart` 的 [mergeJobSnapshot]。
  /// 这里只负责"桶"（哪个会话）与"通知"，不重复规则本身 —— 快照与 `status`
  /// 推送会赛跑（请求早于完成、回来晚于推送），两条写路径必须共用同一条规则，
  /// 否则下一次只会修好一条（2026-10-26 评审）。
  void _mergeJobSnapshot(String sid, List<JobRow> rows) {
    _jobs[sid] = mergeJobSnapshot(_jobs[sid] ?? const <JobRow>[], rows);
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
      // **应答不读**：开流的作用在服务端，输出走 `job` 帧。
      await wire.followJobOutput(client, sid: sid, jobId: jobId);
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
      await wire.unfollowJobOutput(client, sid: sid, jobId: jobId);
    } on ProtocolException catch (error) {
      _jobErrors[jobId] = error.message;
    }
    notifyListeners();
  }

  /// 停一个任务。**走宿主的人类发起门面**，返回电脑侧的结论。
  Future<String?> killJob(String sid, String jobId) async {
    try {
      return await wire.killJob(client, sid: sid, jobId: jobId);
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
      // **同一份合并规则**：终态单向（`core/job.dart` 的 [mergeJobRow]）。
      // 推送路径也曾漏过这条 —— 一条迟到的 `status` 帧会把已结束的任务改回 running。
      final merged = mergeJobRow(index >= 0 ? bucket[index] : null, row);
      _jobs[targetSid] = index >= 0
          ? [...bucket..[index] = merged]
          : [...bucket, merged];
      notifyListeners();
      return;
    }
    // 全局更新：任务在**任何**已建桶的会话里都同步（同 id 覆盖）。
    // 这是为了"用户在 A 看任务、B 也开过"时状态不分裂 —— 但不新建桶
    // （硬塞进一个错误的会话比丢一帧更糟）。
    for (final entry in _jobs.entries) {
      final index = entry.value.indexWhere((j) => j.id == row.id);
      if (index >= 0) {
        final merged = mergeJobRow(entry.value[index], row);
        _jobs[entry.key] = [...entry.value..[index] = merged];
        notifyListeners();
        return;
      }
    }
  }

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
  StreamSubscription<SessionStatus>? _statusSub;
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
  SessionSummary? sessionOf(String sid) => _sessionIndexMap()[sid];

  /// `_sessions` 换成新列表的**同一性**判据 + 按 sid 的索引。
  ///
  /// ## 为什么用"身份"而不是在每个赋值点重建
  ///
  /// `_sessions` 在 7 个地方被整体替换（列表刷新 / 新建会话 / 计数更新 / 标题更新…），
  /// 逐个去记得重建索引 = 7 个会漏的地方。这里只认"列表对象换了没有"：
  /// 换了就重建一次（O(n)），没换就 O(1) 查 —— 换来的是**少 7 个必须同步的入口**。
  ///
  /// 它替掉的是原来每次调用都线性扫（10 处调用点，其中几处在 `build` 里）。
  Map<String, SessionSummary> _sessionIndexMap() {
    if (!identical(_indexedSessions, _sessions)) {
      _indexedSessions = _sessions;
      _sessionIndex = <String, SessionSummary>{
        for (final s in _sessions) s.sid: s,
      };
    }
    return _sessionIndex;
  }

  List<SessionSummary>? _indexedSessions;
  Map<String, SessionSummary> _sessionIndex = const {};

  /// 当前会话的条目（只读快照；没打开会话时是空表）。
  List<ChatItem> get items =>
      _currentSid == null ? const [] : _storeOf(_currentSid!).items;

  /// 当前会话里**被改动过的文件**（右侧「文件」面板用）。
  ///
  /// 数据来源是工具调用本身：`write` / `edit` / `str_replace_editor` 的参数形状
  /// 满足条件时，`changedPathOf` 给出路径（判据照 DSH 的 `mutationPath`，
  /// `ui-deliverables/src/client/turn-deliverables.ts:61-77`）。
  /// 这是 **model-free** 的 —— 不靠模型自述，靠真实调用。
  ///
  /// **但"这一轮改了什么"最终以电脑的记录为准**：真实文件、行数增减、二进制与超大
  /// 的判定都在宿主的 `workspace-changes`（`workspace-changes/src/types.ts:25-76`）。
  /// 手机这一份是**过渡期的来源**（协议里还没有 `file.changes`，见方案笔记批 C）；
  /// 桌面记录过线后，改动卡与差异面板改读它，`changedPath` 只留给正文提及当词表。
  ///
  /// 去重：同一路径多次改动只留一行，**取最后一次的统计**（最新事实）；
  /// 顺序按"最后一次改动"从新到旧 —— 面板的第一行应该是刚动过的那个。
  ///
  /// ## 为什么要缓存（2026-10-20）
  ///
  /// 它是**每次 build 都会被问**的：`_sideHeader()` 与 `_fileBody()`
  /// 在 `ChatPage.build` 里各问一次（`_sideHeader()` 里还问了两次）。
  /// 而它要扫**全部条目**。八千条事件时那是每帧几万次判断 ——
  /// 流式输出期间每秒几十帧，白烧 CPU。
  ///
  /// 失效判据用**列表同一性**：`SessionStore` 每次归并都换成新的
  /// `List.unmodifiable`（`session_store.dart:118`），所以
  /// `identical` 为假等于"条目真的变了"；没变就复用上次的结果。
  /// 这比加一个 `revision` 计数更稳 —— 少一处可能与真实状态漂移的真值。
  List<({String path, ({int added, int removed})? stat})> get changedFiles =>
      _derivations.changedFiles;

  // ---- 模型（`session/modelCatalog` + `modelSelection` 投影）----

  /// 模型目录（`session/modelCatalog`，DSH `buildModelCatalog` 的真形状解析）。
  ///
  /// **拿不到就是 null** —— 手机显示"未选择"，不手抄第二份名单
  /// （2026-10-15 之前 picker 里是四个写死的模型名）。
  /// 2026-10-17 修：解析器原来认的是一个臆想形状（`List<{provider, models}>`），
  /// 而真形状是 `{default, routableProviders, groups, failures}` —— 顶层是对象，
  /// 于是目录在生产里**一次都没解析成功过**。详见 `model/model_catalog.dart` 文件头。
  ModelCatalog? get modelCatalog => _catalogs.modelCatalog;

  /// 当前会话的模型（`modelSelection` 投影，`next ?? lastUsed`）。
  ///
  /// 取的是 [SessionSummary.model]，而那一项**优先来自行的投影提示**
  /// （`app/lib/wire/rpc/session.dart` 的 `readSessionRow`：`values.modelSelection`
  /// 先于行顶层 `model`）—— 子会话没有活 agent，只有这条能给出模型。
  /// 输入栏的模型名 / 推理等级 / 模型选择面板的"当前"标记都走这里，不各自取。
  ///
  /// **会话没记录选择时回落宿主默认**（桌面 `directory.ts:162,180`：
  /// `projected.next ?? catalog.value.default`；会话侧也活跟随默认，
  /// `api/session-controller/src/agent.ts:464-472`）。少了这一档，
  /// 新会话就显示「请选择模型」—— 而桌面从不显示它，因为默认一直在。
  /// 目录拿不到时 `defaultSelection` 是空 provider/model：照实返回 null
  /// （界面说"拿不到"，不编一个）。
  ModelRef? get currentModel {
    final sid = _currentSid;
    if (sid == null) return null;
    final recorded = sessionOf(sid)?.model;
    if (recorded != null) return recorded;
    final fallback = _catalogs.modelCatalog?.defaultSelection;
    if (fallback == null) return null;
    if (fallback.provider.isEmpty || fallback.model.isEmpty) return null;
    return fallback;
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
      final selected = await wire.selectModel(
        client,
        sid: sid,
        provider: provider,
        model: model,
        reasoningEffort: reasoningEffort,
        requestId: newRequestId('sel'),
      );
      // 切完立刻重拉一次清单：`session.list` 的行带 `model` 字段，
      // 而输入栏的模型名走的是它。不拉就要等下一次自然刷新才变。
      if (!_disposed) await refreshSessions();
      if (_disposed) return null;
      // **认不出回执就用刚发出去的那个值**：切模型是写操作，"我请求了 X、
      // 回执读不出"时显示 X 比显示「未选择」更接近事实（这不是猜电脑侧的状态，
      // 是复述我们自己的请求）。回执读不出已经计数了一次。
      return selected ??
          ModelRef(
            provider: provider,
            model: model,
            reasoningEffort: reasoningEffort,
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

  // ---- 设备本地 UI 状态（`data/ui_state.dart` 的消费者）----
  //
  // 这几条是"会话级/列表级"的状态，**它们不属于 widget**：关一次抽屉、
  // 切一次会话、重启一次 App 都不该丢。落盘与迁移全在 `UiStateStore` 里，
  // 这里只做内存缓存与转发（`notifyListeners` 只发给真正变化的那一次）。

  /// 一个会话的页签 id（`chat` / `trajectory`）；`null` = 还没读过（UI 回 `chat`）。
  String? viewOf(String sid) => _views[sid];

  /// 切页签。存的是**注册项 id**，不是下标（桌面 `ui-conversation/src/client/stores.ts:23-25`）。
  Future<void> setView(String sid, String viewId) async {
    if (_views[sid] == viewId) return;
    _views[sid] = viewId;
    if (!_disposed) notifyListeners();
    await _uiState?.setView(sid, viewId);
  }

  /// 抽屉里一个组（工作区）的展开态；`null` = 没记过，UI 按"展开"处理。
  ///
  /// 键是 `workspaceId`（或非真工作区分组的 `label`），**不是显示标题** ——
  /// 桌面也是按工作区身份记（`ui-workspace/src/client/stores.ts:25-26`）。
  bool? drawerExpandedOf(String groupKey) =>
      _uiState?.drawerExpandedOf(groupKey);

  Future<void> setWorkspaceExpanded(String groupKey, bool expanded) async {
    await _uiState?.setWorkspaceExpanded(groupKey, expanded);
  }

  /// 一个会话的草稿正文（**旁路**：不进 `notifyListeners`）。
  ///
  /// 草稿的活文本由 `ChatPage` 的 `TextEditingController` 持有；这里只负责读盘
  /// 与"记一次击键"。为什么不放进 `AppModel` 通知：`notifyListeners()` 同步遍历
  /// 全部监听者（`foundation/change_notifier.dart:410-451`），草稿一进去就是
  /// 每击键整页重建（设计 §3）。
  Future<String?> draftOf(String sid) async {
    final ui = _uiState;
    if (ui == null) return null;
    return ui.sessionDraftOf(sid);
  }

  /// 记一次击键（防抖在 `UiStateStore` 里，默认 300ms）。
  void noteDraft(String sid, String text) => _uiState?.noteDraft(sid, text);

  /// 把在途草稿立刻落盘（发送后 / 切会话前 / 退到后台）。
  Future<void> flushDrafts() => _uiState?.flushDrafts() ?? Future<void>.value();

  /// 一个会话的**提问作答进度**（JSON；形状由 `ui/takeover.dart` 决定）。
  ///
  /// 存储层不认识交互语义，只当字符串存取 —— 解析在控制器里（那里知道题目与选项）。
  Future<String?> questionDraftOf(String sid) =>
      _uiState?.questionDraftOf(sid) ?? Future<String?>.value();

  /// 写提问进度；`null` = 删（这一项已收束）。
  void saveQuestionDraft(String sid, String? json) =>
      _uiState?.setQuestionDraft(sid, json);

  /// 换电脑（重新配对）：清掉属于某台电脑的那一段（`host.*`），`device.*` 留着。
  Future<void> clearHostUiState() async {
    _views.clear();
    await _uiState?.clearHostScope();
  }

  /// 懒读一个会话的页签（`openSession` 时调一次；**不在 `build` 里读盘**）。
  Future<void> _loadView(String sid) async {
    final ui = _uiState;
    if (ui == null) return;
    final view = await ui.viewOf(sid);
    if (_disposed) return;
    if (_views.containsKey(sid) && _views[sid] == view) return;
    _views[sid] = view;
    notifyListeners();
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

  /// **只给测试**：把一份会话与条目直接放进内存。
  ///
  /// 产品里的"示例数据"已删除（2026-10-26：发版不该带演示内容）；UI 用例仍需要
  /// 一份确定的会话内容，示例内容搬到了 `app/test/support/preview_data.dart`，
  /// 这里只留写入口。**不在任何产品路径上调用**（release 树摇会丢掉它）。
  @visibleForTesting
  void seedForTest({
    required String sid,
    required String title,
    required int updatedAt,
    required List<ChatItem> items,
    // **`blank` 必须能种**：新会话页（hero）与"blank 会话没有工作区就不能发"
    // 这两条判据都只在 blank 上成立，而真实 blank 需要一次 `session.list` 往返。
    bool blank = false,
  }) {
    if (_disposed) return;
    _storeOf(sid).replaceAll(items);
    final summary = SessionSummary(
      sid: sid,
      title: title,
      updatedAt: updatedAt,
      blank: blank,
      itemCount: items.length,
      pendingCount: items
          .whereType<ApprovalItem>()
          .where((item) => !item.decided)
          .length,
    );
    _sessions = [
      for (final session in _sessions)
        if (session.sid != sid) session,
      summary,
    ];
    _lastError = null;
    notifyListeners();
  }

  /// **只给测试**：推进一条交互信号。
  ///
  /// 真实信号来自会话事件投影（`_onProjected` 里的 `interactionSignalOf`）；
  /// 产品里的"演示接管"菜单已删除（2026-10-26），UI 用例改从这里注入。
  @visibleForTesting
  void emitInteractionForTest(InteractionSignal signal) =>
      _interactions.add(signal);

  /// **首帧前**把设备本地 UI 状态读回来（装配层在 `main.dart` 的 `_assemble` 里调）。
  ///
  /// 为什么不在 `start()` 里读（2026-10-27 之前就是）：`start()` 在内容首帧**之后**才跑，
  /// 于是首帧用的是默认值，字号与主题会跳一下。桌面是同步 `localStorage`（首帧前），
  /// 手机要做到同一件事只能把这一步提前到 boot splash 期间。
  Future<void> loadUiState() async {
    final prefs = _prefs;
    if (prefs == null) return;
    final store = UiStateStore(prefs: prefs);
    await store.open();
    if (_disposed) return;
    _uiState = store;
    _applyDevicePreferences();
  }

  /// 把 `device.*` 落进现有字段。**认不出就保持默认**（与 `fromWire` 同一条纪律）。
  void _applyDevicePreferences() {
    final store = _uiState;
    if (store == null) return;
    final transcript = TranscriptView.fromWire(store.transcriptView);
    if (transcript != null) _transcriptView = transcript;
    final performance = PerformanceUsage.fromWire(store.performanceView);
    if (performance != null) _performanceUsage = performance;
    final collapse = CollapseTiming.fromWire(store.collapseTiming);
    if (collapse != null) _collapseTiming = collapse;
    final scale = store.uiScaleIndex;
    if (scale != null) _uiScaleIndex = scale.clamp(0, kUiScaleSteps.length - 1);
  }

  /// 启动：连通道。
  Future<void> start() async {
    _stateSub = client.connection.listen(_onConnectionChanged);
    // 任务输出帧：任务面板与角标都听它。**广播流**，所以这里只订一份。
    _jobSub = client.jobUpdates.listen(_applyJobFrame);
    // 会话运行态：宿主 `api-session/status` 的原样转发（`status` 帧）。
    // **这是 running 的唯一实时来源** —— 以前是"数 turn/start / turn/end + 重连重建 + 轮次代号"，
    // 那套东西已经删掉（宿主本来就有这条推送，见 `lib/core/sync_client.dart` 的说明）。
    _statusSub = client.sessionStatus.listen(_applySessionStatus);
    // 通知上的「允许一次 / 拒绝」：原生把动作回给这里，再走既有的唯一出口
    // `interaction.respond`（这个类里没有第二套答复路径）。
    _approvalSub ??= _notify?.approvals.listen((action) {
      unawaited(_answerFromNotification(action));
    });
    // 开屏就问一次通知权限现状（设置页那一行要显示"已开启 / 点这里开启"，
    // 而不是一直"未读到"）。顺手把保活对齐。
    unawaited(_syncKeepAlive());
    _connection = _viewOf(client.state, client);
    // **发送模式的初始种子**：真值在宿主设置 `ui-conversation.busyEnter`
    // （`refreshSettings` 回来后会覆盖这里），本机这份只在两种时刻起作用：
    // ① 首帧还没读到设置时别闪；② **老连接器没有那个设置面**时的退路。
    // 读不到就保持默认的排队 —— 与 DSH 的默认一致，也不猜。
    final stored = await _prefs?.read(kSendModeKey);
    final restored = SendMode.fromWire(stored);
    if (restored != null) _sendMode = restored;
    // 其余本地偏好（工作步骤展示 / 性能与用量）：装配层已经用 `loadUiState()`
    // 在**首帧前**读过了；没装配这条缝时（单测）才退到旧的单键读法。
    if (_uiState == null) await _restorePreferences();
    notifyListeners();
    await client.start();
  }

  /// 落盘的 meta 键：发送模式。**契约两端共用的字符串**，改动等于作废用户的偏好。
  static const String kSendModeKey = 'send_mode';

  /// 落盘的 meta 键：上次看的会话（连上/冷启动的落点，见 [landingSessionOf]）。
  static const String kLastSessionKey = 'last_session';

  SendMode _sendMode = SendMode.queue;

  /// 当前的发送模式（排队 / 插话）。
  SendMode get sendMode => _sendMode;

  /// 切发送模式。同一个值重复切是空操作。
  ///
  /// **真值在宿主**：`ui-conversation.busyEnter`（桌面也写这里，
  /// `packages/client/ui-conversation/src/submission-settings.ts:1-33`）。
  /// 手机只在**老连接器**（没有这个设置面）时才退回本地键 —— 两份真值并存
  /// 会让"手机显示插话、电脑显示排队"而无处解释，而那是本轮审计点名的
  /// §C-5。写失败**不回滚界面**：用户已经看到按钮变了，回滚只会更错。
  Future<void> setSendMode(SendMode mode) async {
    if (_disposed || mode == _sendMode) return;
    _sendMode = mode;
    notifyListeners();
    if (_settingsValues.containsKey(kBusyEnterNs)) {
      await updateSetting(kBusyEnterNs, kBusyEnterField, mode.wire);
      return;
    }
    await _prefs?.write(kSendModeKey, mode.wire);
  }

  // ---- 手机本地的界面偏好（DSH 的"纯 UI 偏好"，有意偏离存本地）----

  TranscriptView _transcriptView = TranscriptView.standard;
  PerformanceUsage _performanceUsage = PerformanceUsage.detailed;
  CollapseTiming _collapseTiming = CollapseTiming.completion;

  TranscriptView get transcriptView => _transcriptView;
  PerformanceUsage get performanceUsage => _performanceUsage;

  /// 轮组的过程什么时候收起来（`docs/subsystems/turn-groups.md`）。
  CollapseTiming get collapseTiming => _collapseTiming;

  /// 落盘的 meta 键：偏好类。**契约两端共用的字符串**，改动等于作废用户的偏好。
  static const String kTranscriptViewKey = 'transcript_view';
  static const String kPerformanceUsageKey = 'performance_usage';
  static const String kCollapseTimingKey = 'collapse_timing';

  /// 切工作步骤展示密度。落盘；同一个值重复切是空操作。
  Future<void> setTranscriptView(TranscriptView view) async {
    if (_disposed || view == _transcriptView) return;
    _transcriptView = view;
    notifyListeners();
    final store = _uiState;
    if (store != null) {
      await store.setTranscriptView(view.wire);
    } else {
      await _prefs?.write(kTranscriptViewKey, view.wire);
    }
  }

  /// 切性能与用量的详细程度。落盘；同一个值重复切是空操作。
  Future<void> setPerformanceUsage(PerformanceUsage usage) async {
    if (_disposed || usage == _performanceUsage) return;
    _performanceUsage = usage;
    notifyListeners();
    final store = _uiState;
    if (store != null) {
      await store.setPerformanceView(usage.wire);
    } else {
      await _prefs?.write(kPerformanceUsageKey, usage.wire);
    }
  }

  /// 切"过程什么时候收起"。落盘；同一个值重复切是空操作。
  ///
  /// 切完**要清掉用户手动的展开/收起**：那是对旧默认态的手工覆盖，
  /// 留着会让"我改了设置但没反应"（`clearTurnOpen()` 由界面调）。
  Future<void> setCollapseTiming(CollapseTiming timing) async {
    if (_disposed || timing == _collapseTiming) return;
    _collapseTiming = timing;
    notifyListeners();
    final store = _uiState;
    if (store != null) {
      await store.setCollapseTiming(timing.wire);
    } else {
      await _prefs?.write(kCollapseTimingKey, timing.wire);
    }
  }

  /// 落盘的 meta 键：**界面字号档位**（App 内倍率的下标，0–3）。
  /// 旧键 `content_font_size`（10–22 的内容字号）已作废 —— 那一版只放大内容，
  /// 对比会被拉到 2 倍（用户原话「丑」）。见
  /// `.agents/notes/implemented/2026-10-22-global-ui-scale.md`。
  static const String kUiScaleKey = 'ui_scale_index';

  int _uiScaleIndex = kUiScaleDefaultIndex;

  /// 界面字号档位的下标（[kUiScaleSteps] / [kUiScaleLabels] 的下标）。
  int get uiScaleIndex => _uiScaleIndex;

  /// 当前倍率（叠在系统字号之上；`main.dart` 把它乘进 `MediaQuery.textScaler`）。
  double get uiScale => kUiScaleSteps[_uiScaleIndex];

  /// 切界面字号档位。落盘；同一个档位重复设是空操作；越界**夹到边界**。
  Future<void> setUiScaleIndex(int index) async {
    final clamped = index.clamp(0, kUiScaleSteps.length - 1);
    if (_disposed || clamped == _uiScaleIndex) return;
    _uiScaleIndex = clamped;
    notifyListeners();
    final store = _uiState;
    if (store != null) {
      await store.setUiScaleIndex(clamped);
    } else {
      await _prefs?.write(kUiScaleKey, '$clamped');
    }
  }

  // ---- 电脑侧设置（`settings.describe` / `settings.update`，契约 §5.7）----
  //
  // 手机只碰**三个命名空间**（连接器的 `dsh/settings-face.ts` 用两张 allowlist 定死）：
  // `permission`（默认权限档）、`agent-preset-registry`（默认 Agent 预设）、
  // `session-log-deepseek`（Session Log 开关）。读到的值是**已脱敏**的
  // （`role('secret')` 字段被剔除，密钥位只剩"设没设"）。

  /// `ns → 已脱敏的值`。
  final Map<String, Map<String, Object?>> _settingsValues = {};

  /// `ns → 乐观锁版本`（下一次写要带回去；过期会回 `settings/conflict`）。
  final Map<String, Object?> _settingsRevision = {};

  /// 手机关心的四个命名空间。
  ///
  /// 第四个（`ui-conversation`）只读一个字段：**发送模式 `busyEnter`**。
  /// 它是宿主设置里已有的东西（`packages/client/ui-conversation/src/submission-settings.ts:1-33`），
  /// 桌面也写这里 —— 手机不再自己存一份（那是第二份真值，见
  /// `proposed/2026-10-27-state-semantics-audit.md` §C-5）。
  static const List<String> kSettingsNamespaces = [
    'permission',
    'agent-preset-registry',
    'session-log-deepseek',
    'ui-conversation',
  ];

  /// 发送模式在宿主设置里的位置（`ui-conversation.busyEnter`）。
  static const String kBusyEnterNs = 'ui-conversation';
  static const String kBusyEnterField = 'busyEnter';

  /// 某个命名空间的当前值；`null` = 还没读到（**不拿默认值冒充**）。
  Map<String, Object?>? settingsOf(String ns) => _settingsValues[ns];

  /// 读一个字段；`null` = 没有 / 还没读到。
  Object? settingsValue(String ns, String path) => _settingsValues[ns]?[path];

  /// 拉一次三个命名空间的设置快照。
  ///
  /// `settings.describe` 是**读方法**（不带幂等键），重发只是再读一次。
  Future<void> refreshSettings() async {
    try {
      // 形状（`{sections: [{ns, revision, values, secrets}]}`）在 `wire/rpc/settings.dart`；
      // 这里只把快照落进三张表。
      final sections = await wire.loadSettings(
        client,
        namespaces: kSettingsNamespaces,
      );
      if (sections == null) return;
      for (final section in sections) {
        _settingsValues[section.ns] = section.values;
        _settingsRevision[section.ns] = section.revision;
      }
      // **发送模式以宿主为准**：`busyEnter` 有值就覆盖本机那份种子
      // （读不到 = 老连接器 / 没这个 ns，保持种子不动）。
      final hostMode = SendMode.fromWire(
        switch (_settingsValues[kBusyEnterNs]?[kBusyEnterField]) {
          final String value => value,
          _ => null,
        },
      );
      if (hostMode != null) _sendMode = hostMode;
      _lastError = null;
      if (!_disposed) notifyListeners();
    } catch (error) {
      // 与 `refreshSessions` 同一条纪律：兜住所有异常，记下来，界面说"拉不到"。
      _recordError('拉取设置失败', error);
    }
  }

  /// 改一个设置字段（**只发新值**）。返回 `true` = 电脑侧已落值。  ///
  /// 冲突（`settings/conflict`，expectedRevision 过期）时**自动重读一次再返回 false**：
  /// 下一次点击就会带上新的 revision，用户不必自己"刷新页面"。
  Future<bool> updateSetting(String ns, String path, Object? value) async {
    try {
      final section = await wire.updateSettingValue(
        client,
        ns: ns,
        path: [path],
        value: value,
        expectedRevision: _settingsRevision[ns],
        requestId: newRequestId('set'),
      );
      // `section: null` 是合法应答（宿主没给新快照）⇒ 这一行不刷新，但写已生效。
      if (section != null && section.ns == ns && !_disposed) {
        _settingsValues[ns] = section.values;
        _settingsRevision[ns] = section.revision;
      }
      _lastError = null;
      if (!_disposed) notifyListeners();
      return true;
    } on ProtocolException catch (error) {
      if (error.code == ErrorCode.settingsConflict) {
        // 乐观锁过期：重读一次（**不重试这次写** —— 值可能已经被别人改了）。
        await refreshSettings();
      }
      // **失败原因要在重读之后再写回去**：`refreshSettings` 成功时会把 `lastError`
      // 清空，先写就被擦掉了 —— 界面于是只剩一句没有 code 的"改设置失败"。
      _lastError = error;
      if (!_disposed) notifyListeners();
      return false;
    } catch (error) {
      _recordError('改设置失败', error);
      return false;
    }
  }

  // ---- 电脑侧版本（`repo.info.dshVersion`，只读）----

  /// 电脑侧 DSH 版本；`null` = 还没读到 / 这台没报（**不编一个版本号**）。
  String? get dshVersion => _dshVersion;
  String? _dshVersion;

  /// 斜杠命令白名单（`repo.info.commands`，**电脑侧原样过线**）。
  ///
  /// 空表 = **不知道**（老连接器不报这个键）⇒ `/` 不出候选菜单。
  /// **手机侧不抄第二份**：抄一份的后果是电脑侧加了第三条命令，手机菜单里永远没有它
  /// （同一个事实两处表达必然漂）。判据与取舍在契约 §5.7 的 `repo.info` 行。
  ///
  /// 两种形状都收（老连接器的 `string[]` 与新连接器的 `{name, description?}[]`），
  /// 解析在 `model/command.dart` 的 `parseSlashCommands` —— 说明是**宿主命令定义里的话**，
  /// 手机不自带文案。
  List<SlashCommand> get slashCommands => _slashCommands;
  List<SlashCommand> _slashCommands = const <SlashCommand>[];

  /// 电脑侧有没有 `@` 候选（`repo.info.caps.references`）。
  ///
  /// **只看能力位，不看方法表**：连接器那边两个判据是同一个函数
  /// （`connector/src/dsh/caps.ts` 的 `referencesAvailable`，`readCaps` 与挂载点共用），
  /// 所以"有能力位 ⇒ 方法一定在表里"。老连接器不报这个键 ⇒ false ⇒
  /// 手机上**不显示** `@` 面板（不是显示一个永远空的列表）。
  bool get mentionsAvailable => _mentionsAvailable;
  bool _mentionsAvailable = false;

  /// 读一次 `repo.info`（排错要它：手机版本与电脑版本并排看）。
  ///
  /// 连接器只在**拿得到宿主运行时版本**时才报这个字段（见
  /// `connector/src/dsh/host-version.ts`），所以拿不到是正常形态之一 ——
  /// 那时界面说"未读到"，而不是显示连接器自己的 `package.json` 版本冒充。
  Future<void> refreshRepoInfo() async {
    try {
      // 形状（`{protocol, caps, aliasVersion, methods, dshVersion?, commands?}`）在
      // `wire/rpc/repo.dart`：手机只消费四个键（三个能力位 + commands + dshVersion），
      // `protocol` / `aliasVersion` / `methods` 不声明（前者在帧头 `v` 里校验）。
      final info = await wire.loadRepoInfo(client);
      if (info == null) {
        // 应答读不出来：能力位一律 false（界面退回"没有那个面"），并如实记下。
        _dshVersion = null;
        _slashCommands = const <SlashCommand>[];
        _mentionsAvailable = false;
        _filesAvailable = false;
        _pluginsAvailable = false;
        if (!_disposed) notifyListeners();
        return;
      }
      _dshVersion = info.dshVersion;
      _slashCommands = info.slashCommands;
      _mentionsAvailable = info.mentionsAvailable;
      _filesAvailable = info.filesAvailable;
      _changesAvailable = info.changesAvailable;
      _pluginsAvailable = info.pluginsAvailable;
      // **读到了**才置位：界面靠它区分"这台电脑没有这个面"与"还没读到"
      // （离线时 `caps.files` 只是默认 false，不是电脑的答复）。
      _repoInfoKnown = true;
      if (!_disposed) notifyListeners();
    } catch (error) {
      _dshVersion = null;
      _recordError('读取电脑侧版本失败', error);
    }
  }

  // ---- 工作区文件（`file.list` / `file.read`，只读）----

  /// 电脑侧有没有文件面（`repo.info.caps.files`）。老连接器 ⇒ false。
  bool get filesAvailable => _filesAvailable;
  bool _filesAvailable = false;

  /// 是否**成功读到过** `repo.info`。
  ///
  /// `filesAvailable == false` 有两种含义：电脑说"没有这个面"，或**还没读到**
  /// （没连上 / 刚启动）。界面必须分开说，否则离线会被说成"没有文件服务"。
  bool get repoInfoKnown => _repoInfoKnown;
  bool _repoInfoKnown = false;

  /// 列一个目录（`path` 空串 = 工作区根）。
  ///
  /// 失败**不吞**：原因留在 [lastError]（宿主的原话，例如
  /// `workspace-file/not-directory` / `workspace-file/not-found`），调用方显示它 ——
  /// 翻译一遍就成了两句话。
  Future<FileListing?> listFiles(String path) async {
    // **没有能力位就不发请求**（与 `refreshPlugins` 同一条）：老连接器上这个方法不存在，
    // 发出去只会拿一个 `connector/unsupported`，而它会被画成"读取失败"。
    if (!_filesAvailable) return null;
    final sid = _currentSid;
    if (sid == null) {
      _recordError('读取目录失败', StateError('还没有选中的会话'));
      return null;
    }
    try {
      // 形状（`{listing}` 信封 + 本体）在 `wire/rpc/file.dart`。
      final listing = await wire.loadFileListing(client, sid: sid, path: path);
      if (listing == null) {
        _recordError('读取目录失败', StateError('电脑侧的目录应答形状认不出'));
        return null;
      }
      return listing;
    } catch (error) {
      _recordError('读取目录失败', error);
      return null;
    }
  }

  /// 读一页文本（`offset` / `limit` 不传就用宿主的页默认）。
  ///
  /// 二进制文件由宿主拒（`workspace-file/not-text`），原因同样进 [lastError]。
  Future<FilePage?> readFile(String path, {int? offset, int? limit}) =>
      _preview.readPage(path, offset: offset, limit: limit);

  // ---- 打开一个文件（**唯一动作**，四个入口都走它）----

  late final FilePreview _preview = FilePreview(
    client: client,
    sidOf: () => _currentSid,
    filesAvailable: () => _filesAvailable,
    changesAvailable: () => _changesAvailable,
    repoInfoKnown: () => _repoInfoKnown,
    recordError: _recordError,
    lastErrorMessage: () => _lastError?.message,
    // 文案按**码**换（`model/file_failure.dart`）：四类"读得懂但打不开"的文件
    // 说中文结论，其余码保留宿主原话 —— 与桌面 `failureLine()` 同一条。
    lastErrorCode: () => _lastError?.code,
    onChange: () {
      if (!_disposed) notifyListeners();
    },
  );

  /// 最近一次打开请求（`null` = 当前没有打开文件）。
  FileOpenRequest? get fileOpenRequest => _preview.request;

  /// 请求序号：**每次 `openFile` 都 +1**（同一路径连点两次也要再开一次，
  /// 所以不能拿请求值本身当判据 —— 它按值相等）。
  int get fileOpenTicket => _preview.ticket;

  /// 已读到的那份内容（`null` = 正在读 / 读失败 / 没打开）。
  OpenedFile? get openedFile => _preview.openedFile;

  bool get fileLoading => _preview.loading;

  /// 上一次打开的失败原因（电脑侧原话；`null` = 没失败）。
  String? get fileFailure => _preview.failure;

  /// 逐行差异（`FileOpenMode.diff` 的那一份；`null` = 还没读到 / 电脑侧没有记录）。
  FileDiff? get openedDiff => _preview.diff;

  bool get diffLoading => _preview.diffLoading;

  String? get diffFailure => _preview.diffFailure;

  /// 打开一个文件。**所有入口只走它**（正文提及 / 改动卡行 / 侧栏差异行 / 文件页）。
  ///
  /// 路径**原样**交给 `file.read`：scope 由宿主按会话解析
  /// （见 `model/file_open.dart` 的文件头）。
  ///
  /// Note: 为什么是"模型记状态、界面自己画"而不是在这里 push 路由 —— 见
  /// `.agents/notes/implemented/2026-10-26-file-mentions-and-open-file.md`
  ///
  /// 只读第一页；"加载更多"走 [loadMoreOpenedFile]。
  Future<void> openFile(FileOpenRequest request) => _preview.open(request);

  /// 接着读下一页（`eof` 之后是空操作）。
  Future<void> loadMoreOpenedFile() => _preview.loadMore();

  /// 收起当前打开的文件（侧栏回到改动清单 / 文件页返回列表）。
  void closeFile() => _preview.close();

  /// 某一轮**产出过**的路径 —— 正文提及的词表。
  ///
  /// 与 DSH 同一条：词表是**这一轮**的产出，不是工作区文件清单
  /// （`ui-deliverables/src/client/turn-deliverables.ts:132-160`）。
  /// 判据也照它：**只有成功的变更调用算产出**（`:134-137` 的
  /// "failed results contribute nothing"），读取与未知工具不算。
  List<String> producedPathsOf(int? turn) {
    return _derivations.producedPathsOf(turn);
  }

  /// 某条消息里的**文件提及表**（`token → path`），没有提及就是 `null`。
  ///
  /// 只在**收口那条助手正文**上给：桌面把提及限定在"这一轮收口的那条助手消息"
  /// （`ui-chat/src/client/chat/AssistantNodeView.tsx:19-27`：轮次已收口、且
  /// `tail.closing.finalNode` 就是这条），中间步骤的正文里长出链接会与桌面不一致。
  ///
  /// 解析只有一处（`model/file_mentions.dart`），并按条目缓存 ——
  /// 对话页每帧都会问一次，长会话里重复扫正文会把每帧成本拖长。
  /// 缓存与派生在 `ItemDerivations`（同一份入口）。
  Map<String, String>? fileMentionsOf(ChatItem item) =>
      _derivations.fileMentionsOf(item);

  // ---- 改动记录（`file.changes`，只读；数据是桌面的记录）----

  /// 电脑侧有没有改动面（`repo.info.caps.changes`）。老连接器 / 没装
  /// `workspace-changes` 的部署 ⇒ false（不画改动卡）。
  bool get changesAvailable => _changesAvailable;
  bool _changesAvailable = false;

  /// 已读到的改动记录，键是 `'<sid>:<seq>'`。
  ///
  /// **值 `null` 也是一个结果**（电脑侧没有这条记录），所以用 [containsKey] 区分
  /// "没读过"与"读过但空" —— 不拿 `null` 兼表两件事（`memory.md` 教训 4）。
  final Map<String, ChangesSummary?> _changesBySeq = {};
  final Set<String> _changesLoading = {};
  final Map<String, String> _changesFailures = {};

  String? _changesKey(int seq) {
    final sid = _currentSid;
    return sid == null ? null : '$sid:$seq';
  }

  /// 三态读法：`loaded == false` = 还没读过；`loaded && summary == null` = 电脑侧没有记录。
  ({bool loaded, ChangesSummary? summary}) changesStateOf(int seq) {
    final key = _changesKey(seq);
    if (key == null || !_changesBySeq.containsKey(key)) {
      return (loaded: false, summary: null);
    }
    return (loaded: true, summary: _changesBySeq[key]);
  }

  bool changesLoading(int seq) {
    final key = _changesKey(seq);
    return key != null && _changesLoading.contains(key);
  }

  String? changesFailureOf(int seq) {
    final key = _changesKey(seq);
    return key == null ? null : _changesFailures[key];
  }

  /// 最近一轮有改动记录的 `workspace/changes` 事件 seq。
  ///
  /// 侧栏「差异」画的是**这一轮**的记录（桌面右侧栏也是按轮 review）；没有就 `null`。
  int? get latestChangesSeq {
    final list = items;
    for (var i = list.length - 1; i >= 0; i -= 1) {
      final item = list[i];
      if (item is ChangesItem) return item.seq;
    }
    return null;
  }

  /// 读一条改动记录（`seq` = `workspace/changes` 事件序号）。
  ///
  /// **没有能力位就不发请求**：老连接器上方法不存在，发出去只会拿
  /// `connector/unsupported`，而它会被画成"读取失败"。
  /// 失败照报电脑侧原话（[lastError]），卡片据此显示原因。
  Future<void> loadChangesSummary(int seq) async {
    if (!_changesAvailable) return;
    final key = _changesKey(seq);
    if (key == null || _changesLoading.contains(key)) return;
    _changesLoading.add(key);
    _changesFailures.remove(key);
    if (!_disposed) notifyListeners();
    try {
      final summary = await wire.loadChangesSummary(
        client,
        sid: _currentSid!,
        seq: seq,
      );
      if (_disposed) return;
      _changesBySeq[key] = summary;
    } catch (error) {
      if (_disposed) return;
      _recordError('读取改动记录失败', error);
      _changesFailures[key] = _lastError?.message ?? '读取改动记录失败';
    } finally {
      _changesLoading.remove(key);
      if (!_disposed) notifyListeners();
    }
  }

  // ---- 插件（`plugin.list` / `plugin.setEnabled`）----

  /// 电脑侧有没有插件面（`repo.info.caps.plugins`）。老连接器 ⇒ false。
  bool get pluginsAvailable => _pluginsAvailable;
  bool _pluginsAvailable = false;

  /// 已经读到的插件行（**顺序就是电脑侧给的顺序**，手机不重排）。
  List<PluginRow> get plugins => _plugins;
  List<PluginRow> _plugins = const <PluginRow>[];

  /// 读到过没有（`false` = 还在读 / 没读过）。
  bool get pluginsLoaded => _pluginsLoaded;
  bool _pluginsLoaded = false;

  bool get pluginsLoading => _pluginsLoading;
  bool _pluginsLoading = false;

  /// 上一次读取失败的原因（`null` = 没失败）。
  String? get pluginsFailure => _pluginsFailure;
  String? _pluginsFailure;

  /// 已经读到的**包**清单（卸载按包名走，见 `PluginBundle`）。
  List<PluginBundle> get pluginBundles => _pluginBundles;
  List<PluginBundle> _pluginBundles = const <PluginBundle>[];

  /// 拉一次插件清单（只读、不落盘）。
  ///
  /// **没有能力位就不发请求**：老连接器上这个方法不存在，发出去只会拿一个
  /// `connector/unsupported` 回来，而那会被画成"读取失败"—— 比"这台电脑没有
  /// 插件服务"更难懂。
  Future<void> refreshPlugins() async {
    if (!_pluginsAvailable) return;
    _pluginsLoading = true;
    if (!_disposed) notifyListeners();
    try {
      // 两个面各一发（并发）：插件行与包是两张表，卸载按包名走。形状在
      // `wire/rpc/plugin.dart`（行本体仍由 `model/plugins.dart` 的 fromWire 解）。
      final inventory = await wire.loadPluginInventory(client);
      if (inventory == null) {
        _recordError('读取插件清单失败', StateError('电脑侧的插件应答形状认不出'));
        _pluginsFailure = '电脑侧的插件应答形状认不出';
        return;
      }
      _plugins = inventory.rows;
      _pluginBundles = inventory.bundles;
      _pluginsLoaded = true;
      _pluginsFailure = null;
    } catch (error) {
      _recordError('读取插件清单失败', error);
      _pluginsFailure = _lastError?.message ?? '$error';
    } finally {
      _pluginsLoading = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// 启停一行（`plugin.setEnabled`）。
  ///
  /// 回执里的 `enabled` 是**宿主回读后的真值**，所以这里用它就地更正那一行 ——
  /// 请求值与终态可能不同（宿主回 `overridden`）。失败原因在 [lastError]。
  Future<PluginToggleOutcome?> setPluginEnabled(String id, bool enabled) async {
    try {
      // 回执的 `enabled` 是**宿主回读后的真值**（`wire/rpc/plugin.dart`）。
      final toggled = await wire.setPluginEnabled(
        client,
        id: id,
        enabled: enabled,
        requestId: newRequestId('plug'),
      );
      if (toggled == null) {
        _recordError('启停插件失败', StateError('电脑侧的回执形状认不出'));
        return null;
      }
      final outcome = PluginToggleOutcome(
        entryId: id,
        enabled: toggled.enabled,
        application: toggled.application,
        restartReason: toggled.restartReason,
      );
      _plugins = [
        for (final row in _plugins)
          row.entryId == id ? row.withEnabled(outcome.enabled) : row,
      ];
      if (!_disposed) notifyListeners();
      return outcome;
    } catch (error) {
      _recordError('启停插件失败', error);
      return null;
    }
  }

  /// 发起一次安装（`plugin.install`）。返回任务 id（**同一个 id 就是幂等键**）。
  ///
  /// **立刻返回**：真实安装跑 pnpm、常超 60 s 请求超时，所以结论靠
  /// [pluginJobStatus] 轮询（与 `session.projections` 同一种节奏）。
  Future<String?> installPlugin(String spec) async {
    if (!_pluginsAvailable) return null;
    try {
      return await wire.startPluginInstall(
        client,
        spec: spec,
        requestId: newRequestId('plug'),
      );
    } catch (error) {
      _recordError('发起插件任务失败', error);
      return null;
    }
  }

  /// 卸载一个**包**（`plugin.remove`，按包名）。形状与安装相同。
  Future<String?> removePluginBundle(String name) async {
    if (!_pluginsAvailable) return null;
    try {
      return await wire.removePluginBundle(
        client,
        name: name,
        requestId: newRequestId('plug'),
      );
    } catch (error) {
      _recordError('发起插件任务失败', error);
      return null;
    }
  }

  /// 问一次任务状态（`plugin.installStatus`）。失败原因在 [lastError]。
  Future<PluginJob?> pluginJobStatus(String requestId) async {
    try {
      return await wire.pluginJobStatus(client, requestId: requestId);
    } catch (error) {
      _recordError('读取插件任务状态失败', error);
      return null;
    }
  }

  /// 取消一次安装（`plugin.cancelInstall`）。回宿主的三档状态（原样）。
  Future<String?> cancelPluginInstall(String requestId) async {
    try {
      return await wire.cancelPluginInstall(client, requestId: requestId);
    } catch (error) {
      _recordError('取消安装失败', error);
      return null;
    }
  }

  // ---- `@` 候选（`refs.files` / `refs.sessions`，只读）----

  /// 查这个会话里的 `@` 候选（文件 / 目录 + 跨会话引用）。
  ///
  /// **两个方法并发发一次**：面板一行里两种候选都要，串行只是多等一个往返。
  /// **不缓存、不预取**：候选随会话工作目录与我打的字变化，落一份本地快照就是
  /// 第二个真值源（而且下一个按键就得作废它）。去抖与"作废在飞请求"在界面层
  /// （`ui/dsh_composer.dart` 的 `_AtSuggestions`），因为它才是那个知道"又按了一个键"的地方。
  ///
  /// 空结果 = 电脑侧说"没有匹配"；失败 = 原因在返回值的 `error` 里
  /// （两种"没有"在界面上是两种形态，见 [MentionQueryResult]）。
  Future<MentionQueryResult> queryMentions(String query) async {
    final sid = _currentSid;
    if (sid == null) {
      return const MentionQueryResult(error: '还没有选中的会话：@ 候选要在一个会话自己的工作目录里找');
    }
    try {
      // 形状（`{files:[…]}` / `{sessions:[…]}`，并发查一次）在 `wire/rpc/refs.dart`；
      // 行本体仍由 `AtCandidate.fromFileRow` / `fromSessionRow` 解析（认不出的行跳过）。
      final answers = await wire.loadMentionCandidates(
        client,
        sid: sid,
        query: query,
      );
      // 任一侧读不出来 ⇒ 那一侧当"没有"（另一侧照常给）—— 两列独立。
      final files = answers.files;
      final sessions = answers.sessions;
      if (files == null || sessions == null) {
        _recordError('读取 @ 候选失败', StateError('电脑侧的候选应答形状认不出'));
      }
      return MentionQueryResult(
        candidates: AtCandidates(
          files: files ?? const [],
          sessions: sessions ?? const [],
        ),
      );
    } catch (error) {
      // **兜住所有异常**（与 `refreshSessions` / `refreshUsageSummary` 同一条纪律）：
      // 只接协议错误的话，解析 / 超时都会逃逸成未处理的异步错误，
      // 而界面会停在"还在找"——那正是最难与"电脑没有匹配"区分的形态。
      _recordError('读取 @ 候选失败', error);
      return MentionQueryResult(error: _lastError?.message ?? '$error');
    }
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
      // 形状（`{totals, byDay, bySession, byProject, grandTotal}`）在 `wire/rpc/usage.dart`；
      // 聚合规则不在这层（连接器自己遍历可见会话聚出来的）。
      _usageSummary = await wire.loadUsageSummary(client);
      _lastError = null;
    } catch (error) {
      // **兜住所有异常，不只 `ProtocolException`**（与 `refreshSessions` 同一条纪律）：
      // 只接协议错误的话，解析 / 类型 / 超时都会逃逸成未处理的异步错误 ——
      // 界面停在空态且不报错，而那正是"用量页永远是空的"最容易被误判成
      // "电脑上真没有用量"的形态。
      _usageSummary = null;
      _recordError('拉取用量汇总失败', error);
      return;
    }
    if (!_disposed) notifyListeners();
  }

  /// 读一个**通用字符串偏好**（`meta` 表的 k/v）。  ///
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
    final collapse = CollapseTiming.fromWire(
      await _prefs?.read(kCollapseTimingKey),
    );
    if (collapse != null) _collapseTiming = collapse;
    // 界面字号档位：存的是下标；认不出（没存过 / 坏了）就保持默认档（1.0）。
    final scaleIndex = int.tryParse(await _prefs?.read(kUiScaleKey) ?? '');
    if (scaleIndex != null) {
      _uiScaleIndex = scaleIndex.clamp(0, kUiScaleSteps.length - 1);
    }
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
    // 连接态变了要重判"还该不该保活"：进服务态才起服务，掉到退避/关闭就该停
    // （停掉之后通知栏那条常驻随之消失 —— 它说的"正在保持连接"不再成立）。
    unawaited(_syncKeepAlive());
    // **一进服务态就拉会话列表**。
    //
    // 少了这一步，界面永远停在「还没有会话」—— 而那不是"电脑上真没有会话"，
    // 是**根本没人去问过**。连上的那一刻是唯一正确的时机：
    // 之前发请求会撞上"还没握手"，之后没有别的事件会再来一次。
    //
    // **每次进服务态都拉一包会话行**：它的 `running` 按原样覆盖（与 DSH 的浏览器同一条，
    // `manager.ts:248-253`），于是断线期间结束的那一轮会在这里被纠正 —— 不再需要
    // "重连按代号重建"那套护栏（那套已随 W4 一起删掉）。
    //
    // 拉完的结果由 `refreshSessions` 自己 `notifyListeners`，这里不等它：
    // 收帧路径上的回调不该被一个网络往返挡住（§2.2 的状态迁移通知是同步派发的）。
    if (state == ConnectionState.serving) {
      // 拉完列表再落会话：落点要用 `updatedAt` / `running`，那是列表里的字段。
      unawaited(landAfterConnect());
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
      // 形状（`{endpoints: [{kind, url, label?}]}`）在 `wire/rpc/endpoint.dart`。
      final discovered = await wire.loadEndpoints(client);
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

  /// 只重读 `session.list` 的行，**不碰**目录 / 工作区 / 模型目录。
  ///
  /// ## 为什么需要它（2026-10-21 真机验收抓到）
  ///
  /// 子智能体面板一行里的标题、`running`、时长、token 全部来自**子会话自己**
  /// 的 `session.list` 行（`projections.values`），而整包行只在
  /// **连上 / 建会话**（[refreshSessions] 的两个调用点）时拉过。
  /// 子会话是父会话**回合里**才出现的，于是真机上打开面板看到的是
  /// 「当前未运行 + 没有 token + 没有时长」，要杀掉 App 重连才变对 ——
  /// 而组件树的单测一直是绿的（替身一开始就把行喂给了 `sessionOf`）。
  ///
  /// 调用点是"面板真的被看见"的那一刻（右抽屉落到子智能体页 / 切换 sheet 打开），
  /// 不是定时器：这条数据没有推送面，逐帧拉会把一次会话变成一串 `session.list`。
  /// 代价是**指标是"打开那一刻"的**（在跑的行靠 1 秒时钟继续走秒，但
  /// `running` 变成 false 要再开一次面板才收）。判据见
  /// `app/test/subagent_metrics_refresh_test.dart`。
  Future<void> refreshSessionMetrics() async {
    if (_disposed) return;
    try {
      _applySessionList(await _fetchSessionRows());
      if (!_disposed) notifyListeners();
    } catch (error) {
      _recordError('拉取会话指标失败', error);
    }
  }

  /// 向电脑侧要一包会话行（**唯一的 `session.list` 出口**）。
  ///
  /// 方法名、参数形状与应答字段**全在 `app/lib/wire/rpc/session.dart`** ——
  /// 这一层不再知道 `session.list` 长什么样，这正是
  /// `app/tools/verify-rpc-single-caller.mjs` 那个会归零的预算在数的事。
  Future<List<SessionSummary>> _fetchSessionRows() =>
      wire.loadSessionList(client);

  /// 把一包会话行落到 [sessions]（**唯一的赋值口**）。
  ///
  /// **待处理数本地算**：从每个会话已落地的条目里数未决审批/提问。
  /// 不指望 `session.list` 带它 —— 那是跨请求的汇总，而投影就在手里。
  /// 多会话并行时，用户靠这个数知道该切去哪个会话（DSH 的待处理是
  /// per-session 的，切过去才看得见）。
  ///
  /// **`running` 按这一包原样覆盖**（两个方向都覆盖），与 DSH 的浏览器同一条：
  /// 它拿到 `session.list` 之后就是 `session.handleRunning(summary.running)`
  /// （`packages/api/session-controller/src/client/sessions/manager.ts:248-253`、`:450`）。
  /// 之后的变化由 `status` 帧维护（宿主 `api-session/status` 的转发）。
  void _applySessionList(List<SessionSummary> list) {
    _sessions = [
      for (final s in list) s.copyWith(pendingCount: _pendingCountOf(s.sid)),
    ];
    _rows.applyList(_sessions);
    _syncNotices();
  }

  /// 宿主推来的一条运行态（`status` 帧）。
  void _applySessionStatus(SessionStatus status) {
    if (_disposed) return;
    final changed = _rows.applyStatus(status);
    // 只在真的变了的时候通知：这条流跟着宿主的 `agent/status` 走，
    // 相邻两次常常是同一状态（重连后的首条就是），没必要让整页重建。
    if (changed || status.running) notifyListeners();
    _syncNotices();
  }

  // ---- 通知与后台保活（端口在 `core/notify.dart`，实现只在 `platform/`）----
  //
  // 这一段的**全部输入都是既有事实**：`_runningSids` / `_completionUnread` /
  // 本地条目里的 `ApprovalItem` 与 `ask_user_question` 的 `ToolCallItem` /
  // `_currentSid` / 前后台态。**没有第四份状态机**，也没有落盘 —— "已提醒过哪几条"
  // 就记在 [_activeNotices] 里（派生，杀 App 即丢，与"完成绿点"同一条理由）。

  /// 前台还是后台（`AppStateReporter` 翻译 Flutter 生命周期之后调 [setAppForeground]）。
  bool _appForeground = true;

  /// 通知权限（原生报的真值）；`null` = 还没问过。
  bool? _notifyGranted;

  /// 电脑侧此刻允许我们发通知吗（设置页那行用；`null` = 不知道）。
  bool? get notifyGranted => _notifyGranted;

  /// 已经贴上去的那批（`id → notice`）：`_syncNotices` 靠它做增删差集。
  final Map<int, AttentionNotice> _activeNotices = <int, AttentionNotice>{};

  StreamSubscription<NotifyApproval>? _approvalSub;

  /// 前后台态变化（装配点从 `AppStateReporter` 转过来）。
  ///
  /// 它同时是两件事的输入：**通知**（前台且看着那个会话 ⇒ 不提醒）与
  /// **保活**（退到后台才需要那条前台服务）。
  void setAppForeground(bool foreground) {
    if (_appForeground == foreground) return;
    _appForeground = foreground;
    _syncNotices();
    unawaited(_syncKeepAlive());
  }

  /// **给连接层报哪个态**（`AppStateReporter` 的 `activeFor` 接到这里）。
  ///
  /// 退到后台**不再等于断开**：保活生效时（通知权限开着 **且** 连接在服务态），
  /// 照报 `foreground` —— 连接要活着、心跳要继续，而且这台设备仍然能直接答
  /// （通知上那两个按钮就是答案入口）。
  ///
  /// **判据就这一处**：`AppStateReporter` 只负责问，不自己判。
  /// 没保活时照旧报 `background` ⇒ 连接断开（§2.2 的老行为不变）。
  bool connectionForeground(bool appForeground) =>
      appForeground ||
      (_notifyGranted == true && client.state == ConnectionState.serving);

  /// 问一次通知权限（设置页那一行点下去调它）。
  ///
  /// 返回**问完之后**的真实状态；顺手把保活对齐（刚给了权限就该能起服务）。
  Future<bool> requestNotifyPermission() async {
    final port = _notify;
    if (port == null) return false;
    final granted = await port.requestPermission();
    _notifyGranted = granted;
    if (!_disposed) notifyListeners();
    await _syncKeepAlive();
    return granted;
  }

  /// 跳到系统的通知渠道设置（**声音/震动归系统**，App 不再造一套开关）。
  Future<void> openNotificationSettings() async =>
      _notify?.openChannelSettings();

  /// 通知上的按钮（原生回话）：走**既有的唯一出口** `interaction.respond`。
  ///
  /// 「允许一次」= `selected: ['allowed-once']`（DSH 的 outcome 值，
  /// `user-approval/src/types.ts:32`）；「拒绝」= 空 `selected` 且无 `custom`
  /// （契约 §5.7 那一行）。**没有"总是允许"**，所以通知按不出永久授权。
  Future<void> _answerFromNotification(NotifyApproval action) async {
    final sid = _sidOfPendingItem(action.itemId);
    if (sid == null) {
      // 找不到那个待处理项（已答 / 会话不在列表里）：撤掉通知，什么都不答。
      // 不猜一个 sid —— 答错会话比不答更糟。
      final stale = noticeIdOf('approval:${action.itemId}');
      _activeNotices.remove(stale);
      await _notify?.cancel(stale);
      return;
    }
    try {
      await respondInteraction(
        InteractionAnswer(
          sid: sid,
          itemId: action.itemId,
          answers: [
            InteractionAnswerItem(
              id: action.itemId,
              selected: action.allowedOnce ? const ['allowed-once'] : const [],
            ),
          ],
        ),
      );
    } catch (error) {
      // **失败照原样记下来**（`not-pending` 说明卡已经不在待处理里了），
      // 并撤掉那条通知 —— 让用户去 App 里看到真实状态，而不是对着一个
      // 已经无效的按钮反复按。
      _recordError('通知上的答复没能送达', error);
      final id = noticeIdOf('approval:${action.itemId}');
      _activeNotices.remove(id);
      await _notify?.cancel(id);
    }
  }

  /// 某个待处理项属于哪个会话（只查**已订阅**会话的本地条目）。
  ///
  /// 与 `_pendingCountOf` 同一个数据面，所以边界也一样：没访问过的会话在本地
  /// 没有条目（它的事件没订阅）—— 那种会话的审批**在手机上不提醒**
  /// （写在契约 §15）。
  String? _sidOfPendingItem(String itemId) {
    for (final session in _sessions) {
      for (final item in _storeOf(session.sid).items) {
        if (item is ApprovalItem && !item.decided && item.itemId == itemId) {
          return session.sid;
        }
      }
    }
    return null;
  }

  /// 期望的通知集合 —— **完全从既有事实派生**。
  List<AttentionNotice> _desiredNotices() {
    final notices = <AttentionNotice>[];
    for (final session in _sessions) {
      // 前台且正看着它 ⇒ 不提醒：结果就在眼前（与"完成绿点"同一条判据）。
      if (_appForeground && session.sid == _currentSid) continue;
      final title = session.displayTitle;
      for (final item in _storeOf(session.sid).items) {
        if (item is ApprovalItem && !item.decided) {
          notices.add(
            AttentionNotice(
              id: noticeIdOf('approval:${item.itemId}'),
              kind: NoticeKind.approval,
              sid: session.sid,
              title: '等你审批 · $title',
              body: item.title.isEmpty ? '有一项操作需要你确认' : item.title,
              itemId: item.itemId,
              allowLabel: '允许一次',
              denyLabel: '拒绝',
            ),
          );
        }
        // 提问：`ask_user_question` 的 `tool/call` 还没有 `tool/result` ——
        // 与连接器认身份的那条规则同一个判据（`connector/src/dsh/question-call.ts`）。
        if (item is ToolCallItem &&
            item.name == 'ask_user_question' &&
            item.status == ToolCallStatus.running) {
          notices.add(
            AttentionNotice(
              id: noticeIdOf('question:${item.itemId}'),
              kind: NoticeKind.question,
              sid: session.sid,
              title: '有人在问你 · $title',
              body: '点开回答（通知上不答题：答案要按问题逐条给）',
            ),
          );
        }
      }
      if (completionUnreadOf(session.sid)) {
        notices.add(
          AttentionNotice(
            id: noticeIdOf('completed:${session.sid}'),
            kind: NoticeKind.completed,
            sid: session.sid,
            title: '跑完了 · $title',
            body: '你没看着它的时候这一轮结束了',
          ),
        );
      }
    }
    return notices;
  }

  /// 把"该贴的"与"已贴的"对齐：消失的撤、新增的贴、同样的不动。
  void _syncNotices() {
    final port = _notify;
    if (port == null || _disposed) return;
    final desired = <int, AttentionNotice>{
      for (final notice in _desiredNotices()) notice.id: notice,
    };
    for (final id in _activeNotices.keys.toList()) {
      if (desired.containsKey(id)) continue;
      _activeNotices.remove(id);
      unawaited(port.cancel(id));
    }
    for (final entry in desired.entries) {
      if (_activeNotices.containsKey(entry.key)) continue;
      _activeNotices[entry.key] = entry.value;
      unawaited(port.show(entry.value));
    }
  }

  /// 前台服务：**退到后台 + 有通知权限 + 连接在服务态** ⇒ 保住它。
  ///
  /// 三条判据都是既有的：前后台态来自 `AppStateReporter`，权限是平台真值，
  /// "连接在服务态"就是 `client.state`。**没有第四条**。
  ///
  /// 为什么没权限就不起：平台原文说清 —— 拒绝 `POST_NOTIFICATIONS` 时前台服务的
  /// 通知进不了通知抽屉；那条服务唯一可观察的产出就没了，起了只是白耗电。
  Future<void> _syncKeepAlive() async {
    final port = _notify;
    if (port == null || _disposed) return;
    final status = await port.status();
    _notifyGranted = status.granted;
    final want =
        !_appForeground &&
        status.granted &&
        client.state == ConnectionState.serving;
    if (want && !status.keepAlive) {
      await port.startKeepAlive(
        title: 'DeepSeek Harness',
        // **不承诺"连接还在"**：进程会被系统冻结 / 被 ROM 杀掉，那时这句话就是假的
        // （2026-10-24 真机实测，见 `docs/subsystems/notifications.md` §2）。
        text: '后台保活已开启',
      );
    } else if (!want && status.keepAlive) {
      await port.stopKeepAlive();
      // 保活撤了而人还在后台 ⇒ 把连接**真的**断掉（否则服务没了、连接还在，
      // 那是"看不见的长连接"，比断开更糟）。
      if (!_appForeground) unawaited(client.setAppState(AppState.background));
    }
  }

  /// 连上（或冷启动）之后落到哪个会话 —— **只用宿主已有的数据**。
  ///
  /// 桌面的"当前打开哪个会话"是**浏览器本地 UI 状态**
  /// （`ui-chat` 的 `ctx.uiWorkspace.openSession`），宿主没有这个字段；
  /// 手机拿得到的只有 `session.list` 的 `updatedAt` 与 `running`。
  /// 所以落点规则只有四档：
  ///
  /// 1. 上次看的那个还在 → 回到它（它要是正在跑，界面直接显示"运行中"）；
  /// 2. 否则 **在跑的里面最新的**（"电脑那边还在跑"是最该先看见的状态）；
  /// 3. 再否则最新 `updatedAt` 的；
  /// 4. 列表为空 / 只有子会话 → `null`，保持空白屏，**不发明会话**。
  ///
  /// 子会话不参与落点：它属于某个父会话的视图（子智能体页另开一条路）。
  SessionSummary? landingSessionOf({String? remembered}) {
    final list = sessions;
    if (list.isEmpty) return null;
    if (remembered != null) {
      for (final row in list) {
        if (row.sid == remembered) return row;
      }
    }
    SessionSummary? best;
    for (final row in list) {
      if (row.subagent) continue;
      if (best == null) {
        best = row;
        continue;
      }
      final betterRunning = row.running && !best.running;
      final sameRunning = row.running == best.running;
      if (betterRunning || (sameRunning && row.updatedAt > best.updatedAt)) {
        best = row;
      }
    }
    return best;
  }

  /// **有没有在途的落点**（`true` = 还在等清单/落点，界面画加载态）。
  ///
  /// 默认 `true`（没有在途落点）：没连电脑、测试里的空模型都按原样画，
  /// 只有真的"进了服务态且还没落过"那一段才是 `false`。
  ///
  /// 不这么定的话，所有"没会话"的正常场景（未配对、列表空）都会被加载态挡住。
  /// 真机反馈与判据见 `app/test/landing_loading_test.dart` 的文件头。
  bool get landingDone => _landingDone;
  bool _landingDone = true;

  /// 是否已经落过一次（只在**第一次**落点时给界面加载态；重连不再闪）。
  bool _everLanded = false;

  /// 进服务态后的那一串：拉清单 → 落点。
  ///
  /// 界面在 `landingDone == false` 的这段窗口画加载态 —— 那正是"清单还没回来、
  /// 却已经画出没有会话那一屏"的来源（真机"连续跳好几个页面"）。
  Future<void> landAfterConnect() async {
    if (!_everLanded && _currentSid == null) {
      _landingDone = false;
      if (!_disposed) notifyListeners();
    }
    await refreshSessions();
    await landOnSession();
  }

  /// 连上之后落到 [landingSessionOf] 挑出来的那个会话（已经有会话就不动）。
  ///
  /// **任何出口都要置 [landingDone]**（`finally`）：清单为空 / 只有子会话也是
  /// 一次"尝试过了"—— 不置的话界面会一直转圈。
  Future<void> landOnSession() async {
    try {
      await _landOnSessionBody();
    } finally {
      if (!_landingDone) {
        _landingDone = true;
        _everLanded = true;
        if (!_disposed) notifyListeners();
      }
    }
  }

  Future<void> _landOnSessionBody() async {
    if (_disposed || _currentSid != null) return;
    // 唯一缝优先（`host.last_session`）；没装配缝时退到旧键（单测）。
    final remembered = _uiState != null
        ? _uiState!.lastSession
        : await _prefs?.read(kLastSessionKey);
    if (_disposed || _currentSid != null) return;
    final target = landingSessionOf(remembered: remembered);
    if (target == null) {
      // 第 4 档：列表空 / 只有子会话 ⇒ 不发明会话。此时若电脑侧还有一个 blank，
      // 落上去仍是"这一屏"（照 DSH 的 `reuseOrCreateBlank`，见该方法注释）——
      // 它是**兜底**，不是第 1 档之前的一步。
      await _openBlankSessionIfUnselected();
      return;
    }
    await openSession(target.sid);
  }

  /// 拉会话列表（`session.list`）。
  ///
  /// **失败不吞**：把错误记进 [lastError] 并让界面能显示。
  /// 吞掉的话界面只会显示"空列表"，而用户无从知道是"真没有会话"还是"请求失败了"。
  Future<void> refreshSessions() async {
    try {
      _applySessionList(await _fetchSessionRows());
      // **设备本地状态跟着清单失效**：清单里没有的会话，它的页签/草稿没有意义
      // （桌面从不清理 `dsh.conversation.<sid>`，那是 localStorage 的便宜，不是产品要求）。
      final ui = _uiState;
      if (ui != null) {
        unawaited(ui.pruneSessions({for (final s in _sessions) s.sid}));
      }
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
    await _catalogs.refreshModels();
    // 权限预设目录同理（进程级，与会话无关）。失败只留声：
    // 拿不到时权限 sheet 说"拿不到目录"，而不是摆三档手抄的名字。
    await _catalogs.refreshPermissions();
    // 工作区清单：会话列表**按它分组**（Web 的侧栏就是 工作区 → 会话）。
    // 失败只留声：拿不到时列表退回不分组，而不是按 `cwd` 猜一个分组。
    await refreshWorkspaces();
    // Agent 预设目录（hero 上那枚模式 chip 的名字来源）。同样只留声：
    // 拿不到时 chip 说"拿不到目录"，而不是摆一份手抄的四个内置预设。
    await _catalogs.refreshPresets();
    // 设置面（三行：默认权限档 / 默认 Agent 预设 / Session Log 开关）。
    // 拿不到时那三行**不出现**（不是摆一个假开关），与 `settings.describe` 的能力位同一条。
    await refreshSettings();
    // 电脑侧 DSH 版本（`repo.info.dshVersion`）：与 App 版本并排显示，排错用。
    await refreshRepoInfo();
    // **这里不选会话**：落点是 `_landOnSession()` 一个人的事（四档规则见
    // `docs/subsystems/connect-landing.md` §2）。
    // Note: 为什么不允许两条落点路径 —— 见
    // `.agents/notes/implemented/2026-10-27-connect-landing-single-path.md`。
    // 2026-10-27 真机实测：
    // 这一步原先在这里 `_openBlankSessionIfUnselected()`，把 blank 先选中了，
    // 于是随后的 `_landOnSession()` 撞上 `_currentSid != null` 直接早退 ——
    // 记住的会话永远没机会，还顺手把 `host.last_session` 覆盖成那个 blank。
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
    if (_disposed) return;
    if (_currentSid != null) return;
    // **找不到 blank 就什么都不做**（不是建一个）：建是 `createSession` 的事，
    // 这里只负责"选中"。
    final blank = await findBlankSession();
    if (blank == null) return;
    await openSession(blank);
  }

  /// 现有的 blank 会话（`session.list` 的 `blank` 为真的第一个，非子智能体）。
  ///
  /// `null` = 这台电脑上现在没有 blank 会话（列表空 / 全是跑过的会话）。
  ///
  /// ## 为什么"新建会话"要先问它
  ///
  /// DSH Web 的 `startSession` 是 **reuse-or-create**
  /// （`ui-sidebar/src/client/contract/slots.ts:119-121` 原话：
  /// "with a workspace, reuse-or-create its blank session and open it"）——
  /// 先复用现有的 blank，没有才建。而我们原先的「新建会话」直接
  /// `session.create`，**每点一次就在电脑侧多一个会话**（用户反悔不發消息
  /// 也留着，抽屉里慢慢堆满空会话）。
  ///
  /// ## [workspaceId]：只复用这个工作区里的 blank
  ///
  /// 判据照 DSH 的 `createInWorkspace`
  /// （`ui-workspace/src/client/navigation.ts:220-233`）：
  /// `blank && cwd == workspace.path && workspace.sessionIds.includes(id) && !archived`。
  /// 不筛的话，手机会复用一个属于**别的工作区**的 blank，于是"新建会话"
  /// 落进别的分组（或未分组）—— 与 `session.create` 不带 `workspaceId` 同一个症状。
  Future<String?> findBlankSession({String? workspaceId}) async {
    if (_disposed) return null;
    WorkspaceGroup? group;
    if (workspaceId != null) {
      for (final g in _workspaces) {
        if (g.workspaceId == workspaceId) group = g;
      }
      // 给了工作区但清单里没有它：**一个 blank 都不复用** —— 清单过期时宁可新建，
      // 也不要把别组的 blank 拖进这一组（那正是"新会话落进别的分组"的成因）。
      if (group == null) return null;
    }
    for (final s in _sessions) {
      if (!s.blank || s.subagent) continue;
      if (_archivedSids.contains(s.sid)) continue;
      if (group == null) return s.sid;
      if (!group.sessionIds.contains(s.sid)) continue;
      if (s.cwd != group.path) continue;
      return s.sid;
    }
    return null;
  }

  /// Agent 预设目录（`agentPresets.list`）；没拉过是 `null`。转发给 [HostCatalogs]。
  AgentPresetRoster? get agentPresetRoster => _catalogs.agentPresetRoster;

  /// 当前会话跑的是哪个预设（`agentPreset` 投影的 `string | null`）。
  ///
  /// **`null` 就是"这个会话没记过预设"**（老会话，或这台电脑没有预设服务）——
  /// 界面退回"按目录里的默认项显示"或显示 id，不猜一个档。
  ///
  /// 不另判 `_currentSid == null`：与 [permissionValue] 同一条（getter 已按归属判过）。
  String? get agentPresetValue => projections?.agentPreset;

  /// 当前会话归属的工作区；`null` = 清单里没有它（或清单还没到）。
  WorkspaceGroup? get currentWorkspace {
    final sid = _currentSid;
    if (sid == null) return null;
    // 索引按 `_workspaces` 的**同一性**重建（同 `_sessionIndexMap` 的理由：
    // 逐处记重建 = 会漏）。原来这里是 `workspaceGroupOf`，O(工作区×成员) 且
    // 在 hero / sheet 的 build 里被问三次。
    if (!identical(_indexedWorkspaces, _workspaces)) {
      _indexedWorkspaces = _workspaces;
      _workspaceIndex = <String, WorkspaceGroup>{
        for (final group in _workspaces)
          for (final member in group.sessionIds) member: group,
      };
    }
    return _workspaceIndex[sid];
  }

  List<WorkspaceGroup>? _indexedWorkspaces;
  Map<String, WorkspaceGroup> _workspaceIndex = const {};

  /// 新建会话会落在哪个工作区（`null` = 这台电脑一个工作区都没有）。
  ///
  /// 链照 DSH 的 `startSession`：当前会话所在工作区 → 最近工作区
  /// （`ui-workspace/src/client/navigation.ts:320-334`、`:553-572`），
  /// 实现与偏离见 `model/workspace.dart` 的 `newSessionWorkspaceId`。
  ///
  /// **它决定会话进哪个分组**：`session.create` 不带 `workspaceId` 时宿主不把
  /// 会话记进任何工作区的账本（`session-controller/src/commands.ts:116-148`），
  /// 而分组只认账本（`workspace.list` 的 `sessionIds`）—— 那样的会话在抽屉里
  /// 永远是「未分组」（2026-10-22 真机反馈）。
  String? get defaultNewSessionWorkspaceId => newSessionWorkspaceId(
    currentWorkspaceId: currentWorkspace?.workspaceId,
    groups: _workspaces,
    updatedAtOf: (sid) {
      for (final s in _sessions) {
        if (s.sid == sid) return s.updatedAt;
      }
      return -1;
    },
  );

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

  /// 拉一次工作区清单（会话列表按它分组）。
  ///
  /// **拿不到就留空**（`_workspaces` 空列表）：界面退回不分组。按 `cwd` 猜分组
  /// 是第二份真值 —— `cwd` 与工作区不是一对一，猜错比不分组更难查。
  /// 方法不存在（老连接器 / 没装 `workspaceController`）与读取失败都走这条：
  /// 分组是增强，不是正确性前提。
  Future<void> refreshWorkspaces() async {
    try {
      // 形状（分组 + 两列 id，**同一份应答**）在 `wire/rpc/workspace.dart`。
      final snapshot = await wire.loadWorkspaceList(client);
      if (snapshot == null) return;
      if (_disposed) return;
      _workspaces = snapshot.groups;
      // 归档集、置顶集与工作区分组**同一份应答**（`workspace.list` 同时带
      // `archivedSessionIds` 与 `pinnedSessionIds`）—— 分两次解析会让
      // "列表看过一眼、归档/置顶集还是旧的"。
      _archivedSids = snapshot.archivedSessionIds;
      _pinnedSids = snapshot.pinnedSessionIds;
      // 工作区被删 ⇒ 裁掉它的折叠记忆（照桌面 `retainAccountKeys`，
      // `ui-workspace/src/client/stores.ts:100-109`）。
      final ui = _uiState;
      if (ui != null) {
        unawaited(
          ui.pruneWorkspaces({for (final g in snapshot.groups) g.workspaceId}),
        );
      }
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

  /// 已置顶的会话 sid 集合（`workspace.list` 的 `pinnedSessionIds`）。
  ///
  /// **registry 全局集合**（不分工作区），顺序在集合里不重要：显示时只按
  /// "置顶 / 非置顶"分区，区内仍照电脑侧给的会话顺序（DSH Web 的 `sectionMembers`，
  /// `ui-workspace/src/client/tree.ts:273-287`）。
  Set<String> get pinnedSids => _pinnedSids;
  Set<String> _pinnedSids = const {};

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
      final archived = await wire.workspaceArchive(
        client,
        sid: sid,
        stopActivity: stopActivity,
        requestId: newRequestId('arc'),
      );
      // 应答认不出就**不动**：有损地落一个归档集会让"哪条是归档的"错位，
      // 而症状只是"列表里少了一条"。**但归档本身已经成功**（宿主回的 ok），
      // 所以仍返回 true —— 不能对写操作说谎；读不出的那一半已经计过数。
      if (archived != null && !_disposed) {
        _archivedSids = archived;
        notifyListeners();
      }
      return true;
    } catch (error) {
      _recordError('归档失败', error);
      return false;
    }
  }

  /// 取消归档（**宿主侧幂等**：没归档过的 id 也成功）。
  Future<bool> unarchiveSession(String sid) async {
    try {
      final archived = await wire.workspaceUnarchive(
        client,
        sid: sid,
        requestId: newRequestId('unarc'),
      );
      if (archived != null && !_disposed) {
        _archivedSids = archived;
        notifyListeners();
      }
      return true;
    } catch (error) {
      _recordError('取消归档失败', error);
      return false;
    }
  }

  /// 置顶一个会话（`workspace.pin`）。
  ///
  /// 宿主返回**置顶全集**（最近置顶的在前）；手机不本地猜，照应答落。
  /// 归档与置顶互斥：已归档的会话会被宿主拒成 `gateway/bad-request`
  /// （`workspace-controller/src/commands.ts:209-211`）—— 主列表本来就不列
  /// 已归档行，所以这里不预判，出错照实显示。
  Future<bool> pinSession(String sid) async {
    try {
      final pinned = await wire.workspacePin(
        client,
        sid: sid,
        requestId: newRequestId('pin'),
      );
      if (pinned == null) {
        // 置顶**是写操作但应答是"整份真值"**：读不出就没法把本地的集合对齐，
        // 而错位的表现是"某条没置顶"。如实报错，不假装成功（与旧行为一致）。
        _recordError('置顶失败', StateError('应答缺少 pinnedSessionIds'));
        return false;
      }
      if (_disposed) return true;
      _pinnedSids = pinned;
      notifyListeners();
      return true;
    } catch (error) {
      _recordError('置顶失败', error);
      return false;
    }
  }

  /// 取消置顶（宿主侧幂等：没置顶过的 id 也成功）。
  Future<bool> unpinSession(String sid) async {
    try {
      final pinned = await wire.workspaceUnpin(
        client,
        sid: sid,
        requestId: newRequestId('unpin'),
      );
      if (pinned == null) {
        _recordError('取消置顶失败', StateError('应答缺少 pinnedSessionIds'));
        return false;
      }
      if (_disposed) return true;
      _pinnedSids = pinned;
      notifyListeners();
      return true;
    } catch (error) {
      _recordError('取消置顶失败', error);
      return false;
    }
  }

  /// 在同一工作区内把 [sid] 移到 [beforeSid] 之前。
  ///
  /// [beforeSid] 为 `null` 表示**追加到末尾**（DSH 的 `beforeSessionId?` 缺省语义）。
  /// 越界（首条上移 / 末条下移）由调用方先挡掉，不发请求。
  ///
  /// 返回的是该工作区**新的**会话顺序（`{sessionIds}`，已换回手机见的 sid），
  /// 所以落本地时直接替换那一组的 `sessionIds`，不重读整份基线。
  Future<bool> moveSession(String sid, {required String? beforeSid}) async {
    final group = workspaceGroupOf(sid, _workspaces);
    if (group == null) {
      _recordError('移动会话失败', StateError('会话不属于任何工作区'));
      return false;
    }
    try {
      final order = await wire.workspaceInsertSessionBefore(
        client,
        workspaceId: group.workspaceId,
        sid: sid,
        beforeSid: beforeSid,
        requestId: newRequestId('mv'),
      );
      if (order == null) {
        _recordError('移动会话失败', StateError('应答缺少 sessionIds'));
        return false;
      }
      _applyWorkspaceOrder(group.workspaceId, order);
      return true;
    } catch (error) {
      _recordError('移动会话失败', error);
      return false;
    }
  }

  /// 把一个**工作区**挪到 [beforeWorkspaceId] 之前（`null` = 移到末尾）。
  ///
  /// 与 [moveSession] 是两条：那条改**组内会话**顺序，这条改**工作区自己**的顺序
  /// （侧栏项目头的上下位置）。宿主返回**整份** `{workspaceIds}`，照它重排
  /// [_workspaces]；应答里没提到的组留在末尾，不丢。
  Future<bool> moveWorkspace(
    String workspaceId, {
    required String? beforeWorkspaceId,
  }) async {
    try {
      final order = await wire.workspaceInsertBefore(
        client,
        workspaceId: workspaceId,
        beforeWorkspaceId: beforeWorkspaceId,
        requestId: newRequestId('mvw'),
      );
      if (order == null) {
        _recordError('移动工作区失败', StateError('应答缺少 workspaceIds'));
        return false;
      }
      _applyWorkspaceListOrder(order);
      return true;
    } catch (error) {
      _recordError('移动工作区失败', error);
      return false;
    }
  }

  /// 用应答里的**整份**顺序重排 [_workspaces]。
  ///
  /// 只认已知的 workspaceId：应答里多出来的（宿主新增、手机还没读到的）跳过，
  /// 没提到的保留在末尾 —— 排序是增强，**不能因为一次重排把组弄丢**。
  void _applyWorkspaceListOrder(List<String> order) {
    if (_disposed) return;
    final byId = {for (final group in _workspaces) group.workspaceId: group};
    final next = <WorkspaceGroup>[
      // 应答里多出来的 id（宿主新增、手机还没读到）落成 null 被丢掉 ——
      // 排序是增强，不认识的组留在下面那段兜底里。
      for (final id in order) ?byId[id],
    ];
    final seen = {for (final group in next) group.workspaceId};
    for (final group in _workspaces) {
      if (!seen.contains(group.workspaceId)) next.add(group);
    }
    _workspaces = next;
    notifyListeners();
  }

  /// 用应答里的顺序替换那一组的 `sessionIds`。**只动这一组**：别的组没有新真值。
  void _applyWorkspaceOrder(String workspaceId, List<String> sessionIds) {
    if (_disposed) return;
    _workspaces = [
      for (final group in _workspaces)
        if (group.workspaceId == workspaceId)
          WorkspaceGroup(
            workspaceId: group.workspaceId,
            title: group.title,
            path: group.path,
            sessionIds: sessionIds,
          )
        else
          group,
    ];
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

  /// 某个会话此刻有几个**未决**待处理（审批/提问，从本地投影数）。
  ///
  /// 与 UI 层 `TakeoverController` 的桶同源而未连通：那里管"输入栏显示哪个"，
  /// 这里管"列表里告诉用户有几个"。**故意不合成一个** —— 数据层不认识 UI 状态机。
  /// 会话行的待处理计数。
  ///
  /// 直接读 `SessionStore.pendingCount`（**它自己按条目列表同一性缓存**，
  /// `session_store.dart:114-122`），不再每次列表刷新都重扫全部条目：
  /// 原来这条在"会话数 × 条目数"上是 O(n²) 的。
  int _pendingCountOf(String sid) => _storeOf(sid).pendingCount;

  /// 新建会话。
  ///
  /// **会话由电脑侧建**（它才是会话的 owner），所以这里走 `session.create`，
  /// 然后把新 sid 加进列表并打开它。
  ///
  /// 它走 `outbox`（带幂等键的写操作）：点了两次不会建出两个会话 ——
  /// 重发复用同一个 `requestId`，电脑侧去重。
  ///
  /// [workspaceId] / [agentPreset] 是 hero 上那两枚 chip 的选择。
  ///
  /// **不给 `workspaceId` 时按 DSH 的链解析**（显式 → 当前会话工作区 →
  /// 最近工作区，见 [defaultNewSessionWorkspaceId]）：不带 `workspaceId` 建的
  /// 会话不会进任何工作区的账本（`session-controller/src/commands.ts:116-148`），
  /// 而分组只认账本 —— 那样的会话在抽屉里**永远是「未分组」**。
  /// 解析不出来（这台电脑一个工作区都没有）时才真的不塞：那时"未分组"是事实。
  ///
  /// Note: 链的来源、被否方案（`cwd` / 本地塞组 / 默认工作区）与代价 ——
  /// 见 `.agents/notes/implemented/2026-10-22-new-session-lands-in-a-workspace.md`。
  ///
  /// [agentPreset] 仍然是"不给就不塞"（DSH 有默认预设）。
  ///
  /// 选预设走这里而不是 `agentPresets.select`：后者对**跑过一轮**的会话会拒
  /// （`agent-preset/locked`，`agent-preset-registry/src/index.ts:351`），
  /// 而建会话时带上根本不会碰到那条限制。取舍见
  /// `.agents/notes/implemented/2026-10-17-blank-session-hero.md`。
  Future<void> createSession({String? workspaceId, String? agentPreset}) async {
    final targetWorkspaceId = workspaceId ?? defaultNewSessionWorkspaceId;
    // 方法名与参数形状（含"两个可选键只发有值的那个"）在
    // `wire/rpc/session.dart` 的 `createSession`；`sid` 缺失会在那边计数并回 null。
    final sid = await wire.createSession(
      client,
      workspaceId: targetWorkspaceId,
      agentPreset: agentPreset,
      requestId: newRequestId('new'),
    );
    if (sid == null) {
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
    // **建完立刻重读工作区清单**：分组只认 `workspace.list` 的 `sessionIds`
    // （`workspaceGroupOf`），而刚建出来的会话还没进那份快照 ——
    // 不重读的话抽屉会把它摆在「未分组」，直到下一次刷新（实测：杀 App 重开才对）。
    // 失败只留声（`refreshWorkspaces` 自己兜），不影响"会话已经建好"这个事实。
    await refreshWorkspaces();
  }

  /// 在一轮的收口处**分支**（`session.fork`），回子会话别名。
  ///
  /// 成功后**重拉一次会话列表**：子会话要进抽屉（与 `createSession` 同一步）。
  /// 失败把原因留在 [lastError] 并返回 `null` —— 界面如实弹错误，
  /// **不假装成功**（fork 是宿主状态，客户端伪造不了）。
  Future<String?> forkSession(String sid, {int? atSeq}) async {
    try {
      final child = await wire.forkSession(client, sid: sid, atSeq: atSeq);
      if (child == null) {
        _recordError('分支失败', StateError('电脑侧的分支应答形状认不出'));
        return null;
      }
      await refreshSessions();
      return child;
    } catch (error) {
      _recordError('分支失败', error);
      return null;
    }
  }

  /// 打开一个会话：订阅它，并把条目喂给 store。
  ///
  /// [since] 是本地已有的水位（本地库还没做，先给 0 = 从零开始，电脑侧会给快照）。
  Future<void> openSession(String sid, {int since = 0}) async {
    _currentSid = sid;
    // 打开它就是"看见了"：未读的完成点当场消失（DSH 的"在主视图里就清"，`:511`）。
    _rows.markSeen(sid);
    if (!_disposed) notifyListeners();

    // 订阅前先把这一路的事件流接上（顺序反了会丢掉开启帧 —— 那是第一帧）。
    _deltaSubs[sid] ??= client.sessionUpdates(sid).listen((delta) {
      _onDelta(sid, delta);
    });

    // 记住"上次看的是哪个"：下次连上（或冷启动）落回它 —— 见 [landingSessionOf]。
    final ui = _uiState;
    if (ui != null) {
      unawaited(ui.setLastSession(sid));
    } else {
      unawaited(_prefs?.write(kLastSessionKey, sid));
    }
    // 页签：**按会话懒读一次**（不在 `build` 里读盘），读到的 id 进内存。
    unawaited(_loadView(sid));

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
    // 换了会话就重判通知：切到的那个会话不该再有一条"等你处理"挂在通知栏里
    // （与"点进去绿点消失"同一条判据）。
    _syncNotices();
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

  /// 会话行的运行态事实（在跑 / 子智能体在跑 / 未读完成 / 活时钟 / 轮号）。
  ///
  /// 判据与"为什么不再自建状态机"都在 `data/session_rows.dart` 的文件头。
  late final SessionRows _rows = SessionRows(
    rowOf: sessionOf,
    currentSidOf: () => _currentSid,
  );

  /// 这个会话此刻在跑吗（唯一真值：宿主的 `status` 帧 + `session.list` 覆盖）。
  bool runningOf(String sid) => _rows.runningOf(sid);

  /// 这个会话有几个**直接子智能体**此刻在跑（公式照桌面 `tree.ts:381-386`）。
  int runningChildrenOf(String sid) => _rows.runningChildrenOf(sid);

  /// 这个会话"跑完了、但我没看着"—— DSH 的 `completionUnread`。
  ///
  /// **派生、不落盘**：DSH 的浏览器端也只持有一个 `Set<SessionId>`
  /// （`ui-session/src/client/index.ts:292`），刷新即丢；代价如实记 ——
  /// 杀 App 即丢，与浏览器刷新一致（这是"一个提示"，不是持久事实）。
  bool completionUnreadOf(String sid) => _rows.completionUnreadOf(sid);

  /// 本轮开始的时刻（毫秒 epoch）；`null` = 不知道。
  ///
  /// 兜底读 `trajectory` 投影里那一轮的 `startTime`，但**只对当前会话** ——
  /// 投影是按当前会话读的，别的会话拿它等于张冠李戴。
  int? turnStartedAtOf(String sid) {
    final fromEvents = _rows.startedAtOf(sid);
    if (fromEvents != null) return fromEvents;
    if (sid != _currentSid) return null;
    return trajectory?.runningTurn?.startTime;
  }

  // Note: 逐条错误隔离（一条坏事件不再炸掉整批）+ 插话判定（DSH
  // SteeringHistory 的移植）—— 见
  // .agents/notes/implemented/2026-10-17-conversation-rendering-fills-dsh-gaps.md
  /// 这条事件属于第几轮：事件自带 `data.turn` 就用它，否则退回
  /// "最近一次 `turn/start` 的轮号"（[SessionRows.currentTurnOf]）。
  /// 两边都没有就是 `null` —— 那种条目在轮组里落进"未归属"，不参与折叠（不猜）。
  int? _turnOfEvent(SessionEvent event, String sid) {
    final raw = event.data is Map ? (event.data as Map)['turn'] : null;
    return raw is int ? raw : _rows.currentTurnOf(sid);
  }

  void _onDelta(String sid, SessionDelta delta) {
    if (_disposed) return;
    final store = _storeOf(sid);

    // **持久事件** → 投影成界面条目 → upsert。
    // 一次恢复可能带一批：`upsertAll` 内部把通知合并成一次。
    if (delta.events.isNotEmpty) {
      final items = <ChatItem>[];
      var inboxChanged = false;
      // 这一批里有没有 `turn/end`（循环末尾据此补一次会话行 —— 见下面那段注释）。
      var turnEnded = false;
      final tracker = _inboxTrackers.putIfAbsent(sid, () => _InboxTracker());
      // **本批已投影的条目**（itemId → 条目）：`tool/call` 与 `tool/result`
      // 可能在同一个 delta 里先后到达，而 `store.upsertAll` 在循环之后才发生 ——
      // 那时结果要找的"前一个条目"还没落表。所以前一个值按
      // "本批优先、落表兜底"取（DSH 的 `update(context, match)` 同样是
      // 在同一个 Context 里滚动状态，不是回到库里查）。
      final inBatch = <String, ChatItem>{};
      for (final event in delta.events) {
        // **"这一轮在跑吗"不在这里判**：它走宿主的 `status` 帧（见 `_runningSids`）。
        // `turn/start` 的 `time` 仍然是活时钟的起点 —— 那是事件的**时间事实**，
        // 推送里没有它。
        if (event.type == 'turn/start') {
          _rows.noteTurnStart(sid, time: event.time);
        }
        // **`session/title` 不是条目，是标题的真值**：DSH 生成/改名时落一条
        // （`session-title/src/index.ts` 的 fold 就认这个 type）。它进条目表
        // 只会渲染出一条莫名其妙的"其它事件"，所以在这里截住并落地成标题。
        if (event.type == 'turn/end') turnEnded = true;
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
        // 批次里（翻页/快照加载时前者在更早的批次），只靠本批就拿不到这一轮的
        // seq 区间，计数会**永远是 0**。落成 OtherItem 后，`_turnStatsOf`
        // 能从 store 里翻到它。
        //
        // **用时不再从这里来**（2026-10-22）：它由电脑侧折进 `trajectory`
        // 投影、随 `session.projections` 下发（`model/trajectory.dart`）——
        // 手机一个时间减法都不做。
        if (event.type == 'turn/start') {
          final turn = event.data is Map ? (event.data as Map)['turn'] : null;
          if (turn is int) {
            // **轮号要落在条目上**：轮组靠它知道"从这里开始是新的一轮"
            // （`docs/subsystems/turn-groups.md`）。
            _rows.noteTurnStart(sid, time: event.time, turn: turn);
            items.add(
              OtherItem(
                itemId: event.itemId,
                seq: event.seq,
                updatedAt: event.time,
                turn: turn,
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
          // **`turn/end` 专用入参**：该轮已收录条目的计数。投影层是纯函数，
          // 不认识"哪些条目属于这一轮"，所以由这一层按 seq 区间数好给进来。
          //
          // **落表兜底**：`turn/start` 与 `turn/end` 常常不在同一个 delta
          // 批次里（翻页 / 快照加载时前者在更早的批次）。只靠 store 里那条
          // `OtherItem`（`turn/start` 落表用的）就能拿到区间。
          final projection = projectEvent(
            type: event.type,
            seq: event.seq,
            data: event.data,
            time: event.time,
            steering:
                event.type == 'user/message' &&
                tracker.claimIfSteering(event.data),
            // **唤醒新一轮的非人消息**：DSH 按 `inbox-next-turn` 的 claim 认它
            // （`conversation-nodes/message.ts:96-111`），判成 `turn-trigger` 节点，
            // 标题按 `source.kind` 换词（「子任务状态更新」/「收到任务消息」…，
            // `chat/turn-trigger.ts:29-70` + `locale.ts:53-62`）。
            // 不认这条，界面上就只剩「上下文注入」——用户看不到"是谁触发了这一轮"。
            waking:
                event.type == 'user/message' &&
                tracker.claimIfWaking(event.data),
            // **upsert 的前一个值**：`tool/result` 要靠它把工具名与参数
            // 从 `tool/call` 继承过来（DSH `rootResult(match, previous)`，
            // 真日志里结果消息不带名字）。投影层自己是纯函数，所以
            // "前一个条目是什么"由这一层给。
            previous: inBatch[event.itemId] ?? store.byId(event.itemId),
            turnStats: event.type == 'turn/end'
                ? _turnStatsOf(
                    store,
                    inBatch,
                    _turnStartSeqOf(store, event.data, event.seq),
                    event.seq,
                  )
                : null,
            // **这一条属于第几轮**：事件自带就用它，否则用最近一次
            // `turn/start`（`user/message` / `command/*` / `llm/retry` /
            // `compaction/*` 都不带 `turn`，而真机日志的次序是
            // `turn/start` → `step/start` → `user/message`）。
            turn: _turnOfEvent(event, sid),
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
        _refreshProjectionsOnce(sid);
      }
      // **回合结束 = 时间轴变了**：`trajectory` 投影的 `endTime` / `durationMs`
      // 正是 `turn/end` 折出来的（连接器 `src/dsh/trajectory.ts`）。不重读的话
      // 这一轮的段会永远停在"还在跑"，用量也就永远没有 —— 真机上是
      // "对话流里那一行说用时未知，轨迹页那一轮没有长度"。
      //
      // 只读当前会话：`_projections` 只装当前会话那一包（`_applyProjectionValues`），
      // 给后台会话补读没有落点；同一次收帧里若已有一次在飞，就并进那次
      // （`turn/end` 可能跟着一串事件到达，一次就够）。
      if (turnEnded && sid == _currentSid) {
        _refreshProjectionsOnce(sid);
      }
      // **回合结束 = 子会话那一包行可能变了**（新建 / 跑完 / token 涨）。
      // 顶栏那枚「N 个子智能体，正在运行」读的就是这些行的 `running`，
      // 而它只在 连上 / 建会话 / 打开子智能体面板 时拉过 —— 真机上于是
      // **计数（来自目录）会变、running 永远不亮**（2026-10-21 验收抓到）。
      // 只在当前会话**真有子智能体**时补一次：普通会话多一次 list 没有信息量。
      if (turnEnded && _subagentCatalogs[sid]?.entries.isNotEmpty == true) {
        unawaited(refreshSessionMetrics());
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
    // 待处理集合（审批 / 提问）就长在条目里，所以收帧之后对齐一次通知 ——
    // "有人等你"这件事的新增与消失都在这里发生。
    _syncNotices();
  }

  /// `turn/end` 载荷里的轮次号（取不到是 null）。
  static int? _turnOf(Object? data) =>
      data is Map && data['turn'] is int ? data['turn'] as int : null;

  /// 该轮 `turn/start` 的 seq（`turn/end` 前最近的一条）。
  ///
  /// 为什么从落表翻：`turn/start` 与 `turn/end` 常常不在同一个 delta 批次里
  /// （翻页 / 快照加载时前者在更早的批次）。落表的那条是
  /// `OtherItem(eventType: 'turn/start')`，所以这里靠 **seq 小于 `turn/end`
  /// 的最后一条**认它 —— 同轮只可能有一条 `turn/start`（DSH 的格式不变量：
  /// turn 号递增），所以"最后一条"就是它。
  ///
  /// **只取 seq，不取 time**：用时由电脑侧算（`trajectory` 投影），这一层
  /// 拿时间只可能是为了做减法 —— 那正是禁止的（2026-10-22）。
  static int? _turnStartSeqOf(SessionStore store, Object? endData, int endSeq) {
    if (_turnOf(endData) == null) return null;
    int? found;
    for (final item in store.items) {
      if (item is! OtherItem || item.eventType != 'turn/start') continue;
      if (item.seq >= endSeq) continue;
      if (found == null || item.seq > found) found = item.seq;
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
  static TurnStats _turnStatsOf(
    SessionStore store,
    Map<String, ChatItem> inBatch,
    int? startSeq,
    int endSeq,
  ) {
    if (startSeq == null) return const TurnStats();
    var messages = 0;
    var tools = 0;
    var subagents = 0;
    // **该轮各条助手消息的用量相加** —— 一个 turn 有多步，每步一条
    // `assistant/message`（真日志：8641 个 step/start 对 8634 条
    // assistant/message）。DSH 的 `aggregateAttempts` 也是把该轮各次尝试的
    // `totalTokens` 相加（`turn-usage.ts:130`），不是取最后一条。
    TurnTokenUsage? usage;
    // 该轮助手回复的正文（多步按 seq 顺序拼）—— 「复制」那一枚要复制它。
    final assistantTexts = <({int seq, String text})>[];
    // **本批优先、落表兜底**：同一条目可能两处都有（`tool/call` 在本批、
    // 更早的 `tool/result` 在表里），按 itemId 去重后各计一次。
    final seen = <String>{};
    for (final item in [...inBatch.values, ...store.items]) {
      if (!seen.add(item.itemId)) continue;
      if (item.seq < startSeq || item.seq > endSeq) continue;
      // **"几条消息"只数带正文的**：DSH 的 `messageCount` 走
      // `hasAssistantReplyContent`（`assistant-content.ts:9-15`，reasoning 与
      // tool-call 都不算回复内容）。一个 turn 里"只有思考 + 调工具"的那一步
      // 现在投影成 [ReasoningItem]，它计入 token 合计、不计入条数。
      if (item is ReasoningItem) {
        final sample = item.usage;
        if (sample != null) usage = usage == null ? sample : usage + sample;
      } else if (item is MessageItem && item.role == MessageRole.assistant) {
        final sample = item.usage;
        if (sample != null) usage = usage == null ? sample : usage + sample;
        if (item.text.trim().isNotEmpty) {
          messages += 1;
          assistantTexts.add((seq: item.seq, text: item.text));
        }
      } else if (item is ToolCallItem) {
        if (_isSubagentDelegation(item.name)) {
          subagents += 1;
        } else {
          tools += 1;
        }
      }
    }
    assistantTexts.sort((a, b) => a.seq.compareTo(b.seq));
    return TurnStats(
      messages: messages,
      tools: tools,
      subagents: subagents,
      usage: usage,
      text: assistantTexts.map((e) => e.text).join('\n\n'),
    );
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
  /// 键是**卡自己的 `itemId`**（`i:<approvalId>` / `t:<callId>`）—— 连接器的在途 claim
  /// 也以它为键；幂等键用同一个值（§5.6：键形状由业务定，`i:` / `t:` 带冒号只进信封），
  /// 所以重复点两次不会变成两次授权。
  ///
  /// 失败**照原样抛**：调用方（接管卡）要据此把那一项标成"已过期"，
  /// 而吞掉它会让用户以为答成功了 —— 答案从未进入会话。
  Future<void> respondInteraction(InteractionAnswer answer) async {
    // 形状（`{sid, itemId, answers}` + 幂等键 = itemId）在 `wire/rpc/interaction.dart`；
    // 这一层只负责把答复批次**原样**递过去（一个字段都不翻译）。
    await wire.respondInteraction(
      client,
      sid: answer.sid,
      itemId: answer.itemId,
      answers: <Map<String, Object?>>[
        for (final item in answer.answers)
          <String, Object?>{
            'id': item.id,
            'selected': item.selected,
            if (item.custom != null) 'custom': item.custom,
          },
      ],
    );
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

  /// 释放（**幂等**）。
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_stateSub?.cancel());
    unawaited(_jobSub?.cancel());
    unawaited(_statusSub?.cancel());
    for (final sub in _deltaSubs.values) {
      unawaited(sub.cancel());
    }
    _deltaSubs.clear();
    unawaited(_interactions.close());
    // 通知：**收尾要干净** —— 撤掉自己贴的那批、停掉前台服务（否则 App 已经
    // 不在了，通知栏里还挂着一条"正在保持连接"的骗人常驻）。
    unawaited(_approvalSub?.cancel());
    final port = _notify;
    if (port != null) {
      unawaited(port.cancelAll());
      unawaited(port.stopKeepAlive());
    }
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

  /// 从 **next-turn** 被 claim 掉的 id：随后到达的非人消息就是**唤醒该轮**的那条
  /// （DSH `conversation-nodes/message.ts:97,110` 的 `inbox-next-turn.currentClaimed`）。
  final Set<String> _claimedNextTurn = <String>{};

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
      _claimedNextTurn.remove(id);
    }
    // 取消的 splice 不算 claim（消息又回到队列里）。
    if (data['outcome'] == 'canceled') return;
    // **只有从 next-step 被 claim 掉的才是插话候选**。
    if (target == 'next-step') _claimedNextStep.addAll(removed);
    // 从 next-turn 被 claim 掉的：这条非人消息**唤醒了新一轮**（turn-trigger）。
    if (target == 'next-turn') _claimedNextTurn.addAll(removed);
  }

  /// 一条**非人**的 `user/message` 是不是唤醒了新一轮（消费掉那个候选）。
  ///
  /// 判据照 DSH：`source.kind !== 'user'` 且 id 在 `next-turn` 的 claim 里
  /// （`conversation-nodes/message.ts:96-111`）。
  bool claimIfWaking(Object? data) {
    if (data is! Map) return false;
    final id = data['id'];
    if (id is! String || id.isEmpty) return false;
    if (!_claimedNextTurn.remove(id)) return false;
    final source = data['source'];
    return source is Map && source['kind'] != 'user';
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
