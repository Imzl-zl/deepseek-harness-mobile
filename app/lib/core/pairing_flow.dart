/// 首配编排（契约 §12.1；规格 `docs/subsystems/pairing-v2.md` §5）。
///
/// ## 为什么分两段 —— 分段本身就是设计
///
/// ```text
/// beginPairing(…)         局域网直连 → 受限握手
///                          （载荷没有局域网地址 / 全拨不通时）换票(候选) → 带票升级 → 受限握手
///         ↓  把电脑身份给用户看，等用户点确认      ← 秘密还没出去
/// attempt.commit(code)    发 pair-commit → 收 pair-result（设备令牌 + 辅助 SAS）
/// ```
///
/// v2 的硬不变量是「**用户确认前不发送秘密、不创建有效设备记录、不签发长期令牌**」。
/// 一个"一条道走到黑"的函数没有地方插进"用户确认"那一步，所以这里给出的是一个
/// 可以停在「通道已就绪、秘密未发」的对象。
///
/// ## 两条路，同一套帧
///
/// 局域网那条路**不经过中转**：二维码里带着电脑的 `ws://<ip>:<port>`，手机直接拨过去
/// （`pairingDialUrl`），握手与提交帧一个字节都不用改 —— 它们本来就与传输无关。
/// 中转只在"跨网 / 没有局域网"时才需要。
///
/// 顺序是**先局域网、全拨不通才回落中转**：同一 WiFi 下直连是毫秒级且不依赖任何服务器，
/// 而中转要多一次 HTTP 换票 + 一条公网往返。反过来（先中转）会让"中转没开"直接变成
/// 配对失败，尽管手机和电脑就在同一张桌子上。用户可以在设置里把顺序改成
/// `中转优先`（`device.pairing_prefer`）；**改了顺序也不改回落**，而且默认只在
/// "本机与某张局域网地址在同一 /24"时才直连优先（见 [PairingPreference]）。
///
// Note: 为什么先局域网、为什么全不通才回落 —— 见
// `.agents/notes/implemented/2026-11-03-pairing-without-relay.md`；
// 为什么降级标与拨号顺序偏好要显式 —— 见
// `.agents/notes/implemented/2026-11-04-pairing-degradation-is-visible.md`。
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
import 'errors.dart';
import 'pairing.dart';
import 'pairing_channel.dart';
import 'pairing_client.dart';
import 'pairing_exchange.dart';
import 'transport.dart';

/// 建一条**已经拼好地址**的传输（中转那条是 `<根>/ws/device?ticket=…`，
/// 局域网那条是 `<lan>?pair=…&cand=…`）。
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
    required this.dial,
    required this.dialUrl,
    required PairingChannel channel,
  }) : _channel = channel;

  final PairingOffer offer;
  final IdentityKeys identity;

  /// 本机作为候选的自报身份（电脑侧只认握手时的那一份，不认提交载荷里的自报）。
  final PairingCandidate candidate;

  /// 电脑侧会用的设备 id（`hello` 里带的那个）。
  final String devId;

  /// 这条受限通道**实际走的是哪条路**。
  ///
  /// 确认卡要如实说出来：走局域网却写"中转"，会让人以为中转必须开着。
  final PairingDial dial;

  /// 给人看的地址：局域网那条就是它的 `ws://` 地址；中转那条是**根地址**
  /// （拨号地址里带着一次性票，绝不往界面上放）。
  final String dialUrl;

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

/// 配对通道实际走的那条路（确认卡据此说清"怎么连上的"）。
enum PairingDial {
  /// 局域网直连（二维码里的 `lan`，不经过中转）。
  lan,

  /// 中转（换票 → 带票升级）。
  relay,
}

