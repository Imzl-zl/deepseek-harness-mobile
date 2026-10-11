/// 真实的 HTTP 发送（`core/pairing_client.dart` 那条缝的平台侧实现）。
///
/// ## 为什么这一层可以碰平台，而 `core/` 不行
///
/// 与 `websocket_transport.dart` 同一个理由：`core/` 是纯 Dart、零平台依赖
/// （`node app/tools/verify-platform-boundary.mjs` 会拦 `dart:io`），
/// 而真实网络请求必然碰平台。所以"缝"在 `core/`，"实现"在这里，
/// 而"选哪个实现"只发生在装配层（`main.dart`）。
///
/// ## 为什么用 `package:http` 而不是 `dart:io` 的 HttpClient
///
/// 它是 Dart 官方包（publisher `tools.dart.dev`），且它的 `Client` 是一个**可注入的缝** ——
/// 于是这一层自己不持有全局状态，测试能塞一个 `MockClient`（`http/testing.dart` 自带）
/// 而完全不碰网络。用裸 `HttpClient` 的话，这一层会自己管连接池与生命周期。
///
/// ## 超时必须有
///
/// 手机在移动网络上，而"请求永远不返回"的表现是**配对页一直转圈**（用户只能杀 App）。
/// 取 10 s：与 `WebSocketTransport` 的建连超时同一个量级 —— 两个动作都是
/// "一次网络往返 + 服务端一点点处理"，用一个值便于对照排查。
library;

import 'package:http/http.dart' as http;

import '../core/pairing_client.dart';

/// HTTP 请求超时（与 WS 建连超时同量级，见文件头）。
const Duration httpCallTimeout = Duration(seconds: 10);

/// 造一个真实的 [HttpSender]。
///
/// [client] 可注入（测试用 `MockClient`）；不给就每次调用建一个短命的
/// `http.Client` 并在结束时关掉 —— 配对换票是**低频**动作（一次配对一次），
/// 为一个低频动作常驻一个连接池不值得，而关掉它是必须的（否则连接会一直挂着）。
HttpSender createHttpSender({http.Client? client}) {
  return (call) async {
    final owned = client == null;
    final active = client ?? http.Client();
    try {
      final request = http.Request(call.method, Uri.parse(call.url))
        ..headers.addAll(call.headers);
      if (call.body != null) request.body = call.body!;
      final response = await active.send(request).timeout(httpCallTimeout);
      final body = await response.stream.bytesToString().timeout(
        httpCallTimeout,
      );
      return HttpResult(status: response.statusCode, body: body);
    } finally {
      if (owned) active.close();
    }
  };
}
