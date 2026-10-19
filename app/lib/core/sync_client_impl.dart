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
import 'job.dart';
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
        // **帧号，不是幂等键**。`requestId` 只进信封顶层（§5.6 / §5.7）——
        // 它的形状由业务定（`i:<callId>` 就带冒号），而帧头 `id` 受契约 §3 的
        // ASCII 安全字符集约束，`res` 原样回显它。
        //
        // 曾经这里写 `entry.requestId`，于是业务键上了帧头：连接器按
        // `protocol/bad-frame` 拒收并关连接（`codec.ts` 的 `ID_PATTERN`），
        // 表现是"点了允许一次，连接断了，队列不推进"。
        // 因果与备选方案见
        // `.agents/notes/implemented/2026-10-17-frame-id-not-idempotency-key.md`。
        'id': entry.frameId,
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

  /// **已声明的订阅集**（`sid → since`）。它跟着连接活：断开即清空，
  /// 重连后由 `sync.hello` 整份重新声明（契约 §5.4）。
  ///
  /// 为什么由本类记着而不是问 UI：UI 打开哪个会话是它的事，而"这条连接声明了哪些会话"
  /// 是连接的状态 —— 断线之后 UI 不会再调一次 `subscribe`（用户没有重新点开），
  /// 于是恢复只能由持有连接的这一层发起。
  final Map<String, int> _declared = <String, int>{};

  /// `sync.hello` 的载荷（契约 §5.4）：前后台态 + 整份订阅集。
  ///
  /// **`app` 是必须的**：电脑侧据此判定"用户是否正看着手机"，而 `foreground` 档的
  /// 审批接管判据正是"前台且已订阅该会话"。少了它，手机上永远收不到审批。
  Map<String, Object?> _helloParams() => <String, Object?>{
    'app': _appState == AppState.foreground ? 'foreground' : 'background',
    'sessions': <Object?>[
      for (final entry in _declared.entries)
        <String, Object?>{'sid': entry.key, 'since': entry.value},
    ],
  };

  /// 发一次 `sync.hello`（恢复握手 + 应用态声明，契约 §5.4）。
  ///
  /// **不等应答**：应答里的恢复内容手机不用（增量与快照走订阅流，
  /// `sync.hello` 只是"批量订阅 + 应用态声明"的入口）。而"紧接着可能就要断开"
  /// 的场景必须等它真的写出去，所以这里等的是**写**，不是 `res`。
  ///
  /// 被拒时（例如某个 `sid` 已经不存在）的后果是"电脑侧不知道手机在前台"——
  /// 于是审批继续在桌面上答。那是**安全**的方向，且下一次回前台还会再发一次
  /// （契约 §9 的兜底），所以这里不把错误往上传。
  Future<bool> _sendHello() async {
    if (!_machine.acceptsBusinessFrames) return false;
    return _sendFrameWritten({
      'v': wireVersion,
      't': 'req',
      'id': _newId(),
      'box': encodeRequestEnvelope('sync.hello', _helloParams()),
    });
  }

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
    // **终态不重连**：身份不被认（换票被拒）后，机器停在 `closed` 等上层重新配对
    // （装配点会换一个新客户端）。这里再 `start()` 只会又拿到同一个 401；
    // 且 `closed → connecting` 是**非法迁移**（`setAppState(foreground)` 会在
    // 终态后把 `closed` 当"该重连"调到这里）—— 直接挡掉，两条都避掉。
    if (_lastConnectWasTerminal) return;
    // **放弃过的手动重试**：用户点了「重试连接」到这里 —— 清掉放弃标记并把
    // 退避表回到起点，否则下一次 closed 会立刻又判 exhausted。
    if (_connectGaveUp) {
      _connectGaveUp = false;
      _backoff.reset();
    }
    if (_machine.isAnyOf([
      ConnectionState.serving,
      ConnectionState.handshake,
    ])) {
      return;
    }
    await _connect();
  }

  @override
  Future<void> reconnect() async {
    // **先收干净再建**：正在服务的连接必须断掉，否则新连接建起来会与它并存 ——
    // 两套握手、两套 fc 计数器，服务端按设备只留一条（新的顶掉旧的），
    // 本端却以为两条都活着。
    _cancelBackoff?.call();
    _cancelBackoff = null;
    _closeTransport();
    _enterClosed();
    // `closed` 是终态，`start()` 会直接返回；恢复意图要显式回到起点。
    // 但**终态失败（身份不被认）不复活**：那种情况该走重新配对。
    if (_lastConnectWasTerminal) return;
    if (_machine.isAnyOf([ConnectionState.closed, ConnectionState.backoff])) {
      _machine.to(ConnectionState.idle);
    }
    _connectGaveUp = false;
    _backoff.reset();
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
      //
      // **身份不被认（notPaired / revoked）是终态，不进退避**：换票被拒说明
      // 这台电脑已不再认可本机（停用 / 凭据失效 / 名册里没有），退避重连只会
      // 每次都拿到同一个 401，用户永远卡在"重连中…"。这种情况由上层
      // （装配点，经 AppModel → ConnectionRecovery）清掉本地凭据并回配对页；
      // 连接层只负责"不重连 + 留声"，不认识平台、也不导航。
      final exception = _connectFailure(error);
      _lastProtocolError = exception;
      _lastConnectWasTerminal = exception.clientAction == ClientAction.rePair;
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

  /// 把一次建连失败翻成协议错误，**保留换票被拒的错误码**。
  ///
  /// `TicketedWebSocketTransport` / `EndpointTransport` 把 `ProtocolException`
  /// 的码塞进 `TransportException.code`（否则 401 会被当成网络问题，用户永远
  /// 卡在退避重连上 —— 议题 2 的真因）。这里把它还原成 `ProtocolException`，
  /// 让 `clientAction` 可判。纯网络类失败归 `relay/offline`（照旧退避）。
  ProtocolException _connectFailure(Object error) {
    if (error is ProtocolException) return error;
    if (error is TransportException) {
      final code = error.code;
      // 带码的传输错误（换票被拒等）：保留码与原文，让 clientAction 可判。
      if (code != null) return ProtocolException(code, error.message);
    }
    return ProtocolException(ErrorCode.relayOffline, '建连失败：$error');
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
    // 连上了：这条连接不再是"终态停摆"（下次掉线按正常退避判）。
    _lastConnectWasTerminal = false;
    // 连上了：放弃标记与退避表都回到起点（否则下次掉线会从大间隔开始，
    // 甚至立刻又判 exhausted）。
    _connectGaveUp = false;
    _backoff.reset();
    _machine.to(ConnectionState.serving);
    // 连上了就把待发队列按序补发（§5.6：先落盘、连接可用时再发）。
    unawaited(_deps.outbox.flush());
    // **进服务态就声明一次 `sync.hello`**：它是恢复握手 + 前后台态声明（契约 §5.4）。
    // 断线期间 UI 不会重新 `subscribe`（用户没有重新点开），所以恢复只能在这里发起。
    unawaited(_sendHello());
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
    // **流控记账要用解箱后的那一帧**。
    //
    // 曾经这里直接把 `frame` 递给 `_accountFlow`，而 `frame['box']` 还是**密文** ——
    // 于是 `decodeCredit` 拿到密文并抛 `credit 载荷不是合法 JSON`，
    // 整条连接被 `_protocolFailure` 关掉。症状极有误导性：**握手成功、随即断线**，
    // 而电脑侧一条日志都没有（真机实测：`serving` 之后 20 ms 就 `closed`）。
    //
    // 电脑侧同一处是对的（`connector/src/transport/connection.ts` 的
    // `const opened = { ...frame, box: cipher.openFrame(...) }`，两份都从它取）——
    // 这就是"两侧各写一遍"的代价：一侧改了另一侧不会红。
    _accountFlow(<String, Object?>{...frame, 'box': plaintext});

    switch (type) {
      case 'res':
        _resolveCall(frame, plaintext);
      case 'ev':
        _onEvent(frame, plaintext);
      case 'live':
        _onLive(frame, plaintext);
      case 'job':
        _jobFrames.add((frame, plaintext));
        _emitJobFrame(frame, plaintext);
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
  ///
  /// @returns `false` = 这一帧**没有被接受**（不在服务态、满窗、或没有密码器）。
  bool _sendFrame(Map<String, Object?> frame) {
    final prepared = _prepareFrame(frame);
    if (prepared == null) return false;
    unawaited(_sealAndWrite(prepared));
    return true;
  }

  /// 准备一帧：过服务态与窗口、分配 `fc`、记账。返回 `null` 表示没被接受。
  ///
  /// 与 {@link _sealAndWrite} 分开是**为了能只等"写出去"而不等应答**：
  /// `sync.hello` 这种声明帧需要"发出去就好"（紧接着可能就要断开），
  /// 而 `call()` 要等 `res`。合成一个口就只剩"等应答"一种形状。
  Map<String, Object?>? _prepareFrame(Map<String, Object?> frame) {
    if (!_machine.acceptsBusinessFrames) return null;
    final type = '${frame['t']}';
    // 满窗时对可补帧如实回 `false`：这一帧**没有被接受**，调用方据此暂停（§4.3）。
    //
    // 手机侧目前恒为 `true`：它只发 `req` / `res` / `credit` / `persisted` / `ping`，
    // 而 §4.3 只压"可补"的 `ev` / `live` / `job` —— 手机一个都不发。
    // 保留这个判定是因为契约是**双向**的：将来手机要发 `job` 控制帧时它就该起作用。
    // （原先这里还配了一套 `_writableWaiters` 唤醒机制，但**没有任何生产者**
    //  —— 那是照搬电脑侧的设计，已删；需要时随"手机发可补帧"一起加。）
    if (!_res.canSend(type)) return null;
    if (_res.box == null) {
      // 配了 secure 却拿不出密码器：只可能是"握手已过但密码器没装上"这类装配错误。
      // 宁可不发，也不明文上线。
      return null;
    }
    // `fc` 的分配与封箱必须紧挨着（见文件头）。分配前先看窗口 —— 没发出去的帧
    // 不该消耗序号，否则窗口算术会把没上线的帧也算进去。
    final fc = _res.nextFc();
    _res.onSent(fc, type);
    return <String, Object?>{...frame, 'fc': fc};
  }

  /// 封箱并写出。返回 `false` 表示封箱失败（那一帧没出去）。
  Future<bool> _sealAndWrite(Map<String, Object?> wire) async {
    final codec = _res.box;
    if (codec == null) return false;
    // **封箱之前记一份明文请求**：线上 `box` 是密文，事后无从知道发过哪个方法
    // （诊断面因此完全瞎掉）。记在这是唯一能拿到明文的位置。
    if ('${wire['t']}' == 'req') _recordRequest('${wire['box'] ?? ''}');
    try {
      final box = await codec.sealFrame(wire, '${wire['box'] ?? ''}');
      _write(<String, Object?>{...wire, 'box': box});
      return true;
    } catch (error) {
      // 封箱失败（比如 nonce 绊线）：这一帧不发，并吵一声。
      _protocolFailure(
        error is ProtocolException
            ? error
            : ProtocolException(ErrorCode.internal, '封箱失败：$error'),
      );
      return false;
    }
  }

  /// 已发出的请求信封（**明文**，封箱前抄下来的）。有界：只留最近 64 条。
  final List<Map<String, Object?>> _sentRequests = <Map<String, Object?>>[];

  void _recordRequest(String envelopeText) {
    try {
      final parsed = jsonDecode(envelopeText);
      if (parsed is Map) {
        _sentRequests.add(Map<String, Object?>.from(parsed));
        if (_sentRequests.length > 64) _sentRequests.removeAt(0);
      }
    } catch (_) {
      // 记不下来的信封不影响发送；诊断面少一条而已。
    }
  }

  /// 发一帧业务帧并**等它写出去**（不等应答）。
  ///
  /// 给"声明类"帧用：`sync.hello` 的应答内容手机不用（恢复内容走订阅流），
  /// 但"紧接着要断开"的场景必须等它真的写出去，否则 `_disconnect()`
  /// 会把还没封箱的那一帧连同连接一起丢掉。
  Future<bool> _sendFrameWritten(Map<String, Object?> frame) async {
    final prepared = _prepareFrame(frame);
    if (prepared == null) return false;
    return _sealAndWrite(prepared);
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
  Future<SessionAnchor> subscribe(String sid, {required int since}) async {
    // 订阅是一次**写操作**（电脑侧要为它建立 follow），所以走 outbox：先落盘再发。
    _declared[sid] = since;
    final requestId = _newId();
    await _deps.outbox.enqueue(
      OutboxEntry(
        requestId: requestId,
        method: 'session.subscribe',
        params: {'sid': sid, 'since': since},
        sid: sid,
        frameId: _newId(),
      ),
    );
    await _deps.outbox.flush();
    // **anchor 目前拿不到，用保守默认**（`hasMore: false` = "不知道有没有更多"）。
    //
    // 电脑侧确实在 `session.subscribe` 的应答里发 `{since, hasMore}`
    // （`connector/src/session-subscriptions.ts:80-85`），而手机侧拿不到它：
    // outbox 的语义是"发出去就好"，它的 `res` 应答走 [_resolveCall] 那条路，
    // 而那里只解**即时 `call`** 挂起的 future（按帧头 `id`）——
    // outbox 的 `frameId` 没有对应的 future 在等。
    //
    // **不能为此多发一次 `call`**：2026-10-19 实测那样会**双发**同一个
    // `session.subscribe`（outbox 一次 + 即时一次），且第二发没有 requestId，
    // 电脑侧按新订阅处理 —— 测试替身直接等到超时。双发比拿不到 anchor 糟得多。
    //
    // 要真拿到 anchor，得让 outbox 的应答能回到调用方（一个"带 requestId 的
    // pending future"表）。那是 `core/` 的架构改动，见 `memory.md` 待办。
    return const SessionAnchor(since: 0, hasMore: false);
  }

  @override
  Future<SessionPage> page({
    required String sid,
    required int beforeSeq,
    int maxMessages = SyncClient.kHistoryPageMaxMessages,
    int minMessages = SyncClient.kHistoryPageMinMessages,
    int minTurns = SyncClient.kHistoryPageMinTurns,
  }) async {
    try {
      final reply = await call<Object?>('session.page', {
        'sid': sid,
        'beforeSeq': beforeSeq,
        'maxMessages': maxMessages,
        'turnWindow': {'minMessages': minMessages, 'minTurns': minTurns},
      });
      return SessionPage(
        events: _pageEventsOf(reply),
        hasMore: boolFieldOf(reply, 'hasMore') ?? false,
      );
    } on ProtocolException catch (error) {
      // **失败不当成"没有更多"**（契约 §3.1：`session/window-missed` 的客户端
      // 动作是重新订阅走快照）。把原因带回去，让上层决定。
      // `ErrorCode` 是 String 的字面量联合，`name` 拿它的标识符
      // （`session/window-missed` 这类带斜杠的用 `message` 更可读）。
      return SessionPage(
        events: const [],
        hasMore: true,
        failure: error.code.name,
      );
    }
  }

  /// `session.page` 的 `items` → 事件表。
  ///
  /// 形状（`connector/src/session-page.ts:102-111`）：
  /// `items: [{kind:'record', record:{type:'event', event}} | {kind:'refetch', seq, bytes}]`。
  ///
  /// **`refetch` 项跳过**：那是"这条太大，改用 `session.refetch` 单独取"的标记
  /// （`session-page.ts:104-107`），本身不含事件。跳过后这一页会少几条 ——
  /// 比把标记当事件渲染成一条莫名其妙的东西好。
  List<SessionEvent> _pageEventsOf(Object? reply) {
    final items = reply is Map ? reply['items'] : null;
    if (items is! List) return const [];
    final out = <SessionEvent>[];
    for (final item in items) {
      if (item is! Map || item['kind'] != 'record') continue;
      final record = item['record'];
      if (record is! Map) continue;
      final event = record['event'];
      if (event is! Map) continue;
      final type = event['type'];
      final seq = event['seq'];
      if (type is! String || seq is! int) continue;
      out.add(
        SessionEvent(
          itemId: itemIdOf(
            EventLike(type: type, seq: seq, data: event['data']),
          ),
          type: type,
          seq: seq,
          time: event['time'] is int ? event['time'] as int : seq,
          data: event['data'],
        ),
      );
    }
    return out;
  }

  @override
  Future<void> unsubscribe(String sid) async {
    _declared.remove(sid);
    final requestId = _newId();
    await _deps.outbox.enqueue(
      OutboxEntry(
        requestId: requestId,
        method: 'session.unsubscribe',
        params: {'sid': sid},
        sid: sid,
        frameId: _newId(),
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
      // 判据与登记必须在**同一段同步代码**里：中间放一个 `await`（落盘）就会让
      // 两次并发调用都通过判据，然后后一个把前一个的完成器覆盖掉 ——
      // 被覆盖的那个调用方永远挂着（断连才被 `failAll` 收）。
      //
      // 判据是**幂等键**而不是帧号：每次重发都会换一个新帧号，按帧号判就会漏。
      if (_calls.isPendingRequest(requestId)) return null as T;
      // 帧号在落盘之前铸：调用方必须赶在 `flush()` 之前拿到它才能登记在途等待，
      // 否则 `res` 可能早于登记到达而被当成"迟到的"丢掉。
      final frameId = _newId();
      final completer = _calls.register(frameId, requestId: requestId);
      try {
        await _deps.outbox.enqueue(
          OutboxEntry(
            requestId: requestId,
            method: method,
            params: params,
            frameId: frameId,
          ),
        );
      } catch (_) {
        // 没落盘就不算这次写操作存在，登记也要撤。
        _calls.unregister(frameId);
        rethrow;
      }
      // 队列发出去了，但结果要等 `res`。帧头 `id` 就是上面铸的帧号，
      // 电脑侧的 `res {id = 帧号}` 兑现它。
      //
      // 曾经这里直接 `return null`（原话"结果由会话流收敛"），于是
      // **调用方确实需要结果**的写永远收不到返回值 —— 2026-10-17 真机验收：
      // hero 上选工作区后弹"开新任务失败：新建会话没有回 sid"，而会话其实
      // 已经建成了。同一条路还让电脑侧的**拒绝**对 App 不可见：
      // `interaction.respond` 的注释写着"失败照原样抛，调用方据此把那一项
      // 标成已过期"，而 `res {ok:false}` 在旧行为里直接被丢掉。
      final FlushOutcome outcome;
      try {
        outcome = await _deps.outbox.flush();
      } catch (_) {
        _calls.unregister(frameId);
        rethrow;
      }
      if (outcome == FlushOutcome.offline) {
        // 离线：已落盘，等连接回来补发。这里如实抛，**不假装成功**。
        _calls.unregister(frameId);
        throw const ProtocolException(
          ErrorCode.relayOffline,
          '离线：写操作已入队，待连接恢复后补发',
        );
      }
      // 连接在在途时断掉：`CallRegistry.failAll` 会拒绝这个完成器
      // （否则调用方永远等不到），调用方退避重连后重发 —— 同一个幂等键
      // 保证重发不会造成第二次写。
      return await completer.future as T;
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
    final previous = _appState;
    _appState = next;
    _keepalive.setForeground(next == AppState.foreground);
    if (next == AppState.background) {
      // **先声明退到后台，再断开**：电脑侧的 `foreground` 档接管判据是"前台且已订阅"，
      // 声明过之后即使断开慢了一步，审批也不会继续推给一台已经退到后台的手机。
      if (previous != next && _machine.acceptsBusinessFrames) {
        await _sendHello();
      }
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
    // 任务帧流也收口：不关的话 UI 上的订阅会挂在一个已死的客户端上。
    await _jobUpdates.close();
    // 关闭时也要拒掉在途请求（同 `_enterClosed`，但错误码不同：
    // 这里是"客户端被关了"，不是"连接断了" —— 前者不该再重试）。
    _calls.failAll(const ProtocolException(ErrorCode.internal, '客户端已关闭'));
    await _stateController.close();
  }

  // -------------------------------------------------------------------------
  // 状态与定时器
  // -------------------------------------------------------------------------

  void _onStateChanged(ConnectionState from, ConnectionState to) {
    // **终态不进退避**：身份不被认（`_lastConnectWasTerminal`）时，连接停在这里
    // 等上层清凭据回配对页；自动退避只会每次都拿到同一个 401（议题 2）。
    if (to == ConnectionState.closed && !_closed && !_lastConnectWasTerminal) {
      // 连接结束 → 进退避 → 到点且前台才重连（§2.2：只在 App 前台重连）。
      _machine.to(ConnectionState.backoff);
      // **失败太多次就放弃**：电脑关机 / 中转挂了时，无限重连意味着用户永远看着
      // 一个转圈的东西，而没有任何结论（2026-10-15 真机反馈："我电脑关机了,
      // 早上来了,手机一直重连,没有说重连多久连不上然后就停止"）。
      // 放弃后界面说「连接不上」+ 给手动重试；下一次回前台仍会再试一轮（§2.2）。
      if (_backoff.exhausted) {
        _connectGaveUp = true;
        return;
      }
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

  /// 上一次建连失败是否是**终态**（身份不被认，不再退避重连）。
  ///
  /// 见 [_onStateChanged] 的守卫与 `SyncClientProbe.lastConnectWasTerminal`。
  /// 只在 [_connect] 的失败分支按 `clientAction == rePair` 置位，
  /// 握手成功（[_onEstablished]）时复位。
  bool _lastConnectWasTerminal = false;

  /// 连续失败太多次、已经停止自动重连（见 `_onStateChanged`）。
  ///
  /// 界面据此说「连接不上」并给手动重试；`start()` 会清掉它。
  bool _connectGaveUp = false;

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

  /// 上一次建连失败是否是终态（身份不被认，不再退避重连）。
  @override
  bool get lastConnectWasTerminal => _lastConnectWasTerminal;

  @override
  bool get lastConnectGaveUp => _connectGaveUp;

  /// 已声明的订阅集（`sync.hello` 的输入）。
  @override
  Map<String, int> get declaredSessions => Map.unmodifiable(_declared);

  /// 已发出的请求信封（**明文**；线上的 `box` 是密文，事后无从知道发过哪个方法）。
  @override
  List<Map<String, Object?>> get sentRequests =>
      List.unmodifiable(_sentRequests);

  // -------------------------------------------------------------------------
  // 供测试观察的帧收集（生产里 UI 不读这些）
  // -------------------------------------------------------------------------

  final List<(Map<String, Object?>, String)> _jobFrames = [];
  final List<Map<String, Object?>> _presenceFrames = [];

  final StreamController<JobFrame> _jobUpdates =
      StreamController<JobFrame>.broadcast();

  /// 收到的任务输出帧（`(帧头, 明文)`；任务面板读它）。
  @override
  List<(Map<String, Object?>, String)> get jobFrames =>
      List.unmodifiable(_jobFrames);

  /// 任务输出帧流（已解析成 `core/job.dart` 的类型）。
  @override
  Stream<JobFrame> get jobUpdates => _jobUpdates.stream;

  /// 收到的 `presence` 帧（设备与连接状态读它）。
  @override
  List<Map<String, Object?>> get presenceFrames =>
      List.unmodifiable(_presenceFrames);

  void _emitJobFrame(Map<String, Object?> frame, String plaintext) {
    // 解析只在这里发生一次：UI 拿类型，不拿明文。
    // **解析失败不当协议错误**：一帧解不动就断连接太狠，而这帧只是任务输出。
    // 但也不静默丢 —— 转成 `JobError` 让任务面板显示"这一帧没解出来"。
    // `late final`：两个分支各赋一次，Dart 的定值分析对 try/catch 保守，
    // 用 `final` 会报"只能设一次"。
    late final JobFrame parsed;
    try {
      parsed = parseJobFrame(plaintext);
    } on FormatException catch (error) {
      parsed = JobError(
        jobId: '${frame['id'] ?? ''}',
        message: '任务帧解不开：$error',
      );
    }
    if (!_jobUpdates.isClosed) _jobUpdates.add(parsed);
  }

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

/// 取一个整数字段（不是 int 就是 `null`，**不收 num**）。
///
/// `since` 这类回包字段在契约里是明确的数字；形状不对时宁可不填
/// （调用方有自己的兜底），也不猜。
int? intFieldOf(Object? value, String key) {
  if (value is! Map) return null;
  final field = value[key];
  return field is int ? field : null;
}

/// 取一个布尔字段（不是 bool 就是 `null`）。
bool? boolFieldOf(Object? value, String key) {
  if (value is! Map) return null;
  final field = value[key];
  return field is bool ? field : null;
}
