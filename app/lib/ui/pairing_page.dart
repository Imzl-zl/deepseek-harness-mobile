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
/// | 网络不通 / 握手不过 | 检查网络与中转；核对二维码是不是这台电脑的 |
/// | 回执丢失（超时） | **结果待确认**：去电脑上核对这台设备有没有登记上，别直接重扫 |
///
/// 所以错误原样带出（含错误码）而不是笼统的"配对失败"——后者会让人在"码不对"时去查网络。
///
/// ## 为什么不做相机扫码（此刻）
///
/// 相机权限 + 各端扫码库是三端能力包的事（`packages/`），而它的判据是
/// "App 不在前台也要工作吗"（C1）—— 扫码显然不是。所以这里先做**粘贴二维码内容**：
/// 功能等价（二维码里就是一段 JSON），零权限、零依赖、三端同样能跑，而且是**可测**的。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/crypto.dart';
import '../core/errors.dart';
import '../core/frame.dart';
import '../core/pairing.dart';
import '../core/pairing_client.dart';
import '../core/pairing_flow.dart';
import '../core/transport.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';
import '../theme/dsh_theme.dart';

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
  /// 生产为 `false`：明文只在显式开启的本机调试里可用（`pairing-v2.md` §3）。
  final bool allowInsecureLocal;

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  final _input = TextEditingController();
  String? _error;
  bool _busy = false;

  /// 忙碌时的进度文案（配对链有好几步，用户该看到自己在哪一步）。
  String _busyLabel = '处理中…';

  /// 第一段的产物：受限通道已就绪、**秘密还没发出去**。
  PairingAttempt? _attempt;

  /// 本次配对生成的主种子（确认那一步之后才落盘，见 `_commit`）。
  String? _masterSeedHex;

  /// 电脑身份指纹（本地算，用来和电脑上打印的那段载荷对照）。
  String? _pcFingerprint;

  PairingResult? _result;

  @override
  void dispose() {
    // 页面上还挂着一条候选连接时必须关掉它：配对是短交互，而"用户退了页面、
    // 电脑侧那条候选连接还开着"正是要避免的状态（`pairing-v2.md` §6）。
    final attempt = _attempt;
    if (attempt != null) unawaited(attempt.cancel());
    _input.dispose();
    super.dispose();
  }

  /// 第一段：解析二维码 → 换票 → 带票升级 → 受限握手。**不发秘密。**
  Future<void> _connect() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
      _busyLabel = '解析二维码…';
    });
    try {
      final offer = PairingOffer.fromQrPayload(
        text,
        allowInsecureLocal: widget.allowInsecureLocal,
      );
      // 设备身份：主种子 + 派生的两把公钥。主种子此刻只在本页内存里，
      // 确认并配对成功之后才进系统安全存储。
      final masterSeedHex = toHex(randomBytes(32));
      final identity = await deriveIdentity(masterSeedHex);
      final fingerprint = (await sha256Hex(
        offer.pcSignPubHex,
      )).substring(0, 16);

      final attempt = await beginPairing(
        offer: offer,
        identity: identity,
        deviceName: widget.deviceName,
        send: widget.send,
        transportFor: widget.transportFor,
        onStage: _setBusy,
        allowInsecureLocal: widget.allowInsecureLocal,
      );
      if (!mounted) {
        // 页面已经退了：把刚建起来的候选连接收掉，别留在中转上。
        await attempt.cancel();
        return;
      }
      setState(() {
        _masterSeedHex = masterSeedHex;
        _pcFingerprint = fingerprint;
        _attempt = attempt;
      });
    } on ProtocolException catch (error) {
      _showError('${error.message}（${error.code.wire}）');
    } on TransportException catch (error) {
      _showError('${error.message}（连不上中转）');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 第二段：提交配对码 → 取回执。
  Future<void> _commit() async {
    final attempt = _attempt;
    final masterSeedHex = _masterSeedHex;
    if (attempt == null || masterSeedHex == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _busyLabel = '提交配对码…';
    });
    try {
      final ack = await attempt.commit();
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
      if (!mounted) return;
      setState(() {
        // 提交完这条短连接就关了（`PairingAttempt.commit` 的 finally）：
        // 之后再点一次"确认"没有意义，所以把它摘掉。
        _attempt = null;
        _result = result;
      });
    } on ProtocolException catch (error) {
      // **如实报**：回执丢失时这一句是"结果待确认"，而不是"没配对过"。
      _showError('${error.message}（${error.code.wire}）');
      if (mounted) setState(() => _attempt = null);
    } on TransportException catch (error) {
      _showError('${error.message}（配对连接断了，请到电脑上核对这台设备是否已登记）');
      if (mounted) setState(() => _attempt = null);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 用户放弃这一轮候选：关掉短连接，回到可重扫的状态。
  Future<void> _cancelAttempt() async {
    final attempt = _attempt;
    setState(() {
      _attempt = null;
      _masterSeedHex = null;
      _pcFingerprint = null;
    });
    if (attempt != null) await attempt.cancel();
  }

  void _showError(String message) {
    if (!mounted) return;
    setState(() => _error = message);
  }

  void _setBusy(String label) {
    if (!mounted) return;
    setState(() => _busyLabel = label);
  }

  @override
  Widget build(BuildContext context) {
    final attempt = _attempt;
    final result = _result;
    return Scaffold(
      backgroundColor: DshColors.bgBase,
      appBar: AppBar(
        backgroundColor: DshColors.sidebar,
        foregroundColor: DshColors.labelPrimary,
        title: const Text('配对'),
        // 能退回去看界面（配对是**主动的一步**，不是必经的门）。
        leading: widget.onCancel == null
            ? null
            : IconButton(
                tooltip: '返回',
                onPressed: widget.onCancel,
                icon: const DshIcon(
                  'chevronLeft',
                  size: 20,
                  color: DshColors.labelPrimary,
                ),
              ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _Step(index: 1, text: '在电脑上执行出码命令，得到二维码（5 分钟内有效、一次性）'),
          const _Step(index: 2, text: '把二维码内容粘贴到下面，点"连接电脑"'),
          const _Step(index: 3, text: '核对电脑身份；确认之后，配对码才会发出去'),
          const SizedBox(height: 12),
          TextField(
            controller: _input,
            minLines: 3,
            maxLines: 6,
            style: const TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              color: DshColors.labelPrimary,
            ),
            decoration: InputDecoration(
              hintText:
                  '{"v":2,"relay":"wss://…","pcId":"…","pcPubEd":"…","pcPubDh":"…","offerId":"…","code":"…"}',
              hintStyle: const TextStyle(
                fontSize: 11,
                color: DshColors.labelTertiary,
              ),
              filled: true,
              fillColor: DshColors.layer1,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(DshRadius.md),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            // 已经有一条候选通道挂着时不许再开一条（中转对同一台设备只该有一条）。
            onPressed: _busy || attempt != null ? null : _connect,
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.accentBlue,
              foregroundColor: DshColors.onAccent,
            ),
            // 文案诚实：这一步**真的会连电脑**（换票 → 升级 → 受限握手），
            // 而不是"解析一下"。用户按下去之后电脑侧会出现一行候选记录。
            child: Text(_busy ? _busyLabel : '连接电脑'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            _ErrorBox(message: _error!),
          ],
          if (attempt != null) ...[
            const SizedBox(height: 16),
            _IdentityCard(
              offer: attempt.offer,
              deviceName: widget.deviceName,
              fingerprint: _pcFingerprint ?? '',
              busy: _busy,
              onConfirm: _commit,
              onCancel: _cancelAttempt,
            ),
          ],
          if (result != null) ...[
            const SizedBox(height: 16),
            _DoneCard(
              result: result,
              deviceName: widget.deviceName,
              onDone: () => unawaited(widget.onPaired(result)),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: DshColors.layer2,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$index',
              style: const TextStyle(
                fontSize: 11,
                color: DshColors.labelSecondary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 13,
                color: DshColors.labelSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 错误框。
class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DshColors.layer1,
        borderRadius: BorderRadius.circular(DshRadius.sm),
        border: Border.all(color: DshColors.error),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const DshIcon('warningTriangle', size: 16, color: DshColors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 12, color: DshColors.error),
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
    required this.busy,
    required this.onConfirm,
    required this.onCancel,
  });

  final PairingOffer offer;
  final String deviceName;
  final String fingerprint;
  final bool busy;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: DshColors.layer1,
        borderRadius: BorderRadius.circular(DshRadius.md),
        border: Border.all(color: DshColors.layer3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '通道已就绪，等待你确认',
            style: TextStyle(
              fontSize: 13,
              color: DshColors.labelPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '下面这台电脑的身份来自你扫的二维码，网络无法替换它。'
            '确认之后，配对码才会加密发过去 —— 电脑此刻还没有这台设备的任何记录。',
            style: TextStyle(fontSize: 11, color: DshColors.labelTertiary),
          ),
          const SizedBox(height: 12),
          _Field(label: '电脑 ID', value: offer.pcId),
          _Field(label: '中转', value: offer.relayUrl),
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
                    backgroundColor: DshColors.roleContext,
                    foregroundColor: DshColors.onAccent,
                  ),
                  child: const Text('确认并配对'),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: busy ? null : onCancel,
                style: TextButton.styleFrom(
                  foregroundColor: DshColors.labelSecondary,
                ),
                child: const Text('取消'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 完成卡：配对已经成功（设备令牌已拿到），把它记下来再进主界面。
///
/// SAS 在这里是**辅助指纹**：它由两端各算一遍，值相同说明双方看到的是同一组公钥。
/// v2 的授权判据不依赖它（那由二维码固定的电脑身份 + 候选持钥证明 + 配对码承担）。
class _DoneCard extends StatelessWidget {
  const _DoneCard({
    required this.result,
    required this.deviceName,
    required this.onDone,
  });

  final PairingResult result;
  final String deviceName;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: DshColors.layer1,
        borderRadius: BorderRadius.circular(DshRadius.md),
        border: Border.all(color: DshColors.layer3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '配对成功',
            style: TextStyle(
              fontSize: 13,
              color: DshColors.labelPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '电脑已经登记这台设备并签发了设备令牌。下面是这台设备的辅助指纹，'
            '与电脑侧记录里的值相同（不参与授权判定）。',
            style: TextStyle(fontSize: 11, color: DshColors.labelTertiary),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _SasDisplay(sas: result.sas),
              const Spacer(),
              IconButton(
                tooltip: '复制',
                onPressed: () => unawaited(
                  Clipboard.setData(ClipboardData(text: result.sas)),
                ),
                icon: const DshIcon(
                  'copy',
                  size: 16,
                  color: DshColors.labelTertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Field(label: '设备名', value: deviceName),
          _Field(label: '设备 ID', value: result.devId),
          _Field(label: '电脑 ID', value: result.pcId),
          _Field(label: '中转', value: result.offer.relayUrl),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onDone,
              style: FilledButton.styleFrom(
                backgroundColor: DshColors.roleContext,
                foregroundColor: DshColors.onAccent,
              ),
              child: const Text('完成'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 6 位数字（等宽、放大 —— 它是给人看/念的东西）。
class _SasDisplay extends StatelessWidget {
  const _SasDisplay({required this.sas});

  final String sas;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final digit in sas.split(''))
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Container(
              width: 26,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: DshColors.layer2,
                borderRadius: BorderRadius.circular(DshRadius.xs),
              ),
              child: Text(
                digit,
                style: const TextStyle(
                  fontSize: 18,
                  fontFamily: 'monospace',
                  color: DshColors.labelPrimary,
                ),
              ),
            ),
          ),
      ],
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                color: DshColors.labelTertiary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: DshColors.labelSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
