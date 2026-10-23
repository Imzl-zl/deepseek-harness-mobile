/// 心跳与半开检测（契约 §2.2、§9、§10）。
///
/// 两条规则：
///
/// 1. **仅在前台且连接空闲时每 60 s 发一次心跳**；任一方向有帧时不额外发，切后台即停
///    （§9）。60 s 这个值的依据是 RFC 5382 REQ-5 与 SIGCOMM 2011 的运营商级实测对照。
/// 2. **半开判据：`serving` 期间任一方向连续 2 个心跳周期无任何帧 → 视为断开，重连**
///    （§2.2）。TCP 半开连接不会报错 —— 写进去没人管、也没有 FIN，只有靠这个判据发现，
///    否则用户会看到「连着但什么都收不到」。
///
/// **时间一律由调用方传入**（`onFrame(now)` / `tick(now)`），本类既不读时钟也不起定时器。
/// 「上一次有帧是什么时候」必须是**真收到帧的那一刻**，不能用「上一次 tick 的时刻」代替 ——
/// 后者会把空闲计时系统性地推迟一整个 tick 周期，而半开判据正是拿它做阈值的。
///
/// 移植源：`connector/src/transport/keepalive.ts`（行为基准）。
library;

/// 心跳周期（毫秒）。
const int heartbeatMs = 60000;

/// 连续多少个心跳周期没有任何帧就判半开。
const int halfOpenPeriods = 2;

/// 一次 tick 的判定结果。
sealed class KeepaliveAction {
  const KeepaliveAction();
}

/// 什么都不做。
class KeepaliveIdle extends KeepaliveAction {
  const KeepaliveIdle();
}

/// 该发一次心跳。
class KeepalivePing extends KeepaliveAction {
  const KeepalivePing();
}

/// 判定为半开，调用方应关闭并重连。
class KeepaliveHalfOpen extends KeepaliveAction {
  const KeepaliveHalfOpen(this.silentMs);

  /// 已经沉默多久（用于日志与指标）。
  final int silentMs;
}

/// 心跳与半开判定。
class Keepalive {
  Keepalive({int? startedAt, int? heartbeat, int? periods})
    : _heartbeatMs = heartbeat ?? heartbeatMs,
      _periods = periods ?? halfOpenPeriods,
      _lastFrameAt = startedAt {
    _halfOpenAfterMs = _heartbeatMs * _periods;
  }

  final int _heartbeatMs;
  final int _periods;
  late final int _halfOpenAfterMs;

  int? _lastFrameAt;

  /// 已经发过心跳、还没等到任何帧 —— 避免同一个空闲期反复发 `ping`。
  bool _pingedInThisIdle = false;

  /// 收到或发出**任何**帧时调用，带上当时的时间。
  void onFrame(int now) {
    _lastFrameAt = now;
    _pingedInThisIdle = false;
  }

  /// 周期性调用（真实时钟驱动，间隔自定；判定只依赖传入的 `now`）。
  KeepaliveAction tick(int now) {
    // 第一次 tick 之前没有任何帧：以这次为基准，而不是把"启动到现在"算成沉默。
    _lastFrameAt ??= now;
    final silent = now - _lastFrameAt!;

    if (silent >= _halfOpenAfterMs) return KeepaliveHalfOpen(silent);

    if (silent < _heartbeatMs || _pingedInThisIdle) {
      return const KeepaliveIdle();
    }

    // 心跳本身是我们**发出**的一帧，所以它重置空闲计时 —— 否则会在对端还没回 pong
    // 之前就自己判半开。同时记下"这个空闲期已经 ping 过"，避免每 tick 都发。
    _pingedInThisIdle = true;
    _lastFrameAt = now;
    return const KeepalivePing();
  }

  // **没有 `setForeground`**：心跳不分前后台（契约 §9）。后台连接是否维持由
  // "前台服务活着"那一条决定（§13 的安卓例外），不是靠"后台别发心跳"。

  /// 距离上一次帧过了多久。
  int silentFor(int now) => _lastFrameAt == null ? 0 : now - _lastFrameAt!;

  /// 半开阈值（毫秒）。自检与测试用。
  int get halfOpenAfterMs => _halfOpenAfterMs;
}
