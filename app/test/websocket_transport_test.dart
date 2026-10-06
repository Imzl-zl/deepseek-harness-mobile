/// 真实 WebSocket 传输的回归（`platform/` 那一层）。
///
/// 这一组**起真的 WebSocket 服务端**，用真 socket 验证三件事：
///
/// 1. **升级头真的到了服务端**（`Authorization: Bearer …`，契约 §2.2）——
///    这是选 `IOWebSocketChannel` 而不是跨平台 `WebSocketChannel.connect` 的**唯一理由**，
///    所以必须有一条用例盯着它，否则将来"顺手换成跨平台那个"不会红；
/// 2. **收帧交出的是原始片**，不是切好的行（分帧归 `core/`，见 `transport.dart`）；
/// 3. **发帧一行一帧**（分隔符由 `core/frame.dart` 的 `encodeFrame` 负责，这里不补）。
///
/// 本文件在 `app/test/` 下，可以 import `dart:io`（门禁只扫 `lib/` 与 `packages/`）。
library;

import 'dart:io';

import 'package:dsh_mobile/core/transport.dart';
import 'package:dsh_mobile/platform/websocket_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一个最小的 WebSocket 服务端（`dart:io` 的 `HttpServer` + upgrade）。
///
/// 不用第三方包：这一层要验的正是"我们发出去的升级头长什么样"，
/// 而 `HttpServer` 把请求头原样交给我们，是这条断言最直接的观察面。
class TestServer {
  TestServer._(this._server);

  final HttpServer _server;
  final List<HttpHeaders> upgradeHeaders = [];
  final List<Uri> upgradeUris = [];
  final List<WebSocket> sockets = [];

  /// 服务端收到的每一片文本。
  final List<String> received = [];

  int get port => _server.port;

  static Future<TestServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final wrapper = TestServer._(server);
    server.listen((request) async {
      wrapper.upgradeHeaders.add(request.headers);
      wrapper.upgradeUris.add(request.uri);
      final socket = await WebSocketTransformer.upgrade(request);
      wrapper.sockets.add(socket);
      socket.listen(
        (dynamic data) => wrapper.received.add('$data'),
        onError: (Object _) {},
        cancelOnError: false,
      );
    });
    return wrapper;
  }

  Future<void> stop() async {
    for (final socket in sockets) {
      await socket.close();
    }
    await _server.close(force: true);
  }
}

void main() {
  late TestServer server;

  setUp(() async {
    server = await TestServer.start();
  });

  tearDown(() async {
    await server.stop();
  });

  test('升级头真的到了服务端（令牌走 Authorization，不进 URL）', () async {
    final transport = WebSocketTransport(
      WebSocketTransportOptions(
        url: 'ws://127.0.0.1:${server.port}/ws/connector',
        headers: const {'authorization': 'Bearer test-token-1'},
      ),
    );
    // ignore: unawaited_futures
    await transport.connect();
    // 服务端应该已经看到升级请求。
    expect(server.upgradeHeaders, isNotEmpty, reason: '升级请求应到达服务端');
    final headers = server.upgradeHeaders.single;
    expect(
      headers.value('authorization'),
      'Bearer test-token-1',
      reason: '令牌必须走升级头 —— 这是用 IOWebSocketChannel 而不是跨平台 connect 的唯一理由',
    );
    // URL 里不该有令牌（它会进日志/代理记录）。
    expect(
      server.upgradeUris.single.toString().contains('test-token-1'),
      isFalse,
      reason: '令牌走升级头、不进 URL',
    );

    await transport.close();
  });

  test('收帧交出**原始片**，不是切好的行（分帧归 core/）', () async {
    final transport = WebSocketTransport(
      WebSocketTransportOptions(url: 'ws://127.0.0.1:${server.port}/ws'),
    );
    final stream = await transport.connect();
    final events = <TransportEvent>[];
    stream.listen(events.add);

    // 等服务端接上。
    await _waitFor(() => server.sockets.isNotEmpty);
    // 服务端一次发**两行**：传输层应把它当**一片**交出来（拼行归 core/）。
    server.sockets.single.add('{"a":1}\n{"b":2}\n');
    await _waitFor(() => events.isNotEmpty);

    final message = events.whereType<TransportMessage>().single;
    expect(
      message.chunk,
      '{"a":1}\n{"b":2}\n',
      reason: '传输层不做分帧 —— 分隔符规则只有一个 owner（core/frame.dart）',
    );

    await transport.close();
  });

  test('发帧一行一帧：分隔符由调用方给，这里不补也不删', () async {
    final transport = WebSocketTransport(
      WebSocketTransportOptions(url: 'ws://127.0.0.1:${server.port}/ws'),
    );
    await transport.connect();
    await _waitFor(() => server.sockets.isNotEmpty);

    // `encodeFrame` 的产物（已带 \n）。
    expect(transport.send('{"v":1,"t":"ping","fc":0,"box":""}\n'), isTrue);
    await _waitFor(() => server.received.isNotEmpty);
    expect(server.received.single, endsWith('\n'));

    await transport.close();
  });

  test('建连失败抛 TransportException（不是让调用方永远等）', () async {
    // 指向一个**没有监听**的端口：连接会被拒。
    final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = dead.port;
    await dead.close();

    final transport = WebSocketTransport(
      WebSocketTransportOptions(
        url: 'ws://127.0.0.1:$deadPort/ws',
        connectTimeout: const Duration(seconds: 3),
      ),
    );
    await expectLater(
      transport.connect(),
      throwsA(isA<TransportException>()),
      reason: '连不上要抛，而不是留一个永远不完成的 Future',
    );
  });

  test('close 幂等，且之后 send 如实回 false', () async {
    final transport = WebSocketTransport(
      WebSocketTransportOptions(url: 'ws://127.0.0.1:${server.port}/ws'),
    );
    await transport.connect();
    await _waitFor(() => server.sockets.isNotEmpty);

    await transport.close();
    await transport.close(); // 幂等
    expect(transport.send('x\n'), isFalse, reason: '关掉之后发不出去，要如实回 false');
  });

  test('对端关闭 → 收到 TransportClosed（带关闭码）', () async {
    final transport = WebSocketTransport(
      WebSocketTransportOptions(url: 'ws://127.0.0.1:${server.port}/ws'),
    );
    final stream = await transport.connect();
    final events = <TransportEvent>[];
    stream.listen(events.add);
    await _waitFor(() => server.sockets.isNotEmpty);

    await server.sockets.single.close(4003, 'not-paired');
    await _waitFor(() => events.whereType<TransportClosed>().isNotEmpty);

    final closed = events.whereType<TransportClosed>().single;
    expect(closed.code, 4003, reason: '关闭码是结构化的（用包换来的）');
    expect(closed.reason, 'not-paired');

    await transport.close();
  });
}

/// 等一个条件成立（超时即失败）—— 比固定 sleep 稳、也比它快。
Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('等待超时：条件在 ${timeout.inSeconds}s 内没有成立');
}
