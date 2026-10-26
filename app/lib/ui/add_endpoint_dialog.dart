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
/// 允许什么地址是**安全边界**（`core/endpoint.dart` 的 `checkedRelayUri`：公网必须 wss、
/// 明文只限非公网）。`AppModel.addManualEndpoint` 只存值 —— 两处各判一遍就会漂。
///
/// **直连只收 `ws://`**：电脑侧监听面刻意不终结 TLS（`connector/src/transport/listener.ts`），
/// 所以直连地址就是明文；写成 `wss://` 反而拨不通。
library;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../core/endpoint.dart';
import '../core/errors.dart';
import '../model/chat_item.dart' show endpointKindLabel;
import '../theme/dsh_colors.dart';

/// 弹「添加端点」并返回用户填的那一条（取消 / 校验失败 ⇒ `null`）。
Future<Endpoint?> showAddEndpointDialog(
  BuildContext context, {
  EndpointKind initialKind = EndpointKind.direct,
}) => showDialog<Endpoint>(
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

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit() {
    final raw = _input.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = '填一个地址');
      return;
    }
    try {
      // 过安全边界：公网必须 wss、明文只限非公网。
      checkedRelayUri(raw, allowInsecureLocal: kDebugMode);
      if (_kind == EndpointKind.direct) {
        if (!raw.startsWith('ws://')) {
          setState(() => _error = '直连是明文 ws://（电脑侧监听面不终结 TLS）');
          return;
        }
        if (!isPrivateOrLoopback(Uri.parse(raw).host)) {
          setState(() => _error = '直连地址必须是局域网 / 回环地址');
          return;
        }
      }
    } on ProtocolException catch (error) {
      setState(() => _error = error.message);
      return;
    }
    Navigator.of(context).pop(Endpoint(kind: _kind, url: raw));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.dshColors;
    return AlertDialog(
      backgroundColor: c.layer1,
      title: const Text('添加端点'),
      content: Column(
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
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          const SizedBox(height: 8),
          Text(
            _kind == EndpointKind.direct
                ? '直连不走中转、不要票：填电脑侧直连监听面的地址。'
                : '中转要换票：填中转的根地址（不带路径）。',
            style: TextStyle(fontSize: 11, color: c.labelTertiary),
          ),
        ],
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
