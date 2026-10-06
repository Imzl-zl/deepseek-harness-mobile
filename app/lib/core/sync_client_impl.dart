/// `SyncClient` 的实现：连接、订阅、恢复、流控的唯一 owner。
///
/// 判据全部在别处（见 `sync_client.dart` 的表格），本文件只做**接线**。
/// 唯一的例外是**帧的分派**（哪个帧类型归谁）—— 那是这一层独有的知识，
/// 因为它知道"这一帧该交给握手、订阅、还是应答等待表"。
///
/// ## 出帧只有两个口
///
/// - [sendFrame]：业务帧。**只有 `serving` 时可用**（`fc` 由这里分配，与封箱紧挨着）。
/// - [sendPreKeysFrame]：握手帧与配对帧。它们在 `serving` **之前**就要出去。
///
/// 分开是刻意的：把两者合成一个口，等于给"握手期发业务帧"开口子（契约 §3）。
///
/// ## `fc` 的分配权在这里
///
/// `fc` 是每连接的帧计数器、也是 nonce 来源（§4.2）。让上层决定它等于给上层机会
/// 重用 nonce，而重用 nonce 直接破 AEAD。所以待发帧类型里**没有** `fc`，
/// 由 [sendFrame] 统一盖上，并且**分配与封箱紧挨着**（`box.dart` 另设一道绊线）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'box.dart';
import 'connection.dart';
import 'crypto.dart';
import 'errors.dart';
import 'flow.dart';
import 'frame.dart';
import 'handshake_driver.dart';
import 'items.dart';
import 'keepalive.dart';
import 'outbox.dart';
import 'sync_client.dart';
import 'transport.dart';

/// 建一个 `SyncClient`。
///
/// 它**不自己起定时器**：所有周期任务走 [SyncClientDeps.schedule]，
/// 于是测试能用假定时器在毫秒内跑完"退避 30 s"这类场景。
SyncClient createSyncClient(SyncClientDeps deps) => _SyncClient(deps);

class _SyncClient implements SyncClient, SyncClientProbe {
  _SyncClient(this._deps)
    : _machine = ConnectionMachine(),
      _backoff = _deps.backoff ?? Backoff(),
      _keepalive =
          _deps.keepalive ??
          Keepalive(heartbeat: _deps.keepalive?.halfOpenAfterMs) {
    _stateController = StreamController<ConnectionState>.broadcast(
      onListen: () => _stateController.add(_machine.state),
    );
    _machine.onChange((from, to) {
      _deps.session; // 状态变化不直接动会话，订阅面自己按 sid 处理。
      if (!_stateController.isClosed) _stateController.add(to);
      _onStateChanged(from, to);
    });
  }

  final SyncClientDeps _deps;
  final ConnectionMachine _machine;
  final Backoff _backoff;
  final Keepalive _keepalive;

  late final StreamController<ConnectionState> _stateController;

  /// 每会话的更新流（广播：UI 多个部件要听同一会话）。
  final Map<String, StreamController<SessionDelta>> _sessionControllers = {};

  /// 在途请求（`req.id` → 完成器）。应答到达时按 `id` 兑现。
  final Map<String, Completer<Object?>> _pendingCalls = {};

  /// 每连接的箱密码器。**每次建连换一把密钥**，所以建连时必须清空（§4.2）。
  BoxCodec? _box;

  /// 每连接的握手会话。
  HandshakeSession? _handshake;

  /// 每连接的传输事件订阅。
  StreamSubscription<TransportEvent>? _subscription;

  /// 每连接的发送计数器与流控窗口（`fc` 从 0 重数）。
  SendCounter _counter = SendCounter();
  SendWindow _window = SendWindow();

  /// 每连接的行分帧器。
  LineSplitter _splitter = LineSplitter();

  /// 退避计时器的取消函数。
  void Function()? _cancelBackoff;

  /// 心跳判定周期任务的取消函数。
  void Function()? _cancelTick;

  AppState _appState = AppState.foreground;
  bool _closed = false;

