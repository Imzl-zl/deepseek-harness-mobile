/// 按有序端点表拨号，失败自动换下一个（契约 §14.6 的直连拓扑 + §2 的中转拓扑）。
///
/// ## 它解决什么
///
/// 手机侧原来只有一个端点（`PairedCredentials.relayUrl`），传输层写死
/// `TicketedWebSocketTransport` —— 于是"直连"这种拨号**无法表达**：
/// 直连不要票、不走 `/ws/device?ticket=`。把端点提成一等公民之后，
/// 这里负责"按偏好顺序试，试到第一个通的"。
///
/// ## 为什么回落住在传输层，而不是连接层
///
/// 连接层只认识**一个** `ChannelTransport`：`connect()` 抛错就进退避重连
/// **同一个** transport（`sync_client_impl.dart` 的 `_deps.transport.connect()`）。
/// 把回落写进连接层，它会"重试同一个死地址"—— 那是错的形状。
///
/// ## 三条刻意的选择
///
/// - **一轮里每个端点只试一次**。不重试当前这个：刚失败的重试几乎必然再失败，
///   只会把每次建连的耗时乘以 N。
/// - **不降权、不重排**。失败的端点下一轮仍在原位置 —— 否则"出门一次回落中转"
///   之后就再也回不到直连（降权是永久的，而直连是会恢复的）。
///   顺序即偏好：用户把直连放前面，它就一直是第一选择。
/// - **成功的端点只通过回调报出去，不自己改表**。表的所有权在调用方
///   （装配层 / 设置页），这里不写别人的状态。
/// - **每次 `connect()` 现读端点表**（见 [EndpointSource]）。端点表是**会变的**：
///   连接器在连上之后才自报直连地址，而那之后要立刻能拨到它。
///
/// 取舍与被否方案：`.agents/notes/implemented/2026-10-14-endpoint-switching-lan-direct.md`
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import 'endpoint.dart';
import 'errors.dart';
import 'transport.dart';

/// 造一个端点的传输。**由 `platform/` 的装配点注入** ——
/// `core/` 不 import `platform/`（`verify-platform-boundary.mjs` 的
/// `core-no-platform-import` 会拦），而"票从哪来"是平台侧的知识。
typedef TransportFactory = ChannelTransport Function(Endpoint endpoint);

/// 取当前端点表。**每次 `connect()` 调一次。**
///
/// 为什么不是构造时传一份列表：端点表会变 —— 连接器只在**连上之后**才自报
/// 直连地址（`endpoint.describe`），而发现的结果要立刻能拨。
/// 构造时定格会让"发现了直连"必须等下一次重启 App 才生效。
/// 顺序即偏好：调用方（装配层 / 设置页）是这个表唯一的所有者。
typedef EndpointSource = List<Endpoint> Function();

/// 按有序端点表拨号的传输。
class EndpointTransport implements ChannelTransport {
  EndpointTransport({
    required this.endpointsOf,
    required this.factory,
    this.onActivated,
    this.onAttempt,
  });

  /// 当前端点表。
  final EndpointSource endpointsOf;

  final TransportFactory factory;

  /// 某个端点**拨通了**（WS 已建立，握手还没开始）时回调。
  ///
  /// 只报事实，不改表：表的所有权在调用方。用来让界面显示"当前走哪条"。
  /// **可后设**（装配时 `AppModel` 还没建出来，见 `main.dart` 的 `_assemble`）。
  void Function(Endpoint endpoint)? onActivated;

  /// 某个端点**试过了**（拨通或失败）时回调。只报事实，不改表。
  ///
  /// 与 [onActivated] 的分工：那个只报"赢了哪个"，这个报"每个试过的结局" ——
  /// 设置页的"通不通"与"为什么走了中转"都要后者（回落时 active 是中转，
  /// 而用户关心的是"直连怎么没了"）。失败也报：**一次拨不通是下一轮
  /// "通不通"的唯一证据**，连接层退避重连时每一轮都会重报。
  /// **可后设**（同 [onActivated]）。
  void Function(Endpoint endpoint, EndpointAttempt attempt)? onAttempt;

  ChannelTransport? _active;

