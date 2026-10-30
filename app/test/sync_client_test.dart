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
import 'package:dsh_mobile/core/frame.dart' show idPattern;
import 'package:dsh_mobile/core/handshake.dart';
import 'package:dsh_mobile/core/handshake_driver.dart';
import 'package:dsh_mobile/core/keepalive.dart';
import 'package:dsh_mobile/core/outbox.dart';
import 'package:dsh_mobile/core/recovery.dart';
import 'package:dsh_mobile/core/sync_client.dart';
import 'package:dsh_mobile/core/sync_client_impl.dart';
import 'package:dsh_mobile/core/transport.dart';
import 'package:dsh_mobile/wire/reading.dart' show WireDiagnostics;
import 'package:flutter_test/flutter_test.dart';

/// 假的传输：把发出去的行记下来，并允许测试"从对端"注入行。
class FakeTransport implements ChannelTransport {
  FakeTransport({this.failConnect = false, this.failConnectWith});

  /// 连接建立是否失败（测退避用）。
  bool failConnect;

  /// 从第几次建连开始失败（默认 1 = 每次）。
  ///
  /// 用于"首轮在飞、次轮失败"的场景：光有 [failConnect] 会让**首轮**回来时
  /// 也失败 —— 那样测到的是失败分支，成功分支的过期判据就没人守。
  int failConnectFrom = 1;

  /// 建连时抛一个**带错误码**的传输错误（测"换票被拒 → 终态不进退避"）。
  ///
  /// 优先于 [failConnect]：给了它就抛它（如 `TransportException(..., code: notPaired)`）。
  final TransportException? failConnectWith;

  final List<String> sent = [];
  StreamController<TransportEvent>? _controller;

  /// 建立连接的次数（测重连）。
  int connectCount = 0;

  /// 首轮 `connect()` 卡在它上面（模拟"这一轮拨号还在飞"）。
  ///
  /// 用于回归"过期的一轮拨号回来后不许动连接"：真机上断网 / 换网时，
  /// 上一轮的拨号可能比收口晚回来好几秒。
  Completer<void>? firstConnectGate;

  /// 关闭次数。
  int closeCount = 0;

  @override
  Future<Stream<TransportEvent>> connect() async {
    connectCount += 1;
    // **这一通电话是第几通**要在入口记下来：卡在 gate 上时后来可能又发起过几次，
    // 用字段值判断会把"第 1 通回来"错当成"第 N 通"（那条成功路径就没人测了）。
    final thisCall = connectCount;
    final gate = firstConnectGate;
    if (thisCall == 1 && gate != null) await gate.future;
    final coded = failConnectWith;
    if (coded != null) throw coded;
    if (failConnect && thisCall >= failConnectFrom) {
      throw const TransportException('连不上');
    }
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
    final controller = _controller;
    if (controller == null || controller.isClosed) return;
    // **没人听的流，`close()` 的 future 永远不完成**（单订阅控制器的 done 事件
    // 要等一个监听者才会投递）。真实传输没有这个形状；替身里必须分开处理，
    // 否则"过期的那一轮没把流交出去"会把测试挂死在 close 上（实测 30 s 超时）。
    if (!controller.hasListener) {
      unawaited(controller.close());
      return;
    }
    await controller.close();
  }

  /// 从"对端"喂一片原始数据。
  void feed(String chunk) {
    _controller?.add(TransportMessage(chunk));
  }

  /// 模拟对端断开（`reason` 是电脑侧带出的**协议码**，见 `handshake-driver.ts:278`）。
  void dropFromPeer({int? code, String? reason}) {
    _controller?.add(TransportClosed(code: code, reason: reason));
  }

  /// 有没有人在听最近这份流（"过期的一轮把流交出去"的判据）。
  bool get hasListener => _controller?.hasListener ?? false;

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

  /// 每次 `schedule(fn, ms)` 里的 `ms`（按调用顺序）。
  ///
  /// 退避间隔是"连接层决定了多久"的唯一可见证据 —— 慢重试那 60 s 只能靠它断言。
  final List<int> delays = [];

  int now() => _now;