/// 拨号顺序偏好（设备本地设置 `device.pairing_prefer`，默认 [auto]）。
///
/// **只影响先试哪条，失败仍然回落**：三条路都还会被试到，没有"选了直连就永远不试中转"
/// 这回事 —— 否则一次网络切换就会让一张好好的码配不上。
///
/// - [auto]：知道本机 IP、且码里有一张局域网地址在同一 /24 时先直连；否则**先中转**
///   （出门在外不该先为一张局域网地址白等一个超时）。
/// - [direct]：永远先试局域网直连。
/// - [relay]：永远先试中转。
///
// Note: 为什么默认自动、为什么失败必须回落 —— 见
// `.agents/notes/implemented/2026-11-04-pairing-degradation-is-visible.md`
enum PairingPreference {
  auto('自动', 'auto'),
  direct('直连优先', 'direct'),
  relay('中转优先', 'relay');

  const PairingPreference(this.label, this.wire);

  /// 设置页那一行显示的名字。
  final String label;

  /// 线上值（落盘用，`device.pairing_prefer`）。
  final String wire;

  /// 认不出回 `null`（调用方保持默认，不猜）。
  static PairingPreference? fromWire(Object? raw) {
    if (raw is! String) return null;
    for (final value in values) {
      if (value.wire == raw) return value;
    }
    return null;
  }
}

/// 第一段：局域网直连（拨不通则回落换票 → 带票升级）→ 受限握手。
///
/// **不发送秘密、不创建有效设备记录、不签发任何令牌** —— 那三件事都发生在
/// [PairingAttempt.commit]。
///
/// [myIpv4] 只影响**顺序**（同一 /24 的那条先拨，见 `dialOrder`）；拿不到就按电脑侧
/// 给的顺序拨，不猜。[prefer] 也只影响顺序（见 [PairingPreference]）。
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

  /// 本机当前的局域网 IPv4（`platform/lan_address.dart`）；只用于排序。
  String? myIpv4,

  /// 先试哪条路；失败仍回落（见 [PairingPreference]）。
  PairingPreference prefer = PairingPreference.auto,
}) async {
  final candidate = offer.candidate(identity, deviceName);
  final devId = await candidate.deviceId();

  /// 造一条受限通道。**两条路共用**：帧序列、密钥派生、超时全都一样，
  /// 差别只有"往哪拨"。
  PairingChannel channelFor(String upgradeUrl) => PairingChannel(
    transport: transportFor(upgradeUrl),
    offer: offer,
    identity: identity,
    candidate: candidate,
    devId: devId,
    newFrameIdHex: newFrameIdHex,
    newEphemeralSeedHex: newEphemeralSeedHex,
    newNonceHex: newNonceHex,
    handshakeTimeout: handshakeTimeout,
  );

  PairingAttempt attemptFor(
    PairingChannel channel,
    PairingDial dial,
    String dialUrl,
  ) => PairingAttempt(
    offer: offer,
    identity: identity,
    candidate: candidate,
    devId: devId,
    dial: dial,
    dialUrl: dialUrl,
    channel: channel,
  );

  // ---- ① 局域网直连（不需要中转）----
  //
  // 地址来自二维码的 `lan`：电脑自己持有这次 offer、自己也听得见这个端口，
  // 所以"保管邀请"与"通知有候选"这两件事在局域网上都不需要服务器。
  final lanFailures = <String>[];
  Future<PairingAttempt?> tryLan() async {
    for (final endpoint in dialOrder([
      for (final url in offer.lanUrls)
        Endpoint(kind: EndpointKind.direct, url: url),
    ], myIpv4: myIpv4)) {
      onStage?.call('局域网直连…');
      final channel = channelFor(pairingDialUrl(endpoint.url, candidate));
      try {
        await channel.open();
        onStage?.call('等待你确认');
        return attemptFor(channel, PairingDial.lan, endpoint.url);
      } catch (error) {
        // 这一条不通：收干净再试下一条（半开的 socket 留着只会占端口与超时预算）。
        await channel.close();
        lanFailures.add('${endpoint.url}：$error');
      }
    }
    return null;
  }

  // ---- ② 中转（跨网 / 没有局域网地址 / 局域网全拨不通）----
  Future<PairingAttempt> tryRelay() async {
    onStage?.call(lanFailures.isEmpty ? '换票…' : '局域网没通，改用中转…');
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
    final channel = channelFor(deviceUpgradeUrl(offer.relayUrl, ticket.ticket));
    await channel.open();

    onStage?.call('等待你确认');
    return attemptFor(channel, PairingDial.relay, offer.relayUrl);
  }

  // 降级码（`lanOnly`）：中转那条腿这次**不存在** —— 不去换票（注定 409），
  // 也不把失败说成"请让电脑重新出码"。原因只能是"不在同一个 WiFi"。
  if (offer.lanOnly) {
    final attempt = await tryLan();
    if (attempt != null) return attempt;
    throw TransportException(
      '这张码只能在同一 WiFi 下使用（出码时没登记上中转），局域网直连也没通'
      '（${lanFailures.length} 个地址）：${lanFailures.isEmpty ? '没有可拨的局域网地址' : lanFailures.last}',
    );
  }

  // 顺序：显式偏好优先；`auto` 只在"本机 IP 与某张局域网地址在同一 /24"时才直连优先。
  // 拿不到本机 IP 时保持旧行为（先直连）—— 不猜。
  final autoPrefersDirect =
      offer.lanUrls.isEmpty ||
      myIpv4 == null ||
      offer.lanUrls.any((url) => sameSubnet(myIpv4, url));
  final directFirst =
      prefer == PairingPreference.direct ||
      (prefer == PairingPreference.auto && autoPrefersDirect);

  if (directFirst) {
    final lanAttempt = await tryLan();
    if (lanAttempt != null) return lanAttempt;
    try {
      return await tryRelay();
    } catch (error, stack) {
      // 局域网那几条失败过的话，**在原因前面点出来**：否则用户看到"请让电脑重新出码"，
      // 而真因是"手机不在那个 WiFi"。
      _rethrowWithLanNote(error, stack, lanFailures);
    }
  }

  // 中转优先：先换票；失败仍回落直连（"失败仍回落"是这条偏好的前提）。
  try {
    return await tryRelay();
  } catch (error, stack) {
    final lanAttempt = await tryLan();
    if (lanAttempt != null) return lanAttempt;
    // 两条都不通：以**中转那条原因**为准（它通常可照做：重新出码 / 检查网络），
    // 局域网失败只作为补充说明。
    _rethrowWithRelayNote(error, stack, lanFailures);
  }
}