  /// 用户点名的那个端点（`null` = 走自动队列）。
  ///
  /// **只影响下一次 `connect()`**：点名是"这一次就用它"，不是"以后都用它" ——
  /// 后者是顺序（`preferEndpoint`）与顶点（`rememberedEndpointUrl`）的事。
  /// 拨通或失败后由调用方清掉（失败即回到自动，见 `AppModel.useEndpointNow`）。
  Endpoint? get requestedEndpoint => _requested;
  Endpoint? _requested;

  /// 点名"下一次拨号只用这个"（传 `null` 回到自动队列）。
  void requestEndpoint(Endpoint? endpoint) => _requested = endpoint;

  /// 当前拨通的那个端点（`connect()` 之前是 `null`）。
  Endpoint? get activeEndpoint => _activeEndpoint;
  Endpoint? _activeEndpoint;

  @override
  Future<Stream<TransportEvent>> connect() async {
    // 上一次的连接先收干净：不的话 `send` 会委托给一条已经断的 socket，
    // 而调用方看到的是"发成功了"（`_inner.send` 回 true 的旧连接）。
    await _disposeActive();

    // **现读**：发现结果（`endpoint.describe`）只在连接器自报之后才有，
    // 而那之后要立刻能拨到它 —— 构造时定格就得重启 App。
    // **点名优先**：用户指定了那一条就只试它，**不顺延** ——
    // 顺延会让"我选了直连"变成"其实又偷偷走了中转"，而用户无从得知。
    // 失败由上层（`AppModel.useEndpointNow`）清掉点名、回到自动并说明原因。
    final requested = _requested;
    final endpoints = requested != null ? [requested] : endpointsOf();
    if (endpoints.isEmpty) {
      throw const TransportException('没有可拨的端点');
    }

    TransportException? lastError;
    for (final endpoint in endpoints) {
      final ChannelTransport transport;
      try {
        transport = factory(endpoint);
      } on TransportException catch (error) {
        // 造传输就失败（例如 relay 端点没给票源）：记下，换下一个。
        lastError = error;
        continue;
      }
      final attemptStart = DateTime.now();
      try {
        final stream = await transport.connect();
        debugPrint(
          '[dial] ${endpoint.kind.name} ${endpoint.url} 通 '
          '(${DateTime.now().difference(attemptStart).inMilliseconds}ms)',
        );
        _active = transport;
        _activeEndpoint = endpoint;
        onActivated?.call(endpoint);
        onAttempt?.call(endpoint, const EndpointAttempt(ok: true));
        return stream;
      } on TransportException catch (error) {
        debugPrint(
          '[dial] ${endpoint.kind.name} ${endpoint.url} 失败 '
          '(${DateTime.now().difference(attemptStart).inMilliseconds}ms): ${error.message}',
        );
        // **终态错误不再换端点**：身份不被认（换票被拒 → `notPaired`）时，
        // 换下一个端点只会把"为什么连不上"弄丢 —— 直连要到握手处才失败，
        // reason 变成 close 4003，而 401 那个"电脑不认本机"的信号会被掩盖。
        // 直接把它抛出去，让连接层判终态（不进退避、交上层回配对页）。
        //
        // 终态也照旧报一次拨号结果：它是事实（这一轮确实没通），
        // 而设置页要能显示"为什么这条连不上"。
        onAttempt?.call(
          endpoint,
          EndpointAttempt(ok: false, reason: error.message),
        );
        if (error.code?.clientAction == ClientAction.rePair) rethrow;
        // 其余：拨不通是该换下一条。别的异常（工厂里的 bug）照旧抛出去 ——
        // 吞掉它会让"代码写错了"表现成"网络不通"。
        lastError = error;
        continue;
      }
    }
    // 全试过了。带上最后一个失败的原因：只说"连不上"会让排查从网络开始，
    // 而真因可能是凭据（`TicketedWebSocketTransport` 的换票失败）。
    // **code 也一起带**：让连接层在"全是网络类失败"时仍能判出它不是终态。
    throw TransportException(
      '所有端点都拨不通（共 ${endpoints.length} 个）：${lastError?.message ?? '无'}',
      code: lastError?.code,
    );
  }

  @override
  bool send(String line) => _active?.send(line) ?? false;

  @override
  Future<void> close() => _disposeActive();

  Future<void> _disposeActive() async {
    final active = _active;
    _active = null;
    _activeEndpoint = null;
    if (active == null) return;
    try {
      await active.close();
    } on TransportException {
      // 收尾失败不抛：调用方关心的是"已经关了"，而这条路本来就要弃了。
    }
  }
}