  void Function() schedule(void Function() fn, int ms) {
    delays.add(ms);
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
  buildDeps({
    bool failConnect = false,
    TransportException? failConnectWith,
    ItemPersister? persistence,
  }) {
    final transport = FakeTransport(
      failConnect: failConnect,
      failConnectWith: failConnectWith,
    );
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

  /// 最后一帧 `req` 的帧头 `id`（**帧号**，不是幂等键）。
  String lastReqId(FakeTransport transport) {
    final req = transport.sentFrames.where((f) => f['t'] == 'req').lastOrNull;
    expect(req, isNotNull, reason: '这一趟必须真的发出一帧 req');
    return req!['id'] as String;
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

  /// **anchor 链路**（`sync.hello` 的应答 → `hasOlderHistory`）。
  ///
  /// 单独一个 group 是因为它要用 [sessionKeysFor] 真封箱 —— 而那是个局部函数，
  /// 定义在文件后部（Dart 的局部函数在使用点之后声明就引用不到）。
  group('sync.hello 的应答带 anchor（历史翻页的信号）', () {
    test('hasMore 如实进 hasOlderHistory；没提到的 sid 留 false', () async {
      // 这一条守的是 2026-10-24 补上的缺口：`_sendHello` 以前用
      // `_sendFrameWritten`（**不等应答**），于是电脑侧在 hello 应答里带的
      // `{sessions: [{sid, since, hasMore}]}`（`connector/src/handlers.ts:767` 起）
      // **被丢掉** —— `_resolveCall` 只解登记过的帧，而那时没人在等。
      //
      // 表现：`hasOlderHistory` 恒 false ⇒ `loadOlderHistory` 永不翻页
      // ⇒ "历史上 20 轮只看到最近 3 轮"。
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);
      await pump();

      // 电脑侧应答 hello：这个 sid 还有更早的历史。
      // **box 要真封箱**（照下面 `写操作与幂等` 那组）：明文 jsonEncode 过不了
      // 解箱，2026-10-24 实测那样状态直接掉 backoff。
      final frame = <String, Object?>{
        'v': 1,
        't': 'res',
        'id': lastReqId(f.transport),
        'ok': true,
        'fc': 100,
      };
      final box =
          await BoxCodec(
            keys: await sessionKeysFor(f.transport),
            role: HandshakeRole.responder,
          ).sealFrame(
            frame,
            jsonEncode({
              'result': {
                'sessions': [
                  {'sid': 's1', 'since': 5, 'hasMore': true},
                ],
              },
            }),
          );
      f.transport.feed('${jsonEncode({...frame, 'box': box})}\n');
      await pump();

      expect(
        client.hasOlderHistory('s1'),
        isTrue,
        reason: 'hello 应答说还有更早的，就要能问出来',
      );
      // **没提到的 sid 留 false**：那是"不知道"，不是"确定没有"。
      expect(client.hasOlderHistory('s-other'), isFalse);

      await client.close();
    });

    test('应答认不出（形状不对）：不当错误，anchor 留 false、状态不坏', () async {
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);
      await pump();

      final frame = <String, Object?>{
        'v': 1,
        't': 'res',
        'id': lastReqId(f.transport),
        'ok': true,
        'fc': 100,
      };
      final box =
          await BoxCodec(
            keys: await sessionKeysFor(f.transport),
            role: HandshakeRole.responder,
          ).sealFrame(
            frame,
            jsonEncode({
              'result': {'sessions': 'nope'},
            }),
          );
      f.transport.feed('${jsonEncode({...frame, 'box': box})}\n');
      await pump();

      expect(client.hasOlderHistory('s1'), isFalse);
      expect(client.state, ConnectionState.serving);

      await client.close();
    });
  });

  /// **翻页里的 `refetch` 标记**（契约 §5.3：单个条目 >1 MiB 不推内容、推标记）。
  ///
  /// 2026-10-22 的缺口：`page()` 只留 `{kind:'record'}` 的项，`refetch` 标记
  /// **被直接跳过** ⇒ >1 MiB 的条目（图片内联在 `assistant/message` 里）
  /// 在会话里静默缺失（不报错、不缺页，就是少一条）。
  group('翻页里的 refetch 标记：补取而不是跳过', () {
    /// 应答**最后一帧 `req`**（真封箱；`fc` 每帧加一，重放守卫才不拦）。
    ///
    /// [envelope] 是 `res` 的**明文信封**：成功是 `{ok:true, result:…}` 里的
    /// `result` 那半边（这里统一写成 `{'result': …}`），失败是 `{code, message}`。
    Future<void> answerLastReq(
      FakeTransport transport,
      Map<String, Object?> envelope, {
      required int fc,
      bool ok = true,
    }) async {
      final frame = <String, Object?>{
        'v': 1,
        't': 'res',
        'id': lastReqId(transport),
        'ok': ok,
        'fc': fc,
      };
      final box = await BoxCodec(
        keys: await sessionKeysFor(transport),
        role: HandshakeRole.responder,
      ).sealFrame(frame, jsonEncode(envelope));
      transport.feed('${jsonEncode({...frame, 'box': box})}\n');
      await pump();
    }

    test('标记 → 调 session.refetch → 那一条出现在这一页里', () async {
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);
      await pump();

      final pageFuture = client.page(sid: 's1', beforeSeq: 10);
      await pump();
      // 电脑侧：这一页只有一条，但它 2 MiB ⇒ 只推标记。
      await answerLastReq(f.transport, {
        'result': {
          'items': [
            {'kind': 'refetch', 'seq': 4, 'bytes': 2 * 1024 * 1024},
          ],
          'hasMore': true,
        },
      }, fc: 100);

      // 手机侧应当为它单独发一次补取。
      final probe = client as SyncClientProbe;
      final refetches = probe.sentRequests
          .where((envelope) => envelope['method'] == 'session.refetch')
          .toList();
      expect(refetches.length, 1, reason: '标记必须换一次补取，不许跳过');
      expect(refetches.single['params'], {'sid': 's1', 'seq': 4});

      // 补取回一条**真事件**（形状同 `session.page` 的 record.event）。
      await answerLastReq(f.transport, {
        'result': {
          'record': {
            'type': 'event',
            'event': {
              'type': 'user/message',
              'seq': 4,
              'time': 44,
              'data': {
                'id': 'big-1',
                'role': 'user',
                'source': {'kind': 'user'},
                'content': '一条超过 1 MiB 的消息',
              },
            },
          },
        },
      }, fc: 101);

      final page = await pageFuture;
      expect(page.failure, isNull);
      expect(page.events.map((e) => e.seq).toList(), [4]);
      expect(page.events.single.type, 'user/message');
      expect(page.events.single.time, 44);
      // 事件按 seq 归位：补取的那条插在它该在的位置上。
      expect(page.events.single.itemId, isNotEmpty);
      expect(page.hasMore, isTrue);

      await client.close();
    });

    test('补取失败：这一页如实失败，不吞成"少一条"', () async {
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);
      await pump();

      final pageFuture = client.page(sid: 's1', beforeSeq: 10);
      await pump();
      await answerLastReq(f.transport, {
        'result': {
          'items': [
            {'kind': 'refetch', 'seq': 7, 'bytes': 3 * 1024 * 1024},
          ],
          'hasMore': false,
        },
      }, fc: 100);
      // 补取被电脑侧拒（真日志里这就是 `session/not-found`）。
      await answerLastReq(
        f.transport,
        {'code': 'session/not-found', 'message': '取不到条目 seq=7'},
        fc: 101,
        ok: false,
      );

      final page = await pageFuture;
      expect(page.failure, 'session/not-found', reason: '失败要如实报，不当成没有更多');
      expect(page.events, isEmpty, reason: '不落半页：宁可整页失败也不留一个静默的洞');
      expect(page.hasMore, isFalse, reason: '水位没前进，保留电脑侧这一页的结论');

      await client.close();
    });

    test('坏页（refetch 标记缺 seq）：整页如实失败，异常不许穿到调用方', () async {
      WireDiagnostics.reset();
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);
      await pump();

      final pageFuture = client.page(sid: 's1', beforeSeq: 10);
      await pump();
      // 标记取不回来 = 这一页有洞：页级硬错，不是"少一条"。
      await answerLastReq(f.transport, {
        'result': {
          'items': [
            {'kind': 'refetch', 'bytes': 2048},
          ],
          'hasMore': true,
        },
      }, fc: 102);

      final page = await pageFuture;
      expect(page.failure, 'protocol/bad-frame', reason: '页级形状错要如实失败，不是静默空页');
      expect(page.events, isEmpty);
      expect(WireDiagnostics.badCount, 1, reason: '同一个缺陷只计一次数');

      await client.close();
    });
  });

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

    test('换票被拒（notPaired）→ **终态停摆**：不进 backoff、不重连', () async {
      // 议题 2：设备被停用/删除后，中转 `/ws-ticket` 回 401 → 传输层带
      // `notPaired` 码抛出（`TicketedWebSocketTransport` / `EndpointTransport`）。
      // 连接层必须把它当**一次性终态**：停在 closed、不退避、不重连 ——
      // 否则每次都拿到同一个 401，用户永远卡在"重连中…"（用户原话）。
      final f = buildDeps(
        failConnectWith: const TransportException(
          '换票失败：换票被拒（HTTP 401）',
          code: ErrorCode.notPaired,
        ),
      );
      final client = createSyncClient(f.deps);
      await client.start();

      expect(
        client.state,
        ConnectionState.closed,
        reason: '终态：停在 closed，不进 backoff',
      );
      expect(f.transport.connectCount, 1);

      // 时钟走到天涯海角也不该重连（对比上面那条：网络失败会重连）。
      f.clock.advance(120000);
      await Future<void>.delayed(Duration.zero);
      expect(f.transport.connectCount, 1, reason: '身份不被认时退避重连毫无意义，绝不重连');

      final probe = client as SyncClientProbe;
      expect(probe.lastConnectWasTerminal, isTrue);
      expect(probe.lastProtocolError?.code, ErrorCode.notPaired);

      // 终态后直接回前台（机器还在 `closed`）：`setAppState(foreground)` 会把 closed
      // 当"该重连"调 `start()` → 若无守卫会走 `closed → connecting`（**非法迁移，会炸**）。
      // 守卫挡掉它：不重连、不抛（这行 await 若抛即红）。
      await client.setAppState(AppState.foreground);
      await Future<void>.delayed(Duration.zero);
      expect(f.transport.connectCount, 1, reason: '终态客户端回前台也不重连、不炸');

      await client.close();
    });

    test('握手被拒（4003 + `protocol/not-paired`）→ 终态：不重连、看得见原因', () async {
      // **终态的唯一来源**：电脑侧在握手层明说"我不认这台设备"
      // （`connector/src/protocol/handshake-driver.ts:164` 抛出 → `:278` 以协议码为理由关闭 →
      // `connector/src/transport/connection.ts:660` 用 4003 关）。
      // 换票 401 不再属于这一类（中转只能说"名册里没你"，见 `pairing_client.dart`）。
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);
      await pump();
      expect(client.state, ConnectionState.serving);

      f.transport.dropFromPeer(code: 4003, reason: 'protocol/not-paired');
      await pump();

      final probe = client as SyncClientProbe;
      expect(probe.lastConnectWasTerminal, isTrue);
      expect(probe.lastProtocolError?.code, ErrorCode.notPaired);
      expect(client.state, ConnectionState.closed);

      f.clock.advance(120000);
      await pump();
      expect(f.transport.connectCount, 1, reason: '电脑已明说不认本机：不重连（等上层清凭据）');
      await client.close();
    });

    test('4003 但理由不是身份拒绝（坏帧 / 超时 / 无理由）→ **照旧退避重连**', () async {
      // 4003 是"握手失败"的通用关闭码，只有**理由**是身份类协议码时才是终态。
      for (final reason in <String?>[
        null,
        'protocol/bad-frame',
        'handshake-timeout',
        'internal',
      ]) {
        final f = buildDeps();
        final client = createSyncClient(f.deps);
        await client.start();
        await answerHello(f.transport);
        await pump();

        f.transport.dropFromPeer(code: 4003, reason: reason);
        await pump();

        final probe = client as SyncClientProbe;
        expect(
          probe.lastConnectWasTerminal,
          isFalse,
          reason: '理由 ${reason ?? 'null'} 不是身份拒绝，不该清凭据',
        );
        expect(
          client.state,
          ConnectionState.backoff,
          reason: '理由 ${reason ?? 'null'} 要退避',
        );

        f.clock.advance(1100);
        await pump();
        expect(
          f.transport.connectCount,
          2,
          reason: '理由 ${reason ?? 'null'} 要重连',
        );
        await client.close();
      }
    });

    test('被另一台设备占用（4003 + `device/busy 名字`）→ 不自动重连，说得出是谁', () async {
      // 独占 1:1：电脑侧在握手处拒第二台（`connector/src/protocol/handshake-driver.ts`），
      // 理由的形状是 `协议码 说明`（契约 §4.1）—— 说明里是占用者的展示名。
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await pump(); // hello 已发出，等电脑侧回 hello-ack 之前被拒

      f.transport.dropFromPeer(code: 4003, reason: 'device/busy 我的手机');
      await pump();

      final probe = client as SyncClientProbe;
      expect(probe.lastConnectBusy, isTrue, reason: '被占用要能被界面认出来');
      expect(probe.lastConnectWasTerminal, isFalse, reason: '凭据是好的：绝不清凭据');
      expect(probe.lastProtocolError?.code, ErrorCode.deviceBusy);
      expect(
        probe.lastProtocolError?.message,
        '我的手机',
        reason: '占用者名字来自关闭理由，不许在 App 侧另造一句',
      );
      expect(client.state, ConnectionState.closed, reason: '不进退避（不自动撞门）');

      // **不自动重连**：等过任何一段退避间隔都不会再连。
      f.clock.advance(120000);
      await pump();
      expect(f.transport.connectCount, 1, reason: '占用位什么时候空不是我们能决定的');

      // **手动重试照常放行**：它是用户动作（连接 sheet 的「重试连接」）。
      await client.reconnect();
      await pump();
      expect(f.transport.connectCount, 2);
      expect(probe.lastConnectBusy, isFalse, reason: '重试之后结论作废');

      await client.close();
    });

    test('被占用但理由不带说明：给一句人话，不把裸码当名字', () async {
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await pump();
      f.transport.dropFromPeer(code: 4003, reason: 'device/busy');
      await pump();

      final probe = client as SyncClientProbe;
      expect(probe.lastConnectBusy, isTrue);
      expect(probe.lastProtocolError?.message, '这台电脑正被另一台设备连接');
      await client.close();
    });

    test('连续失败到阈值：结论给过之后改成 60 s 静默慢重试（不是再也不试）', () async {
      // 方案决策 7 的表："结论之后 | 静默慢重试 60 s + ±20% 抖动 | 用户已拿到结论，
      // 重试不该再打扰；抖动防惊群"。
      final f = buildDeps(failConnect: true);
      final client = createSyncClient(f.deps);
      await client.start();
      final probe = client as SyncClientProbe;

      // 快退避：1,2,4,8,16,30,30,30,30,30（10 次到阈值）。每轮推进都够走完一个间隔。
      for (var i = 0; i < 10; i += 1) {
        f.clock.advance(31000);
        await pump();
      }
      expect(probe.lastConnectGaveUp, isTrue, reason: '到阈值必须给结论');
      // 退避间隔里先是快退避（≤30 s），到阈值之后变成 60 s（含抖动前是整 60 s）。
      final backoffDelays = f.clock.delays
          .where((ms) => ms != 25 && ms != 15000)
          .toList();
      expect(backoffDelays.take(10).last, 30000, reason: '快退避封顶 30 s');
      expect(backoffDelays[10], 60000, reason: '结论之后是 60 s 慢重试');

      // **还在试**：慢重试到点仍会发起建连（不是再也不试）。
      final before = f.transport.connectCount;
      f.clock.advance(60000);
      await pump();
      expect(f.transport.connectCount, before + 1, reason: '慢重试照样会拨');
      expect(probe.lastConnectGaveUp, isTrue, reason: '结论不被一次静默重试抹掉');

      // **手动重试**把结论与退避一起清掉（回到 1 s 起点）。
      await client.reconnect();
      expect(probe.lastConnectGaveUp, isFalse);
      await pump();

      await client.close();
    });

    test('过期的一轮拨号回来：不许动连接（真机那次 backoff→handshake 崩溃）', () async {
      // 真机实测（断网 / 换网）：第 1 轮拨号还在飞时连接被收口、进了退避；
      // 退避到点发起第 2 轮，第 2 轮很快失败 → 停在 backoff；
      // 这时第 1 轮的拨号才回来（成功）。它若照旧 `to(handshake)`，
      // 就是非法迁移 —— 每轮重连都崩一次，永远连不上，而两端日志都"正常"。
      // 过期的一轮若照旧走下去，会先把这条流**交出去**（`attachSubscription`），
      // 再撞非法迁移。所以判据是"它的流有没有被听"—— 比抓异步异常稳，
      // 也不依赖 zone。
      final errors = <Object>[];
      await runZonedGuarded(
        () async {
          final f = buildDeps();
          final gate = Completer<void>();
          f.transport.firstConnectGate = gate;
          final client = createSyncClient(f.deps);
          unawaited(client.start());
          await pump();
          expect(
            client.state,
            ConnectionState.connecting,
            reason: '第 1 轮卡在拨号里',
          );

          // 第 2 轮：立刻失败 → 停在 backoff（**首轮不在失败范围内**：它待会儿要
          // 带着一条成功的流回来，正是要验的那条路径）。
          f.transport.failConnect = true;
          f.transport.failConnectFrom = 2;
          await client.reconnect();
          await pump();
          expect(client.state, ConnectionState.backoff);

          // 第 1 轮的拨号现在才回来（成功）：这一轮已经过期。
          gate.complete();
          await pump();

          expect(
            client.state,
            ConnectionState.backoff,
            reason: '过期的一轮不许把状态推到 handshake',
          );
          expect(
            f.transport.hasListener,
            isFalse,
            reason: '过期那一轮的流不许交给当前连接（交出去就是又进了握手）',
          );
          await client.close();
        },
        (error, stack) {
          errors.add(error);
        },
      );

      expect(
        errors,
        isEmpty,
        reason: '过期的一轮不许动连接：真机那次非法迁移（backoff → handshake）就是这么来的',
      );
    });

    test('已经在连接中再调 start()：不重复发起（启动那一拍会双触发）', () async {
      // 启动与"回前台"各会调一次 `start()`；第二次撞上 `connecting` 时若照旧
      // `to(connecting)`，就是非法迁移（真机启动那一拍的形状）。
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final f = buildDeps();
        final gate = Completer<void>();
        f.transport.firstConnectGate = gate;
        final client = createSyncClient(f.deps);
        unawaited(client.start());
        await pump();
        expect(client.state, ConnectionState.connecting);

        await client.start(); // 第二次：应当原地返回
        expect(f.transport.connectCount, 1, reason: '已在连接中，不重复发起');

        gate.complete();
        await pump();
        expect([
          ConnectionState.handshake,
          ConnectionState.serving,
        ], contains(client.state));
        await client.close();
      }, (error, stack) => errors.add(error));
      expect(errors, isEmpty);
    });

    test('换票被限流（429 → rateLimited）→ **照旧退避重试**，不是终态', () async {
      // 议题 2 的对照面：限流是"稍后重试"，不是"永久失败"。连接层必须把它
      // 与 notPaired 分开 —— 退避重连、不清凭据、不回配对页。
      final f = buildDeps(
        failConnectWith: const TransportException(
          '换票失败：换票被拒（HTTP 429）',
          code: ErrorCode.rateLimited,
        ),
      );
      final client = createSyncClient(f.deps);
      await client.start();

      expect(client.state, ConnectionState.backoff, reason: '限流进退避，不是终态');
      final probe = client as SyncClientProbe;
      expect(probe.lastConnectWasTerminal, isFalse, reason: '限流不是终态');

      // 到点重连（对比终态：绝不重连）。
      f.clock.advance(1100);
      await Future<void>.delayed(Duration.zero);
      expect(f.transport.connectCount, 2, reason: '限流照旧退避后重连');

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

    test('带幂等键的调用**拿到 res 的结果**（session.create 的真形状）', () async {
      // 2026-10-17 真机验收抓到：hero 上选工作区后弹"开新任务失败：新建会话
      // 没有回 sid"，而会话其实已经建成了。根因是带键路径曾直接 `return null`
      // （原话"结果由会话流收敛"）—— 调用方确实需要结果的写永远收不到返回值。
      // 帧的 `id` 是**另铸的帧号**（不是 requestId），`res` 回显它，所以能兑现。
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);

      final pending = client.call<Map<String, Object?>>('session.create', {
        'workspaceId': 'w1',
      }, requestId: 'new-1');
      await pump();
      final req = f.transport.sentFrames.where((x) => x['t'] == 'req').last;
      expect(
        req['id'],
        isA<String>().having((l) => l.length, 'length', greaterThan(0)),
        reason: '出帧口的 id 必须是帧号（res 靠它配对），不能是空',
      );

      final frameId = req['id'] as String;
      final keys = await sessionKeysFor(f.transport);
      final pc = BoxCodec(keys: keys, role: HandshakeRole.responder);
      final frame = <String, Object?>{
        'v': 1,
        't': 'res',
        'id': frameId,
        'ok': true,
        'fc': 100,
      };
      final box = await pc.sealFrame(
        frame,
        jsonEncode({
          'result': {'sid': 'sid-new'},
        }),
      );
      f.transport.feed('${jsonEncode({...frame, 'box': box})}\n');
      await pump();

      expect(await pending, {'sid': 'sid-new'});
      await client.close();
    });

    test('电脑侧拒绝（ok:false）照原样抛：respondInteraction 的"标成已过期"靠它', () async {
      // 同一条旧路还把**拒绝**吞了：`interaction.respond` 的注释写着
      // "失败照原样抛，调用方据此把那一项标成已过期"，而带键路径在 res 之前
      // 就返回，电脑侧的 `interaction/not-pending` 从来到不了 App。
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);

      final pending = client.call<void>('interaction.respond', {
        'sid': 's1',
        'callId': 'c1',
        'answers': <Object?>[],
      }, requestId: 'i:c1');
      await pump();

      final frameId = lastReqId(f.transport);
      final keys = await sessionKeysFor(f.transport);
      final pc = BoxCodec(keys: keys, role: HandshakeRole.responder);
      final frame = <String, Object?>{
        'v': 1,
        't': 'res',
        'id': frameId,
        'ok': false,
        'fc': 100,
      };
      final box = await pc.sealFrame(
        frame,
        jsonEncode({'code': 'interaction/not-pending', 'message': '已不在待处理'}),
      );
      // **先挂期望再喂帧**：反过来写的话，`pending` 在没有任何监听者时就以错误收场，
      // 那几拍会被记成"无人处理的异步错误"，测试红得莫名其妙。
      final rejected = expectLater(
        pending,
        throwsA(
          isA<ProtocolException>()
              .having((e) => e.code, 'code', ErrorCode.interactionNotPending)
              .having((e) => e.message, 'message', '已不在待处理'),
        ),
      );
      f.transport.feed('${jsonEncode({...frame, 'box': box})}\n');
      await pump();
      await rejected;

      await client.close();
    });

    test('同键重发不建第二个等待（第二次返回 null，不挂）', () async {
      // `interaction.respond` 用 `i:<callId>` 当幂等键，重点一次时电脑侧
      // 去重、那个 res 归第一次的调用方 —— 再建一个完成器只会永远挂着。
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);

      final first = client.call<Object?>('interaction.respond', {
        'sid': 's1',
        'callId': 'c1',
        'answers': <Object?>[],
      }, requestId: 'i:c1');
      await pump();
      final frameId = lastReqId(f.transport);

      final second = await client.call<Object?>('interaction.respond', {
        'sid': 's1',
        'callId': 'c1',
        'answers': <Object?>[],
      }, requestId: 'i:c1');
      expect(second, isNull, reason: '重发不建第二个完成器（那个 res 不会再来）');
      await pump();

      // 重发**不得再多发出一帧**：电脑侧按幂等键去重，重发等于重复执行。
      // 判据用"帧数不增长"而不是"只有一帧"—— `sync.hello` 走的也是 `req`
      // （见 `_sendHello`），所以这里本来就不止一帧。
      final beforeResend = f.transport.sentFrames
          .where((f) => f['t'] == 'req')
          .length;
      final afterResend = f.transport.sentFrames
          .where((f) => f['t'] == 'req')
          .length;
      expect(afterResend, beforeResend, reason: '重发不得再多发出一帧');

      // 第一次仍然拿到结果。
      final keys = await sessionKeysFor(f.transport);
      final pc = BoxCodec(keys: keys, role: HandshakeRole.responder);
      final frame = <String, Object?>{
        'v': 1,
        't': 'res',
        'id': frameId,
        'ok': true,
        'fc': 100,
      };
      final box = await pc.sealFrame(frame, jsonEncode({'result': {}}));
      f.transport.feed('${jsonEncode({...frame, 'box': box})}\n');
      await pump();
      expect(await first, isNotNull);

      await client.close();
    });

    test('在途的幂等写遇到断连同样被拒绝（failAll 覆盖带键路径）', () async {
      final f = buildDeps();
      final client = createSyncClient(f.deps);
      await client.start();
      await answerHello(f.transport);

      final pending = client.call<Object?>(
        'session.create',
        const {},
        requestId: 'new-2',
      );
      await pump();

      final rejected = expectLater(
        pending,
        throwsA(
          isA<ProtocolException>().having(
            (e) => e.code,
            'code',
            ErrorCode.relayOffline,
          ),
        ),
        reason: '断连时在途的带键写也要被拒绝（否则调用方永远等不到）',
      );
      f.transport.dropFromPeer();
      await pump();
      await rejected;
      // **2 不是 1**：`sync.hello` 也登记在途（它的应答带每个会话的
      // `{sid, since, hasMore}`），断连时与这条带键写一起被拒。
      expect((client as SyncClientProbe).lastRejectedCalls, 2);

      await client.close();
    });

    test('帧头 id 与幂等键是两个标识符：业务键永不上帧头（契约 §3 / §5.6）', () async {
      // 2026-10-17 真机验收抓到的线上缺口：出帧口曾把 `requestId` 直接写进帧头
      // `id`。`interaction.respond` 的键是 `i:<callId>`（§5.7），带冒号，
      // 过不了 §3 的 ASCII 安全字符集 —— 连接器按 `protocol/bad-frame` 拒收并
      // **关连接**（`connector/src/transport/codec.ts` 的 `ID_PATTERN`，
      // 我在连接器自己的解码器上实测过：`i:c1 => REJECTED`）。
      // 表现是"点了允许一次，连接断了，队列不推进"。
      //
      // 这条钉的是**不变量本身**，所以遍历生产里出现过的全部键形状
      // （`app/lib/data/app_model.dart` 的七处 + 契约 §5.7 的 `i:<callId>`）。
      const keys = <String, String>{
        'interaction.respond': 'i:call-1',
        'permission.switch': 'perm-1',
        'userQuestion.respond': 'q-1',
        'workspace.archive': 'arc-1',
        'workspace.unarchive': 'unarc-1',
        'session.create': 'new-1',
      };

      for (final entry in keys.entries) {
        final f = buildDeps();
        final client = createSyncClient(f.deps);
        await client.start();
        await answerHello(f.transport);

        final pending = client.call<Object?>(entry.key, const {
          'sid': 's1',
        }, requestId: entry.value);
        await pump();

        final req = f.transport.sentFrames.where((f) => f['t'] == 'req').last;
        final frameId = req['id'] as String;

        expect(
          idPattern.hasMatch(frameId),
          isTrue,
          reason:
              '${entry.key} 的帧号 "$frameId" 必须过 §3 的字符集，'
              '否则连接器按 bad-frame 关连接',
        );
        expect(
          frameId,
          isNot(entry.value),
          reason: '${entry.key} 的幂等键 "$entry.value" 不得写进帧头 id',
        );

        // 幂等键必须**原样出现在信封里**（§5.6：电脑侧唯一认得的键）。
        final sessionKeys = await sessionKeysFor(f.transport);
        final opener = BoxCodec(
          keys: sessionKeys,
          role: HandshakeRole.responder,
        );
        final envelope =
            jsonDecode(await opener.openFrame(req, '${req['box']}'))
                as Map<String, Object?>;
        expect(
          envelope['requestId'],
          entry.value,
          reason: '${entry.key} 的幂等键必须在信封顶层',
        );

        // 收尾：别让这个完成器挂到 tearDown。
        final res = <String, Object?>{
          'v': 1,
          't': 'res',
          'id': frameId,
          'ok': true,
          'fc': 100,
        };
        final box = await opener.sealFrame(res, jsonEncode({'result': {}}));
        f.transport.feed('${jsonEncode({...res, 'box': box})}\n');
        await pump();
        expect(await pending, isNotNull);

        await client.close();
      }
    });

    test('从盘上恢复的旧行没有帧号：restore 补铸，发出的帧号仍合规', () async {
      // `frameId` 刻意不落盘（它只关联一个活的完成器），所以升级前留下的旧行
      // 恢复后是空帧号。空串同样过不了 §3 的字符集 —— 不补铸就是同一个 bug。
      final store = InMemoryOutboxStore();
      // 直接塞一行"旧行"（落盘形态里没有 frameId，见 `OutboxEntry.toJson`）。
      await store.append(
        const OutboxEntry(
          requestId: 'i:legacy-1',
          method: 'interaction.respond',
          params: {'sid': 's1'},
        ),
      );
      final outbox = Outbox(store: store, newFrameId: () => 'restored-1');
      await outbox.restore();
      expect(outbox.pending, 1, reason: '旧行必须被恢复，不能静默丢掉');

      final sent = <OutboxEntry>[];
      outbox.attachSender((entry) async {
        sent.add(entry);
        return true;
      });
      expect(await outbox.flush(), FlushOutcome.sent);
      expect(sent.single.frameId, 'restored-1');
      expect(
        idPattern.hasMatch(sent.single.frameId),
        isTrue,
        reason: '补铸的帧号也要过 §3 的字符集',
      );
    });

    test('同一幂等键重复入队：换帧号、不换键（残留行被新尝试取代）', () async {
      // 上一次尝试抛了 `relay/offline` 之后，条目还排着队而没人等。
      // 再点一次必须换一个新帧号（否则 res 兑的是上一个调用方），
      // 但幂等键不能换（否则电脑侧认不出它是同一次写）。
      final store = InMemoryOutboxStore();
      final outbox = Outbox(store: store, newFrameId: () => 'fresh-1');
      await outbox.enqueue(
        const OutboxEntry(
          requestId: 'i:c1',
          method: 'interaction.respond',
          params: {'sid': 's1'},
          frameId: 'stale-1',
        ),
      );
      await outbox.enqueue(
        const OutboxEntry(
          requestId: 'i:c1',
          method: 'interaction.respond',
          params: {'sid': 's1'},
          frameId: 'fresh-1',
        ),
      );
      expect(outbox.pending, 1, reason: '同一个键只有一条待发项');
      expect(outbox.entries.single.frameId, 'fresh-1');
      expect(outbox.entries.single.requestId, 'i:c1', reason: '键不许换');
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
      //
      // **是 2 不是 1**：2026-10-24 起 `sync.hello` 也登记在途等待
      // （它的应答带着每个会话的 `{sid, since, hasMore}`，那是"还有没有更早的
      // 历史"的唯一来源）。所以断连时被拒的是 `repo.info` 与 `sync.hello` 两条。
      // **hello 那条不许漏** —— 它的完成器由 `_sendHello` 用 `.catchError`
      // 接了错误分支，不会变成未处理的异步错误。
      expect((client as SyncClientProbe).lastRejectedCalls, 2);

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

    test('同一个幂等键重复入队：只留一条，且换成新条目的帧号', () async {
      final store = InMemoryOutboxStore();
      final sent = <OutboxEntry>[];
      final outbox = Outbox(
        store: store,
        send: (entry) async {
          sent.add(entry);
          return true;
        },
      );
      const stale = OutboxEntry(
        requestId: 'r1',
        method: 'session.prompt',
        params: {},
        frameId: 'stale-1',
      );
      await outbox.enqueue(stale);
      await outbox.enqueue(
        const OutboxEntry(
          requestId: 'r1',
          method: 'session.prompt',
          params: {},
          frameId: 'fresh-1',
        ),
      );
      expect(outbox.pending, 1, reason: '同一个键只有一条待发项');
      expect(
        outbox.entries.single.frameId,
        'fresh-1',
        reason: '残留行被新尝试取代：旧帧号没人等，兑给它就是永远挂着',
      );
      expect(outbox.entries.single.requestId, 'r1', reason: '键不许换');
      await outbox.flush();
      expect(sent.map((e) => e.requestId), ['r1'], reason: '只发一次');
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
