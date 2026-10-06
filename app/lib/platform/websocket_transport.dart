/// 真实的 WebSocket 传输（`core/transport.dart` 那条缝的平台侧实现）。
///
/// ## 为什么这一层可以碰平台，而 `core/` 不行
///
/// `core/` 是纯 Dart、零平台依赖（`node app/tools/verify-platform-boundary.mjs` 会拦
/// `dart:io`），因为"core 能在没有 UI、没有平台代码的情况下跑绿"是它的全部判据。
/// 真实 socket 必然碰平台，所以它住在 `platform/`：**门禁的白名单里明确允许这一层**
/// （`app/lib/platform/**` 是 `branch-whitelist` 规则的例外）。
///
/// ## 为什么用 `web_socket_channel` 而不是直接用 `dart:io` 的 WebSocket
///
/// 选型依据（一手，`pub.dev` / `dart-lang/http` 仓）：
///
/// 1. **它是 Dart 官方包**（publisher `tools.dart.dev`，1.6k likes / 11M downloads），
///    而 `dart:io` 的 `WebSocket` 是它内部用的东西 —— 用包等于用官方维护的那层包装；
/// 2. **跨平台**：`WebSocketChannel.connect` 会按平台选实现
///    （io 端 `IOWebSocketChannel`、web 端 `HtmlWebSocketChannel`），
///    将来要在 Chrome 里调试 UI 时不用换实现；
/// 3. **`ready` / `closeCode` / `closeReason` 是结构化的**，而裸 `WebSocket`
///    要靠自己挂 `onclose` 再解析事件对象。
///
/// **它支持我们需要的两件事**（已核实 `IOWebSocketChannel.connect` 的签名）：
/// `headers`（连接器令牌走 `Authorization: Bearer`，契约 §2.2）与 `connectTimeout`。
///
/// ## 分帧不在这一层
///
/// 本类交出的是**原始片**（[TransportMessage] 的 `chunk`）—— 拼行归 `core/frame.dart`
/// 的 `LineSplitter`。让传输层"顺手切行"等于让 `\n` 的规则有两个 owner，
/// 而那一处的偏差表现为"两侧都正常、对端什么都没收到"（本项目踩过一次）。
library;

import 'dart:async';

// 用 `io.dart` 而不是跨平台的 `WebSocketChannel.connect`：**后者不接受 `headers`**
// （已核实 3.0.3 的源码：`static WebSocketChannel connect(Uri uri, {Iterable<String>? protocols})`
// —— 只有 `protocols`）。而连接器令牌必须走 `Authorization` 升级头（契约 §2.2），
// 所以这里用 io 实现。
//
// 代价：这一层因此是 io 专有的（web 端要另写一个实现）。这是**有意的**：
// 手机三端都是 io，而"令牌走哪"是协议决定，不该为了跨平台把它挪到子协议或首帧。
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as ws_status;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/transport.dart';

/// 连接参数。
class WebSocketTransportOptions {
  const WebSocketTransportOptions({
    required this.url,
    this.headers,
    this.connectTimeout = const Duration(seconds: 10),
    this.pingInterval,
  });

  /// `wss://…`（手机上恒为 wss，契约 §2）。
  final String url;

  /// 升级头。连接器令牌走 `Authorization: Bearer <令牌>`（契约 §2.2）。
  ///
  /// **令牌不进 URL**：URL 会进日志、进代理记录、进崩溃上报。
  final Map<String, String>? headers;

  /// 建连超时。不设的话会**永远等**（见 `core/connection.dart` 的退避）。
  final Duration connectTimeout;

  /// 协议级 ping 间隔。
  ///
  /// **默认关掉**（`null`）：我们有契约 §2.2 自己的心跳与半开判定
  /// （`core/keepalive.dart`，60 s / 2 周期），而它判定的依据是**业务帧**
  /// 的收发时刻。让 WebSocket 协议层再发一套 ping 会多出一路不受我们控制的
  /// 保活流量 —— 两套心跳并存时，"半开"的判据就不再是我们定义的那一个了。
  final Duration? pingInterval;
}

/// 真实的 WebSocket 传输。
class WebSocketTransport implements ChannelTransport {
  WebSocketTransport(this.options);

  final WebSocketTransportOptions options;

