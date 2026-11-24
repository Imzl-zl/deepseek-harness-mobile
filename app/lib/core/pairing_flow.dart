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
/// 配对失败，尽管手机和电脑就在同一张桌子上。
///
/// ## 局域网那一窝候选：一起拨，只报一句话
///
/// 电脑侧现在报的是"此刻枚举到的**全部**局域网 IPv4"（WiFi / 以太网 / 虚拟网卡各一条），
/// 而配对只需要其中一条成功。所以那几条**同时发起**受限握手、先通者胜、其余当场收掉
/// （2026-11-24；同一条纪律见 `core/endpoint_transport.dart` 的拨号竞速）。
/// 全灭时对外只有**一句话**（试了几个地址 + 用户该做什么）—— 逐条拼地址与原始错误
/// 只会刷成一屏红字，而用户能做的动作只有一个。中转那条腿仍然自己说自己不通的原因。
///
/// 先试哪条由**设备级策略** `RoutePolicy` 决定（`model/route_policy.dart`），
/// 与"连上之后走哪条"共用同一个设置。`auto` 下"码里有局域网地址就先试它" ——
/// 那是电脑**出码时**给出的现证，不再用手机 IP 猜是否同网段（`/24` 判据已删，
/// `myIpv4` 只用于多条局域网地址之间的排序）。
///
// Note: 为什么先局域网、为什么按策略而不是按网段 —— 见
// `.agents/notes/proposed/2026-11-13-connection-route-model.md`。
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

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../model/route_policy.dart';
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
  Future<PairingAck> commit({
    String? code,
    String? previousPairingId,
    String? deviceCode,
  }) async {
    try {
      return await _channel.commit(
        code ?? offer.code,
        previousPairingId: previousPairingId,
        deviceCode: deviceCode,
      );
    } finally {
      await _channel.close();
    }
  }

  /// 用户放弃：关掉这条短连接（电脑侧那半条会跟着关，候选不留痕）。
  Future<void> cancel() => _channel.close();
}

/// 一条路径的探测结果：**已开着的**受限通道，或"拨不通"的人话原因。
///
/// 两件事一起给，因为界要把它们并列摆出来（`✗ 中转：换票 409 …` 与
/// `✓ 局域网直连 ws://…` 是同一屏上的两行，不是成功/失败两种页面）。
class PairingRouteProbe {
  const PairingRouteProbe({
    required this.dial,
    required this.label,
    this.attempt,
    this.failure,
  });

  final PairingDial dial;

  /// 给人看的路径名（`局域网直连` / `中转`）。
  final String label;

  final PairingAttempt? attempt;

  /// 拨不通的人话；通了就是 `null`。
  final String? failure;

  bool get ok => attempt != null;

  /// 通了才是可拨地址；中转那条给的是**根地址**（票不上界面）。
  String get dialUrl => attempt?.dialUrl ?? '';
}

/// 一次"这张码里的路都探一遍"的结果。
///
/// **不抛异常**：两条都不通也是一种结果 —— 界面要把两条原因一起摆出来。
/// 只报最后一条会让人以为另一条没试过，而"两条都试过"正是这次要消除的猜测。
class PairingProbe {
  const PairingProbe(this.routes);

  final List<PairingRouteProbe> routes;

  PairingAttempt? attemptOf(PairingDial dial) {
    for (final route in routes) {
      if (route.dial == dial) return route.attempt;
    }
    return null;
  }

  /// 关掉除 [keep] 之外的通道：用户选了一条，另一条不该还挂在电脑上。
  ///
  /// [keep] 为 `null` = 全收（取消、退出页面、探测结果作废时）。
  Future<void> cancelExcept(PairingDial? keep) async {
    for (final route in routes) {
      final attempt = route.attempt;
      if (attempt == null || route.dial == keep) continue;
      await attempt.cancel();
    }
  }

  Future<void> cancelAll() => cancelExcept(null);
}

