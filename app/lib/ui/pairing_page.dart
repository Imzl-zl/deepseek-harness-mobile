/// 配对界面（契约 §12.1；规格 `docs/subsystems/pairing-v2.md` §3–§5）。
///
/// ## 这一页解决什么
///
/// 配对之前，App 没有任何可信的电脑身份，所以它连不上任何东西。这一页是那个**入口**：
/// 解析二维码得到可信电脑身份（**唯一来源**）→ 换票 → 带票升级 → 受限握手 →
/// **用户确认** → 加密提交配对码 → 拿到设备令牌 → 交给上层落盘建连。
///
/// ## 为什么是两段，而不是一个"连接"按钮走到底
///
/// v2 的硬不变量：**用户确认之前不发送秘密、不创建有效设备记录、不签发长期令牌**。
/// 所以"连接电脑"只做到「受限通道已就绪」，把电脑身份摆给用户看；配对码要等
/// 用户点「确认并配对」才出去。这也是为什么 SAS 出现在**之后**：它不是授权门，
/// 而是两端各算一遍的辅助指纹（`pairing-v2.md` §5）。
///
/// ## 为什么失败信息要原样显示
///
/// 这条链上几种失败，**用户该做的事完全不同**：
///
/// | 失败 | 用户该做什么 |
/// |---|---|
/// | 二维码版本不对（v1） | 在电脑上升级插件后重新出码 |
/// | 换票 409（邀请过期/已被认领） | 让电脑重新出码 |
/// | 换票 401 / 426 | 凭据或版本不对：重新扫码 |
/// | 网络不通 / 握手不过 | 检查网络（同一 WiFi 会直连，否则经中转）；核对二维码是不是这台电脑的 |
/// | 回执丢失（超时） | **结果待确认**：去电脑上核对这台设备有没有登记上，别直接重扫 |
///
/// 所以错误原样带出（含错误码）而不是笼统的"配对失败"——后者会让人在"码不对"时去查网络。
///
/// 摄像头与粘贴只负责取得同一二维码载荷，后续探测/授权/保存共用这条链。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/crypto.dart';
import '../core/endpoint.dart' show isPrivateOrLoopback;
import '../core/errors.dart';
import '../core/frame.dart';
import '../core/pairing.dart';
import '../core/pairing_client.dart';
import '../core/pairing_flow.dart';
import '../core/transport.dart';
import '../model/route_policy.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';
import 'pairing_routes_panel.dart';
import 'qr_scan_page.dart';

/// 配对完成的结果（交给装配点去落盘与建连）。
class PairingResult {
  const PairingResult({
    required this.offer,
    required this.pairingId,
    required this.sas,
    required this.masterSeedHex,
    required this.devSignPubHex,
    required this.devDhPubHex,
    required this.deviceToken,
    required this.refreshToken,
    required this.pcId,
    required this.devId,
  });

  final PairingOffer offer;

  /// 正式业务的配对标识（**手机自己算的**：由配对码哈希派生，不在回执里）。
  final String pairingId;

  /// 辅助指纹（两端各算一遍，值相同）。**它不是授权判据**。
  final String sas;

  /// 设备主种子（32 字节十六进制）。**要进系统安全存储。**
  final String masterSeedHex;

  final String devSignPubHex;
  final String devDhPubHex;

  /// 设备令牌（之后每次重连换票用它）。**要进系统安全存储。**
  final String deviceToken;

  /// 刷新令牌。同上（轮换流程本期未实现）。
  final String refreshToken;

  /// 电脑侧标识（握手 transcript 的 `pcId`，回执里给）。
  final String pcId;

  /// 电脑侧给本机分配的设备 id（`hello` 里带它）。
  final String devId;
}

/// 这个中转地址是不是"公网 + 明文"（= 需要用户显式同意的那一档）。
///
/// 判据与 `core/endpoint.dart` 的地址边界同源：`ws://` 且主机不是非公网。
bool _plaintextPublicRelay(String relayUrl) {
  final uri = Uri.tryParse(relayUrl);
  if (uri == null || uri.scheme != 'ws' || uri.host.isEmpty) return false;
  return !isPrivateOrLoopback(uri.host);
}