  int _now() => _deps.now?.call() ?? DateTime.now().millisecondsSinceEpoch;

  /// 定时器注入点。默认用真 `Timer`（`Timer.cancel` 就是那个"取消函数"）。
  void Function() Function(void Function() fn, int ms) get _schedule =>
      _deps.schedule ??
      ((fn, ms) {
        final timer = Timer(Duration(milliseconds: ms), fn);
        return timer.cancel;
      });

  String _newId() =>
      _deps.newId?.call() ?? newFrameId(_randomBytes(frameIdBytes));

  /// 系统随机字节。
  ///
  /// 用 `Random.secure()`（系统调用）—— 帧 `id` 与 `requestId` 都是 bearer 凭据级别的随机，
  /// 不能用可预测的伪随机。
  Uint8List _randomBytes(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i += 1) {
      out[i] = _secure.nextInt(256);
    }
    return out;
  }

  static final _secure = _SecureSource();

  @override
  ConnectionState get state => _machine.state;

  @override
  Stream<ConnectionState> get connection => _stateController.stream;

  @override
  Stream<SessionDelta> sessionUpdates(String sid) {
    final controller = _sessionControllers.putIfAbsent(
      sid,
      () => StreamController<SessionDelta>.broadcast(),
    );
    return controller.stream;
  }

  // -------------------------------------------------------------------------
  // 连接生命周期
  // -------------------------------------------------------------------------

  /// 建立连接并走握手。**幂等**：已在连接中或已服务时不重复建。
  @override
  Future<void> start() async {
    if (_closed) return;
    if (_machine.isAnyOf([
      ConnectionState.serving,
      ConnectionState.handshake,
    ])) {
      return;
    }
    await _connect();
  }

  Future<void> _connect() async {
    if (_closed) return;
    _machine.to(ConnectionState.connecting);
    // 每次建连都换分帧器、计数器、窗口与密码器 —— 新连接新密钥，`fc` 从 0 重数（§4.2）。
    _splitter = LineSplitter();
    _counter = SendCounter();
    _window = SendWindow();
    _box = null;
    _handshake = null;

    final Stream<TransportEvent> events;
    try {
      events = await _deps.transport.connect();
    } catch (error) {
      // 建连失败：关掉（如果还开着）并进退避。
      _enterClosed();
      return;
    }

    _subscription = events.listen(
      _onTransportEvent,
      onError: (Object error) => _enterClosed(),
      cancelOnError: false,
    );

    // WSS 建好了 → 进握手态，并把握手驱动装上（**它会立刻发出 hello**）。
    _machine.to(ConnectionState.handshake);
    _handshake = _deps.handshake(
      HandshakeContext(
        send: _sendPreKeysFrame,
        established: _onEstablished,
        failed: (reason, error) {
          _failHandshake(reason, error);
        },
        schedule: _schedule,
      ),
    );
    _startTicking();
  }

  void _onEstablished(HandshakeEstablishment result) {
    if (_closed) return;
    // **先装密码器再进 serving**：顺序反了就会有一小段"已在服务但发不出帧"的窗口，
    // 而那一小段里的每一帧都会被丢掉（宁丢不发明文）。
    _box = _deps.box(result.keys);
    // 握手成功要重置退避：否则下次掉线会从上次积累的大间隔开始等。
    _backoff.reset();
    _machine.to(ConnectionState.serving);
    // 连上了就把待发队列按序补发（§5.6：先落盘、连接可用时再发）。
    unawaited(_deps.outbox.flush());
  }

  void _failHandshake(ErrorCode reason, Object? error) {
    // 握手失败不计入业务重试次数（§4.1）：关掉连接，剩下的交给退避。
    _closeTransport();
    _enterClosed();
  }

  void _onTransportEvent(TransportEvent event) {
    switch (event) {
      case TransportMessage(:final chunk):
        // **拼行在这里做，不在传输层**：分隔符规则只有一个 owner（编解码层）。
        final List<String> lines;
        try {
          lines = _splitter(chunk);
        } on ProtocolException catch (error) {
          _protocolFailure(error);
          return;
        }
        for (final line in lines) {
          _onLine(line);
        }
      case TransportClosed():
        _enterClosed();
    }
  }

  void _onLine(String line) {
    // 任何一帧都算「有动静」：收与发都重置空闲计时（§2.2 的半开判据是"任一方向"）。
    _keepalive.onFrame(_now());

    final DecodeResult decoded;
    try {
      decoded = decodeFrame(line);
    } on ProtocolException catch (error) {
      _protocolFailure(error);
      return;
    }

    switch (decoded) {
      case IgnoredFrame():
        // 未知类型且无 `id`：向前兼容，忽略。
        return;
      case UnsupportedFrame(:final id):
        // 未知类型但带 `id`：**必须回错** —— 沉默会让对端永远挂着（§3）。
        _sendFrame({
          'v': wireVersion,
          't': 'res',
          'id': id,
          'ok': false,
          'box': '{"code":"protocol/unsupported-version"}',
        });
        return;
      case DecodedFrame(:final frame):
        _dispatch(frame);
    }
  }

  void _dispatch(Map<String, Object?> frame) {
    final type = frame['t'];
    if (type is! String) return;

    // 握手帧：交给驱动器（握手完成后不该再来，来了就是重放/重复投递）。
    if (isHandshakeFrameType(type)) {
      if (_machine.isAnyOf([ConnectionState.handshake])) {
        _handshake?.onFrame(frame);
      }
      return;
    }

    // 配对帧：发生在密钥建立**之前**，走明文路径（这一层只把它交出去）。
    if (isPairingFrameType(type)) {
      _pairingFrames.add(frame);
      return;
    }

    // 业务帧：未握手就收到 = 攻击面（§2.2），一律拒并关连接。
    if (!_machine.acceptsBusinessFrames) {
      _protocolFailure(
        ProtocolException(ErrorCode.badFrame, '握手未完成时收到 $type 帧'),
      );
      return;
    }

    // `presence` 是唯一的握手后明文帧（由中继合成，它必须能原样转发）。
    if (!needsBox(type)) {
      _handlePlaintext(frame);
      return;
    }

    final box = frame['box'];
    if (box is! String) {
      _protocolFailure(ProtocolException(ErrorCode.badFrame, '$type 帧缺少 box'));
      return;
    }
    final codec = _box;
    if (codec == null) {
      _protocolFailure(
        const ProtocolException(ErrorCode.internal, '还没有会话密钥就收到了业务帧'),
      );
      return;
    }

    // 解箱是异步的，而收帧路径不能阻塞（同一条 socket 上还有 credit 与保活）。
    // `unawaited` 是**刻意的**：失败走 `_protocolFailure`（关连接），不抛给调用方。
    unawaited(
      codec
          .openFrame(frame, box)
          .then((plaintext) => _handleOpened(frame, plaintext))
          .catchError((Object error) {
            _protocolFailure(
              error is ProtocolException
                  ? error
                  : ProtocolException(ErrorCode.badFrame, '解箱失败：$error'),
            );
          }),
    );
  }

  void _handleOpened(Map<String, Object?> frame, String plaintext) {
    final type = frame['t'];
    // 流控记账在**解箱之后**：`credit` 的 ack 必须先被认证，
    // 否则一帧伪造的 credit 就能替对端松开窗口（§4.3）。
    _accountFlow(frame);

    switch (type) {
      case 'res':
        _resolveCall(frame, plaintext);
      case 'ev':
        _onEvent(frame, plaintext);
      case 'live':
        _onLive(frame, plaintext);
      case 'job':
        _jobFrames.add((frame, plaintext));
      case 'credit':
      case 'ping':
      case 'pong':
      case 'persisted':
        // 保活与流控记账已在上面的 `_accountFlow` 处理。
        return;
      default:
        // **不静默丢弃**：手机端会看到"发出去但没回应"，而电脑侧一片安静 ——
        // 那是最难查的一类故障。
        _protocolFailure(ProtocolException(ErrorCode.badFrame, '不该收到 $type 帧'));
    }
  }

  void _handlePlaintext(Map<String, Object?> frame) {
    if (frame['t'] == 'presence') {
      _presenceFrames.add(frame);
    }
  }

  /// 流控记账（§4.3）。
  ///
  /// 两个 `if` 刻意**不写成 if/else、也不提前 return**：`credit` 走记账、其余帧走回执，
  /// 而"`credit` 不回 `credit`"这条规则**只由 [elicitsCredit] 表达一次**。
  void _accountFlow(Map<String, Object?> frame) {
    final fc = frame['fc'];
    if (fc is! int) return;

    if (frame['t'] == 'credit') {
      final box = frame['box'];
      final ack = decodeCredit(box is String ? box : '');
      final before = _window.unacked;
      _window.onCredit(ack);
      if (_window.unacked < before) {
        // 窗口刚松开：被压住的可补帧可以继续发了（这里只唤醒等待者）。
        _notifyWritable();
      }
    }

    // 收到的每一帧都立刻回 credit。`credit` 自己除外 —— 否则两端互刷 ack 停不下来。
    if (elicitsCredit('${frame['t']}')) {
      _sendFrame({'v': wireVersion, 't': 'credit', 'box': encodeCredit(fc)});
    }
  }

  final List<void Function()> _writableWaiters = [];

  void _notifyWritable() {
    final waiters = List.of(_writableWaiters);
    _writableWaiters.clear();
    for (final resolve in waiters) {
      resolve();
    }
  }

  // -------------------------------------------------------------------------
  // 出帧
  // -------------------------------------------------------------------------

  /// 发一帧业务帧。**只有 `serving` 时可用**（`fc` 在这里分配，与封箱紧挨着）。
  bool _sendFrame(Map<String, Object?> frame) {
    if (!_machine.acceptsBusinessFrames) return false;
    final type = '${frame['t']}';
    // 满窗时对可补帧如实回 `false`：这一帧**没有被接受**，调用方据此暂停（§4.3）。
    if (!_window.canSend(type)) return false;

    final codec = _box;
    // `fc` 的分配与封箱必须紧挨着（见文件头）。分配前先看窗口 —— 没发出去的帧
    // 不该消耗序号，否则窗口算术会把没上线的帧也算进去。
    final fc = _counter.next();
    final wire = <String, Object?>{...frame, 'fc': fc};
    _window.onSent(fc, type);

    if (codec == null) {
      // 配了 secure 却拿不出密码器：只可能是"握手已过但密码器没装上"这类装配错误。
      // 宁可不发，也不明文上线。
      return false;
    }

    unawaited(
      codec
          .sealFrame(wire, '${frame['box'] ?? ''}')
          .then((box) {
            _write(<String, Object?>{...wire, 'box': box});
          })
          .catchError((Object error) {
            // 封箱失败（比如 nonce 绊线）：这一帧不发，并吵一声。
            _protocolFailure(
              error is ProtocolException
                  ? error
                  : ProtocolException(ErrorCode.internal, '封箱失败：$error'),
            );
          }),
    );
    return true;
  }

  /// 发握手帧或配对帧（**不盖 `fc`**：它们的线上形状里没有这个字段，§3）。
  void _sendPreKeysFrame(Map<String, Object?> frame) {
    _write(frame);
  }

  void _write(Map<String, Object?> frame) {
    final line = encodeFrame(frame);
    // 发出去也算「有动静」——**除了 `ping`**：它是探针本身，若它重置计时，
    // 空闲期就永远攒不满两个周期，半开再也判不出来（§2.2）。
    if (frame['t'] != 'ping') _keepalive.onFrame(_now());
    _deps.transport.send(line);
  }

  // -------------------------------------------------------------------------
  // 会话层：事件、恢复、应答
  // -------------------------------------------------------------------------

  void _onEvent(Map<String, Object?> frame, String plaintext) {
    final sid = frame['sid'];
    final seq = frame['seq'];
    if (sid is! String || seq is! int) {
      _protocolFailure(
        const ProtocolException(ErrorCode.badFrame, 'ev 帧缺少 sid/seq'),
      );
      return;
    }
    // 解出的载荷就是一条事件（`itemId` 由事件自身推导，§5.2）。
    final item = _itemFromPayload(plaintext, seq);
    _deps.session.receive(sid, item.itemId, item.text, seq);
    _emit(
      sid,
      SessionDelta(
        sid: sid,
        items: [item],
        transient: _deps.session.transientOf(sid),
      ),
    );
    // **落盘后才发 `persisted`**（§5.3）：水位永不超过落盘内容。
    _sendPersisted(sid, seq);
  }

  void _onLive(Map<String, Object?> frame, String plaintext) {
    final sid = frame['sid'];
    final stream = frame['stream'];
    final rev = frame['rev'];
    if (sid is! String || stream is! int || rev is! int) {
      _protocolFailure(
        const ProtocolException(ErrorCode.badFrame, 'live 帧缺少 sid/stream/rev'),
      );
      return;
    }
    _liveAccumulate(sid, stream, rev, plaintext);
  }

  /// 每会话一个 `LiveAccumulator`（`app-channel-client.md` §2.2）。
  final Map<String, LiveAccumulator> _live = {};

  void _liveAccumulate(String sid, int stream, int rev, String plaintext) {
    final acc = _live.putIfAbsent(sid, LiveAccumulator.new);
    final changed = acc.accept(stream: stream, rev: rev, payload: plaintext);
    // 跳号时 `changed` 为 false：**丢弃该流已累积内容并停止渲染**，
    // 等持久 `assistant/message` 到达（自愈，不请求重传）。
    if (!changed) return;
    _emit(
      sid,
      SessionDelta(
        sid: sid,
        items: const [],
        transient: _deps.session.transientOf(sid),
      ),
    );
  }

  void _sendPersisted(String sid, int seq) {
    // 落盘之后才发（`DeviceSession.commit` 是"渲染/落盘完成"的信号）。
    _deps.session.commit(sid, seq);
    _sendFrame({
      'v': wireVersion,
      't': 'persisted',
      'sid': sid,
      'seq': seq,
      'box': '',
    });
  }

  void _resolveCall(Map<String, Object?> frame, String plaintext) {
    final id = frame['id'];
    if (id is! String) return;
    final completer = _pendingCalls.remove(id);
    if (completer == null) return; // 迟到或重复的应答：忽略。

    final ok = frame['ok'];
    if (ok != true) {
      // 失败也是**正常应答**，不是断连理由（§9）。错误码来自封闭表。
      final code = _errorCodeOf(plaintext);
      completer.completeError(
        ProtocolException(code, _errorMessageOf(plaintext)),
      );
      return;
    }
    completer.complete(_resultOf(plaintext));
  }

  ErrorCode _errorCodeOf(String plaintext) {
    try {
      final parsed = _decodeObject(plaintext);
      final code = parsed['code'];
      return code is String ? ErrorCode.fromWire(code) : ErrorCode.internal;
    } catch (_) {
      return ErrorCode.internal;
    }
  }

  String _errorMessageOf(String plaintext) {
    try {
      final parsed = _decodeObject(plaintext);
      final message = parsed['message'];
      return message is String ? message : '';
    } catch (_) {
      return '';
    }
  }

  Object? _resultOf(String plaintext) {
    try {
      return _decodeObject(plaintext)['result'];
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> _decodeObject(String text) {
    final parsed = _jsonDecode(text);
    if (parsed is! Map) {
      throw const ProtocolException(ErrorCode.badFrame, '载荷必须是 JSON 对象');
    }
    return Map<String, Object?>.from(parsed);
  }

  // -------------------------------------------------------------------------
  // 对外 API
  // -------------------------------------------------------------------------

  @override
  Future<void> subscribe(String sid, {required int since}) async {
    // 订阅是一次**写操作**（电脑侧要为它建立 follow），所以走 outbox：先落盘再发。
    final requestId = _newId();
    await _deps.outbox.enqueue(
      OutboxEntry(
        requestId: requestId,
        method: 'session.subscribe',
        params: {'sid': sid, 'since': since},
        sid: sid,
      ),
    );
    await _deps.outbox.flush();
  }

  @override
  Future<void> unsubscribe(String sid) async {
    final requestId = _newId();
    await _deps.outbox.enqueue(
      OutboxEntry(
        requestId: requestId,
        method: 'session.unsubscribe',
        params: {'sid': sid},
        sid: sid,
      ),
    );
    await _deps.outbox.flush();
  }

  @override
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  }) async {
    // 带幂等键的调用**先落盘再发送**（§5.6）：崩溃窗口里那次写操作不能消失。
    if (requestId != null) {
      await _deps.outbox.enqueue(
        OutboxEntry(requestId: requestId, method: method, params: params),
      );
      final outcome = await _deps.outbox.flush();
      if (outcome == FlushOutcome.offline) {
        // 离线：已落盘，等连接回来补发。这里如实抛，**不假装成功**。
        throw const ProtocolException(
          ErrorCode.relayOffline,
          '离线：写操作已入队，待连接恢复后补发',
        );
      }
      // 队列发出去了，但结果要等 `res`。这里不重复发请求（队列已经发过），
      // 所以不建在途等待 —— 带键的写操作靠电脑侧去重，结果由会话流收敛。
      return null as T;
    }

    if (!_machine.acceptsBusinessFrames) {
      throw const ProtocolException(ErrorCode.relayOffline, '连接不在服务态');
    }
    final id = _newId();
    final completer = Completer<Object?>();
    _pendingCalls[id] = completer;
    final sent = _sendFrame({
      'v': wireVersion,
      't': 'req',
      'id': id,
      'box': encodeRequestEnvelope(method, params),
    });
    if (!sent) {
      _pendingCalls.remove(id);
      throw const ProtocolException(ErrorCode.relayOffline, '发送失败：连接不可用或窗口满');
    }
    return await completer.future as T;
  }

  @override
  Future<void> setAppState(AppState next) async {
    _appState = next;
    _keepalive.setForeground(next == AppState.foreground);
    if (next == AppState.background) {
      // 切后台主动断开并停表（§2.2）：三端都不做后台长连接（§13）。
      await _disconnect();
    } else if (_machine.isAnyOf([
      ConnectionState.idle,
      ConnectionState.closed,
    ])) {
      await start();
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _cancelBackoff?.call();
    _cancelBackoff = null;
    _cancelTick?.call();
    _cancelTick = null;
    _handshake?.dispose();
    _handshake = null;
    await _subscription?.cancel();
    _subscription = null;
    await _deps.transport.close();
    for (final controller in _sessionControllers.values) {
      await controller.close();
    }
    _sessionControllers.clear();
    for (final completer in _pendingCalls.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const ProtocolException(ErrorCode.internal, '客户端已关闭'),
        );
      }
    }
    _pendingCalls.clear();
    await _stateController.close();
  }

  // -------------------------------------------------------------------------
  // 状态与定时器
  // -------------------------------------------------------------------------

  void _onStateChanged(ConnectionState from, ConnectionState to) {
    if (from == ConnectionState.serving && to != ConnectionState.serving) {
      // 离开服务态：唤醒所有等在"窗口有空位"上的发送方（否则它们永远挂着）。
      _notifyWritable();
    }
    if (to == ConnectionState.closed && !_closed) {
      // 连接结束 → 进退避 → 到点且前台才重连（§2.2：只在 App 前台重连）。
      _machine.to(ConnectionState.backoff);
      final delay = _backoff.next();
      _cancelBackoff = _schedule(() {
        _cancelBackoff = null;
        if (_closed) return;
        if (_appState != AppState.foreground) {
          _machine.to(ConnectionState.idle);
          return;
        }
        unawaited(_connect());
      }, delay);
    }
  }

  void _startTicking() {
    _cancelTick?.call();
    // 判定周期取心跳的 1/4：够密，又不必为每次判定设一个精确到毫秒的闹钟。
    final period = (_keepalive.halfOpenAfterMs ~/ (halfOpenPeriods * 4)).clamp(
      10,
      1 << 30,
    );
    void run() {
      if (_closed) return;
      final action = _keepalive.tick(_now());
      switch (action) {
        case KeepalivePing():
          _write({'v': wireVersion, 't': 'ping', 'box': ''});
        case KeepaliveHalfOpen(:final silentMs):
          // 半开：TCP 不会报错，只能自己判。关掉 socket，剩下的交给收口统一处理。
          // `silentMs` 带进诊断面 —— 它是"判了多久才认定"的唯一证据。
          _lastHalfOpenSilentMs = silentMs;
          _closeTransport();
          _enterClosed();
        case KeepaliveIdle():
          break;
      }
      // **只在自己还该活着时续期**：`_enterClosed()` 已经取消了 tick 并可能已进退避，
      // 这里若无条件重排，定时器就会在 backoff 期间继续跑 —— 它会在 `_connect()` 的
      // `await` 中途再调一次 `_enterClosed()`，把状态从 `connecting` 推到 `closed`，
      // 于是 `await` 回来后的 `to(handshake)` 变成非法迁移（实测就是这么红的）。
      if (_closed || _cancelTick == null) return;
      _cancelTick = _schedule(run, period);
    }

    _cancelTick = _schedule(run, period);
  }

  void _closeTransport() {
    unawaited(_deps.transport.close());
  }

  void _enterClosed() {
    _handshake?.dispose();
    _handshake = null;
    // 密钥属于这条连接：断开即作废，避免下一条连接误用上一把（§4.2）。
    _box = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _cancelTick?.call();
    _cancelTick = null;
    if (_machine.isAnyOf([
      ConnectionState.connecting,
      ConnectionState.handshake,
      ConnectionState.serving,
    ])) {
      _machine.to(ConnectionState.closed);
    }
  }

  Future<void> _disconnect() async {
    _cancelBackoff?.call();
    _cancelBackoff = null;
    _closeTransport();
    _enterClosed();
    if (_machine.isAnyOf([ConnectionState.closed, ConnectionState.backoff])) {
      _machine.to(ConnectionState.idle);
    }
  }

  /// 协议级失败：**关连接**（结构化错误不关连接，那是 `res` 的事，§9）。
  void _protocolFailure(ProtocolException error) {
    _lastProtocolError = error;
    _closeTransport();
    _enterClosed();
  }

  /// 最后一次协议错误（诊断用）。
  ProtocolException? _lastProtocolError;

  /// 判定为半开时已沉默多久（诊断用）。
  int? _lastHalfOpenSilentMs;

  /// 诊断面（测试与日志用）。
  @override
  ProtocolException? get lastProtocolError => _lastProtocolError;

  /// 判定为半开时已沉默多久；没判过是 `null`。
  @override
  int? get lastHalfOpenSilentMs => _lastHalfOpenSilentMs;

  // -------------------------------------------------------------------------
  // 供测试观察的帧收集（生产里 UI 不读这些）
  // -------------------------------------------------------------------------

  final List<Map<String, Object?>> _pairingFrames = [];
  final List<(Map<String, Object?>, String)> _jobFrames = [];
  final List<Map<String, Object?>> _presenceFrames = [];

  /// 收到的配对帧（UI 的配对页读它）。
  @override
  List<Map<String, Object?>> get pairingFrames =>
      List.unmodifiable(_pairingFrames);

  /// 收到的任务输出帧（`(帧头, 明文)`；任务面板读它）。
  @override
  List<(Map<String, Object?>, String)> get jobFrames =>
      List.unmodifiable(_jobFrames);

  /// 收到的 `presence` 帧（设备与连接状态读它）。
  @override
  List<Map<String, Object?>> get presenceFrames =>
      List.unmodifiable(_presenceFrames);

  void _emit(String sid, SessionDelta delta) {
    final controller = _sessionControllers[sid];
    if (controller != null && !controller.isClosed) controller.add(delta);
  }
}

