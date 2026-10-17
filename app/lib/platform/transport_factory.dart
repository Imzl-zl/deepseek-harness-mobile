/// 端点 → 真实传输的分派点。**`core/` 与 `platform/` 之间唯一的一座桥。**
///
/// 为什么它住在 `platform/`：`core/endpoint.dart` 只定义 [Endpoint] 这个值类型，
/// 而"造出哪个传输"需要 `TicketedWebSocketTransport` 与 `WebSocketTransport`，
/// 两者都在 `platform/`（`core/` 禁 import `platform/`，
/// `verify-platform-boundary.mjs` 的 `core-no-platform-import` 会拦）。
///
/// 于是 `EndpointTransport`（在 `core/`）收一个 `TransportFactory` 函数，
/// 由装配点把本函数注入进去 —— 依赖倒置，`core/` 因此能被纯 Dart 单测驱动。
library;

import '../core/endpoint.dart';
import '../core/transport.dart';
import 'ticketed_transport.dart';
import 'websocket_transport.dart';

/// 造一个端点的传输。
///
/// **分派只有这一处**：加第三种端点（蓝牙 / Tailscale-only / 云中转）
/// 只加一个分支，不碰 `EndpointTransport`，也不碰装配点。
///
/// **建连超时按 kind 分档**：直连是"同一局域网"——要么毫秒级应答，要么就是
/// 死的（手机换了网络 / 电脑改了地址），10s 的超时会让每个死地址都拖满 10 秒
/// （2026-10-17 真机实测：三个拨不通的 IPv6 地址把冷启动拖成 30 秒）。
/// 中转可能在公网，保留 10s。
ChannelTransport transportFor(
  Endpoint endpoint, {
  TicketSource? ticket,
  Duration? connectTimeout,
}) {
  switch (endpoint.kind) {
    case EndpointKind.relay:
      // 中转只认 `/ws/device?ticket=<票>`（拿根路径去连会得到 404，
      // 而中转对 404 只 debug 日志，手机侧看起来像"连不上、无原因"），
      // 所以票是**必需**的 —— 缺了就直接说，不静默降级成拨根路径。
      final source = ticket;
      if (source == null) {
        throw TransportException('中转端点需要票源：${endpoint.url}');
      }
      return TicketedWebSocketTransport(
        endpoint: endpoint.url,
        ticket: source,
        connectTimeout: connectTimeout ?? const Duration(seconds: 10),
      );
    case EndpointKind.direct:
      // 直连面没有票、没有固定路径：鉴权就是握手本身
      // （未配对设备在 `hello` 处被 `protocol/not-paired` 拒）。
      // 地址由连接器 `endpoint.describe` 自报，原样拨。
      return WebSocketTransport(
        WebSocketTransportOptions(
          url: endpoint.url,
          connectTimeout: connectTimeout ?? const Duration(seconds: 3),
        ),
      );
  }
}
