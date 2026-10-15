/// 配对用的二维码取景页（"扫一扫"）。
///
/// ## 它只做一件事:把摄像头看到的二维码**内容**交出去
///
/// 这一页不认识配对协议、不认识 JSON 形状 —— 它只负责取景 + 解码,
/// 把得到的字符串返回给调用方(`PairingPage._scan`),由那条既有的配对链处理。
/// 另写一条配对路径会让"配对怎么走"有两个答案,而它们迟早不一致。
///
/// ## 三条刻意的选择
///
/// - **扫到就退,不自动开始配对**:把"扫到了"与"开始连电脑"分开,
///   调用方才能在回退栈之外决定下一步(例如先让用户核对电脑身份)。
/// - **不自动重试**:同一张二维码被反复扫到时只回一次;要再扫得再进这一页。
///   否则用户会在一页之内被连续触发多次配对。
/// - **权限被拒时给一条出路**:摄像头权限是运行时权限,被拒了要说清
///   "去哪开",而不是留一个黑屏 —— 黑屏会被理解成"扫码坏了"。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../theme/dsh_colors.dart';
import '../theme/dsh_icons.dart';

/// 二维码取景。返回扫到的内容;用户按返回或取消时返回 `null`。
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  final _controller = MobileScannerController(
    // 只认二维码:多认几种格式会让误扫的概率上去,而这里只等一种。
    formats: const [BarcodeFormat.qrCode],
    // 不需要为省电做太多事:这一页的寿命通常只有几秒。
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  /// 已经回过一次了(同一张码只回一次,见文件头)。
  bool _returned = false;

  @override
  void dispose() {
    unawaited(_controller.dispose());
    super.dispose();
  }

  void _finish(String? value) {
    if (_returned) return;
    _returned = true;
    // 取景页的寿命通常只有几秒,不等这一帧的退出动画。
    unawaited(Navigator.of(context).maybePop(value));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: DshColors.labelPrimary,
        title: const Text('扫一扫'),
        leading: IconButton(
          tooltip: '返回',
          onPressed: () => _finish(null),
          icon: const DshIcon(
            'chevronLeft',
            size: 20,
            color: DshColors.labelPrimary,
          ),
        ),
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            // **取景失败不静默**:相机起不来(权限被拒 / 被别的东西占用)时
            // 必须说清原因,否则用户看到的是黑屏,而那会被理解成"扫码坏了"。
            errorBuilder: (context, error) => _ProblemBox(
              title: '摄像头用不了',
              detail: error.errorCode.name,
              onCancel: () => _finish(null),
            ),
            onDetect: (capture) {
              final barcode = capture.barcodes.firstOrNull;
              final raw = barcode?.rawValue;
              // 空码(扫到但解不出内容)不当成功:回一个空串会让调用方
              // 走进"解析二维码"然后失败,而真因是这一帧就没内容。
              if (raw == null || raw.isEmpty) return;
              _finish(raw);
            },
          ),
        ],
      ),
    );
  }
}

/// 取景失败时的说明(黑屏会被理解成"功能坏了",所以必须有话)。
class _ProblemBox extends StatelessWidget {
  const _ProblemBox({
    required this.title,
    required this.detail,
    required this.onCancel,
  });

  final String title;
  final String detail;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const DshIcon(
              'warningTriangle',
              size: 40,
              color: DshColors.labelTertiary,
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(
                fontSize: 15,
                color: DshColors.labelSecondary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                color: DshColors.labelTertiary,
              ),
            ),
            const SizedBox(height: 20),
            OutlinedButton(onPressed: onCancel, child: const Text('返回')),
          ],
        ),
      ),
    );
  }
}
