/// `SyncClient` 的端到端接线（契约 §2.2、§4、§5、§7）。
///
/// 这一组用**假的传输**驱动真状态机：连接建立、握手、封箱收发、流控、重连。
/// 用假传输是刻意的 —— "断连 / 乱序 / 空洞 / 重连"这些场景在真机上极难精确复现，
/// 而它们恰恰是最容易出错的地方（`app-channel-client.md` §7 的测试策略就是这么写的）。
///
/// 关键：**时间与随机全部注入**，所以"退避 30 s"这类场景在毫秒内跑完。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_mobile/core/box.dart';
import 'package:dsh_mobile/core/connection.dart';
import 'package:dsh_mobile/core/crypto.dart';
import 'package:dsh_mobile/core/errors.dart';
import 'package:dsh_mobile/core/handshake.dart';
import 'package:dsh_mobile/core/handshake_driver.dart';
import 'package:dsh_mobile/core/keepalive.dart';
import 'package:dsh_mobile/core/outbox.dart';
import 'package:dsh_mobile/core/recovery.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/core/sync_client_impl.dart';
import 'package:dsh_mobile/core/transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假的传输：把发出去的行记下来，并允许测试"从对端"注入行。
class FakeTransport implements ChannelTransport {
  FakeTransport({this.failConnect = false});

  /// 连接建立是否失败（测退避用）。
  bool failConnect;

  final List<String> sent = [];
  StreamController<TransportEvent>? _controller;

  /// 建立连接的次数（测重连）。
  int connectCount = 0;

  /// 关闭次数。
  int closeCount = 0;

  @override
  Future<Stream<TransportEvent>> connect() async {
    connectCount += 1;
    if (failConnect) throw const TransportException('连不上');
    _controller = StreamController<TransportEvent>();
    return _controller!.stream;
  }

  @override
  bool send(String line) {
    sent.add(line);
    return true;
  }

  @override
  Future<void> close() async {
    closeCount += 1;
    if (_controller != null && !_controller!.isClosed) {
      await _controller!.close();
    }
  }

  /// 从"对端"喂一片原始数据。
  void feed(String chunk) {
    _controller?.add(TransportMessage(chunk));
  }

  /// 模拟对端断开。
  void dropFromPeer({int? code}) {
    _controller?.add(TransportClosed(code: code));
  }

  /// 已发出的帧（解析后的）。
  List<Map<String, Object?>> get sentFrames => sent
      .map((line) => jsonDecode(line.trim()) as Map<String, Object?>)
      .toList();

  /// 按类型找第一帧。
  Map<String, Object?>? frameOf(String type) =>
      sentFrames.where((f) => f['t'] == type).firstOrNull;
}

/// 假定时器：`advance` 手动触发到期的回调。
class FakeClock {
  final List<({int at, void Function() fn, int id})> _pending = [];
  int _now = 0;
  int _nextId = 0;

  int now() => _now;

  void Function() schedule(void Function() fn, int ms) {
    final id = _nextId++;
    _pending.add((at: _now + ms, fn: fn, id: id));
    return () {
      _pending.removeWhere((entry) => entry.id == id);
    };
  }

  /// 推进时钟并按到期顺序触发回调。
  void advance(int ms) {
    final target = _now + ms;
    while (true) {
      _pending.sort((a, b) => a.at.compareTo(b.at));
      final due = _pending.where((entry) => entry.at <= target).firstOrNull;
      if (due == null) break;
      _pending.remove(due);
      _now = due.at;
      due.fn();
    }
    _now = target;
  }

  /// 还没到期的回调数。
  int get pending => _pending.length;
}

