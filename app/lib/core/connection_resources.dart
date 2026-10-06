/// **每连接**的资源束（契约 §4.2）：一条 socket 一份，断开即作废。
///
/// ## 为什么要有这个类（先量再下）
///
/// 这六件东西的生命周期**完全相同** —— 每次建连各换一份、每次断开各作废一份：
///
/// | 字段 | 为什么必须每连接一份 |
/// |---|---|
/// | `box` | 每连接换密钥（§4.2）；复用上一把会让 nonce 重用 ⇒ 破 AEAD |
/// | `handshake` | 每连接新生成临时密钥（§4.1）；复用会让 `fc` 从 0 重数 |
/// | `subscription` | 订阅的是**这条 socket** 的事件流 |
/// | `counter` | `fc` 是 nonce 来源，新连接从 0 重数（§4.2） |
/// | `window` | 流控额度随 `fc` 归零（§4.3） |
/// | `splitter` | 半行缓冲属于这条 socket；跨连接留用会把两帧拼成一帧 |
///
/// 实测：这六项在 `_connect()` 与 `_enterClosed()` 里**各写一遍同一个清单**
/// （33 处引用）。两份清单迟早不一致，而漏掉任何一项都是**静默 bug** ——
/// 漏 `box` 会让新连接用旧密钥（表现为"解不开"），漏 `splitter` 会把两条连接的
/// 字节拼在一起（表现为"偶尔收到一帧乱码"）。收成一个对象后，"建一份"与"作废一份"
/// 各只有一处。
///
/// ## 它不是"状态机"
///
/// 本类**不做判定**（`ConnectionMachine` 管那个），只是**一组同生共死的字段**
/// 加上它们的构造与作废。所以它没有 `isServing()` 之类的方法 ——
/// 那些问题该问状态机，不该问资源束。
library;

import 'dart:async';

import 'box.dart';
import 'crypto.dart';
import 'flow.dart';
import 'frame.dart';
import 'handshake_driver.dart';
import 'transport.dart';

/// 一条连接上的资源。**建一份 → 用 → 作废**，不跨连接复用。
class ConnectionResources {
  ConnectionResources();

  BoxCodec? _box;
  HandshakeSession? _handshake;
  StreamSubscription<TransportEvent>? _subscription;

  /// `fc` 计数器与流控窗口。
  SendCounter _counter = SendCounter();
  SendWindow _window = SendWindow();

  /// 行分帧器（半行缓冲属于这条 socket）。
  LineSplitter _splitter = LineSplitter();

  /// 会话密钥的封箱器。`null` = 握手还没完成（那时一帧业务帧都不该发）。
  BoxCodec? get box => _box;

  /// 握手会话。`null` = 还没进握手（或已作废）。
  HandshakeSession? get handshake => _handshake;

  /// 收帧的订阅。
  StreamSubscription<TransportEvent>? get subscription => _subscription;

  /// 已发未确认的帧数（诊断面）。
  int get unacked => _window.unacked;

  /// 现在能不能发这一帧（§4.3 的窗口判定）。
  ///
  /// 注意：手机侧目前**只发 `req` / `res` / `credit` / `persisted` / `ping`**，
  /// 而它们都不是"可暂停"的（§4.3 只压 `ev` / `live` / `job`）—— 所以这个判定
  /// 在手机侧恒为 `true`。保留它是因为契约 §4.3 是**双向**的：
  /// 将来手机要发 `job` 控制帧（或本地回放 `ev`）时，窗口就该起作用了。
  bool canSend(String type) => _window.canSend(type);

  /// 装上手握会话（进握手态时调）。
  void attachHandshake(HandshakeSession session) => _handshake = session;

  /// 装上收帧订阅。
  void attachSubscription(StreamSubscription<TransportEvent> subscription) =>
      _subscription = subscription;

  /// 装上会话密钥的封箱器。**必须在进 `serving` 之前调**：
  /// 顺序反了就会有一小段"已在服务但发不出帧"的窗口（§4.1）。
  void attachBox(BoxCodec codec) => _box = codec;

  /// 取下一个 `fc`（**nonce 来源**：只能在这里分配，见 `box.dart` 的说明）。
  int nextFc() => _counter.next();

  /// 记一帧**真的发出去了**（窗口算的是"已发未确认"，不是"打算发"）。
  void onSent(int fc, String type) => _window.onSent(fc, type);

  /// 收到对端的 `credit`：返回窗口是否**因此松开**（调用方据此唤醒等待者）。
  bool onCredit(int ack) {
    final before = _window.unacked;
    _window.onCredit(ack);
    return _window.unacked < before;
  }

  /// 喂一片数据，返回其中的完整行（拼行规则见 `frame.dart`）。
  List<String> split(String chunk) => _splitter(chunk);

  /// **作废这一份资源**（断开时调）。**同步**，且必须同步。
  ///
  /// 六项一次性清掉，不留给下一条连接 —— 这就是本类存在的理由：
  /// "建一份"与"作废一份"各只有一处，不会漏。
  ///
  /// ## 为什么是同步的（这一条被测试逼出来过）
  ///
  /// 最初这里写成 `Future<void>` 并 `await subscription.cancel()`，结果是：
  /// **"资源已死"与"状态已 closed"之间多了一个 `await` 窗口**。
  /// 后果不是崩溃，而是**时序漂移** —— 收口路径（对端断开、半开、协议失败）
  /// 全都在事件回调里，任何一条都可能在那个窗口里被再次触发，
  /// 于是退避计时器的起点跟着漂（实测：一条重连用例因此失败）。
  ///
  /// 关键认识：`cancel()` **返回的 Future 只表示"清理完成"，不表示"还会收事件"** ——
  /// 调用 `cancel()` 的那一刻起事件就不再投递了。所以这里不需要等它，
  /// 与电脑侧 `unawaited(...)` 的写法同一个理由。
  void dispose() {
    _handshake?.dispose();
    _handshake = null;
    _box = null;
    final subscription = _subscription;
    _subscription = null;
    // 新一份（空的分帧器/计数器/窗口）：`fc` 从 0 重数，半行缓冲不留。
    _splitter = LineSplitter();
    _counter = SendCounter();
    _window = SendWindow();
    // 取消订阅：不等它（见上）。错误吞掉 —— 断开路径不该因为清理失败而抛。
    if (subscription != null) {
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
  }
}
