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
/// ## 四条刻意的选择
///
/// - **拨号是竞速，不是串联**：按表顺序错开启动，**第一个建立 socket 的赢**，
///   其余立刻关。2026-10-17 真机那三个死 IPv6 地址把冷启动拖成 30 秒，
///   就是串行"一条一条等满超时"的直接后果。竞速只覆盖**连接建立**：
///   赢家才把流交给连接层（握手在那里），输家连一帧都不发。
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
/// ## 为什么中转端点不并发（同一时刻只让一条 relay 在飞）
///
/// 中转对**同一个 `(connectorId, deviceId)`** 的新数据通道会先关掉上一条
/// （`relay/src/server.ts:184-185` 的 `replaced` 语义，换网重连靠的就是它）。
/// 两条中转端点同时在飞会各自换一张票、各建一条数据通道，于是**后到的那条把先到的顶掉** ——
/// 如果先到的正是赢家，它会被中转无声关掉。所以 relay 端点用一道闸串行；
/// 直连监听面没有这层"同设备单通道"语义，可以随便并发。
///
/// 取舍与被否方案：`.agents/notes/implemented/2026-10-14-endpoint-switching-lan-direct.md`、
/// `.agents/notes/implemented/2026-10-30-dial-racing-and-buffer-trim.md`
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
    this.dialStagger = const Duration(milliseconds: 250),
  });

  /// 相邻两条端点的启动间隔（Happy Eyeballs 的 250ms）。
  ///
  /// 全 0 也能工作（同时拨），但会同时占满 N 条 socket；错开让"首选通常最快"
  /// 这一点先兑现，死地址晚 250ms 才开始，不影响总耗时量级。
  final Duration dialStagger;

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
  /// 后者是顺序（`preferEndpoint`）与顶点（`rememberedEndpointId`）的事。
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

    final outcome = Completer<Object>();
    final failures = <_DialFailure>[];
    final relayGate = _RelayGate();
    var pending = endpoints.length;
    var sealed = false;

    void settle(Object value) {
      if (sealed) return;
      sealed = true;
      outcome.complete(value);
    }

    void finishOne() {
      pending -= 1;
      if (pending == 0 && !sealed) {
        settle(_AllFailed(failures));
      }
    }

    Future<void> dial(Endpoint endpoint, int index) async {
      // **中转端点串行**：同一时刻只让一条 relay 换票 + 建数据通道，
      // 否则后到的那条会被中转按 `replaced` 顶掉（见文件头）。
      final holdsRelay = endpoint.kind == EndpointKind.relay;
      if (holdsRelay) {
        // **闸空闲时同步拿到**（不为第一条 relay 引入一个多余微任务：
        // 那会让"表里排在前面的 relay"反而比后面的直连晚一拍启动）。
        final wait = relayGate.tryAcquire();
        if (wait != null) {
          await wait;
          if (sealed) {
            relayGate.release();
            finishOne();
            return;
          }
        }
      }
      try {
        final ChannelTransport transport;
        try {
          transport = factory(endpoint);
        } on TransportException catch (error) {
          // 造传输就失败（例如 relay 端点没给票源）：记下，等其余端点。
          failures.add(_DialFailure(index, endpoint, error));
          return;
        } catch (error, stack) {
          // 工厂里的 bug：不吞 —— 否则"代码写错了"会装成"网络不通"。
          settle(_Fatal(error, stack));
          return;
        }

        final attemptStart = DateTime.now();
        try {
          final stream = await transport.connect();
          debugPrint(
            '[dial] ${endpoint.kind.name} ${endpoint.url} 通 '
            '(${DateTime.now().difference(attemptStart).inMilliseconds}ms)',
          );
          if (sealed) {
            // 输家：**连上也不进握手**，立刻关，不留半开。
            await _closeQuietly(transport);
            return;
          }
          _active = transport;
          _activeEndpoint = endpoint;
          onActivated?.call(endpoint);
          onAttempt?.call(
            endpoint,
            EndpointAttempt(
              ok: true,
              atMs: DateTime.now().millisecondsSinceEpoch,
            ),
          );
          settle(_DialWin(stream));
          return;
        } on TransportException catch (error) {
          debugPrint(
            '[dial] ${endpoint.kind.name} ${endpoint.url} 失败 '
            '(${DateTime.now().difference(attemptStart).inMilliseconds}ms): ${error.message}',
          );
          await _closeQuietly(transport);
          // 终态也照旧报一次拨号结果：它是事实（这一轮确实没通），
          // 而设置页要能显示"为什么这条连不上"。
          onAttempt?.call(
            endpoint,
            EndpointAttempt(
              ok: false,
              reason: error.message,
              atMs: DateTime.now().millisecondsSinceEpoch,
            ),
          );
          failures.add(_DialFailure(index, endpoint, error));
          // **终态错误不再换端点**：身份不被认（换票被拒 → `notPaired`）时，
          // 换端点只会把"为什么连不上"弄丢（直连要到握手处才失败，
          // reason 变成 close 4003，而 401 那个"电脑不认本机"的信号会被掩盖）。
          // 已经在飞的连接收不回来（没有取消缝），但**尚未开始的端点不再拨**。
          if (error.code?.clientAction == ClientAction.rePair) {
            settle(_Fatal(error, StackTrace.current));
          }
          return;
        }
      } finally {
        if (holdsRelay) relayGate.release();
        finishOne();
      }
    }

    // **并发拨号，按表顺序错开启动**。赢家一出现就停止启动后面的端点；
    // 已经在飞的由它自己看到 `sealed` 后关闭。
    unawaited(() async {
      for (var index = 0; index < endpoints.length; index += 1) {
        if (index > 0 && dialStagger > Duration.zero) {
          await Future<void>.delayed(dialStagger);
        }
        if (sealed) return;
        unawaited(dial(endpoints[index], index));
      }
    }());

    final result = await outcome.future;
    if (result is _DialWin) return result.stream;
    if (result is _Fatal) {
      final error = result.error;
      if (error is TransportException) throw error;
      Error.throwWithStackTrace(error, result.stackTrace);
    }
    final all = result as _AllFailed;
    // 全失败：带上**表里最后一条**失败的原因（与串联时代的语义一致）。
    // **code 也一起带**：让连接层在"全是网络类失败"时仍能判出它不是终态。
    final last = all.failures.isEmpty
        ? null
        : all.failures.reduce((a, b) => a.index >= b.index ? a : b);
    throw TransportException(
      '所有端点都拨不通（共 ${endpoints.length} 个）：${last?.error.message ?? '无'}',
      code: last?.error.code,
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
    await _closeQuietly(active);
  }

  /// 收尾失败不抛：调用方关心的是"已经关了"，而这条路本来就要弃了。
  Future<void> _closeQuietly(ChannelTransport transport) async {
    try {
      await transport.close();
    } on TransportException {
      // 同上。
    }
  }
}

/// 竞速的结果：赢家的流。
class _DialWin {
  const _DialWin(this.stream);

  final Stream<TransportEvent> stream;
}

/// 全部端点都没拨通（`failures` 按表下标带位置，聚合原因用最后一条）。
class _AllFailed {
  const _AllFailed(this.failures);

  final List<_DialFailure> failures;
}

class _DialFailure {
  const _DialFailure(this.index, this.endpoint, this.error);

  final int index;
  final Endpoint endpoint;
  final TransportException error;
}

/// 不该被吞掉的错误（工厂的 bug / 终态身份拒绝）—— 整轮失败用它。
class _Fatal {
  const _Fatal(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}

/// 容量为 1 的闸：中转端点在飞时，下一条 relay 端点排队等它结束。
class _RelayGate {
  bool _busy = false;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  /// 拿到返回 `null`（同步持有）；被占用则返回要等的 future。
  Future<void>? tryAcquire() {
    if (!_busy) {
      _busy = true;
      return null;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      // 直接把持有权交给下一个等的人（`_busy` 保持 true）。
      _waiters.removeAt(0).complete();
      return;
    }
    _busy = false;
  }
}
