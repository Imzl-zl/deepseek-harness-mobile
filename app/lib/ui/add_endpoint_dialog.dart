/// 「手动填一个电脑地址」—— **连不上的那一刻**与设置页共用同一个对话框。
///
/// ## 为什么是共用件
///
/// 换网络之后（家 ⇄ 公司）手机里存的地址会全部拨不通，而**配对凭据与地址无关**：
/// 用户只需要把电脑的新地址告诉它，不需要重新扫码配对。两个入口都要这条路：
///
/// - 设置页「添加端点」（常驻管理）；
/// - 连接操作 sheet「手动填写电脑地址」（连不上时的出口）。
///
/// ## 校验在这里，不在 `data/`
///
/// 允许什么地址是**安全边界**（`core/endpoint.dart` 的 `checkedRelayUri`）。两档明文：
///
/// - **非公网**（局域网 / 回环 / 组网 CGNAT）：直接放行 —— 电脑侧监听面刻意不终结 TLS，
///   直连地址本来就是明文；通道在握手后逐帧 AEAD，明文只暴露元数据。
/// - **公网**：只有用户**勾选确认**后才放行（自部署中转、暂无域名/证书的场景）。
///   `AppModel.addManualEndpoint` 只存值，两处各判一遍就会漂。
///
/// **直连一般填 `ws://`**：电脑侧监听面不终结 TLS，写成 `wss://` 反而拨不通。
library;

import 'package:flutter/material.dart';

import '../core/endpoint.dart';
import '../core/errors.dart';
import '../model/chat_item.dart' show endpointKindLabel;
import '../theme/dsh_colors.dart';

/// 添加端点的结果：填的那一条 + 用户是否确认过"公网明文"。
typedef AddedEndpoint = ({Endpoint endpoint, bool allowPlaintextPublic});

/// 弹「添加端点」并返回结果（取消 / 校验失败 ⇒ `null`）。
Future<AddedEndpoint?> showAddEndpointDialog(
  BuildContext context, {
  EndpointKind initialKind = EndpointKind.direct,
}) => showDialog<AddedEndpoint>(
  context: context,
  builder: (context) => AddEndpointDialog(initialKind: initialKind),
);

/// 填地址的小对话框（kind + url）。
class AddEndpointDialog extends StatefulWidget {
  const AddEndpointDialog({super.key, this.initialKind = EndpointKind.direct});

  final EndpointKind initialKind;

  @override
  State<AddEndpointDialog> createState() => _AddEndpointDialogState();
}

class _AddEndpointDialogState extends State<AddEndpointDialog> {
  late EndpointKind _kind = widget.initialKind;
  final _input = TextEditingController();
  String? _error;

  /// 用户是否勾了"公网明文"那条确认。**只在真的填了公网 `ws://` 时才出现**。
  bool _acknowledged = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// 当前输入是不是"公网 + 明文"（= 需要确认的那一档）。
  bool get _needsPlaintextAck {
    final uri = Uri.tryParse(_input.text.trim());
    if (uri == null || uri.scheme != 'ws' || uri.host.isEmpty) return false;
    return !isPrivateOrLoopback(uri.host);
  }

  void _submit() {
    final raw = _input.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = '填一个地址');
      return;
    }
    try {
      // 非公网明文一律放行；公网明文只认用户勾过的那一下。
      checkedRelayUri(
        raw,
        allowInsecureLocal: true,
        allowInsecurePublic: _acknowledged,
      );
      if (_kind == EndpointKind.direct) {
        if (!raw.startsWith('ws://')) {
          setState(() => _error = '直连是明文 ws://（电脑侧监听面不终结 TLS）');
          return;
        }
        // 直连到公网 IP 是"自己把监听面映射到公网"的自部署形态：允许，但要确认。
        if (_needsPlaintextAck && !_acknowledged) {
          setState(() => _error = '公网直连是明文，请先勾选确认');
          return;
        }
      }
    } on ProtocolException catch (error) {
      setState(() => _error = error.message);
      return;
    }
    Navigator.of(context).pop((
      endpoint: Endpoint(kind: _kind, url: raw),
      allowPlaintextPublic: _needsPlaintextAck && _acknowledged,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return AlertDialog(
      backgroundColor: c.layer1,
      title: const Text('添加端点'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                for (final kind in EndpointKind.values) ...[
                  ChoiceChip(
                    label: Text(endpointKindLabel(kind)),
                    selected: _kind == kind,
                    onSelected: (_) => setState(() {
                      _kind = kind;
                      _error = null;
                    }),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _input,
              autofocus: true,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              decoration: InputDecoration(
                hintText: _kind == EndpointKind.direct
                    ? 'ws://192.168.1.4:8790'
                    : 'wss://relay.example.com',
                hintStyle: const TextStyle(fontSize: 12),
                errorText: _error,
                errorMaxLines: 2,
              ),
              // 每一键都重建：确认框的出现与否取决于当前输入。
              onChanged: (_) => setState(() => _error = null),
            ),
            const SizedBox(height: 8),
            Text(
              _kind == EndpointKind.direct
                  ? '直连不走中转、不要票：填电脑侧直连监听面的地址（局域网 ip，或映射到公网的自部署地址）。'
                  : '中转要换票：填中转的根地址（不带路径）。有域名用 wss；只有公网 IP 时可以用 ws（明文）。',
              style: TextStyle(fontSize: 11, color: c.labelTertiary),
            ),
            if (_needsPlaintextAck) ...[
              const SizedBox(height: 4),
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _acknowledged,
                onChanged: (value) =>
                    setState(() => _acknowledged = value == true),
                title: Text(
                  '我了解：这是公网明文（ws://）。内容仍端到端加密，'
                  '网络上的元数据（帧大小与时序）可见。',
                  style: TextStyle(fontSize: 11, color: c.stateError),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(onPressed: _submit, child: const Text('添加')),
      ],
    );
  }
}