/// 同时探这张码里的每一条路：**真的拨上去、完成受限握手**，不是 ping。
/// Note: 逐条交付真实结果，选定即取消其余候选；见 .agents/notes/implemented/2026-11-24-pairing-cancellation-and-progress.md。
///
/// 与 [beginPairing] 的差别只有"要不要停"：这里两条都开、都留着，由界面选；
/// `beginPairing` 按策略只走一条、失败才换。两者共用同一套拨号与握手
/// （探测直接调 `beginPairing(directOnly)` / `beginPairing(relayOnly)`），
/// 所以"探通"与"配对能走"是同一件事，不存在第二套判据。
///
/// 代价（明确接受）：中转那张票在探测时就被换掉了，用户最后选了局域网时
/// 那张票作废（票是一次性的，但**没有秘密**，也不占电脑侧状态）。
Future<PairingProbe> probePairing({
  void Function(PairingRouteProbe route)? onRoute,
  Future<PairingDial?>? cancelExcept,
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
  bool allowInsecurePublic = false,
  String? myIpv4,

  /// 这台手机**愿意走哪条**（`device.route_policy`）。
  ///
  /// 它决定**探测范围**，不只是预选：`directOnly` 的用户可能在"不要碰中转"，
  /// 那时连换票都不该发生。被策略排除的那条由界面说"按设置未尝试"，
  /// 不显示成"不通"（它没有被拨过）。
  RoutePolicy prefer = RoutePolicy.auto,
}) async {
  final transports = <ChannelTransport, PairingDial>{};
  var stopped = false;
  PairingDial? keep;
  unawaited(
    cancelExcept?.then((selected) {
      stopped = true;
      keep = selected;
      for (final entry in transports.entries) {
        if (entry.value == keep) continue;
        unawaited(
          entry.key.close().catchError((Object error) {
            debugPrint('[pair] 取消候选连接失败：$error');
          }),
        );
      }
    }),
  );
  PairingRouteProbe report(PairingRouteProbe route) {
    if (!stopped) onRoute?.call(route);
    return route;
  }

  Future<PairingAttempt> dial(RoutePolicy policy) => beginPairing(
    offer: offer,
    identity: identity,
    deviceName: deviceName,
    send: send,
    transportFor: (url) {
      final dial = policy == RoutePolicy.directOnly
          ? PairingDial.lan
          : PairingDial.relay;
      if (stopped && dial != keep) throw const TransportException('配对检测已取消');
      final transport = transportFor(url);
      transports[transport] = dial;
      return transport;
    },
    onStage: onStage,
    newFrameIdHex: newFrameIdHex,
    newEphemeralSeedHex: newEphemeralSeedHex,
    newNonceHex: newNonceHex,
    handshakeTimeout: handshakeTimeout,
    allowInsecureLocal: allowInsecureLocal,
    allowInsecurePublic: allowInsecurePublic,
    myIpv4: myIpv4,
    prefer: policy,
  );

  PairingRouteProbe failed(PairingDial dial, String label, Object error) =>
      PairingRouteProbe(
        dial: dial,
        label: label,
        failure: _probeFailureText(error),
      );

  final pending = <Future<PairingRouteProbe>>[
    // 被策略排除的那条**不拨**：`directOnly` 的用户不该因为一次配对就连上中转
    // （换票是一次真实的 HTTP + 一张一次性票）。界面按策略画"未尝试"。
    if (prefer != RoutePolicy.relayOnly && offer.lanUrls.isNotEmpty)
      dial(RoutePolicy.directOnly)
          .then(
            (attempt) => PairingRouteProbe(
              dial: PairingDial.lan,
              label: '局域网直连',
              attempt: attempt,
            ),
            onError: (Object error) => failed(PairingDial.lan, '局域网直连', error),
          )
          .then(report),
    // `lanOnly` 的码里没有中转那条路：**不显示成"拨不通"**，那是另一件事
    // （界面按 `offer.lanOnly` 画"此码不含中转"）。
    if (prefer != RoutePolicy.directOnly && !offer.lanOnly)
      dial(RoutePolicy.relayOnly)
          .then(
            (attempt) => PairingRouteProbe(
              dial: PairingDial.relay,
              label: '中转',
              attempt: attempt,
            ),
            onError: (Object error) => failed(PairingDial.relay, '中转', error),
          )
          .then(report),
  ];
  return PairingProbe(await Future.wait(pending));
}

/// 探测失败的人话。**保留协议错误码**：界面与后续动作按它分类。
String _probeFailureText(Object error) {
  if (error is ProtocolException) return '${error.message}（${error.code.wire}）';
  if (error is TransportException) return error.message;
  return '拨不通：$error';
}

/// 配对通道实际走的那条路（确认卡据此说清"怎么连上的"）。
enum PairingDial {
  /// 局域网直连（二维码里的 `lan`，不经过中转）。
  lan,

  /// 中转（换票 → 带票升级）。
  relay,
}