/// 配对页。
class PairingPage extends StatefulWidget {
  const PairingPage({
    super.key,
    required this.onPaired,
    required this.send,
    required this.transportFor,
    this.onCancel,
    this.deviceName = '我的手机',
    this.allowInsecureLocal = false,
    this.allowInsecurePublic = false,
    this.notice,
    this.previousPairingIdOf,
    this.loadDeviceCode,
    this.myIpv4,
    this.prefer = RoutePolicy.auto,
  });

  /// 配对成功时回调（上层负责落盘与建连）。
  final Future<void> Function(PairingResult result) onPaired;

  /// HTTP 缝（换票用）。实现在装配层注入 —— 这一页不认识 `package:http`。
  final HttpSender send;

  /// 传输缝（受限配对通道用）。同上：这一页不认识 WebSocket。
  final PairingTransportFactory transportFor;

  /// 取消返回（`null` = 这是必经页、退不出去）。
  ///
  /// 它的存在本身就是一条设计决定：**配对不是"没配对就挡在这里"的门**，
  /// 而是用户主动进来的一步 —— 所以能退出去看界面。
  final VoidCallback? onCancel;

  /// 设备名（电脑侧用它显示"哪台设备"）。
  final String deviceName;

  /// 允许本机明文调试（`ws://127.0.0.1`）。
  ///
  /// 它与 [PairingOffer.fromQrPayload] 的同名参数是**同一条边界的两处**：解析二维码时
  /// 放行的地址，换票与升级时也必须放行（否则会出现"码认了、票换不了"的裂缝）。
  final bool allowInsecureLocal;

  /// 允许**公网明文**的中转（用户自部署、暂无域名/证书）。
  ///
  /// 这一档不是"默认放宽"：配对页会把"明文、元数据可见"摆在确认卡上，
  /// 用户点「确认并配对」那一下就是显式同意（见 `core/endpoint.dart` 的注释）。
  final bool allowInsecurePublic;

  /// 顶部常驻的一句话（**为什么会被送到这一页**）。
  ///
  /// 身份不被认（换票被拒 → `notPaired`）时，装配层把原因带到这里 ——
  /// 用 SnackBar 是不够的：它 4 秒就消失，而用户是被**自动送到**这一页的，
  /// 看到时那句话可能已经没了，于是又回到"为什么让我重新扫码"。
  /// 手动点"重新配对"也给一句（"已清掉本机凭据"），两条路同一字段。
  final String? notice;

  /// 按二维码钉死的目标电脑公钥异步读取旧 `pairingId`，并核对 `pcId`。
  /// 没有目标槽/非凭据hint就返回null，不用当前可见电脑或名称猜。
  ///
  /// 重新配对（换密钥）时电脑侧靠它**替换旧行**而不是又攒一行 —— 2026-10-17
  /// 用户："为啥每次扫都是一个新设备"。它**不是凭据**（授权仍是这一次的二维码
  /// 秘密），只是行定位符，且只在 `pair-commit` 的密文里过线。
  /// 装配层注入唯一PairingStore，清槽前的hint也在该所有者内持久记录。
  /// 取舍与威胁模型：`.agents/notes/implemented/2026-10-17-repair-replaces-device-row.md`。
  final Future<String?> Function(PairingOffer offer)? previousPairingIdOf;

  /// 安装级设备显示/定位码；来源是系统安全存储，不是硬件权限或鉴权密钥。
  final Future<String> Function()? loadDeviceCode;

  /// 本机当前的局域网 IPv4（`AppModel.myLanIpv4`）。
  ///
  /// **只影响拨号顺序**：二维码里的局域网地址可能有几条（WiFi + 以太网），
  /// 同一 /24 的那条先拨（`core/endpoint.dart` 的 `dialOrder`）。拿不到就按电脑侧
  /// 给的顺序拨 —— 不猜。
  final String? myIpv4;

