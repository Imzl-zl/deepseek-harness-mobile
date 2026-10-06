/// 配对界面（契约 §12.1）。
///
/// ## 这一页解决什么
///
/// 配对之前，App 没有任何可信的电脑身份，所以 [SessionListPage] 只能显示"连不上"。
/// 这一页就是那个**入口**：把二维码里的 `{relay, pcPubEd, pcPubDh, code}` 搬进来，
/// 派生出 `pairingId` 与 SAS，然后交给上层去连。
///
/// ## 为什么不做相机扫码（此刻）
///
/// 相机权限 + 各端扫码库是三端能力包的事（`packages/`），而它的判据是
/// "App 不在前台也要工作吗"（C1）—— 扫码显然不是。
/// 所以这里先做**粘贴二维码内容**：功能等价（二维码里就是一段 JSON），
/// 零权限、零依赖、三端同样能跑，而且是**可测**的（无需相机）。
/// 相机扫码作为后续增量加在这一页上，不影响下面的逻辑。
///
/// ## SAS 为什么必须显示
///
/// 契约 §12.1 的硬规则：电脑侧对收到的设备公钥做**带外核对**。
/// 两端各自算出同样的 6 位数字，由用户对照 —— 这是"二维码被换掉"的
/// 唯一可检测信号（不做也不会静默泄密，但会把攻击降级成不可检测的可用性破坏）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/crypto.dart';
import '../core/errors.dart';
import '../core/frame.dart';
import '../core/pairing.dart';
import '../theme/dsh_colors.dart';
import '../theme/dsh_theme.dart';

/// 配对完成的结果（交给装配点去建连）。
class PairingResult {
  const PairingResult({
    required this.offer,
    required this.pairingId,
    required this.sas,
    required this.masterSeedHex,
    required this.devSignPubHex,
    required this.devDhPubHex,
  });

  final PairingOffer offer;
  final String pairingId;
  final String sas;

  /// 设备主种子（32 字节十六进制）。**要进系统安全存储。**
  final String masterSeedHex;

  final String devSignPubHex;
  final String devDhPubHex;
}

/// 配对页。
class PairingPage extends StatefulWidget {
  const PairingPage({
    super.key,
    required this.onPaired,
    this.deviceName = '我的手机',
  });

  /// 配对成功时回调（上层负责落盘与建连）。
  final Future<void> Function(PairingResult result) onPaired;

  /// 设备名（电脑侧用它显示"哪台设备"）。
  final String deviceName;

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  final _input = TextEditingController();
  String? _error;
  PairingResult? _result;
  bool _busy = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// 解析粘贴进来的二维码内容。
  ///
  /// **只有解析与派生，不在这里建连**：建连是装配点的事（它要装传输、握手、箱）。
  /// 这一页只把"可信身份"备齐 —— 分工清楚，且这一页因此可以脱网测。
  Future<void> _parse() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
    });
    try {
      final offer = PairingOffer.fromQrPayload(text);
      // 生成设备身份：主种子 + 派生的两把公钥（契约 §12.1 第 2 步）。
      final masterSeedHex = toHex(randomBytes(32));
      final identity = await deriveIdentity(masterSeedHex);
      final result = PairingResult(
        offer: offer,
        pairingId: await offer.pairingId(),
        sas: await sasOf(
          pcSignPubHex: offer.pcSignPubHex,
          devSignPubHex: identity.sign.publicKeyHex,
        ),
        masterSeedHex: masterSeedHex,
        devSignPubHex: identity.sign.publicKeyHex,
        devDhPubHex: identity.dh.publicKeyHex,
      );
      if (!mounted) return;
      setState(() => _result = result);
    } on ProtocolException catch (error) {
      if (!mounted) return;
      // **如实显示错误码**：`unsupported-version` 的动作是"升级"，
      // `not-paired` 的动作是"重扫码" —— 用户看到码才知道该做什么。
      setState(() => _error = '${error.message}（${error.code.wire}）');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: DshColors.bgBase,
      appBar: AppBar(
        backgroundColor: DshColors.sidebar,
        foregroundColor: DshColors.labelPrimary,
        title: const Text('配对'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _Step(index: 1, text: '在电脑上执行出码命令，得到二维码（5 分钟内有效）'),
          const _Step(index: 2, text: '把二维码内容粘贴到下面'),
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
                  '{"v":1,"relay":"wss://…","pcPubEd":"…","pcPubDh":"…","code":"…"}',
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
            onPressed: _busy ? null : _parse,
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.accentBlue,
              foregroundColor: DshColors.onAccent,
            ),
            child: Text(_busy ? '解析中…' : '解析'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            _ErrorBox(message: _error!),
          ],
          if (_result != null) ...[
            const SizedBox(height: 16),
            _ConfirmCard(
              result: _result!,
              deviceName: widget.deviceName,
              onConfirm: () => unawaited(widget.onPaired(_result!)),
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
          const Icon(Icons.error_outline, size: 16, color: DshColors.error),
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

/// 确认卡：显示 SAS 与关键信息，让用户核对后再连。
class _ConfirmCard extends StatelessWidget {
  const _ConfirmCard({
    required this.result,
    required this.deviceName,
    required this.onConfirm,
  });

  final PairingResult result;
  final String deviceName;
  final VoidCallback onConfirm;

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
            '在电脑上核对这 6 位数字',
            style: TextStyle(
              fontSize: 13,
              color: DshColors.labelPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '两端显示的数字必须相同。不同就说明这张二维码不可信，别继续。',
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
                icon: const Icon(
                  Icons.copy,
                  size: 16,
                  color: DshColors.labelTertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _Field(label: '设备名', value: deviceName),
          _Field(label: '中转', value: result.offer.relayUrl),
          _Field(label: '配对标识', value: result.pairingId),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onConfirm,
              style: FilledButton.styleFrom(
                // 用 `roleContext`（token 表里那个绿）而不是自造一个色值 ——
                // 三端的颜色只有一个来源（`dsh_colors.dart`），
                // 在页面里现编一个会让"深色主题统一"从这一处开始漏。
                backgroundColor: DshColors.roleContext,
                foregroundColor: DshColors.onAccent,
              ),
              child: const Text('数字一致，开始连接'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 6 位数字（等宽、放大 —— 它是要**照着念**的东西）。
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