/// 把"局域网也试过了"这件事加进最终错误里，**保留原错误码**（`clientAction` 靠它）。
Never _rethrowWithLanNote(
  Object error,
  StackTrace stack,
  List<String> failures,
) {
  if (failures.isEmpty) {
    Error.throwWithStackTrace(error, stack);
  }
  final prefix = '局域网直连没通（${failures.length} 个地址）；';
  if (error is ProtocolException) {
    Error.throwWithStackTrace(
      ProtocolException(error.code, '$prefix${error.message}'),
      stack,
    );
  }
  if (error is TransportException) {
    Error.throwWithStackTrace(
      TransportException('$prefix${error.message}', code: error.code),
      stack,
    );
  }
  Error.throwWithStackTrace(TransportException('$prefix中转也没通：$error'), stack);
}

/// 中转优先那一路的收尾：**保留中转的错误码**，前面补一句"局域网也没通"。
Never _rethrowWithRelayNote(
  Object error,
  StackTrace stack,
  List<String> failures,
) {
  final prefix = failures.isEmpty ? '' : '局域网直连也没通（${failures.length} 个地址）；';
  if (error is ProtocolException) {
    Error.throwWithStackTrace(
      ProtocolException(error.code, '$prefix${error.message}'),
      stack,
    );
  }
  if (error is TransportException) {
    Error.throwWithStackTrace(
      TransportException('$prefix${error.message}', code: error.code),
      stack,
    );
  }
  Error.throwWithStackTrace(TransportException('$prefix中转也没通：$error'), stack);
}