  /// 先试哪条路（设备级策略 `device.route_policy`，默认自动）。
  ///
  /// 只有 `auto` 会回落；两档单一策略下**不偷偷改路** —— 那正是"想连哪条却连了
  /// 另一条"的来源（见 `model/route_policy.dart`）。
  final RoutePolicy prefer;

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  final _input = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _probing = false;
  int _probeGeneration = 0;
  Completer<PairingDial?>? _cancelProbe;
  String? _deviceCode;

  /// 忙碌时的进度文案（配对链有好几步，用户该看到自己在哪一步）。
  String _busyLabel = '处理中…';

  /// 第一段的产物：受限通道已就绪、**秘密还没发出去**。
  PairingAttempt? _attempt;

  /// 解析出来的二维码（连接失败也留着）：配对页据此**显式**画出这张码有哪几条路、
  /// 这次是不是降级码（`lanOnly`）—— 不让用户自己从失败文案里猜。
  PairingOffer? _offer;

  /// 这张码里的路，**同时探一遍**的结果（通了的那条已经开在电脑上）。
  ///
  /// 探的不是"端口开没开"，是完整的受限握手 —— 所以这里 `ok` 就等于
  /// "现在真的能用它配对"。
  PairingProbe? _probe;

  /// 用户在两条路里选的那条；`null` = 一条都没通。
  PairingDial? _selectedDial;

  /// 本次配对生成的主种子（确认那一步之后才落盘，见 `_commit`）。
  String? _masterSeedHex;

  /// 本次配对自报的**旧配对标识**（重新配对同一台电脑时非空）。
  ///
  /// 在 [_connect] 解析出二维码的 `pcId` 之后取一次值 —— 换一台电脑扫它是
  /// `null`（首配，写新行）。
  String? _previousPairingId;

  /// 电脑身份指纹（本地算，用来和电脑上打印的那段载荷对照）。
  String? _pcFingerprint;

  PairingResult? _result;

  @override
  void dispose() {
    _probeGeneration += 1;
    final cancelled = _cancelProbe;
    if (cancelled != null && !cancelled.isCompleted) cancelled.complete(null);
    // 页面上还挂着候选连接时必须关掉它们：配对是短交互，而"用户退了页面、
    // 电脑侧那条候选连接还开着"正是要避免的状态（`pairing-v2.md` §6）。
    // 两条都通时**两条都在电脑上开着**，所以收的是整组，不是一条。
    final probe = _probe;
    if (probe != null) {
      unawaited(probe.cancelAll());
    } else {
      final attempt = _attempt;
      if (attempt != null) unawaited(attempt.cancel());
    }
    _input.dispose();
    super.dispose();
  }