// 先试哪条路由设备级策略决定：见 `model/route_policy.dart` 与 `beginPairing` 的
// `prefer`。这里不再有本文件私有的"配对偏好"—— 它与连接共用同一个设置。

/// 第一段：局域网直连（拨不通则回落换票 → 带票升级）→ 受限握手。
///
/// **不发送秘密、不创建有效设备记录、不签发任何令牌** —— 那三件事都发生在
/// [PairingAttempt.commit]。
///
/// [myIpv4] 只影响**发起顺序**（同一 /24 的那条排前面先发起，见 `dialOrder`；
/// 全部候选仍在同一轮里同时拨）；拿不到就按电脑侧给的顺序拨，不猜。
/// [prefer] 只影响走哪条（见 [RoutePolicy]）。
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

  /// 先试哪条路（设备级策略，`model/route_policy.dart`）。
  ///
  /// `auto` 才回落：码里有局域网地址就先试它，全不通才走中转。
  /// `directOnly` / `relayOnly` **不回落** —— 用户明确说"只想走这条"时，
  /// 偷偷换一条正是要消除的那种混乱。
  RoutePolicy prefer = RoutePolicy.auto,
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
  // 地址来自二维码的 `lan`：电脑自己持有这次 offer、自己也听得见这些端口，
  // 所以"保管邀请"与"通知有候选"这两件事在局域网上都不需要服务器。
  //
  // **全部候选同时拨**（2026-11-24）：电脑侧现在报的是"此刻枚举到的全部局域网 IPv4"
  // （WiFi / 以太网 / 虚拟网卡各一条），而成功只需要其中**一条**。串行一条一条
  // 等满超时会把配对拖到几十秒，也正是"逐条刷不通"的来源。
  // 与 `core/endpoint_transport.dart` 的拨号竞速同一条纪律：**先通者胜**，
  // 其余当场收掉 —— 半开的 socket 留着只占端口与超时预算（`tryRelay` 曾经漏掉
  // 这一步收尾，见下面的注释）。不设并行上限：候选数是电脑**此刻**报的条数，
  // 多一条就多一条，没有另一档档位可调。
  var lanTried = 0;
  Future<PairingAttempt?> tryLan() async {
    final endpoints = dialOrder([
      for (final url in offer.lanUrls)
        Endpoint(kind: EndpointKind.direct, url: url),
    ], myIpv4: myIpv4);
    lanTried = endpoints.length;
    if (endpoints.isEmpty) return null;
    onStage?.call('局域网直连…');

    // 先通者胜（或全灭）的那一个结果。**每一条各自完成握手，谁先到谁算**。
    final settled = Completer<PairingAttempt?>();
    final dialed = <PairingChannel>[];
    var pending = endpoints.length;
    for (final endpoint in endpoints) {
      final channel = channelFor(pairingDialUrl(endpoint.url, candidate));
      dialed.add(channel);
      unawaited(() async {
        try {
          await channel.open();
        } catch (error) {
          // 这一条不通：收干净（半开的 socket 留着只会占端口与超时预算），
          // 再记账。**原始原因不上界面**：全部候选失败时对外只有一句话
          // （见 `_lanDownText`），而地址与异常在这里的 debugPrint 里 ——
          // 真机排查要它，用户不需要一屏红字。
          debugPrint('[pair] 局域网 ${endpoint.url} 不通：$error');
          await channel.close();
          pending -= 1;
          if (pending == 0 && !settled.isCompleted) settled.complete(null);
          return;
        }
        if (settled.isCompleted) {
          // 赢家已经定了：这条慢到的当场收掉，不留半开连接。
          await channel.close();
          return;
        }
        settled.complete(attemptFor(channel, PairingDial.lan, endpoint.url));
      }());
    }

    final attempt = await settled.future;
    if (attempt == null) return null;
    // 赢家之外的那些（**包括还在握手中的**）：等它们收干净再往下走 ——
    // 调用方拿到确认卡时，电脑侧不该还挂着几条没人要的候选连接。
    for (final channel in dialed) {
      if (channel == attempt._channel) continue;
      await channel.close();
    }
    onStage?.call('等待你确认');
    return attempt;
  }

  // ---- ② 中转（跨网 / 没有局域网地址 / 局域网全拨不通）----
  Future<PairingAttempt> tryRelay() async {
    onStage?.call(lanTried == 0 ? '换票…' : '局域网没通，改用中转…');
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
    try {
      await channel.open();
    } catch (_) {
      // 握手没成：这条半开的 socket 要收掉。局域网那边一直有这一步
      // （`tryLan` 的 catch），中转这边曾漏掉 —— 而"中转连不上"是最常见的失败，
      // 每次配对留一条半开连接，重试几次就攒起来了。
      await channel.close();
      rethrow;
    }

    onStage?.call('等待你确认');
    return attemptFor(channel, PairingDial.relay, offer.relayUrl);
  }

  // 只有局域网那一档（`lanOnly`）：中转那条腿这次不存在 —— 不去换票（注定 409）。
  // 策略是「只用中转」时直接说清冲突，而不是偷偷用局域网配上一张本该走中转的码。
  if (offer.lanOnly) {
    if (prefer == RoutePolicy.relayOnly) {
      throw const TransportException(
        '这张码只能在同一 WiFi 下使用（出码时没有登记中转），'
        '而你的设置是「只用中转」；可以在「连接方式」里改成自动',
      );
    }
    final attempt = await tryLan();
    if (attempt != null) return attempt;
    throw TransportException(
      '这张码只能在同一 WiFi 下使用（出码时没登记上中转），${_lanDownText(lanTried)}',
    );
  }

  // 「只用直连」而这张码没有局域网地址：不猜一个中转出来。
  if (prefer == RoutePolicy.directOnly && offer.lanUrls.isEmpty) {
    throw const TransportException(
      '这张码只有中转那条路，而你的设置是「只用直连」；'
      '可以在「连接方式」里改成自动，或让电脑重新出码',
    );
  }

  // 三档各走各的：`auto` 才回落。`myIpv4` 只参与多条局域网地址之间的排序
  // （`tryLan` 里的 `dialOrder`），不再决定"要不要先走局域网"。
  switch (prefer) {
    case RoutePolicy.directOnly:
      final lanAttempt = await tryLan();
      if (lanAttempt != null) return lanAttempt;
      throw TransportException(_lanDownText(lanTried));
    case RoutePolicy.relayOnly:
      try {
        return await tryRelay();
      } catch (error, stack) {
        _rethrowWithLanNote(error, stack, lanTried);
      }
    case RoutePolicy.auto:
      // 码里有局域网地址就先试它 —— 那是电脑出码时给出的现证，
      // 不再用手机 IP 猜是否同网段（猜错一次就整条路错）。
      final lanAttempt = await tryLan();
      if (lanAttempt != null) return lanAttempt;
      try {
        return await tryRelay();
      } catch (error, stack) {
        // 局域网那几条失败过的话，**在原因前面点出来**：否则用户看到
        // "请让电脑重新出码"，而真因是"手机不在那个 WiFi"。
        _rethrowWithLanNote(error, stack, lanTried);
      }
  }
}

