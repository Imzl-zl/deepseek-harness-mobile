/// 连接与订阅的唯一 owner（契约 §2.2、§5、§7）。
///
/// ## 为什么必须"一个 owner"
///
/// 连接、订阅、恢复、流控全部由本类持有，UI 只订阅它暴露的流 —— **不存在第二处重连逻辑**。
/// 分成两处（比如"网络层自己重连、页面层也重连"）必然导致两条连接同时存在，
/// 而症状是"有时候收到两次、有时候一条都收不到"，在真机上几乎无法归因。
///
/// ## 本层只做"接线"，不重新实现任何判据
///
/// 每个判据都已经在别处被单独测过，这里只负责按契约把它们接起来：
///
/// | 判据 | 出处 |
/// |---|---|
/// | 状态迁移白名单 | `connection.dart` 的 `ConnectionMachine` |
/// | 退避与抖动 | `connection.dart` 的 `Backoff` |
/// | 心跳与半开 | `keepalive.dart` 的 `Keepalive` |
/// | 握手三帧 | `handshake.dart` + `handshake_driver.dart` |
/// | 封箱与解箱 | `box.dart` |
/// | 流控窗口 | `flow.dart` 的 `SendWindow` |
/// | 恢复判定与拼接 | `recovery.dart` 的 `DeviceSession` |
/// | 写操作幂等 | `outbox.dart` |
///
/// 这一层如果自己再写一遍某个判据，就会出现**两个来源** —— 而那正是本项目反复抓到的
/// 一类 bug（见 `tools.md` 的 Pitfalls）。
library;

import 'dart:async';

import 'box.dart';
import 'connection.dart';
import 'crypto.dart';
import 'errors.dart';
import 'handshake_driver.dart';
import 'items.dart';
import 'keepalive.dart';
import 'outbox.dart';
import 'recovery.dart';
import 'transport.dart';

/// App 前后台状态（契约 §2.2、§9）。
///
/// **它决定两件事**：要不要维持连接（后台主动断开并停表）、要不要发心跳。
enum AppState {
  /// 前台：维持连接、发心跳、可重连。
  foreground,

  /// 后台：主动断开、停表、不发心跳（三端都不做后台长连接，见契约 §13）。
  background,
}

/// `SyncClient` 的对外面（`app-channel-client.md` §2 的签名级契约）。
abstract interface class SyncClient {
  /// 开始连接（`idle → connecting`）。**幂等**：已在连接中或已服务时不重复建。
  ///
  /// 与 [setAppState] 分开是刻意的：装配点决定"何时开始"，前台/后台决定"要不要维持"。
  /// 两者合成一个入口的话，"切后台再回前台"与"首次启动"会走同一条路，
  /// 而它们该做的事不同（前者要重连，后者要建连）。
  Future<void> start();

  /// 连接状态流（`idle` / `connecting` / `handshaking` / `serving` / `backoff`）。
  ///
  /// 它是**广播**流：UI 的多个部件都要看连接状态，而单订阅流会让第二个监听者抛错。
  Stream<ConnectionState> get connection;

  /// 某会话的条目更新（增量与快照收口都从这里出）。
  Stream<SessionDelta> sessionUpdates(String sid);

  /// 订阅一个会话。
  ///
  /// [since] 是手机手里的水位（本地库的落盘水位）。电脑侧据此决定给增量还是快照。
  Future<void> subscribe(String sid, {required int since});

  /// 退订一个会话。
  Future<void> unsubscribe(String sid);

  /// 调一个方法（契约 §5.7 的封闭集）。
  ///
  /// [requestId] 是幂等键：带它的调用**先落盘再发送**（§5.6）；不带它的走即时请求
  /// （只读方法不需要幂等）。
  Future<T> call<T>(
    String method,
    Map<String, Object?> params, {
    String? requestId,
  });

  /// 前后台切换。
  Future<void> setAppState(AppState state);

  /// 当前连接状态（同步读，UI 首帧用）。
  ConnectionState get state;

  /// 关闭（释放定时器与连接）。**幂等**。
  Future<void> close();
}

/// 诊断面：**不参与产品逻辑**，只给测试与日志用。
///
/// 单独一个接口而不是塞进 [SyncClient]：UI 不该看到"收到的配对帧列表"这种东西
/// （它会诱使界面层自己解析帧，而那正是分层要防的）。测试按需转成这个类型。
abstract interface class SyncClientProbe {
  /// 收到的配对帧（配对页读它）。
  List<Map<String, Object?>> get pairingFrames;

  /// 收到的任务输出帧（`(帧头, 明文)`）。
  List<(Map<String, Object?>, String)> get jobFrames;

  /// 收到的 `presence` 帧。
  List<Map<String, Object?>> get presenceFrames;

  /// 最后一次协议错误。
  ProtocolException? get lastProtocolError;

  /// 判定为半开时已沉默多久；没判过是 `null`。
  int? get lastHalfOpenSilentMs;

  /// 当前在途请求数（UI 可据此显示"正在等待应答"）。
  int get pendingCalls;

  /// 上一次连接收口时被拒绝的在途请求数；没收口过是 `null`。
  ///
  /// 它值得暴露：**被拒绝的请求数是"这次断连伤到了什么"的唯一证据**。
  /// 没有它，一次断连只留下"连接状态变了"，而"有几个请求被取消"无从得知。
  int? get lastRejectedCalls;
}

/// 一次会话更新（`sessionUpdates` 的元素）。
class SessionDelta {
  const SessionDelta({
    required this.sid,
    required this.items,
    required this.transient,
    this.outcome,
    this.reason,
  });

  final String sid;

  /// 这一批变化的条目（增量：新到的那几条；快照收口：整表）。
  final List<ItemRecord> items;

  /// 瞬时事实（不变量 I4：每次恢复都无条件回带）。
  final TransientFacts transient;

  /// 这次更新的来源（`delta` / `snapshot`）；快照分页的中间页不出流。
  final RecoveryOutcome? outcome;

  /// 快照原因（仅 `outcome == snapshot` 时有）。
  final SnapshotReason? reason;
}

/// `SyncClient` 需要的一切。全部注入，所以它可以脱离真机测试。
class SyncClientDeps {
  const SyncClientDeps({
    required this.transport,
    required this.handshake,
    required this.box,
    required this.outbox,
    required this.session,
    this.keepalive,
    this.backoff,
    this.now,
    this.schedule,
    this.newId,
  });

  /// 传输缝（真实 WSS 或测试替身）。
  final ChannelTransport transport;

  /// 握手驱动器（**发起方** = 手机）。
  final HandshakeDriver handshake;

  /// 封箱/解箱（每连接一把密钥）。
  final BoxCodec Function(SessionKeys keys) box;

  /// 写操作队列。
  final Outbox outbox;

  /// 本地会话状态（接收规则、快照拼接、水位）。
  final DeviceSession session;

  /// 心跳与半开判定。不给则用默认周期。
  final Keepalive? keepalive;

  /// 退避。不给则用默认（生产随机源）。
  final Backoff? backoff;

  /// 时钟（毫秒）。注入以便测试确定化。
  final int Function()? now;

  /// `setTimeout` 语义。**调用它得到取消函数**（`schedule(fn, ms)()` 取消）。
  ///
  /// 注入以便测试用假定时器在毫秒内跑完"退避 30 s"这类场景 —— 真的等 30 s
  /// 会让这组测试慢到没人跑。
  final void Function() Function(void Function() fn, int ms)? schedule;

  /// 生成帧 `id`。注入以便测试确定化。
  final String Function()? newId;
}
