/// **每次建连都换票**的传输包装（契约 §2 的连接建立）。
///
/// ## 它解决什么
///
/// 中转只接受 `ws://<host>/ws/device?ticket=<一次性票>` 这条升级路径 ——
/// 拿根路径去连会得到 **404**，而中转对 404 只 `log?.debug`，
/// 于是手机侧的表现是"连不上、日志里没有原因"。
///
/// 更关键的是**票是一次性的**：`core/` 的连接层会在退避后反复重连
/// （契约 §2 的重连是常态，不是异常路径），而同一张票用过即废。
/// 所以"换票"必须发生在**每一次**建连里，而不是装配时换一次。
///
/// ## 为什么做成包装而不是改 `WebSocketTransport`
///
/// 两者关心的事不同：`WebSocketTransport` 只管"把一条 WS 接起来"，
/// 而"票从哪来、什么时候换"是配对链上的知识（它要用设备令牌）。
/// 分开之后，`websocket_transport_test.dart` 那 6 条真 socket 用例
/// 不必为票准备任何东西 —— 它们验的是 WS 本身。
///
/// ## 失败要如实抛
///
/// 换票失败**不静默降级成"连根路径试试"**：那会得到一个必然的 404，
/// 而症状与"没护照就去登机"一样 —— 错误信息指向连接失败，真因是凭据。
/// 抛出的 [TransportException] **带上原始错误码**，让连接层区分两类失败：
/// 中转临时不可达（`rateLimited` 等）→ 退避重试；身份不被认
/// （`notPaired`/`revoked`）→ **一次性终态**，交上层清凭据回配对页，
/// 不进退避（议题 2：否则用户永远卡在"重连中…"）。
///
/// Note: 为什么每次建连都要换票、为什么用设备令牌换 —— 见
/// `.agents/notes/implemented/2026-10-02-pairing-bootstrap-and-device-binding.md`
library;

import '../core/endpoint.dart';
import '../core/errors.dart';
import '../core/transport.dart';
import 'websocket_transport.dart';

/// 取票：每次建连都会调一次（实现里通常是用设备令牌调 `/ws-ticket`）。
typedef TicketSource = Future<String> Function();

/// 把 [WebSocketTransport] 包一层："先换票，再带票升级"。
class TicketedWebSocketTransport implements ChannelTransport {
  TicketedWebSocketTransport({
    required this.endpoint,
    required this.ticket,
    this.connectTimeout = const Duration(seconds: 10),
  });

  /// 中转的**根**地址（`ws://host:port`，来自二维码的 `relay` 字段）。
  ///
  /// 升级路径不在这里拼：它是协议知识，唯一 owner 是 `core/endpoint.dart` 的
  /// [deviceUpgradeUrl]（配对那条链也要拼同一个 URL —— 两处各写一遍必然漂移）。
  final String endpoint;

  /// 取票（每次建连一次）。
  final TicketSource ticket;

  final Duration connectTimeout;

  WebSocketTransport? _inner;

  @override
  Future<Stream<TransportEvent>> connect() async {
    final String value;
    try {
      value = await ticket();
    } on ProtocolException catch (error) {
      // 换票被拒（401 凭据不对 / 409 登记不可用 / 429 限流）：
      // 归成传输层错误，但**带上原始错误码**（`error.code`）。
      //
      // 丢掉码是议题 2 的真因：连接层于是只会在"网络失败"和"身份不被认"之间
      // 看成一回事，进退避重连，永远转圈。带上码之后，连接层能按
      // `code.clientAction` 区分 —— `notPaired`/`revoked` 是**一次性终态**
      // （清凭据 + 回配对页），`rateLimited`/网络类才退避重试。
      //
      // **仍带上原始信息**："换票失败"与"连不上"在日志里必须能分开，
      // 否则 401 会被当成网络问题查半天。
      throw TransportException('换票失败：${error.message}', code: error.code);
    }
    final transport = WebSocketTransport(
      WebSocketTransportOptions(
        url: deviceUpgradeUrl(endpoint, value),
        connectTimeout: connectTimeout,
      ),
    );
    _inner = transport;
    return transport.connect();
  }

  @override
  bool send(String line) => _inner?.send(line) ?? false;

  @override
  Future<void> close() async {
    final inner = _inner;
    _inner = null;
    await inner?.close();
  }
}
