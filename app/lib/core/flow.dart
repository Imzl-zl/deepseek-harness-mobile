/// 流控窗口（契约 §4.3）。
///
/// 发送方维护 `unacked`（已发但还没收到 `credit` 的帧数），上限 **W = 128**；
/// 达到上限即暂停发送。接收方**每收到一帧立即回 `credit { fc }`**（不要求落盘）。
///
/// **这一层是连接层信用，与会话层的落盘水位是两件事**（契约 §4.3 明写）：
/// - 流控要求即时反馈，所以 `credit` 收到帧就回、不等落盘；
/// - 落盘要求持久确认，用 `persisted { sid, seq }`，手机落盘后才发。
///
/// 混用一个 ack 会让两者互相拖累 —— 等 fsync 才能继续收帧。
///
/// 移植源：`connector/src/protocol/flow.ts`（行为基准）。
library;

import 'dart:convert';

import 'errors.dart';

/// 已发未 credit 的帧数上限（契约 §4.3）。
const int sendWindowFrames = 128;

/// 该帧是否占用流控额度。
///
/// `ping` / `pong` 不占：保活帧若占额度，满窗时双方都发不出 ping、也回不了 pong，
/// 会一起走进"半开检测 → 断开重连"的假故障。
bool consumesCredit(String type) => type != 'ping' && type != 'pong';

/// 满窗时该压住哪些帧。
///
/// **可补的三类**：`ev` 有重放窗口与快照兜底、`live` 会被持久事件替换、
/// `job` 可以按 `from` 重订。而 `res` 是对端在等的应答，`credit` / `persisted`
/// 是正确性依赖的水位 —— 压住它们会同时压住对方的推进（死锁）。
bool pausable(String type) => type == 'ev' || type == 'live' || type == 'job';

/// 收到这一帧之后要不要回 `credit`。
///
/// 只有 `credit` 自己例外：它是"我收到了"的确认，再确认它就变成两端互相刷 ack。
bool elicitsCredit(String type) => type != 'credit';

/// `credit` 的载荷（契约 §4.3）：**累计确认**"我已收到 `[0, ack]`"。
///
/// 它放在箱里而不是帧头：帧头的 `fc` 是发送方向自己的计数器（nonce 与重放防护的
/// 来源），而 `ack` 说的是对端的计数器 —— 同一个字段不能有两个意思。
/// 顺带把伪造也堵住：不经认证的 ack 能让对端误以为窗口已放开。
String encodeCredit(int ack) => jsonEncode(<String, Object?>{'ack': ack});

/// 解 `credit` 载荷。坏值抛 `protocol/bad-frame`（对端发了个读不懂的 ack）。
int decodeCredit(String box) {
  final Object? parsed;
  try {
    parsed = jsonDecode(box);
  } catch (error) {
    throw ProtocolException(ErrorCode.badFrame, 'credit 载荷不是合法 JSON：$error');
  }
  final ack = parsed is Map ? parsed['ack'] : null;
  if (ack is! int || ack < 0) {
    throw ProtocolException(ErrorCode.badFrame, 'credit.ack 必须是非负整数，收到 $ack');
  }
  return ack;
}

/// 发送窗口。
class SendWindow {
  SendWindow([this.limit = sendWindowFrames]);

  /// 已发未 credit 的帧数上限。
  final int limit;

  // credit 携带的是"我刚收到的那个 fc"，所以它确认的是 [0, creditedFc]。
  int _creditedFc = -1;
  int _sent = 0;

  int get _unackedNow {
    final value = _sent - (_creditedFc + 1);
    return value < 0 ? 0 : value;
  }

  /// 现在能不能发这一帧。
  ///
  /// 判定包含**优先级**：不占额度的帧（`ping` / `pong`）与不可暂停的帧
  /// （`req` / `res` / `credit` / `persisted`）恒为真 —— 窗口只压可补帧。
  bool canSend(String type) {
    if (!consumesCredit(type)) return true;
    // 只压可补帧：压住 `res` / `credit` / `persisted` 会让对端等一个永远不会来的应答。
    if (!pausable(type)) return true;
    return _unackedNow < limit;
  }

  /// 记一帧**真的发出去了**（调用方只在发出去之后调）。
  void onSent(int fc, String type) {
    if (!consumesCredit(type)) return;
    final next = fc + 1;
    if (next > _sent) _sent = next;
  }

  /// 收到对端的 `credit { fc }`。
  void onCredit(int fc) {
    // 只前进不后退：乱序或迟到的 credit 不该把窗口"放大"回一个已确认过的状态。
    if (fc > _creditedFc) _creditedFc = fc;
  }

  /// 已发未 credit 的帧数。
  int get unacked => _unackedNow;
}
