/// 安卓实现：`dsh/notifications` 通道（原生在 `MainActivity.registerNotifications`
/// 与 `DshForegroundService` / `DshActionReceiver`）。
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../core/notify.dart';

class AndroidNotify implements NotifyPort {
  AndroidNotify({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dsh/notifications') {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  final _approvals = StreamController<NotifyApproval>.broadcast();

  /// 原生 → Dart：只认 `approval`（其余一律忽略，不抛 —— 前向兼容）。
  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'approval') return;
    final arguments = call.arguments;
    if (arguments is! Map) return;
    final itemId = arguments['itemId'];
    final outcome = arguments['outcome'];
    if (itemId is! String || itemId.isEmpty) return;
    _approvals.add(
      NotifyApproval(itemId: itemId, allowedOnce: outcome == 'allowed-once'),
    );
  }

  @override
  Stream<NotifyApproval> get approvals => _approvals.stream;

  @override
  Future<NotifyStatus> status() async {
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('status');
      return NotifyStatus(
        granted: raw?['granted'] == true,
        keepAlive: raw?['keepAlive'] == true,
      );
    } on PlatformException {
      // 拿不到就是"不知道" —— 调用方按"没有权限"处理（fail-closed：
      // 不起服务、不贴通知）。
      return const NotifyStatus(granted: false, keepAlive: false);
    } on MissingPluginException {
      return const NotifyStatus(granted: false, keepAlive: false);
    }
  }

  @override
  Future<bool> requestPermission() async {
    try {
      return await _channel.invokeMethod<bool>('requestPermission') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> startKeepAlive({
    required String title,
    required String text,
  }) async {
    try {
      await _channel.invokeMethod<void>('startKeepAlive', {
        'title': title,
        'text': text,
      });
    } on PlatformException {
      // 起不来（ROM 拒绝 / 前台服务被禁）**不静默**：调用方下一拍
      // `status()` 会看到 `keepAlive: false`，界面据此说"没保住"。
    } on MissingPluginException {
      // 非安卓宿主：什么都不做（这个类只在安卓上被选中）。
    }
  }

  @override
  Future<void> stopKeepAlive() async {
    try {
      await _channel.invokeMethod<void>('stopKeepAlive');
    } on PlatformException {
      // 停不掉没有后果：服务随进程走。
    } on MissingPluginException {
      // 同上。
    }
  }

  @override
  Future<bool> show(AttentionNotice notice) async {
    try {
      return await _channel.invokeMethod<bool>('show', {
            'id': notice.id,
            'title': notice.title,
            'text': notice.body,
            if (notice.itemId != null) 'itemId': notice.itemId,
            if (notice.allowLabel != null) 'allowLabel': notice.allowLabel,
            if (notice.denyLabel != null) 'denyLabel': notice.denyLabel,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> cancel(int id) async {
    try {
      await _channel.invokeMethod<void>('cancel', {'id': id});
    } on PlatformException {
      // 撤不掉没有后果（通知会随 App 回前台被撤一批）。
    } on MissingPluginException {
      // 同上。
    }
  }

  @override
  Future<void> cancelAll() async {
    try {
      await _channel.invokeMethod<void>('cancelAll');
    } on PlatformException {
      // 同上。
    } on MissingPluginException {
      // 同上。
    }
  }

  @override
  Future<void> openChannelSettings() async {
    try {
      await _channel.invokeMethod<void>('openChannelSettings');
    } on PlatformException {
      // 系统没有那个设置页（极少数 ROM）：不做兜底跳转，用户自己进设置。
    } on MissingPluginException {
      // 同上。
    }
  }

  @override
  Future<void> close() async {
    _channel.setMethodCallHandler(null);
    await _approvals.close();
  }
}