/// 从 `ev` 的解箱载荷取一条条目（`itemId` 由事件自身推导，§5.2）。
ItemRecord _itemFromPayload(String plaintext, int seq) {
  final parsed = _jsonDecode(plaintext);
  if (parsed is! Map) {
    throw const ProtocolException(ErrorCode.badFrame, 'ev 载荷必须是 JSON 对象');
  }
  final data = Map<String, Object?>.from(parsed);
  // 电脑侧封的是 `{itemId, text}`（见 `recovery.dart` 的 `record`）。
  final itemId = data['itemId'];
  final text = data['text'];
  if (itemId is! String || itemId.isEmpty) {
    throw const ProtocolException(ErrorCode.badFrame, 'ev 载荷缺少 itemId');
  }
  return ItemRecord(itemId: itemId, text: text is String ? text : '', seq: seq);
}

Object? _jsonDecode(String text) {
  try {
    return jsonDecode(text);
  } catch (error) {
    throw ProtocolException(ErrorCode.badFrame, '载荷不是合法 JSON：$error');
  }
}

/// `sync_client` 的 `call` 用的请求信封编码（`method` / `params` / `requestId` 顶层）。
String encodeRequestEnvelope(String method, Map<String, Object?> params) =>
    jsonEncode({'method': method, 'params': params});

