/// 传输缝（契约 §2.2）：把"一条 WSS 连接"抽象成 [ChannelTransport]。
///
/// ## 为什么要有这一层
///
/// `core/` 是**纯 Dart、零平台依赖**（`node app/tools/verify-platform-boundary.mjs` 会拦
/// `dart:io`）。而真实的 WSS 客户端必然碰平台（`dart:io` 的 `WebSocket`，
/// 或各端的原生实现）。所以这里只定义**缝**，实现由 `platform/` 装配点注入。
///
/// 好处不只是"能过门禁"：`sync_client` 的全部状态机逻辑都能用**假的传输**驱动，
/// 于是"断连 / 乱序 / 空洞 / 重连"这些最难在真机上复现的场景可以在单测里精确构造
/// （`app-channel-client.md` §7 的测试策略就是这么写的）。
///
/// ## 行级分帧在这一层之下
///
/// [ChannelTransport] 交出的是**完整的行**（不含分隔符），拼行由 `frame.dart` 的
/// [LineSplitter] 负责。这样"分隔符由谁负责"只有一个答案，而它已经踩过一次
/// （漏 `\n` 的表现是"两侧都正常、对端什么都没收到"）。
library;

import 'dart:async';

import 'errors.dart';

/// 一条连接的生命周期事件。
sealed class TransportEvent {
  const TransportEvent();
}

/// 收到了**一片原始数据**（WebSocket 的一帧文本，或 TCP 的一段）。
///
/// **刻意不叫"一行"**：它可能含多行、也可能只有半行。拼行由 `frame.dart` 的
/// [LineSplitter] 负责 —— 分隔符规则**只有一个 owner**（编解码层）。
/// 让传输层"顺手帮忙切行"，等于让 `\n` 的规则存在第二处，而那一处的偏差
/// 表现为"两侧都正常、对端什么都没收到"（本项目踩过一次）。
class TransportMessage extends TransportEvent {
  const TransportMessage(this.chunk);

  /// 原始文本片（未切分）。
  final String chunk;
}

/// 连接关闭（对端断开、网络错误、或本侧主动关）。
class TransportClosed extends TransportEvent {
  const TransportClosed({this.code, this.reason});

  /// 关闭码（WebSocket 语义；`null` 表示没有码，比如 TCP 直接断）。
  final int? code;
  final String? reason;
}

/// 传输缝。**实现由 `platform/` 注入**。
abstract interface class ChannelTransport {
  /// 建立连接。
  ///
  /// 返回的流是**单订阅**的（每条连接一个消费者）—— 多订阅会让"谁在收帧"变得含糊，
  /// 而这一层必须只有一个消费者（`sync_client`）。
  Future<Stream<TransportEvent>> connect();

  /// 发一行。**调用方不用管分隔符**（实现负责补，或交给 `encodeFrame` 的产物）。
  ///
  /// 返回 `false` 表示"现在发不出去"（背压或连接已关）—— 调用方据此排队，
  /// 而不是以为发出去了。
  bool send(String line);

  /// 关闭连接。**幂等**。
  Future<void> close();
}

/// 传输层错误（连接建立失败、发送失败）。
///
/// ## 为什么带 [code]
///
/// 换票被拒（`protocol/not-paired` 等）发生在**建连之前**，而它是身份问题、
/// 不是网络问题。若只抛一句 `TransportException('换票失败…')`，连接层会把它
/// 和"中转不可达"看成一回事 → 进退避重连 → 每次都拿到同一个 401，
/// 用户永远卡在"重连中…"（议题 2 的真因：`TicketedWebSocketTransport`
/// 原先就把 `ProtocolException` 的码丢在了这里）。
///
/// 带上 [code] 后，连接层能按 `code.clientAction` 区分：
/// `rePair` 是**一次性终态**（不进退避，交给上层清凭据回配对页），
/// 其余照旧退避重试。
class TransportException implements Exception {
  const TransportException(this.message, {this.code});

  final String message;

  /// 建连失败对应的协议错误码（换票被拒等）；`null` = 纯网络类失败。
  ///
  /// 它来自被丢掉的 `ProtocolException.code`（见文件头）—— 传输层只搬码，
  /// 不解释它。
  final ErrorCode? code;

  @override
  String toString() => 'TransportException: $message';
}