/// 局域网那条腿全灭时对外给的**一句话**。
///
/// 为什么不再逐条报：电脑现在报的是"此刻枚举到的全部局域网 IPv4"，一张码里
/// 三四条是常态；把每条的地址与原始错误拼起来，用户看到的是三行红字，而他能做的
/// 动作只有一个 —— 确认手机和电脑是不是同一个 Wi-Fi。所以这里只说**规模**
/// （试了几个）与**那个动作**，地址与异常留在 `tryLan` 的 `debugPrint` 里
/// （真机排查要它，界面不要）。
///
/// 与 `core/endpoint_transport.dart` 的"全失败"收口同一条口径：先说规模、
/// 再说用户该做什么。**中转那条腿不并进来** —— 两条腿对用户是两件事，
/// 中转自己的原因仍由它自己的消息说（见 [_rethrowWithLanNote]）。
String _lanDownText(int tried) =>
    tried == 0 ? '这张码里没有可拨的局域网地址' : '局域网不通（试了 $tried 个地址，是否同一 Wi-Fi？）';

/// 把"局域网也试过了"这件事加进最终错误里，**保留原错误码**（`clientAction` 靠它）。
///
/// 只加**一句**局域网结论，后面接中转自己给的原因：两条腿是两件事，
/// 而把它们并成一句会让"到底是网不通还是码过期"重新变成一个谜。
Never _rethrowWithLanNote(Object error, StackTrace stack, int lanTried) {
  if (lanTried == 0) {
    Error.throwWithStackTrace(error, stack);
  }
  final prefix = '${_lanDownText(lanTried)}；';
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