void main() {
  late KeyPair phoneStatic;
  late KeyPair pcDh;
  late String pcSignSeed;
  late String pcSignPub;

  setUpAll(() async {
    phoneStatic = await x25519FromSeed('a1' * 32);
    pcDh = await x25519FromSeed('b2' * 32);
    final pcIdentity = await deriveIdentity('f0' * 32);
    pcSignSeed = pcIdentity.signSeedHex;
    pcSignPub = pcIdentity.sign.publicKeyHex;
  });

  /// 一套"手机侧"的 deps。
  ({
    SyncClientDeps deps,
    FakeTransport transport,
    FakeClock clock,
    DeviceSession session,
    InMemoryOutboxStore store,
  })
  buildDeps({bool failConnect = false}) {
    final transport = FakeTransport(failConnect: failConnect);
    final clock = FakeClock();
    final session = DeviceSession();
    final store = InMemoryOutboxStore();
    var idSeq = 0;
    var ephSeq = 0;

    final deps = SyncClientDeps(
      transport: transport,
      handshake: createHandshakeDriver(
        identity: HandshakeIdentity(
          staticKeys: phoneStatic,
          signSeedHex: 'c3' * 32,
          devId: 'dev-1',
        ),
        peer: PeerIdentity(
          pcSignPubHex: pcSignPub,
          pcDhPubHex: pcDh.publicKeyHex,
          pcId: 'pc-1',
          pairingId: 'pair-1',
        ),
        // 确定化的临时种子与 nonce（生产里每次建连都重新生成）。
        newEphemeralSeedHex: () =>
            (0xd0 + ephSeq++).toRadixString(16).padLeft(2, '0') * 32,
        newNonceHex: () => '11' * 32,
        newFrameIdHex: () => 'id${idSeq++}',
      ),
      box: (keys) => BoxCodec(keys: keys, role: HandshakeRole.initiator),
      outbox: Outbox(store: store, send: (_) async => false),
      session: session,
      keepalive: Keepalive(heartbeat: 60000, periods: 2),
      backoff: Backoff(random: () => 0.5),
      now: clock.now,
      schedule: clock.schedule,
      newId: () => 'rid${idSeq++}',
    );
    return (
      deps: deps,
      transport: transport,
      clock: clock,
      session: session,
      store: store,
    );
  }

  /// 把事件循环跑到静默。
  ///
  /// 为什么需要它：从种子建密钥对、验签、派生、封箱**都是 async 的**
  /// （`cryptography` 的 API 本身返回 `Future`）。所以"`start()` 返回"不等于
  /// "`hello` 已经发出去了" —— 真实客户端是长活的，那一拍无所谓；测试要在那一拍之后断言。
  Future<void> pump([int rounds = 10]) async {
    for (var i = 0; i < rounds; i += 1) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// 扮演电脑侧：回应 `hello`（真签名、真 transcript）。
  Future<void> answerHello(
    FakeTransport transport, {
    String? overrideSig,
  }) async {
    await pump(); // 等 `hello` 真的发出去
    final helloFrame = transport.frameOf('hello');
    expect(helloFrame, isNotNull, reason: '手机必须先发 hello');
    final hello = parseHello(helloFrame!['box']! as String);
    final ackFields = HelloAckFields(
      ephPubB: (await x25519FromSeed('e5' * 32)).publicKeyHex,
      pcId: 'pc-1',
      nonceB: '22' * 32,
    );
    final transcript = transcriptFromFields(hello, ackFields);
    final sigB = overrideSig ?? await signTranscript(pcSignSeed, transcript);
    transport.feed(
      '${jsonEncode({'v': 1, 't': 'hello-ack', 'id': 'a1', 'box': encodeHelloAck(ackFields, sigB)})}\n',
    );
    // 让异步链跑完（验签 → 派生 → 发 confirm → established）。
    await pump();
  }

  /// 复算会话密钥（测试扮演电脑侧要用它封箱）。
  ///
  /// 材料全在测试手里且固定（种子、nonce、pairingId 都是注入的），所以复算一遍即可 ——
  /// **不重新实现协议**，只是把电脑侧该算的那一次算出来（`role: responder`）。
  Future<SessionKeys> sessionKeysFor(FakeTransport transport) async {
    final helloFrame = transport.frameOf('hello');
    expect(helloFrame, isNotNull, reason: '要先有 hello 才能复算');
    final hello = parseHello(helloFrame!['box']! as String);
    return deriveSessionKeys(
      role: HandshakeRole.responder,
      ownStaticPrivate: pcDh.keyPair,
      ownEphemeralPrivate: (await x25519FromSeed('e5' * 32)).keyPair,
      peerStaticPublicHex: phoneStatic.publicKeyHex,
      peerEphemeralPublicHex: hello.ephPubA,
      nonceA: hello.nonceA,
      nonceB: '22' * 32,
      info: keyInfo,
      pairingId: 'pair-1',
    );
  }

  group('连接与握手（契约 §2.2、§4.1）', () {
    test('start → connecting → handshake，并发出 hello', () async {
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      final states = <ConnectionState>[];
      client.connection.listen(states.add);

      await client.start();
      await pump(); // `hello` 是异步发出去的（要从种子建密钥对）
      expect(client.state, ConnectionState.handshake);
      expect(f.transport.sentFrames.map((f) => f['t']), contains('hello'));

      await client.close();
    });

    test('走完握手 → serving；两侧密钥可用（真封箱）', () async {
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);

      expect(client.state, ConnectionState.serving);
      // 手机发出的 confirm 是明文的（握手帧），且带 transcriptHash。
      final confirm = f.transport.frameOf('confirm');
      expect(confirm, isNotNull);
      expect(confirm!.containsKey('fc'), isFalse, reason: '握手帧不盖 fc');

      await client.close();
    });

    test('验签不过 → 连接被关，且不进 serving（抗中间人的落点）', () async {
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      // 别人签的 sigB = 中继替换了公钥。
      await answerHello(
        f.transport,
        overrideSig: await signTranscript('ff' * 32, utf8.encode('x')),
      );

      expect(client.state, isNot(ConnectionState.serving));
      expect(f.transport.closeCount, greaterThan(0), reason: '握手失败要关连接');

      await client.close();
    });

    test('建连失败 → 进退避；到点后重连（且只在"到期"之后）', () async {
      final f = buildDeps(failConnect: true);
      final client = createSyncClient(f.deps);
      await client.start();
      expect(client.state, ConnectionState.backoff);
      expect(f.transport.connectCount, 1);

      // 时钟没到：不该重连。
      f.clock.advance(500);
      expect(f.transport.connectCount, 1);

      // 到点（1000 ms，抖动为 0）：重连一次。
      f.clock.advance(600);
      await Future<void>.delayed(Duration.zero);
      expect(f.transport.connectCount, 2);

      await client.close();
    });

    test('切后台主动断开并停在 idle；回前台重新连', () async {
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);
      expect(client.state, ConnectionState.serving);

      await client.setAppState(AppState.background);
      expect(client.state, ConnectionState.idle, reason: '后台不维持连接（§13）');

      await client.setAppState(AppState.foreground);
      expect(client.state, ConnectionState.handshake, reason: '回前台重新建连');

      await client.close();
    });

    test('对端断开 → closed → backoff（半开/断线都走同一条收口）', () async {
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);
      expect(client.state, ConnectionState.serving);

      f.transport.dropFromPeer();
      await Future<void>.delayed(Duration.zero);
      expect(client.state, ConnectionState.backoff);

      await client.close();
    });
  });

  group('心跳与半开（契约 §2.2、§9）', () {
    test('空闲满一个心跳周期发 ping（走定时器，不靠真等 60 s）', () async {
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);
      expect(client.state, ConnectionState.serving);

      // 判定周期是心跳的 1/4 = 15 s；推进 60 s 应发出 ping。
      f.clock.advance(60000);
      expect(f.transport.sentFrames.map((f) => f['t']), contains('ping'));

      await client.close();
    });

    test('连续两个周期无帧 → 判半开并关连接（TCP 半开不会报错）', () async {
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);

      // 推进到 ping 之后又过两个周期：对端一直不回，判半开。
      f.clock.advance(60000 * 4);
      await Future<void>.delayed(Duration.zero);
      expect(client.state, isNot(ConnectionState.serving));
      expect(f.transport.closeCount, greaterThan(0));

      await client.close();
    });
  });

  group('收帧与流控（契约 §3、§4.3、§5）', () {
    test('presence 是握手后的明文帧，能收（中继合成的那一类）', () async {
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);

      f.transport.feed(
        '${jsonEncode({'v': 1, 't': 'presence', 'computer': 'online'})}\n',
      );
      await Future<void>.delayed(Duration.zero);
      // 诊断面是**另一个接口**（`SyncClientProbe`）—— UI 看不到它，
      // 免得界面层自己解析帧（那正是分层要防的）。
      final probe = client as SyncClientProbe;
      expect(probe.presenceFrames.length, 1);

      await client.close();
    });

    test('未知帧类型无 id → 忽略；有 id → 回 res ok:false（沉默会让对端永远挂着）', () async {
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);
      final before = f.transport.sent.length;

      // 无 id：忽略，什么都不回。
      f.transport.feed('{"v":1,"t":"future-frame"}\n');
      await Future<void>.delayed(Duration.zero);
      expect(f.transport.sent.length, before);

      // 有 id：必须回错。
      f.transport.feed('{"v":1,"t":"future-frame","id":"r1"}\n');
      await Future<void>.delayed(Duration.zero);
      final res = f.transport.sentFrames
          .where((x) => x['t'] == 'res')
          .lastOrNull;
      expect(res, isNotNull);
      expect(res!['ok'], isFalse);
      expect(res['id'], 'r1');

      await client.close();
    });

    test('握手期收到业务帧 = 攻击面 → 关连接', () async {
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      expect(client.state, ConnectionState.handshake);

      // 还没握手完就塞一个业务帧（`ev`）。
      f.transport.feed(
        '${jsonEncode({'v': 1, 't': 'ev', 'sid': 's1', 'seq': 1, 'fc': 0, 'box': 'x'})}\n',
      );
      await Future<void>.delayed(Duration.zero);
      expect(client.state, isNot(ConnectionState.serving));
      expect(f.transport.closeCount, greaterThan(0));

      await client.close();
    });

    test('缺 box 的业务帧被拒（跳过解箱等于跳过认证与重放守卫）', () async {
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);

      f.transport.feed('${jsonEncode({'v': 1, 't': 'credit', 'fc': 0})}\n');
      await Future<void>.delayed(Duration.zero);
      expect(f.transport.closeCount, greaterThan(0), reason: '缺 box 必须关连接');

      await client.close();
    });

    test('ev 的载荷是**真实 DSH 事件**（不是 fixtures 的 {itemId,text}）', () async {
      // 实测电脑侧封的是 `JSON.stringify(record.event)`，而它是
      // `{type, seq, time, data}`（`connector/src/session-subscriptions.ts:170,175`）。
      // fixtures 词汇层的 `{itemId, text}` 是**可逆占位**，不是线上形状 ——
      // 按 fixture 形状解析真实流量会在第一个事件上就抛"缺少 itemId"。
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      final deltas = <SessionDelta>[];
      client.sessionUpdates('s1').listen(deltas.add);

      await client.start();
      await answerHello(f.transport);
      final keys = await sessionKeysFor(f.transport);
      // 电脑侧封一帧真实的 `assistant/message` 事件。
      final pc = BoxCodec(keys: keys, role: HandshakeRole.responder);
      final event = {
        'type': 'assistant/message',
        'seq': 3,
        'time': 1234,
        'data': {
          'message': {'id': 'msg-7'},
        },
      };
      const frame = <String, Object?>{
        'v': 1,
        't': 'ev',
        'sid': 's1',
        'seq': 3,
        'fc': 0,
        'box': '',
      };
      final box = await pc.sealFrame(frame, jsonEncode(event));
      f.transport.feed('${jsonEncode({...frame, 'box': box})}\n');
      await pump();

      expect(deltas, isNotEmpty, reason: '真实形状的事件必须被解析出来');
      // `itemId` 由事件自身推导（§5.2）：`assistant/message` → `m:<message.id>`。
      expect(deltas.last.items.single.itemId, 'm:msg-7');
      // 文本留空：这一层不认识 `type` 的语义，内容投影归渲染层。
      expect(deltas.last.items.single.text, '');

      await client.close();
    });

    test('ev 载荷缺 type / 不是对象 → 关连接（不是静默丢弃）', () async {
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);
      final keys = await sessionKeysFor(f.transport);

      final pc = BoxCodec(keys: keys, role: HandshakeRole.responder);
      const frame = <String, Object?>{
        'v': 1,
        't': 'ev',
        'sid': 's1',
        'seq': 1,
        'fc': 0,
        'box': '',
      };
      // 没有 `type` 的载荷：读不出 itemId，必须吵而不是静默丢。
      final box = await pc.sealFrame(frame, jsonEncode({'seq': 1}));
      f.transport.feed('${jsonEncode({...frame, 'box': box})}\n');
      await pump();

      expect(f.transport.closeCount, greaterThan(0));

      await client.close();
    });
  });

  group('写操作与幂等（契约 §5.6）', () {
    test('subscribe 先落盘再发送（顺序反了崩溃窗口会丢写操作）', () async {
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);

      await client.subscribe('s1', since: 7);
      // 落盘里有这一条（幂等键在）。
      final stored = await f.store.load();
      expect(stored.length, 1);
      expect(stored.single.method, 'session.subscribe');
      expect(stored.single.requestId.isNotEmpty, isTrue);

      await client.close();
    });

    test('离线时带幂等键的调用抛 relayOffline，但**已落盘**（不假装成功）', () async {
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      // 不 start：连接不在服务态。
      await expectLater(
        client.call<void>('session.prompt', {
          'sid': 's1',
          'text': 'hi',
        }, requestId: 'rid-1'),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.relayOffline,
          ),
        ),
      );
      // 但它是**落盘过的** —— 连接回来后能补发。
      final stored = await f.store.load();
      expect(stored.single.requestId, 'rid-1');

      await client.close();
    });

    test('不带幂等键的调用在离线时直接抛（只读方法不需要落盘）', () async {
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await expectLater(
        client.call<void>('repo.info', const {}),
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.relayOffline,
          ),
        ),
      );
      expect((await f.store.load()), isEmpty, reason: '只读方法不该进待发队列');

      await client.close();
    });
  });

  group('Outbox 自身（契约 §5.6，不变量 I8）', () {
    test('落盘失败即拒绝入队（不是"先发了再说"）', () async {
      final store = _FailingStore();
      final outbox = Outbox(store: store, send: (_) async => true);
      await expectLater(
        outbox.enqueue(
          const OutboxEntry(
            requestId: 'r1',
            method: 'session.prompt',
            params: {},
          ),
        ),
        throwsA(isA<StateError>()),
      );
      expect(outbox.pending, 0, reason: '没落盘就不能留在队列里');
    });

    test('同一个幂等键重复入队是**无操作**（重发复用同一条）', () async {
      final store = InMemoryOutboxStore();
      final sent = <String>[];
      final outbox = Outbox(
        store: store,
        send: (entry) async {
          sent.add(entry.requestId);
          return true;
        },
      );
      const entry = OutboxEntry(
        requestId: 'r1',
        method: 'session.prompt',
        params: {},
      );
      await outbox.enqueue(entry);
      await outbox.enqueue(entry);
      expect(outbox.pending, 1);
      await outbox.flush();
      expect(sent, ['r1'], reason: '只发一次');
    });

    test('离线时 flush 停住（不跳过继续）—— FIFO 顺序是刻意的', () async {
      final store = InMemoryOutboxStore();
      final attempted = <String>[];
      var online = false;
      final outbox = Outbox(
        store: store,
        send: (entry) async {
          attempted.add(entry.requestId);
          return online;
        },
      );
      await outbox.enqueue(
        const OutboxEntry(requestId: 'r1', method: 'a', params: {}),
      );
      await outbox.enqueue(
        const OutboxEntry(requestId: 'r2', method: 'b', params: {}),
      );

      expect(await outbox.flush(), FlushOutcome.offline);
      expect(attempted, ['r1'], reason: '第一条发不出去就停住，不试第二条');
      expect(outbox.pending, 2, reason: '都没发出去');

      online = true;
      expect(await outbox.flush(), FlushOutcome.sent);
      expect(outbox.pending, 0);
      expect(attempted, ['r1', 'r1', 'r2']);
    });

    test('restore 从落盘恢复且幂等；坏行抛错不静默跳过', () async {
      final store = InMemoryOutboxStore();
      await store.append(
        const OutboxEntry(requestId: 'r1', method: 'a', params: {}),
      );
      final outbox = Outbox(store: store, send: (_) async => true);
      await outbox.restore();
      await outbox.restore(); // 幂等
      expect(outbox.pending, 1);

      // 坏行：缺 requestId。
      expect(
        () => OutboxEntry.fromJson(const {'method': 'a'}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => OutboxEntry.fromJson(const {'requestId': 'r', 'method': ''}),
        throwsA(isA<FormatException>()),
      );
    });

    test('clear 清空落盘与内存', () async {
      final store = InMemoryOutboxStore();
      final outbox = Outbox(store: store, send: (_) async => true);
      await outbox.enqueue(
        const OutboxEntry(requestId: 'r1', method: 'a', params: {}),
      );
      await outbox.clear();
      expect(outbox.pending, 0);
      expect(await store.load(), isEmpty);
    });

    test('newRequestId 是 base64url 且无填充', () {
      final id = newRequestId(Uint8List.fromList(List.generate(16, (i) => i)));
      expect(id.endsWith('='), isFalse);
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id), isTrue);
    });
  });

  group('LiveAccumulator（app-channel-client.md §2.2）', () {
    String chunk(String text) => jsonEncode({
      'type': 'chunk',
      'time': 1,
      'chunk': {'text': text},
    });

    test('rev 连续则追加', () {
      final acc = LiveAccumulator();
      expect(acc.accept(stream: 1, rev: 0, payload: chunk('你')), isTrue);
      expect(acc.accept(stream: 1, rev: 1, payload: chunk('好')), isTrue);
      expect(acc.text, '你好');
    });

    test('stream 变大 ⇒ 换流并重置', () {
      final acc = LiveAccumulator();
      acc.accept(stream: 1, rev: 0, payload: chunk('旧'));
      expect(acc.accept(stream: 2, rev: 0, payload: chunk('新')), isTrue);
      expect(acc.text, '新', reason: '换流要重置累加器');
      expect(acc.stream, 2);
    });

    test('rev 跳跃 ⇒ 丢弃已累积内容并停止渲染（自愈，不请求重传）', () {
      final acc = LiveAccumulator();
      acc.accept(stream: 1, rev: 0, payload: chunk('一'));
      acc.accept(stream: 1, rev: 1, payload: chunk('二'));
      expect(acc.text, '一二');
      // 跳到 rev=5：丢流。
      expect(acc.accept(stream: 1, rev: 5, payload: chunk('三')), isFalse);
      expect(acc.text, '', reason: '丢弃该流已累积内容，等持久事件到达');
      expect(acc.lastRev, 5);
      // 从 5 之后继续（+1）就能接着走。
      expect(acc.accept(stream: 1, rev: 6, payload: chunk('四')), isTrue);
      expect(acc.text, '四');
    });

    test('持久事件到达时替换累加器内容（以持久为准）', () {
      final acc = LiveAccumulator();
      acc.accept(stream: 1, rev: 0, payload: chunk('流式'));
      acc.replaceWith('最终文本');
      expect(acc.text, '最终文本');
    });

    test('读不懂的载荷不断连，只停在当前内容', () {
      final acc = LiveAccumulator();
      acc.accept(stream: 1, rev: 0, payload: chunk('保留'));
      expect(acc.accept(stream: 1, rev: 1, payload: 'not json'), isFalse);
      expect(acc.text, '保留');
    });
  });
}

/// 落盘失败的表（测"落盘失败即拒绝"）。
class _FailingStore implements OutboxStore {
  @override
  Future<List<OutboxEntry>> load() async => const [];

  @override
  Future<void> append(OutboxEntry entry) async => throw StateError('磁盘满了');

  @override
  Future<void> remove(String requestId) async {}

  @override
  Future<void> clear() async {}
}
