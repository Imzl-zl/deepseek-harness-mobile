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
import 'package:dsh_mobile/core/flow.dart';
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

/// `buildDeps` 的返回类型。
///
/// 它本来是个匿名记录类型，而匿名记录类型没法写进函数签名 ——
/// 那让"接收一套 deps 的辅助函数"必须把五个字段重抄一遍（且抄错不报错）。
/// 起个名字就解决了，且它让测试签名的意图一眼可见。
typedef Harness = ({
  SyncClientDeps deps,
  FakeTransport transport,
  FakeClock clock,
  DeviceSession session,
  InMemoryOutboxStore store,
});

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
  buildDeps({bool failConnect = false, ItemPersister? persistence}) {
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
      persistence: persistence,
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
    // **最后一帧** hello：重连之后会有多帧，而要答的是**当前这条连接**发的那一帧
    // （答早了的那一帧只会让旧连接白等，症状是"重连后再也进不了 serving"）。
    final helloFrame = transport.sentFrames
        .where((f) => f['t'] == 'hello')
        .lastOrNull;
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

  group('sync.hello：恢复握手 + 前后台态声明（契约 §5.4、§6.2）', () {
    test('进服务态就声明一次：app=foreground， sessions 是已声明的订阅集', () async {
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);
      await pump();

      final probe = client as SyncClientProbe;
      final hello = probe.sentRequests.singleWhere(
        (envelope) => envelope['method'] == 'sync.hello',
      );
      expect(hello['params'], {
        'app': 'foreground',
        'sessions': <Object?>[],
      }, reason: '还没订阅任何会话：声明空集，而前后台态必须如实报');
      // `sync.hello` 不带幂等键（它不是写操作）—— 电脑侧的分发器会因此放过它。
      expect(hello['requestId'], isNull);

      await client.close();
    });

    test('订阅集跟着声明走：subscribe 记下来，unsubscribe 摘掉', () async {
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);
      final probe = client as SyncClientProbe;

      await client.subscribe('s1', since: 7);
      await client.subscribe('s2', since: 0);
      await client.unsubscribe('s1');
      expect(probe.declaredSessions, {'s2': 0});

      // 断线重连之后**由连接层**重新声明整份订阅集（UI 不会重新点开会话）。
      f.transport.dropFromPeer();
      await pump();
      expect(client.state, ConnectionState.backoff);
      f.clock.advance(1000);
      await pump();
      await answerHello(f.transport);
      await pump();

      final hellos = probe.sentRequests
          .where((envelope) => envelope['method'] == 'sync.hello')
          .toList();
      expect(hellos.length, 2, reason: '每次进服务态都声明一次');
      expect(hellos.last['params'], {
        'app': 'foreground',
        'sessions': <Object?>[
          {'sid': 's2', 'since': 0},
        ],
      }, reason: '恢复要的是"所有会话"，不是一个');

      await client.close();
    });

    test('切后台：先声明 app=background 并**等它写出去**，再断开', () async {
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);
      await client.subscribe('s1', since: 3);
      final probe = client as SyncClientProbe;

      await client.setAppState(AppState.background);
      expect(client.state, ConnectionState.idle);

      final hellos = probe.sentRequests
          .where((envelope) => envelope['method'] == 'sync.hello')
          .toList();
      expect(hellos.length, 2, reason: '进服务态一次、切后台一次');
      expect(
        hellos.last['params'],
        {
          'app': 'background',
          'sessions': <Object?>[
            {'sid': 's1', 'since': 3},
          ],
        },
        reason: '退到后台也要如实声明 —— 电脑侧的 foreground 档据此停止把审批推给手机',
      );

      await client.close();
    });
  });

  /// 复算会话密钥（测试扮演电脑侧要用它封箱）。
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

    test('重连后心跳状态是**新的**（旧连接的沉默不能算到新连接头上）', () async {
      // 这条守的是一个真 bug：`Keepalive` 持每连接状态（`_lastFrameAt`），
      // 而它只在构造时建一次、`_connect()` **不重置它**。
      //
      // 时序要算准才暴露得出来（第一次写这条用例时算错了，它"通过"了但什么都没验到）：
      // 心跳 60 s、半开阈值 120 s、判定周期 15 s。
      // - t=60 s：发过一次 ping（它重置了 `_lastFrameAt`），此后 `_pingedInThisIdle`
      //   挡住新 ping，于是沉默开始累积；
      // - t=178 s：沉默 118 s（**还差 2 s 到阈值**，所以这时断开是合法的 ——
      //   真到 120 s 的话半开早就把它关了）；
      // - 断开 + 退避 1 s → t=179 s 重连，`_startTicking()` 取消旧 tick 并重排到 t=194 s；
      // - t=194 s 那次 tick：**不重置**的话沉默算成 134 s ≥ 120 s → 立刻判半开
      //   （症状是"刚重连上就被踢"，然后退避→重连→再被踢，抖个不停）。
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);
      expect(client.state, ConnectionState.serving);

      f.clock.advance(178000);
      f.transport.dropFromPeer();
      await pump();
      expect(client.state, ConnectionState.backoff);

      f.clock.advance(1000); // 退避到点 → 重连
      await pump();
      expect(client.state, ConnectionState.handshake, reason: '重连应进握手');

      // 新连接的一个判定周期：沉默只该从**重连那一刻**算（15 s < 120 s）。
      f.clock.advance(15000);
      await pump();
      expect(
        client.state,
        ConnectionState.handshake,
        reason: '旧连接沉默的 118 s 不能算到新连接头上（否则刚连上就被踢）',
      );

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
      // 封箱是异步的（`_sendFrame` 里 `unawaited(...)`），所以要放一个微任务
      // 让那一帧真正落到发件口上 —— 否则 `sentFrames` 里还没有它。
      await Future<void>.delayed(Duration.zero);
      final ping = f.transport.sentFrames.firstWhere((f) => f['t'] == 'ping');

      // **`ping` 必须带 `fc`**：它是要封箱的（§3），而 `fc` 是 nonce 的来源 ——
      // 少了它，对端在解箱那一步就判 `protocol/bad-frame` 并关掉连接
      // （真机实测：每 15 秒一轮重连，连接器日志是 `ping 帧没有 fc,不该封箱`）。
      // 这条曾经漏过：`ping` 走的是"直接写"那条路，绕开了 `fc` 的分配点。
      expect(
        ping['fc'],
        isA<int>(),
        reason: 'ping 要封箱，就必须有 fc（否则对端解不开、判坏帧、断连）',
      );

      // **`ping` 必须带 `id`**（§2.2）：`pong` 没有 `sid`，中转只能靠 `id` 回程 ——
      // 少了它，应答在中转侧被丢弃，探针永远等不到回复，
      // 于是每个心跳周期都判一次半开（真机实测的 60 s 周期重连）。
      expect(
        ping['id'],
        isA<String>(),
        reason: 'ping 要能被应答送回，就必须带 id（否则中转丢弃 pong）',
      );

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

    test('**封了箱的** credit 必须被解开后记账（曾把密文喂给 decodeCredit）', () async {
      // 这条守的是一个真 bug（2026-10-13 真机实测）：`_handleOpened` 把**还没解箱的**
      // `frame` 递给 `_accountFlow`，于是 `decodeCredit` 拿到密文并抛
      // `credit 载荷不是合法 JSON` → `_protocolFailure` → 关连接。
      //
      // 症状极有误导性：**握手成功、随即断线**（真机上 `serving` 之后 20 ms 就 closed），
      // 而电脑侧一条日志都没有。上面那条"缺 box"的用例抓不到它 ——
      // 它喂的帧压根没有箱，走的是另一条分支。
      //
      // 电脑侧同一处是对的（`connection.ts` 的 `opened` 两份都从它取）；
      // 两侧各写一遍，一侧改了另一侧不会红。
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);
      expect(client.state, ConnectionState.serving);

      final keys = await sessionKeysFor(f.transport);
      final codec = BoxCodec(keys: keys, role: HandshakeRole.responder);
      // 电脑侧回一个**真封箱**的 credit（确认到 fc=0）。
      final sealed = await codec.sealFrame({
        'v': 1,
        't': 'credit',
        'fc': 0,
      }, encodeCredit(0));
      f.transport.feed(
        '${jsonEncode({'v': 1, 't': 'credit', 'fc': 0, 'box': sealed})}\n',
      );
      await pump();

      expect(
        client.state,
        ConnectionState.serving,
        reason:
            '封了箱的 credit 必须被解开后记账；把密文喂给 decodeCredit 会关连接'
            '（诊断：${(client as SyncClientProbe).lastProtocolError?.message ?? '无'}）',
      );
      expect(f.transport.closeCount, 0, reason: '这一帧不该关连接');

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
      final received = deltas.last.events.single;
      // `itemId` 由事件自身推导（§5.2）：`assistant/message` → `m:<message.id>`。
      expect(received.itemId, 'm:msg-7');
      // **`type` 与 `data` 必须原样带上**：上层（`data/projection.dart`）靠它们
      // 决定"渲染成什么"。解析时丢掉它们，等于逼上层从 `text` 里猜事件类型。
      expect(received.type, 'assistant/message', reason: 'type 不能被丢掉');
      expect((received.data! as Map)['message'], {
        'id': 'msg-7',
      }, reason: 'data 不能被丢掉（内容投影归上层）');
      // 时刻也带上了（DSH 事件自带 `time`）。
      expect(received.time, 1234);

      await client.close();
    });

    group('落盘与 persisted（契约 §5.3：水位永不超过落盘内容）', () {
      /// 造一帧真的 `ev`（电脑侧封箱）。
      Future<void> feedEvent(
        Harness f,
        int seq, {
        required String itemId,
        int? fc,
      }) async {
        final keys = await sessionKeysFor(f.transport);
        final pc = BoxCodec(keys: keys, role: HandshakeRole.responder);
        final event = <String, Object?>{
          'type': 'assistant/message',
          'seq': seq,
          'time': 1000 + seq,
          'data': {
            'message': {'id': itemId},
          },
        };
        final frame = <String, Object?>{
          'v': 1,
          't': 'ev',
          'sid': 's1',
          'seq': seq,
          // **`fc` 必须逐帧递增**：收帧侧有重放守卫（契约 §4.2），
          // 重复的 `fc` 会被判成重放并关连接 —— 第一版固定写 0，
          // 连发三帧时第三帧就把连接关了（症状是
          // `Bad state: Cannot add event after closing`，指向的是测试工具而不是真因）。
          'fc': fc ?? (seq - 1),
          'box': '',
        };
        final box = await pc.sealFrame(frame, jsonEncode(event));
        f.transport.feed('${jsonEncode({...frame, 'box': box})}\n');
        await pump();
      }

      /// `persisted` 帧（按 `seq`）。
      List<int> persistedSeqs(Harness f) => f.transport.sentFrames
          .where((frame) => frame['t'] == 'persisted')
          .map((frame) => frame['seq']! as int)
          .toList();

      test('持久事件**落盘之后**才发 persisted，且带的是原样的 seq', () async {
        final persister = _RecordingPersister();
        final f = buildDeps(persistence: persister);
        final client = createSyncClient(f.deps);
        await client.start();
        await answerHello(f.transport);

        await feedEvent(f, 1, itemId: 'm1');
        await pump();

        expect(persister.calls.length, 1, reason: '应落盘一次');
        expect(persister.calls.single.sid, 's1');
        expect(persister.calls.single.seq, 1);
        expect(persister.calls.single.events.single.itemId, 'm:m1');
        expect(persistedSeqs(f), [1], reason: '落盘成功后才发 persisted');

        await client.close();
      });

      test('**落盘失败就不发 persisted**（水位不前进 ⇒ 重连时电脑会重发）', () async {
        // 这是本组最重要的一条。发出去的 persisted 会让电脑**裁掉那边的增量缓冲**，
        // 而手机其实没存 —— 后果是重启后那段数据**永久丢失**（源头已经裁掉了）。
        // 所以"落盘失败还发 persisted"是最糟的选择：把可恢复的失败变成数据丢失。
        final persister = _RecordingPersister(failWith: StateError('磁盘满了'));
        final f = buildDeps(persistence: persister);
        final client = createSyncClient(f.deps);
        await client.start();
        await answerHello(f.transport);

        await feedEvent(f, 1, itemId: 'm1');
        await pump();

        expect(persister.calls.length, 1, reason: '它确实尝试了落盘');
        expect(
          persistedSeqs(f),
          isEmpty,
          reason: '落盘失败绝不能发 persisted —— 水位超前于内容 = 数据永久丢失',
        );
        // 但本地水位也不该前进（否则重连时手机会说"我到 1 了"）。
        expect(f.session.sinceOf('s1'), 0, reason: '本地水位不该前进');
        // 失败要如实记下来（问题是"数据少了一段"，没有别的可见症状）。
        expect((client as SyncClientProbe).lastPersistError, isStateError);

        await client.close();
      });

      test('多条事件按**到达顺序**落盘（水位不会倒退）', () async {
        // 落盘是异步的：若并发做，完成顺序可能与到达顺序不同，
        // 而水位"取最大"—— 那会让先发出去的 persisted 带较大的 seq。
        // 串行链保证顺序，且让 `core/` 不依赖存储实现的那个细节。
        final persister = _RecordingPersister(delayMs: 5);
        final f = buildDeps(persistence: persister);
        final client = createSyncClient(f.deps);
        await client.start();
        await answerHello(f.transport);

        await feedEvent(f, 1, itemId: 'm1');
        await feedEvent(f, 2, itemId: 'm2');
        await feedEvent(f, 3, itemId: 'm3');
        // 等串行链跑完（每条 5 ms 延迟）。
        await Future<void>.delayed(const Duration(milliseconds: 120));
        await pump();

        expect(persister.calls.map((c) => c.seq).toList(), [
          1,
          2,
          3,
        ], reason: '落盘必须按到达顺序');
        expect(persistedSeqs(f), [1, 2, 3], reason: 'persisted 也按顺序');

        await client.close();
      });

      test('没有落盘缝时仍发 persisted（只给不关心崩溃恢复的单测）', () async {
        final f = buildDeps();
        final client = createSyncClient(f.deps);
        await client.start();
        await answerHello(f.transport);

        await feedEvent(f, 1, itemId: 'm1');
        await pump();

        expect(persistedSeqs(f), [1]);

        await client.close();
      });
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
    test('subscribe 先落盘再发送，且真的发出去了', () async {
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);

      await client.subscribe('s1', since: 7);
      // `_sendFrame` 是**同步返回、异步封箱**的（它 `unawaited` 了 sealFrame），
      // 所以"发出去了"要等一轮事件循环才看得到。
      await pump();

      // 出帧口必须装上（没装就永远发不出去，而 `flush` 只会如实说 offline）。
      expect(
        f.deps.outbox.hasSender,
        isTrue,
        reason: 'SyncClient 构造时应把出帧口装到队列上',
      );

      // **真的发出去了**：这一条曾经是假的 —— 装配点传了
      // `send: (_) async => false`，于是 `flush()` 永远返回 `offline`、
      // 队列里每一条都永远发不出去，而症状只是"订阅了但收不到数据"。
      //
      // 按**方法名**数而不是按帧数：进服务态时还会发一帧 `sync.hello`
      // （契约 §5.4 的恢复握手 + 前后台态声明）。线上的 `box` 是密文，
      // 所以这里读诊断面上的明文信封（`SyncClientProbe.sentRequests`）。
      final probe = client as SyncClientProbe;
      final methods = probe.sentRequests
          .map((envelope) => envelope['method'])
          .toList();
      expect(
        methods.where((m) => m == 'session.subscribe').length,
        1,
        reason: 'subscribe 应发出一帧 session.subscribe req（当前状态 ${client.state}）',
      );
      expect(
        methods.where((m) => m == 'sync.hello').length,
        1,
        reason: '进服务态必须声明一次 sync.hello（否则电脑侧不知道手机在前台）',
      );
      final subscribe = probe.sentRequests.singleWhere(
        (envelope) => envelope['method'] == 'session.subscribe',
      );
      expect(
        subscribe['requestId'],
        isNotEmpty,
        reason: '写操作要带幂等键的信封（电脑侧据此去重，重发安全）',
      );
      expect(subscribe['params'], {
        'sid': 's1',
        'since': 7,
      }, reason: 'sid 与水位原样递下去');

      // 发出之后从队列里移除（电脑侧已收到）。
      expect(await f.store.load(), isEmpty, reason: '已发出的不该留在待发队列里');

      await client.close();
    });

    test('离线时**不发送**，条目留在队列里等重连', () async {
      // 这条守的是 FIFO 队列的本意：发不出去时既不能丢，也不能假装发成功。
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      // 不 start：连接不在服务态。
      await client.subscribe('s1', since: 7);

      expect(
        f.transport.sentFrames.where((frame) => frame['t'] == 'req'),
        isEmpty,
        reason: '不在服务态就不该发出去',
      );
      final stored = await f.store.load();
      expect(stored.length, 1, reason: '发不出去要留在队列里（不许丢）');
      expect(stored.single.method, 'session.subscribe');
      expect((f.deps.outbox).pending, 1);

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

    test('在途请求遇到断连**必须被拒绝**，不能永远挂着', () async {
      // 这条守的是一个真缺口：`_pendingCalls` 既没有超时，`_enterClosed()` 也不清它。
      // 后果：连接在请求在途时断掉，调用方的 `await` **永远不返回** ——
      // 而 UI 的表现是"转圈转到天荒地老"，用户只能杀掉 App。
      // 断连是常态（§2.1 明写"重连是常态，不是异常路径"），所以这条路必然走到。
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);
      expect(client.state, ConnectionState.serving);

      // 发一个不带幂等键的调用（走即时请求路径），不等它。
      final pending = client.call<Object?>('repo.info', const {});
      await pump();
      expect(
        f.transport.sentFrames.any((x) => x['t'] == 'req'),
        isTrue,
        reason: '请求应已发出',
      );

      // **先挂上断言，再断开**：`pending` 会以错误完成，而 Dart 在"没有处理者的
      // 错误 Future"上是直接报未处理异常（测试会红在断言之前，看起来像 bug 没修）。
      final rejected = expectLater(
        pending,
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.relayOffline,
          ),
        ),
        reason: '断连时在途请求要被拒绝（否则调用方永远等不到）',
      );

      // 对端断开。
      f.transport.dropFromPeer();
      await pump();
      await rejected;

      // 诊断面：被拒绝的条数要如实记下来（"这次断连伤到了什么"的唯一证据）。
      expect((client as SyncClientProbe).lastRejectedCalls, 1);

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

/// 记账用的落盘缝（测"persisted 只在落盘成功后发"）。
///
/// 它不真存东西 —— 这一层的被测对象是**调用时序**（什么时候发 `persisted`），
/// 而"真的存进去了没有"由 `store_contract_test.dart` 用真 SQLite 钉住。
class _RecordingPersister implements ItemPersister {
  _RecordingPersister({this.failWith, this.delayMs = 0});

  /// 给了就让每次落盘抛这个错（测"失败不发 persisted"）。
  ///
  /// 类型是 `Object`：真实落盘失败可能是 `Exception`（IO）也可能是 `Error`
  /// （比如 sqflite 的 `DatabaseException`），而这一层要能表达两种。
  final Object? failWith;

  /// 每次落盘的延迟（测"串行链"时需要它把顺序问题放大）。
  final int delayMs;

  final List<({String sid, List<SessionEvent> events, int seq})> calls = [];

  @override
  Future<void> persist({
    required String sid,
    required List<SessionEvent> events,
    required int seq,
  }) async {
    calls.add((sid: sid, events: events, seq: seq));
    if (delayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: delayMs));
    }
    final failure = failWith;
    // 这个假实现**故意**抛给定的东西（可能是 Error 也可能是 Exception，
    // 两种在真实落盘里都会出现）。所以这里明确压掉那条 lint。
    // ignore: only_throw_errors
    if (failure != null) throw failure;
  }
}
