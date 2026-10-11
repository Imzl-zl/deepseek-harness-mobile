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

import 'call_registry.dart';
import 'connection.dart';
import 'connection_resources.dart';
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
    // **把出帧口装到队列上**（§5.6）。
    //
    // 这里而不是装配点：只有本类知道"帧怎么发"（要过流控窗口、走 `_write`、
    // 带上 `fc`）。装配点曾经传一个假实现（`send: (_) async => false`），
    // 后果是**队列里每一条都永远发不出去**，而症状只是"订阅了但收不到数据" ——
    // 没有任何报错（`offline` 是合法返回值）。见 `Outbox.attachSender` 的说明。
    _deps.outbox.attachSender((entry) async {
      if (!_machine.acceptsBusinessFrames) return false;
      return _sendFrame({
        'v': wireVersion,
        't': 'req',
        'id': entry.requestId,
        // 写操作走**带幂等键**的信封（§5.6）：电脑侧据此去重，重发安全。
        // `requestId` 必须进信封顶层 —— 它是电脑侧唯一认得的幂等键。
        'box': encodeRequestEnvelope(
          entry.method,
          entry.params,
          requestId: entry.requestId,
        ),
      });
    });
  }

  final SyncClientDeps _deps;
  final ConnectionMachine _machine;
  final Backoff _backoff;
  final Keepalive _keepalive;

  late final StreamController<ConnectionState> _stateController;

  /// 每会话的更新流（广播：UI 多个部件要听同一会话）。
  final Map<String, StreamController<SessionDelta>> _sessionControllers = {};

  /// 在途请求表（`req.id` → 完成器）。应答到达时按 `id` 兑现。
  ///
  /// **它不跟着连接资源一起换**：旧 `id` 绝不能被新连接的应答兑现
  /// （那是上一条连接的请求）。所以由连接状态的迁移驱动它的作废 ——
  /// 见 `call_registry.dart` 的文件头。
  final CallRegistry _calls = CallRegistry();

  /// **每连接**的资源束（密码器 / 握手会话 / 收帧订阅 / 计数器 / 窗口 / 分帧器）。
  ///
  /// 收成一个对象而不是六个字段：它们的生命周期完全相同，而原先
  /// `_connect()` 与 `_enterClosed()` 里**各写一遍同一个清单** —— 两份迟早不一致，
  /// 漏掉任何一项都是静默 bug（见 `connection_resources.dart` 的文件头）。
  ConnectionResources _res = ConnectionResources();

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
      _deps.newId?.call() ?? newFrameId(randomBytes(frameIdBytes));

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
    // 每次建连换**一整份**每连接资源（新密钥、新计数器、新分帧器）—— §4.2。
    _res = ConnectionResources();

    final Stream<TransportEvent> events;
    try {
      events = await _deps.transport.connect();
    } catch (error) {
      // 建连失败：关掉（如果还开着）并进退避。
      //
      // **必须记进诊断面**：这条路上原先什么都不留 —— 于是"连不上"在界面上
      // 与"连上了但没数据"长得一模一样（都是空列表、都无错误），
      // 而真机上**反复重连**正是走这里（换票失败、升级被拒都会抛到这里）。
      _lastProtocolError = error is ProtocolException
          ? error
          : ProtocolException(ErrorCode.relayOffline, '建连失败：$error');
      _enterClosed();
      return;
    }

    _res.attachSubscription(
      events.listen(
        _onTransportEvent,
        onError: (Object error) => _enterClosed(),
        cancelOnError: false,
      ),
    );

    // WSS 建好了 → 进握手态，并把握手驱动装上（**它会立刻发出 hello**）。
    _machine.to(ConnectionState.handshake);
    _res.attachHandshake(
      _deps.handshake(
        HandshakeContext(
          send: _sendPreKeysFrame,
          established: _onEstablished,
          failed: (reason, error) {
            _failHandshake(reason, error);
          },
          schedule: _schedule,
        ),
      ),
    );
    _startTicking();
  }

  void _onEstablished(HandshakeEstablishment result) {
    if (_closed) return;
    // **先装密码器再进 serving**：顺序反了就会有一小段"已在服务但发不出帧"的窗口，
    // 而那一小段里的每一帧都会被丢掉（宁丢不发明文）。
    _res.attachBox(_deps.box(result.keys));
    // 握手成功要重置退避：否则下次掉线会从上次积累的大间隔开始等。
    _backoff.reset();
    // **连上了就把「上次为什么断」清掉**。
    //
    // 少了这一行，失败过一次之后那句话**永远留在界面上**（哪怕后来连上了）——
    // 于是 App 会一边正常收发、一边显示"握手失败"，
    // 而排查的人会去追一个**已经不存在**的故障（真机实测：屏幕上写着
    // `handshake-timeout`，而中转侧的记录显示 hello / confirm / req 三步全都正常走完）。
    _lastProtocolError = null;
    _lastHandshakeFailure = null;
    _lastCloseCode = null;
    _lastCloseReason = null;
    _lastHalfOpenSilentMs = null;
    _machine.to(ConnectionState.serving);
    // 连上了就把待发队列按序补发（§5.6：先落盘、连接可用时再发）。
    unawaited(_deps.outbox.flush());
  }

  void _failHandshake(ErrorCode reason, Object? error) {
    // 握手失败不计入业务重试次数（§4.1）：关掉连接，剩下的交给退避。
    //
    // **必须记进诊断面**：这是唯一一条原先什么都不记的关闭路径，而它恰好是
    // 真机上"每 10 秒重连一次、两端都没有任何原因"的那一条（`handshake-timeout`
    // 就走这里）。不记的话，界面上只剩"列表空的"，而**原因被 `reason` 参数带进来又被丢掉**。
    _lastHandshakeFailure = error == null
        ? reason.wire
        : '${reason.wire}：$error';
    _closeTransport();
    _enterClosed();
  }

  void _onTransportEvent(TransportEvent event) {
    switch (event) {
      case TransportMessage(:final chunk):
        // **拼行在这里做，不在传输层**：分隔符规则只有一个 owner（编解码层）。
        final List<String> lines;
        try {
          lines = _res.split(chunk);
        } on ProtocolException catch (error) {
          _protocolFailure(error);
          return;
        }
        for (final line in lines) {
          _onLine(line);
        }
      case TransportClosed(:final code, :final reason):
        // **断开本身要留声**，即使它是"正常"关闭。
        //
        // 这条路上原先什么都不记，于是真机上"每 10 秒重连一次"在**两端**都查不出原因：
        // 它不是协议错误（诊断面为空）、也不是半开（还没到点），就是**对端或本端把连接关了**。
        // 记下关闭码与理由，至少能区分"谁关的""为什么关"。
        _lastCloseCode = code;
        _lastCloseReason = reason;
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
        _res.handshake?.onFrame(frame);
      }
      return;
    }

    // 业务帧：未握手就收到 = 攻击面（§2.2），一律拒并关连接。
    //
    // 配对两帧**也走这里**：它们是要封箱的（`pair-commit` 的载荷就是配对码），
    // 所以在密钥建立之前出现只能是伪造或阶段搞错 —— 电脑侧同一处也是硬失败
    // （`connector/src/transport/codec.ts:132` 的 `assertHandshakePhase`）。
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
    final codec = _res.box;
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
      _res.onCredit(decodeCredit(box is String ? box : ''));
    }

    // 收到的每一帧都立刻回 credit。`credit` 自己除外 —— 否则两端互刷 ack 停不下来。
    if (elicitsCredit('${frame['t']}')) {
      _sendFrame({'v': wireVersion, 't': 'credit', 'box': encodeCredit(fc)});
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
    //
    // 手机侧目前恒为 `true`：它只发 `req` / `res` / `credit` / `persisted` / `ping`，
    // 而 §4.3 只压"可补"的 `ev` / `live` / `job` —— 手机一个都不发。
    // 保留这个判定是因为契约是**双向**的：将来手机要发 `job` 控制帧时它就该起作用。
    // （原先这里还配了一套 `_writableWaiters` 唤醒机制，但**没有任何生产者**
    //  —— 那是照搬电脑侧的设计，已删；需要时随"手机发可补帧"一起加。）
    if (!_res.canSend(type)) return false;

    final codec = _res.box;
    // `fc` 的分配与封箱必须紧挨着（见文件头）。分配前先看窗口 —— 没发出去的帧
    // 不该消耗序号，否则窗口算术会把没上线的帧也算进去。
    final fc = _res.nextFc();
    final wire = <String, Object?>{...frame, 'fc': fc};
    _res.onSent(fc, type);

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
    final event = _eventFromPayload(plaintext, seq);
    // 本地会话状态只需要"哪一条到了"（它做去重、水位与快照拼接）。
    //
    // 第三个参数是"文本"，而**连接层拿不到文本** —— 文本要从事件的 `data` 投影出来，
    // 那是 `data/projection.dart` 的事（它认识 `type` 的语义，这一层不认识）。
    // 传空串是如实的：这一层不知道内容，只知道序号。会话状态用它做的也只有
    // "去重 / 水位 / 空洞计数"三件事，都与文本无关。
    _deps.session.receive(sid, event.itemId, '', seq);
    _emit(
      sid,
      SessionDelta(
        sid: sid,
        events: [event],
        transient: _deps.session.transientOf(sid),
      ),
    );
    // **落盘后才发 `persisted`**（§5.3）：水位永不超过落盘内容。
    //
    // 这一步是**异步**的（要落盘），而 `_dispatch` 是同步的 —— 所以不 `await`，
    // 由 `_sendPersisted` 自己在落盘完成后发帧。顺序由 `_persistChain` 串起来
    // （见那一处：落盘必须**按到达顺序**做，否则水位会倒退）。
    _sendPersisted(sid, event, seq);
  }

  /// 落盘的串行链。
  ///
  /// ## 为什么必须串行
  ///
  /// 事件逐条到达，而落盘是异步的。若并发落盘，两次 `commit` 的完成顺序可能与
  /// 到达顺序不同 —— 而 `commit` 会把水位**取最大**。
  /// 于是"后到的先写完"不会出错，但"先到的后写完"会让**先发出去的 `persisted`
  /// 带了较大的 seq**，之后那批较小的又被写一次（幂等，无害）。
  ///
  /// 真正的风险是反过来的：若实现是"覆盖水位"而不是"取最大"，
  /// 并发会让水位**倒退**，而电脑已经按较大的水位裁过缓冲了 —— 那段数据永久丢失。
  ///
  /// 所以这里串起来，**让 `core/` 不依赖存储实现的那个细节**。
  Future<void> _persistChain = Future<void>.value();

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
        // **流式文本走 `liveText`，不进 `events`**：它没有稳定 itemId，
        // 且会被随后的持久 `assistant/message` 整体替换（见 `SessionDelta.liveText`）。
        liveText: acc.text,
        transient: _deps.session.transientOf(sid),
      ),
    );
  }

  /// 把一条事件落盘，**成功后**才发 `persisted`。
  ///
  /// ## 这一步是本文件里最容易写成谎话的地方
  ///
  /// 契约 §5.3 的原文是"`ev` 落盘后才发 `persisted`"。
  /// 早先的实现在这里只调了一次内存里的 `commit` 就发帧 ——
  /// 于是**水位是假的**：手机告诉电脑"我到 `seq` 了"，
  /// 电脑据此裁掉那边的增量缓冲，而手机其实什么都没存。
  /// 后果不是当次崩溃，而是**重启后那段数据永久丢失**（源头已经裁掉了）。
  ///
  /// ## 落盘失败怎么办
  ///
  /// **不发 `persisted`**，并把错误如实抛给上层（记进诊断面）。
  /// 不发是对的：水位不前进，电脑就会在重连时重发那一段（幂等，安全）。
  /// 而"落盘失败还发 persisted"是最糟的选择 —— 它把可恢复的失败变成了数据丢失。
  void _sendPersisted(String sid, SessionEvent event, int seq) {
    final persister = _deps.persistence;
    if (persister == null) {
      // 没有落盘缝：发的是"我处理完了"，**不是**"它在盘上了"。
      // 这只在不关心崩溃恢复的单测里成立（`SyncClientDeps.persistence` 的说明）。
      _deps.session.commit(sid, seq);
      _persistedFrame(sid, seq);
      return;
    }

    // 串到链尾：落盘按到达顺序做（见 `_persistChain` 的说明）。
    _persistChain = _persistChain
        .then((_) async {
          await persister.persist(sid: sid, events: [event], seq: seq);
          // **成功之后**才提交本地水位并发帧。
          _deps.session.commit(sid, seq);
          _persistedFrame(sid, seq);
        })
        .catchError((Object error) {
          // 落盘失败：水位不前进、不发帧。如实记进诊断面（不是静默吞掉）。
          _lastPersistError = error;
        });
  }

  void _persistedFrame(String sid, int seq) {
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

    final ok = frame['ok'];
    if (ok != true) {
      // 失败也是**正常应答**，不是断连理由（§9）。错误码来自封闭表。
      _calls.resolve(
        id,
        result: null,
        error: ProtocolException(
          _errorCodeOf(plaintext),
          _errorMessageOf(plaintext),
        ),
      );
      return;
    }
    // 迟到或重复的应答：`resolve` 返回 false，忽略即可（不是错误）。
    _calls.resolve(id, result: _resultOf(plaintext));
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
    final completer = _calls.register(id);
    final sent = _sendFrame({
      'v': wireVersion,
      't': 'req',
      'id': id,
      'box': encodeRequestEnvelope(method, params, requestId: requestId),
    });
    if (!sent) {
      // 发送失败要**撤销登记**：否则表里留一个永远不兑现的条目。
      _calls.unregister(id);
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
    // 每连接资源一次作废（握手会话 / 密码器 / 收帧订阅）。
    _res.dispose();
    await _deps.transport.close();
    for (final controller in _sessionControllers.values) {
      await controller.close();
    }
    _sessionControllers.clear();
    // 关闭时也要拒掉在途请求（同 `_enterClosed`，但错误码不同：
    // 这里是"客户端被关了"，不是"连接断了" —— 前者不该再重试）。
    _calls.failAll(const ProtocolException(ErrorCode.internal, '客户端已关闭'));
    await _stateController.close();
  }

  // -------------------------------------------------------------------------
  // 状态与定时器
  // -------------------------------------------------------------------------

  void _onStateChanged(ConnectionState from, ConnectionState to) {
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
          // 走 `_sendFrame` 而**不是** `_write`：`fc` 的分配与封箱都在 `_sendFrame` 里，
          // 而 `ping` 是要封箱的（§3）—— 直接 `_write` 会发出一帧**没有 `fc`** 的
          // `ping`，对端在解箱那一步就把它判成 `protocol/bad-frame` 并关连接
          // （真机实测：`ping 帧没有 fc,不该封箱`，每 15 秒一轮重连）。
          //
          // **`id` 也是必需的**（§2.2）：`pong` 没有 `sid`，中继只能靠 `id`
          // 把它送回发起方 —— 不带 `id` 的话探针永远等不到应答，于是每个心跳周期
          // 判一次半开、关掉一条健康的连接（中继日志：`丢弃一帧：ping 找不到对应设备`）。
          //
          // Note: 这两个缺口（缺 `fc` / 缺 `id`）与另外两处"线上形状不一致"一起记在
          // `.agents/notes/implemented/2026-10-07-three-wire-shape-mismatches.md`
          _sendFrame({
            'v': wireVersion,
            't': 'ping',
            'id': _deps.newId?.call() ?? newFrameId(randomBytes(frameIdBytes)),
            'box': '',
          });
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

  /// 收口到 `closed`：作废每连接资源，并让状态机走它自己的白名单。
  ///
  /// **同步**（`_res.dispose()` 是同步的）：收口路径全在事件回调里，
  /// 中间多一个 `await` 窗口就会让退避起点漂移（见 `connection_resources.dart`
  /// 的 `dispose` 说明 —— 那条是被一条重连用例逼出来的）。
  void _enterClosed() {
    _res.dispose();
    _cancelTick?.call();
    _cancelTick = null;
    // **在途请求必须被拒绝**，否则调用方的 `await` 永远不返回
    //（断连是常态，这条路必然走到 —— 见 `call_registry.dart` 的文件头）。
    // 错误码用 `relay/offline`：它对应的客户端动作是"退避重试"，
    // 而不是 `internal` 的"记日志重试"—— 前者知道这是连接问题。
    final rejected = _calls.failAll(
      const ProtocolException(ErrorCode.relayOffline, '连接已断开，在途请求被取消'),
    );
    if (rejected > 0) {
      _lastRejectedCalls = rejected;
    }
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

  /// 上一次握手失败的原因（诊断用；`null` = 没失败过）。
  ///
  /// **它曾经是被丢掉的那个参数**：`_failHandshake(reason, error)` 收下原因、
  /// 然后只关连接、什么都不记 —— 于是真机上"每 10 秒重连"在两端都无迹可寻。
  String? _lastHandshakeFailure;

  /// 判定为半开时已沉默多久（诊断用）。
  int? _lastHalfOpenSilentMs;

  /// 上一次传输关闭的码与理由（诊断用；两者都可能为 `null`）。
  ///
  /// **它补的是最大的一块诊断盲区**：断开有三种来源 ——
  /// 协议错误（`_lastProtocolError`）、判半开（`_lastHalfOpenSilentMs`）、
  /// **以及对端/本端直接把连接关了**。前两种原先有记录，第三种什么都没有，
  /// 而真机上"每 10 秒重连一次"恰好就是第三种：两端日志都查不出原因。
  int? _lastCloseCode;
  String? _lastCloseReason;

  /// 上一次收口时被拒绝的在途请求数（诊断用）。
  int? _lastRejectedCalls;

  /// 上一次落盘失败（诊断用；`null` = 没失败过）。
  ///
  /// 它值得暴露：**落盘失败的表现是"数据少了一段"，而不是任何可见的错误** ——
  /// 没有这个字段，那条失败只留在日志里（而日志会被冲掉）。
  Object? _lastPersistError;

  /// 诊断面（测试与日志用）。
  @override
  ProtocolException? get lastProtocolError => _lastProtocolError;

  /// 判定为半开时已沉默多久；没判过是 `null`。
  @override
  int? get lastHalfOpenSilentMs => _lastHalfOpenSilentMs;

  @override
  int? get lastCloseCode => _lastCloseCode;

  @override
  String? get lastCloseReason => _lastCloseReason;

  @override
  String? get lastHandshakeFailure => _lastHandshakeFailure;

  /// 当前在途请求数。
  @override
  int get pendingCalls => _calls.pending;

  /// 上一次连接收口时被拒绝的在途请求数；没收口过是 `null`。
  @override
  int? get lastRejectedCalls => _lastRejectedCalls;

  /// 上一次落盘失败；没失败过是 `null`。
  @override
  Object? get lastPersistError => _lastPersistError;

  // -------------------------------------------------------------------------
  // 供测试观察的帧收集（生产里 UI 不读这些）
  // -------------------------------------------------------------------------

  final List<(Map<String, Object?>, String)> _jobFrames = [];
  final List<Map<String, Object?>> _presenceFrames = [];

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

/// 从 `ev` 的解箱载荷取一条条目。
///
/// ## 载荷是**真实的 DSH 会话事件**，不是 fixtures 的 `{itemId, text}`
///
/// 实测（`connector/src/session-subscriptions.ts:170,175`）：电脑侧封的是
/// `JSON.stringify(record.event)` —— 而 `record.event` 是 DSH 的 `SessionWireEvent`：
///
/// ```ts
/// { type: string, seq: number, time: number, data: JsonValue }   // types.ts
/// ```
///
/// 而 `protocol/fixtures` 的词汇层用的是 `{itemId, text}`（见 `connector/src/protocol/recovery.ts:144`）
/// —— 那是**可逆占位**，不是线上形状。两者不能混：按 fixture 形状解析真实流量会在
/// 第一个事件上就抛"缺少 itemId"。
///
/// 所以 `itemId` 走 [itemIdOf]（契约 §5.2 的推导表，不变量 I9），
/// 而"这条事件渲染成什么"是**上层**的事（它认识 `type` 与 `data`）——
/// 这一层只负责"这一条属于哪个 itemId"，**并把原始 `type`/`data` 原样带上**，
/// 而不是在解析时就把它们丢掉（丢掉会让上层只能从 `text` 里猜，那是"UI 各自解释事件"
/// 的开端 —— 接线时实测踩到过）。
SessionEvent _eventFromPayload(String plaintext, int seq) {
  final parsed = _jsonDecode(plaintext);
  if (parsed is! Map) {
    throw const ProtocolException(ErrorCode.badFrame, 'ev 载荷必须是 JSON 对象');
  }
  final event = Map<String, Object?>.from(parsed);
  final type = event['type'];
  if (type is! String || type.isEmpty) {
    throw const ProtocolException(ErrorCode.badFrame, 'ev 载荷缺少 type');
  }
  final eventSeq = event['seq'];
  final resolvedSeq = eventSeq is int ? eventSeq : seq;
  final itemId = itemIdOf(
    EventLike(type: type, seq: resolvedSeq, data: event['data']),
  );
  final time = event['time'];
  return SessionEvent(
    itemId: itemId,
    type: type,
    seq: resolvedSeq,
    time: time is int ? time : resolvedSeq,
    data: event['data'],
  );
}

Object? _jsonDecode(String text) {
  try {
    return jsonDecode(text);
  } catch (error) {
    throw ProtocolException(ErrorCode.badFrame, '载荷不是合法 JSON：$error');
  }
}

/// `sync_client` 的 `call` 用的请求信封编码。
///
/// **`requestId` 在顶层**（契约 §5.7）—— 不是塞在 `params` 里。
/// 带幂等键的方法（`session.prompt` / `interaction.respond` / 设置与凭据的写）
/// 少了它会被电脑侧直接拒：`session.prompt 必须带 requestId（幂等键）`。
///
/// **这行曾经把 `requestId` 整个丢掉**（签名里压根没这个参数），
/// 而函数上方的注释却写着"`requestId` 顶层" —— 注释说了、代码没做。
/// 后果是真机上"发一句什么也没有"：请求到了电脑侧、被拒、错误只在一闪而过的 SnackBar 里。
String encodeRequestEnvelope(
  String method,
  Map<String, Object?> params, {
  String? requestId,
}) => jsonEncode({
  'method': method,
  'params': params,
  // null-aware 的 `?` 作用于**值**（键是字面量）：没有幂等键时不写这个字段。
  'requestId': ?requestId,
});

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
