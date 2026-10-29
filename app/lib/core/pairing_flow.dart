/// 首配编排（契约 §12.1；规格 `docs/subsystems/pairing-v2.md` §5）。
///
/// ## 为什么分两段 —— 分段本身就是设计
///
/// ```text
/// beginPairing(…)         换票(候选) → 带票升级 → 受限握手     ← 秘密还没出去
///         ↓  把电脑身份给用户看，等用户点确认
/// attempt.commit(code)    发 pair-commit → 收 pair-result（设备令牌 + 辅助 SAS）
/// ```
///
/// v2 的硬不变量是「**用户确认前不发送秘密、不创建有效设备记录、不签发长期令牌**」。
/// 一个"一条道走到黑"的函数没有地方插进"用户确认"那一步，所以这里给出的是一个
/// 可以停在「通道已就绪、秘密未发」的对象。
///
/// ## 这条链上的失败，客户端动作完全不同
///
/// | 失败 | 客户端该做什么 |
/// |---|---|
/// | 换票 409（邀请过期 / 已被认领） | 让电脑**重新出码**（不是"网络错误"） |
/// | 换票 426（旧版明文配对） | 二维码是 v1：在电脑上升级后重新出码 |
/// | 升级失败 / 握手不过 | 电脑不在线，或被替换 —— 检查网络与二维码 |
/// | `pair-result` 里 `ok:false` | 原样显示电脑侧给的原因（"配对码已过期"） |
/// | 回执丢失（超时 / 断开） | **结果待确认**：断开不等于写入回滚，不能报"没配对过" |
///
/// 前四种都能在纯 Dart 单测里构造（HTTP 与传输都是注入的缝），所以"用户该做什么"
/// 这件事有断言盯着，而不是靠真机上试出来。
///
/// ## 依赖方向
///
/// `ui/` 调它；它调 `core/pairing_client.dart`（HTTP 缝）、`core/pairing_channel.dart`
/// （协议）与装配层注入的 [PairingTransportFactory]（真实 socket）。
library;

import 'crypto.dart';
import 'endpoint.dart';
import 'pairing.dart';
import 'pairing_channel.dart';
import 'pairing_client.dart';
import 'pairing_exchange.dart';
import 'transport.dart';

/// 建一条**已带票**的传输（`<根>/ws/device?ticket=…`）。
///
/// 缝设在"URL 已拼好"这一层，于是本文件不需要认识 WebSocket，而装配层不需要认识协议。
typedef PairingTransportFactory = ChannelTransport Function(String upgradeUrl);

/// 「受限通道已就绪、秘密尚未发出」的那一步。
class PairingAttempt {
  PairingAttempt({
    required this.offer,
    required this.identity,
    required this.candidate,
    required this.devId,
    required PairingChannel channel,
  }) : _channel = channel;

  final PairingOffer offer;
  final IdentityKeys identity;

  /// 本机作为候选的自报身份（电脑侧只认握手时的那一份，不认提交载荷里的自报）。
  final PairingCandidate candidate;

  /// 电脑侧会用的设备 id（`hello` 里带的那个）。
  final String devId;

  final PairingChannel _channel;

  /// 提交配对码并取回执。**用完即关**：配对是短交互，之后 App 会用正式传输重新连。
  ///
  /// [code] 默认取二维码里那个 —— 只有测试才会传别的值（那是"提交错码"的场景）。
  /// [previousPairingId] 是本机上一次配对的标识（重新配对同一台电脑时带上）：
  /// 电脑侧据此替换旧行而不是又攒一行。**行定位符，不是凭据** —— 见
  /// `pairing_channel.dart` 的 `commit` 与
  /// `.agents/notes/implemented/2026-10-17-repair-replaces-device-row.md`。
  Future<PairingAck> commit({String? code, String? previousPairingId}) async {
    try {
      return await _channel.commit(
        code ?? offer.code,
        previousPairingId: previousPairingId,
      );
    } finally {
      await _channel.close();
    }
  }

  /// 用户放弃：关掉这条短连接（电脑侧那半条会跟着关，候选不留痕）。
  Future<void> cancel() => _channel.close();
}

/// 第一段：换票 → 带票升级 → 受限握手。
///
/// **不发送秘密、不创建有效设备记录、不签发任何令牌** —— 那三件事都发生在
/// [PairingAttempt.commit]。
Future<PairingAttempt> beginPairing({
  required PairingOffer offer,
  required IdentityKeys identity,
  required String deviceName,
  required HttpSender send,
  required PairingTransportFactory transportFor,
  void Function(String stage)? onStage,
  String Function()? newFrameIdHex,
  String Function()? newEphemeralSeedHex,
  String Function()? newNonceHex,
  Duration handshakeTimeout = pairingHandshakeTimeout,
  bool allowInsecureLocal = false,

  /// 公网明文（用户自部署中转）：由配对页"看过电脑身份并确认"的那一步传 true。
  bool allowInsecurePublic = false,
}) async {
  final candidate = offer.candidate(identity, deviceName);
  final devId = await candidate.deviceId();

  onStage?.call('换票…');
  // 首配这一跳**没有令牌**：凭据就是公开邀请 + 候选公钥。这一条是整条链能起步的原因
  // —— 换票要设备令牌，而设备令牌是配对的产物，那会成环。
  //
  // `allowInsecureLocal` 一路透到地址边界（`core/endpoint.dart`）：默认只认 WSS，
  // 明文分两档 —— 非公网（局域网/组网）与**用户确认过的公网自部署中转**。
  final ticket = await PairingClient(
    relayUrl: offer.relayUrl,
    send: send,
    allowInsecureLocal: allowInsecureLocal,
    allowInsecurePublic: allowInsecurePublic,
  ).ticketByOffer(candidate);

  onStage?.call('连接电脑…');
  final channel = PairingChannel(
    transport: transportFor(deviceUpgradeUrl(offer.relayUrl, ticket.ticket)),
    offer: offer,
    identity: identity,
    candidate: candidate,
    devId: devId,
    newFrameIdHex: newFrameIdHex,
    newEphemeralSeedHex: newEphemeralSeedHex,
    newNonceHex: newNonceHex,
    handshakeTimeout: handshakeTimeout,
  );
  await channel.open();

  onStage?.call('等待你确认');
  return PairingAttempt(
    offer: offer,
    identity: identity,
    candidate: candidate,
    devId: devId,
    channel: channel,
  );
}