  WebSocketChannel? _channel;

  @override
  Future<Stream<TransportEvent>> connect() async {
    // `IOWebSocketChannel.connect` 是**唯一**接受 `headers` 的入口（见文件头的选型说明）。
    final channel = IOWebSocketChannel.connect(
      Uri.parse(options.url),
      headers: options.headers,
      // 建连超时由包自己管（它也接受 `connectTimeout`），但**这里仍用 `ready.timeout`**：
      // 包的 `connectTimeout` 只覆盖 `WebSocket.connect` 那一段，而 `ready` 才是
      // "这条 channel 可用"的完整信号。用一个判据而不是两个，避免"到底哪个超时了"。
      pingInterval: options.pingInterval,
    );
    _channel = channel;

    try {
      await channel.ready.timeout(options.connectTimeout);
    } on TimeoutException {
      _closeQuietly();
      throw TransportException(
        '建连超时（${options.connectTimeout.inSeconds}s）：${options.url}',
      );
    } catch (error) {
      _closeQuietly();
      throw TransportException('建连失败：$error');
    }

    // **交出原始片**：分帧归 `core/`（见文件头）。
    //
    // 两个转换是必需的：
    // - 二进制帧在协议里不该出现（§3 是行级 UTF-8 JSON），但我们**不在这里拒**：
    //   把它交给 `core/` 去当"不是合法 JSON"处理，错误码才是协议层那一个
    //   （这里自己造一个错误码，等于让错误分类有两个来源）；
    // - 关闭事件带上 `closeCode`/`closeReason`（结构化，这是用包换来的）。
    return channel.stream.transform(
      StreamTransformer<dynamic, TransportEvent>.fromHandlers(
        handleData: (dynamic data, EventSink<TransportEvent> sink) {
          final chunk = data is String
              ? data
              : String.fromCharCodes(data as List<int>);
          sink.add(TransportMessage(chunk));
        },
        handleError:
            (Object error, StackTrace stack, EventSink<TransportEvent> sink) {
              // 传输层的错误 → `TransportClosed`：连接层只需知道"这条路断了"。
              sink.add(TransportClosed(reason: '$error'));
              sink.close();
            },
        handleDone: (EventSink<TransportEvent> sink) {
          sink.add(
            TransportClosed(
              code: _channel?.closeCode,
              reason: _channel?.closeReason,
            ),
          );
          sink.close();
        },
      ),
    );
  }

  @override
  bool send(String line) {
    final channel = _channel;
    if (channel == null) return false;
    try {
      // **一行一帧**（行级分帧，§3）：`line` 由 `core/frame.dart` 的
      // `encodeFrame` 产出，**已经带换行**，这里不再补 —— 分隔符只有一个 owner。
      channel.sink.add(line);
      return true;
    } catch (_) {
      // 写失败（对端已走、socket 半开）在包里是抛异常或静默丢弃；
      // 这里如实回 `false`，让调用方知道"这一帧没发出去"。
      return false;
    }
  }

  @override
  Future<void> close() async {
    final channel = _channel;
    _channel = null;
    if (channel == null) return;
    await channel.sink
        .close(ws_status.normalClosure, 'client closing')
        .catchError((Object _) {});
  }

  /// 建连失败时的清场。
  ///
  /// **绝不 `await`** —— 这是读包源码得出的结论（`adapter_web_socket_channel.dart`）：
  /// `AdapterWebSocketChannel` 只在 ``webSocketFuture.then(...)`` 里订阅内部流，
  /// 而**连不上时那段从不执行**（走 `onError` 分支：`completeError` 之后只
  /// `addError` + `close` 那个 local sink，**从不订阅** foreign sink）。
  /// 于是 `sink.close()` 的 Future **永远不会完成**：
  ///
  /// - 实测症状：3 s 的 `connectTimeout` 变成 30 s 的**测试超时**，
  ///   报错指向"测试超时"而不是"连不上" —— 排查时容易往错的方向找；
  /// - 修法：清场是**礼节**（连接本来就没建起来），发出去、不等它。
  void _closeQuietly() {
    final channel = _channel;
    _channel = null;
    if (channel == null) return;
    unawaited(
      channel.sink
          .close(ws_status.goingAway, 'connect failed')
          .catchError((Object _) {}),
    );
  }
}