/// 系统安全随机源。
class _SecureSource {
  final _random = Random.secure();

  int nextInt(int max) => _random.nextInt(max);
}

/// 每会话的流式累加器（`app-channel-client.md` §2.2）。
///
/// 读法（**顺序即语义**）：
/// - `stream` 变大 ⇒ 换流（上一次尝试结束），重置累加器；
/// - `rev == last + 1` ⇒ 追加；
/// - `rev` 跳跃 ⇒ **丢弃该流已累积内容并停止渲染**，等持久 `assistant/message` 到达
///   （自愈，**不请求重传**）。
///
/// 它**不碰任务输出**（`job` 帧）：任务输出的"修订号"是字节偏移、会跳号，
/// 而这个累加器把跳号读成"丢流" —— 两者不能共用一个累加器（契约 §3 的术语表）。
class LiveAccumulator {
  int? _stream;
  int? _lastRev;
  final StringBuffer _text = StringBuffer();

  /// 当前累积的文本（跳号后为空 —— 那是"停止渲染"的意思）。
  String get text => _text.toString();

  /// 当前流 id。
  int? get stream => _stream;

  /// 最近一次修订号。
  int? get lastRev => _lastRev;

  /// 收一帧 `live`。
  ///
  /// @returns 内容是否变化（`false` = 跳号，调用方**不该**重绘）。
  bool accept({
    required int stream,
    required int rev,
    required String payload,
  }) {
    if (_stream != stream) {
      // 换流：上一次尝试结束了。重置累加器（旧内容由持久事件负责替换）。
      _stream = stream;
      _lastRev = null;
      _text.clear();
    }
    final last = _lastRev;
    if (last != null && rev != last + 1) {
      // 跳跃：丢弃已累积内容并**停止渲染**，等持久事件到达。
      _lastRev = rev;
      _text.clear();
      return false;
    }
    _lastRev = rev;

    // 载荷形状见 `session-subscriptions.ts` 的 `expand`：`{type, time?, chunk?, ...}`。
    try {
      final parsed = _jsonDecode(payload);
      if (parsed is Map) {
        final chunk = parsed['chunk'];
        if (chunk is Map) {
          final text = chunk['text'];
          if (text is String && text.isNotEmpty) {
            _text.write(text);
            return true;
          }
        }
      }
    } catch (_) {
      // 载荷读不懂不该断连（它只是流式输出）：停在当前内容上。
      return false;
    }
    return false;
  }

  /// 持久事件到达：**替换**累加器内容（以持久为准，避免"流式与最终文本不一致"）。
  void replaceWith(String finalText) {
    _text
      ..clear()
      ..write(finalText);
  }
}