  /// 扫码：把摄像头取到的二维码内容**原样交给 [_connect] 那条链**。
  ///
  /// 为什么不另写一条配对路径：扫码改的只是"载荷从哪来"(摄像头 vs 剪贴板),
  /// 后面的换票 / 升级 / 受限握手 / 确认 / 落盘**完全同一套**。
  /// 另写一条就等于让"配对怎么走"有两个答案,而它们迟早不一致。
  Future<void> _scan() async {
    final scanned = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrScanPage()));
    // `null` = 用户按返回退出取景;空串 = 扫到了但不是我们要的载荷。
    if (!mounted || scanned == null || scanned.isEmpty) return;
    _input.text = scanned;
    await _connect();
  }

  /// 第一段：解析二维码 → **同时探两条路**（真的拨上去、完成受限握手）。
  /// **不发秘密。**
  ///
  /// 探完不自动选一条了事：两条都通时把选择交回用户（`PairingRoutePicker`），
  /// 只有"按策略该先走哪条"作为预选。两种失败（这条不通 / 这张码不含这条）
  /// 在界面上是两种说法，不混成一句。
  Future<void> _connect() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final previous = _cancelProbe;
    if (previous != null && !previous.isCompleted) previous.complete(null);
    final generation = ++_probeGeneration;
    final cancelled = _cancelProbe = Completer<PairingDial?>();
    setState(() {
      _busy = true;
      _probing = true;
      _error = null;
      _result = null;
      _offer = null;
      _probe = null;
      _selectedDial = null;
      _attempt = null;
      _busyLabel = '解析二维码…';
    });
    PairingProbe? probe;
    try {
      final offer = PairingOffer.fromQrPayload(
        text,
        allowInsecureLocal: widget.allowInsecureLocal,
        allowInsecurePublic: widget.allowInsecurePublic,
      );
      // 先把"这张码有哪几条路"摆出来：降级码（`lanOnly`）要在这里就显式提示，
      // 而不是等用户出门、换票失败之后才从一句"重新出码"里猜。
      if (mounted) setState(() => _offer = offer);
      // 旧配对标识：**只有扫的是同一台电脑**（pcId 相同）才报上去。
      // 换一台电脑时它是 null —— 那边没有旧行可替换，报了也白报。
      final previousPairingId = await widget.previousPairingIdOf?.call(offer);
      final deviceCode = await widget.loadDeviceCode?.call();
      // 设备身份：主种子 + 派生的两把公钥。主种子此刻只在本页内存里，
      // 确认并配对成功之后才进系统安全存储。
      final masterSeedHex = toHex(randomBytes(32));
      final identity = await deriveIdentity(masterSeedHex);
      final fingerprint = (await sha256Hex(
        offer.pcSignPubHex,
      )).substring(0, 16);

      if (!mounted || generation != _probeGeneration) return;
      setState(() {
        _masterSeedHex = masterSeedHex;
        _previousPairingId = previousPairingId;
        _deviceCode = deviceCode;
        _pcFingerprint = fingerprint;
        _busyLabel = '正在检测可用路径…';
      });
      probe = await probePairing(
        cancelExcept: cancelled.future,
        onRoute: (route) {
          if (!mounted || generation != _probeGeneration) return;
          final partial = PairingProbe([...?_probe?.routes, route]);
          final chosen = _selectedDial ?? _preselect(partial, widget.prefer);
          setState(() {
            _probe = partial;
            _selectedDial = chosen;
            _attempt = chosen == null ? null : partial.attemptOf(chosen);
            if (chosen != null) _busy = false;
          });
        },
        offer: offer,
        identity: identity,
        deviceName: widget.deviceName,
        send: widget.send,
        transportFor: widget.transportFor,
        allowInsecureLocal: widget.allowInsecureLocal,
        allowInsecurePublic: widget.allowInsecurePublic,
        myIpv4: widget.myIpv4,
        prefer: widget.prefer,
      );
      if (!mounted || generation != _probeGeneration) {
        // 用户已选定或退出：选定的通道属于提交，不能被迟到探测收掉。
        return;
      }
      final done = probe;
      final chosen = _selectedDial ?? _preselect(done, widget.prefer);
      setState(() {
        _probe = done;
        _masterSeedHex = masterSeedHex;
        _previousPairingId = previousPairingId;
        _pcFingerprint = fingerprint;
        _selectedDial = chosen;
        _attempt = chosen == null ? null : done.attemptOf(chosen);
      });
      if (chosen == null) _showError(_noRouteError(done));
    } on ProtocolException catch (error) {
      await probe?.cancelAll();
      _showError('${error.message}（${error.code.wire}）');
    } on TransportException catch (error) {
      await probe?.cancelAll();
      _showError('${error.message}（连不上中转）');
    } catch (error) {
      await probe?.cancelAll();
      // **兜底必须说出来**：换票用的是 `http.Client`，它抛的是 `SocketException` /
      // `TimeoutException` 这类**既不是** ProtocolException **也不是** TransportException
      // 的东西（Android 的明文拦截就是这种：`SocketException … errno = 103`）。
      // 少了这一支，用户看到的是"点了没反应"——今天真机上就是这么白等了十几分钟。
      _showError('配对没走通：$error');
    } finally {
      if (mounted && generation == _probeGeneration) {
        setState(() {
          _busy = false;
          _probing = false;
        });
      }
    }
  }

  /// 预选：**只在策略允许的那条里挑**，不跨策略回落。
  ///
  /// `directOnly` / `relayOnly` 是用户明确说过的意图；在配对页偷偷改用另一条，
  /// 正是 2026-11-13 要消除的那种"选了直连连了中转"。被排除的那条根本不探，
  /// 所以这里也不存在"它有 attempt 但不选"的中间态。
  PairingDial? _preselect(PairingProbe probe, RoutePolicy policy) {
    final hasLan = probe.attemptOf(PairingDial.lan) != null;
    final hasRelay = probe.attemptOf(PairingDial.relay) != null;
    switch (policy) {
      case RoutePolicy.directOnly:
        return hasLan ? PairingDial.lan : null;
      case RoutePolicy.relayOnly:
        return hasRelay ? PairingDial.relay : null;
      case RoutePolicy.auto:
        if (hasLan) return PairingDial.lan;
        if (hasRelay) return PairingDial.relay;
        return null;
    }
  }

  /// 没有可选路径时的那一句。**先分辨"被策略排除"**：
  /// 那不是"没通"，改设置就能走，动作完全不同。
  String _noRouteError(PairingProbe probe) {
    final offer = _offer;
    if (offer != null &&
        widget.prefer == RoutePolicy.relayOnly &&
        offer.lanOnly) {
      return '这张码只含局域网直连，而你的设置是「只用中转」；'
          '去「连接方式」改成自动后可走它。';
    }
    if (offer != null &&
        widget.prefer == RoutePolicy.directOnly &&
        offer.lanUrls.isEmpty) {
      return '这张码只含中转，而你的设置是「只用直连」；'
          '去「连接方式」改成自动后可走它。';
    }
    if (probe.routes.isEmpty) {
      return '这张码里没有任何可拨的路径：请让电脑重新出码，或检查连接方式设置。';
    }
    return probe.routes.length > 1 ? '两条路都没通，原因见下。' : '这条路没通，原因见下。';
  }

  /// 用户改选另一条（只有通了的那行可点）。
  void _select(PairingDial dial) {
    if (_busy) return;
    final attempt = _probe?.attemptOf(dial);
    if (attempt == null || dial == _selectedDial) return;
    setState(() {
      _selectedDial = dial;
      _attempt = attempt;
      _error = null;
    });
  }

  /// 第二段：提交配对码 → 取回执。
  Future<void> _commit() async {
    final attempt = _attempt;
    final masterSeedHex = _masterSeedHex;
    if (attempt == null || masterSeedHex == null) return;
    _probeGeneration += 1;
    final cancelled = _cancelProbe;
    if (cancelled != null && !cancelled.isCompleted) {
      cancelled.complete(_selectedDial);
    }
    setState(() {
      _probing = false;
      _busy = true;
      _error = null;
      _busyLabel = '提交配对码…';
    });
    // 用户选定了这一条：另一条已开的通道现在就该收掉 ——
    // 电脑上同时挂着两条候选，既没意义，也让"这台设备到底走了哪条"说不清。
    try {
      await _probe?.cancelExcept(_selectedDial);
      final ack = await attempt.commit(
        previousPairingId: _previousPairingId,
        deviceCode: _deviceCode,
      );
      final identity = attempt.identity;
      final result = PairingResult(
        offer: attempt.offer,
        pairingId: await attempt.offer.pairingId(),
        sas: ack.sas,
        masterSeedHex: masterSeedHex,
        devSignPubHex: identity.sign.publicKeyHex,
        devDhPubHex: identity.dh.publicKeyHex,
        deviceToken: ack.deviceToken,
        refreshToken: ack.refreshToken,
        pcId: ack.pcId,
        devId: ack.devId,
      );
      if (mounted) {
        setState(() {
          _attempt = null;
          _probe = null;
          _selectedDial = null;
          _result = result;
        });
      }
      // Note: 回执收到即持久保存，辅助 SAS 不再充当落盘门；见 .agents/notes/implemented/2026-11-24-stable-device-code-and-pairing-continuity.md。
      await _completePairing(result);
    } on ProtocolException catch (error) {
      // **如实报**：回执丢失时这一句是"结果待确认"，而不是"没配对过"。
      _showError('${error.message}（${error.code.wire}）');
      _dropAttemptState();
    } on TransportException catch (error) {
      _showError('${error.message}（配对连接断了，请到电脑上核对这台设备是否已登记）');
      _dropAttemptState();
    } catch (error) {
      // 同 `_connect`：任何别的异常也必须出现在用户眼前（结果仍然"待确认"）。
      _showError('提交没走通：$error（去电脑上核对这台设备是否已登记）');
      _dropAttemptState();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _completePairing(PairingResult result) async {
    if (mounted) {
      setState(() {
        _busy = true;
        _error = null;
        _busyLabel = '保存配对并连接…';
      });
    }
    try {
      await widget.onPaired(result);
      if (mounted) setState(() => _result = null);
    } catch (error) {
      _showError('电脑已经登记这台设备，本机保存或连接未完成：$error。可以重试继续，不需要重扫。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 用户放弃这一轮候选：关掉所有已开通道，回到可重扫的状态。
  Future<void> _cancelAttempt() async {
    _probeGeneration += 1;
    final cancelled = _cancelProbe;
    if (cancelled != null && !cancelled.isCompleted) cancelled.complete(null);
    final probe = _probe;
    final attempt = _attempt;
    setState(() {
      _busy = false;
      _probing = false;
      _attempt = null;
      _probe = null;
      _selectedDial = null;
      _masterSeedHex = null;
      _previousPairingId = null;
      _pcFingerprint = null;
    });
    if (probe != null) {
      await probe.cancelAll();
    } else if (attempt != null) {
      await attempt.cancel();
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() => _error = message);
  }

  /// 提交失败后把"这一轮候选"整组摘掉（通道已随 `commit` 的 finally 关闭）。
  ///
  /// 三处失败分支同一件事，写三遍就会有一处先腐化 —— 收成一个入口。
  void _dropAttemptState() {
    if (!mounted) return;
    setState(() {
      _attempt = null;
      _probe = null;
      _selectedDial = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    final attempt = _attempt;
    final result = _result;
    return Scaffold(
      backgroundColor: c.bgBase,
      appBar: AppBar(
        backgroundColor: c.sidebar,
        foregroundColor: c.labelPrimary,
        title: const Text('配对'),
        // 能退回去看界面（配对是**主动的一步**，不是必经的门）。
        leading: widget.onCancel == null
            ? null
            : IconButton(
                tooltip: '返回',
                onPressed: widget.onCancel,
                icon: DshIcon('chevronLeft', size: 20, color: c.labelPrimary),
              ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // **为什么会被送到这一页**：常驻，不随 SnackBar 消失。
          if (widget.notice != null) ...[
            Container(
              key: const Key('pairing-notice'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: c.layer1,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: c.error),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DshIcon('warningTriangle', size: 18, color: c.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.notice!,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: c.labelPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
          // **失败放在页首**：这一页在有了"两条路"选择之后会变长，
          // 错误框留在按钮下方就等于要用户先滚到底才知道为什么没连上。
          if (_error != null) ...[
            PairingErrorBox(message: _error!),
            const SizedBox(height: 16),
          ],
          const _Step(index: 1, text: '在电脑上执行出码命令，得到二维码（5 分钟内有效、一次性）'),
          const _Step(index: 2, text: '扫二维码，或把内容粘贴到下面'),
          const _Step(index: 3, text: '核对电脑身份、选择走哪条；确认之后，配对码才会发出去'),
          const SizedBox(height: 12),
          // **扫码是首选入口**，粘贴是兜底。
          //
          // 为什么扫码在前：二维码本来就在电脑屏幕上，摄像头对着就完事；
          // 而那段 JSON 有 290 字节（含两把 64 字符公钥），手打既容易错
          // 也没法"扫"。深链拉起（二维码编码 dshmobile:// URL、系统相机扫完
          // 唤起 App）被否：用户已经在 App 里了，切去系统相机再切回来是多两次
          // 上下文切换，见
          // `.agents/notes/implemented/2026-10-14-pairing-scans-in-app.md`
          FilledButton.icon(
            onPressed: _busy || _probing || attempt != null || result != null
                ? null
                : _scan,
            style: FilledButton.styleFrom(
              backgroundColor: c.accentBlue,
              foregroundColor: c.onAccent,
            ),
            icon: DshIcon(
              // **必须是 DSH 图标集里的名字**：`dsh_icons.dart` 查不到键就抛，
              // 而那个 ErrorWidget 会把本页的输入框与按钮**挤出屏幕** ——
              // 2026-10-15 真机上就这样整个配对页变成一块红（当时写的是
              // `cameraScan`，集合里没有它）。判据由
              // `mock/proto/tools/verify-icons.cjs` 的"app/lib 引用的图标都存在"
              // 那条守着。
              'inspect',
              size: 16,
              color: c.onAccent,
            ),
            label: const Text('扫一扫'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _input,
            minLines: 3,
            maxLines: 6,
            // **关掉输入法联想**：这一格是 JSON，手打时被自动纠错/候选词改一个字符
            // 就解析失败（粘贴不受影响，所以只有"手打"这一路会中招）。
            // 两个开关缺一不可 —— `enableSuggestions` 在 Android 是独立的
            // TYPE_TEXT_FLAG_NO_SUGGESTIONS，在 iOS 联想则**跟着 `autocorrect` 走**
            // （`packages/flutter/lib/src/services/text_input.dart:623-636`）。
            enableSuggestions: false,
            autocorrect: false,
            style: TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              color: c.labelPrimary,
            ),
            decoration: InputDecoration(
              hintText:
                  '{"v":2,"relay":"wss://…","pcId":"…","pcPubEd":"…","pcPubDh":"…","offerId":"…","code":"…"}',
              hintStyle: TextStyle(fontSize: 11, color: c.labelTertiary),
              filled: true,
              fillColor: c.layer1,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(DshRadius.md),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 12),
          // **这张码有哪几条路**：扫完就摆出来。降级码在这里显式说"只能同一 WiFi"，
          // 两条都在时说明先试哪条、正在试哪条（`_busyLabel` 就是当前那一步）。
          if (_offer != null && _result == null) ...[
            PairingOfferRoutes(
              offer: _offer!,
              busy: _busy || _probing,
              stage: _busyLabel,
            ),
            const SizedBox(height: 12),
            // **码里写了什么**（上面）与**此刻实测哪条通**（这里）是两件事：
            // 前者是电脑出码时的承诺，后者是真的拨通了。分开画，用户不用从
            // 一句失败文案里倒推是哪一边的问题。
            PairingRoutePicker(
              offer: _offer!,
              probe: _probe,
              selected: _selectedDial,
              busy: _probing,
              policy: widget.prefer,
              onSelect: _select,
            ),
            const SizedBox(height: 12),
          ],
          FilledButton(
            // 已经有一条候选通道挂着时不许再开一条（中转对同一台设备只该有一条）。
            onPressed: _busy || _probing || attempt != null || result != null
                ? null
                : _connect,
            style: FilledButton.styleFrom(
              backgroundColor: c.accentBlue,
              foregroundColor: c.onAccent,
            ),
            // 文案诚实：这一步**真的会连电脑**（换票 → 升级 → 受限握手），
            // 而不是"解析一下"。用户按下去之后电脑侧会出现一行候选记录。
            child: Text(_busy ? _busyLabel : '连接电脑'),
          ),
          if (attempt != null) ...[
            const SizedBox(height: 16),
            _IdentityCard(
              offer: attempt.offer,
              deviceName: widget.deviceName,
              fingerprint: _pcFingerprint ?? '',
              // **如实说走的是哪条路**：走局域网却写"中转"，会让人以为中转必须开着。
              dial: attempt.dial,
              dialUrl: attempt.dialUrl,
              busy: _busy,
              onConfirm: _commit,
              onCancel: _cancelAttempt,
              // 重新配对同一台电脑：把"会替换旧记录"说在确认之前 ——
              // 用户该知道这一扫之后电脑侧少一行、而不是又多一行。
              replacing: _previousPairingId != null,
            ),
          ],
          if (result != null) ...[
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : () => _completePairing(result),
              child: const Text('重试保存并连接'),
            ),
          ],
        ],
      ),
    );
  }
}

/// 编号步骤。
class _Step extends StatelessWidget {
  const _Step({required this.index, required this.text});

  final int index;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: c.layer2, shape: BoxShape.circle),
            child: Text(
              '$index',
              style: TextStyle(fontSize: 11, color: c.labelSecondary),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, color: c.labelSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// 确认卡：**受限通道已就绪**，把电脑身份摆给用户看，等一句确认。
///
/// 这里显示的每一样都来自二维码（`pairing-v2.md` §1：它是电脑身份的唯一带外来源）
/// 加上"通道确实通"这一事实。配对码此刻**还没有**发出去。
class _IdentityCard extends StatelessWidget {
  const _IdentityCard({
    required this.offer,
    required this.deviceName,
    required this.fingerprint,
    required this.dial,
    required this.dialUrl,
    required this.busy,
    required this.onConfirm,
    required this.onCancel,
    this.replacing = false,
  });

  final PairingOffer offer;
  final String deviceName;
  final String fingerprint;

  /// 这条通道实际走的那条路（局域网 / 中转）与它的地址。
  final PairingDial dial;
  final String dialUrl;

  final bool busy;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  /// 这一次是**重新配对同一台电脑**（手机自报了旧配对标识）：电脑侧会
  /// 替换旧行而不是又攒一行。确认前要说出来 —— 记录行数变化是用户看得见
  /// 的后果（`.agents/notes/implemented/2026-10-17-repair-replaces-device-row.md`）。
  final bool replacing;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.layer1,
        borderRadius: BorderRadius.circular(DshRadius.md),
        border: Border.all(color: c.layer3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '通道已就绪，等待你确认',
            style: TextStyle(
              fontSize: 13,
              color: c.labelPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '下面这台电脑的身份来自你扫的二维码，网络无法替换它。'
            '确认之后，配对码才会加密发过去 —— 电脑此刻还没有这台设备的任何记录。',
            style: TextStyle(fontSize: 11, color: c.labelTertiary),
          ),
          // **公网明文**（用户自部署中转）：必须摆明代价，并让"确认并配对"这一下
          // 成为**显式同意**。判据与地址边界同一条（`core/endpoint.dart`）：
          // 公网 + `ws://` 才提示；非公网（局域网/组网）不打扰。
          if (_plaintextPublicRelay(offer.relayUrl)) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DshIcon('info', size: 14, color: c.stateError),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '这台电脑的中转是明文连接（ws://，自部署）：内容仍然端到端加密，'
                    '但网络上的元数据（帧大小与时序）可见。点「确认并配对」即表示接受。',
                    style: TextStyle(fontSize: 11, color: c.stateError),
                  ),
                ),
              ],
            ),
          ],
          if (replacing) ...[
            const SizedBox(height: 8),
            // 重新配对的后果：换新密钥与新令牌，电脑侧**替换**这台手机的旧记录
            // （不再多一行）。这是 2026-10-17 用户"为啥每次扫都是一个新设备"
            // 的答案在手机侧的那一半。
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DshIcon('refresh', size: 14, color: c.labelTertiary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '本机在这台电脑上已有配对记录：这次会换新密钥并替换那条记录，'
                    '不会新增一行。',
                    style: TextStyle(fontSize: 11, color: c.labelTertiary),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          _Field(label: '电脑 ID', value: offer.pcId),
          _Field(label: dial == PairingDial.lan ? '局域网' : '中转', value: dialUrl),
          // 指纹是**本地算的**（二维码里公钥的哈希前 16 位）：它与电脑上打印的那段
          // 载荷对得上，就是"我扫的确实是这台电脑"的一个可核对值。
          _Field(label: '公钥指纹', value: fingerprint),
          _Field(label: '设备名', value: deviceName),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: busy ? null : onConfirm,
                  style: FilledButton.styleFrom(
                    // 用 `roleContext`（token 表里那个绿）而不是自造一个色值 ——
                    // 三端的颜色只有一个来源（`dsh_colors.dart`）。
                    backgroundColor: c.roleContext,
                    foregroundColor: c.onAccent,
                  ),
                  child: const Text('确认并配对'),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: busy ? null : onCancel,
                style: TextButton.styleFrom(foregroundColor: c.labelSecondary),
                child: const Text('取消'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 一行"标签 · 值"。
class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(
              label,
              style: TextStyle(fontSize: 11, color: c.labelTertiary),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: c.labelSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
