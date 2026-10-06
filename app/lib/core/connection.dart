/// 连接状态机与重连退避（契约 §2.2、§9、§10）。
///
/// ```text
///   idle ──建连──▶ connecting ──鉴权通过──▶ handshake ──握手完成──▶ serving
///                      │                        │                      │
///                   失败/超时                 失败/超时              断开/错误
///                      ▼                        ▼                      ▼
///                    closed ◀───────────────────┴──────────────────────┘
///                      │ 连接结束
///                      ▼
///                   backoff ──计时到且前台──▶ connecting
/// ```
///
/// ## 为什么迁移表是**白名单**
///
/// 不在表里的迁移一律抛错。状态机的全部价值就在于「非法迁移会响」—— 如果允许任意跳转，
/// 它就退化成一个字符串字段，而真正的 bug（从 `idle` 直接进 `serving`、或 `backoff` 里
/// 又开一条连接）会静默发生，表现为**两条连接同时存在**。
///
/// 移植源：`connector/src/transport/state.ts` 与 `backoff.ts`（行为基准）。
library;

import 'dart:math';

/// 状态取值（契约 §2.2）。
enum ConnectionState {
  /// 未建连（初始态）。
  idle,

  /// 正在建连（DNS / TCP / WSS 升级）。
  connecting,

  /// WSS 已建立，正在走 §4.1 的三帧握手。
  handshake,

  /// 握手完成，可以收发业务帧。
  serving,

  /// 连接结束（失败、超时、断开、错误都先到这里）。
  closed,

  /// 退避等待中（到点且前台才回 `connecting`）。
  backoff,
}

/// 允许的迁移（白名单）。
///
/// - `idle → connecting`：发起建连。
/// - `connecting → handshake`：WSS 建好且鉴权通过。
/// - `handshake → serving`：§4.1 的三条消息走完。
/// - `* → closed`：失败、超时、断开、错误。
/// - `closed → backoff`：连接结束，进入退避计时。
/// - `closed → idle` / `backoff → idle`：**主动断开**（切后台、卸载），不再重连。
const Map<ConnectionState, List<ConnectionState>> _transitions = {
  ConnectionState.idle: [ConnectionState.connecting],
  ConnectionState.connecting: [
    ConnectionState.handshake,
    ConnectionState.closed,
  ],
  ConnectionState.handshake: [ConnectionState.serving, ConnectionState.closed],
  ConnectionState.serving: [ConnectionState.closed],
  ConnectionState.closed: [ConnectionState.backoff, ConnectionState.idle],
  ConnectionState.backoff: [ConnectionState.connecting, ConnectionState.idle],
};

/// 非法迁移。
class IllegalTransitionError implements Exception {
  IllegalTransitionError(this.from, this.to);

  final ConnectionState from;
  final ConnectionState to;

  @override
  String toString() {
    final allowed = _transitions[from]!.map((s) => s.name).join(', ');
    return '非法的连接状态迁移：${from.name} → ${to.name}（允许的去向：${allowed.isEmpty ? '无' : allowed}）';
  }
}

/// 连接状态机。**不碰 I/O、不碰定时器**：它只回答「现在能不能去那个状态」。
class ConnectionMachine {
  ConnectionMachine([this._state = ConnectionState.idle]);

  ConnectionState _state;
  final List<void Function(ConnectionState from, ConnectionState to)>
  _listeners = [];

  /// 当前状态。
  ConnectionState get state => _state;

  /// 迁移；非法则抛 [IllegalTransitionError]。
  void to(ConnectionState next) {
    if (!_transitions[_state]!.contains(next)) {
      throw IllegalTransitionError(_state, next);
    }
    final from = _state;
    _state = next;
    // 复制一份再遍历：监听器里取消订阅是常见写法，直接遍历会在并发修改上抛。
    for (final listener in List.of(_listeners)) {
      listener(from, next);
    }
  }

  /// 当前是否处于其中之一。
  ///
  /// 名字不叫 `is`：那是 Dart 的保留字（电脑侧 TS 的 `is(...)` 在这里必须换名）。
  bool isAnyOf(List<ConnectionState> states) => states.contains(_state);

  /// 收到帧时是否合法（契约 §2.2：未完成握手的连接只接受握手帧与配对帧）。
  ///
  /// 做成状态机的一个查询，而不是散在对端的 `if` 里 —— 那是**攻击面**
  /// （密钥还没协商好就塞业务数据），值得一个能被测试直接点名的判据。
  bool get acceptsBusinessFrames => _state == ConnectionState.serving;

  /// 订阅迁移（日志与指标用）。返回取消订阅。
  void Function() onChange(
    void Function(ConnectionState from, ConnectionState to) listener,
  ) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}

/// 首次退避（毫秒）。
const int backoffBaseMs = 1000;

/// 退避上界（毫秒）。上界是"回到前台能快速恢复"的保证。
const int backoffMaxMs = 30000;

/// 抖动幅度：±20%。
const double backoffJitter = 0.2;

/// 重连退避（契约 §2.2、§10）。
///
/// `1s → 2s → 4s → … → 30s` 封顶，**抖动 ±20%**。两个取值各有依据：
/// 指数是为了避免惊群；30 s 上界是为了「回到前台能快速恢复」。
///
/// 抖动**必须真的随机**：多台设备同时掉线时，固定间隔会让它们排着队在同一毫秒重连。
/// 所以 [random] 是注入的 —— 测试里给确定值，生产里给 `Random()`。
///
/// 另一条纪律在调用方：**只在 App 前台重连**；切后台要主动断开并停表（§2.2）。
/// 本类不判断前台态，只负责「下一次该等多久」。
class Backoff {
  Backoff({double Function()? random}) : _random = random ?? _defaultRandom;

  final double Function() _random;
  int _attempt = 0;

  /// 生产用的随机源。
  ///
  /// 用 `dart:math` 的 [Random]（**不是**手写 LCG，也不是 `DateTime.now()` 播种）：
  /// 它是标准库、与平台无关（`core/` 只禁 `dart:io` 与 `package:flutter/*`），
  /// 而自造随机源会引入一个**隐藏的时钟依赖**，让测试结果随时钟漂移。
  /// 抖动只需要粗随机，不需要密码学质量 —— 后者由 `cryptography` 包负责。
  static final Random _defaultRng = Random();
  static double _defaultRandom() => _defaultRng.nextDouble();

  /// 第 n 次（0 起）的**未抖动**间隔：base * 2^n，封顶 max。
  static int _rawAt(int n) {
    // 先算指数再封顶：每一步都夹住上界，避免大 n 时溢出。
    var value = backoffBaseMs;
    for (var i = 0; i < n && value < backoffMaxMs; i += 1) {
      value *= 2;
    }
    return value < backoffMaxMs ? value : backoffMaxMs;
  }

  /// 取下一次退避时长并推进（含抖动）。
  int next() {
    final raw = _rawAt(_attempt);
    _attempt += 1;
    // `[0,1) → [-1,1)`，再乘幅度。抖动后仍夹住上界：上界不能被抖动顶破。
    final jitter = (_random() * 2 - 1) * backoffJitter;
    final value = (raw * (1 + jitter)).round();
    if (value < 0) return 0;
    return value > backoffMaxMs ? backoffMaxMs : value;
  }

  /// 回到起点。**连接成功进入 `serving` 后必须调用**，否则下次掉线会从上次的大间隔开始。
  void reset() => _attempt = 0;

  /// 已经连续失败多少次。
  int get attempt => _attempt;
}
